import Foundation

struct HostProxySetting: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var host: String
    var port: Int

    var displayValue: String {
        guard isEnabled, !host.isEmpty else { return "None" }
        return "\(host):\(port)"
    }
}

struct HostProxySnapshot: Codable, Hashable, Sendable {
    var serviceName: String
    var web: HostProxySetting
    var secureWeb: HostProxySetting
}

/// Reads and writes the macOS system HTTP(S) proxy for the primary network service.
///
/// An iOS simulator has no network stack of its own: it uses the Mac's, and CFNetwork
/// inside the simulator reads the host's proxy configuration. Routing simulator traffic
/// into Lens therefore means changing a system setting, which needs administrator
/// rights. Lens is ad-hoc signed and cannot install a privileged helper, so writes go
/// through one `osascript` authorization prompt.
@MainActor
@Observable
final class HostProxyController {
    private static let snapshotKey = "hostProxySnapshotBeforeLens"

    private(set) var appliedPort: Int?

    private let runner: any CommandRunning
    private let defaults: UserDefaults
    private let authorizer: any PrivilegedCommandAuthorizing

    var isApplied: Bool { appliedPort != nil }

    init(
        defaults: UserDefaults = .standard,
        runner: any CommandRunning = CommandRunner(),
        authorizer: any PrivilegedCommandAuthorizing = AppleScriptPrivilegedAuthorizer()
    ) {
        self.defaults = defaults
        self.runner = runner
        self.authorizer = authorizer
    }

    // MARK: - Reading

    /// Resolves the network service that carries the default route.
    func primaryServiceName() async throws -> String {
        let routeOutput = try await networksetupSibling(
            URL(fileURLWithPath: "/sbin/route"),
            arguments: ["-n", "get", "default"]
        )
        guard let interface = Self.parseDefaultRouteInterface(routeOutput) else {
            throw HostProxyError.primaryServiceUnavailable
        }
        let order = try await networksetup(["-listnetworkserviceorder"])
        guard let service = Self.parseServiceName(forInterface: interface, in: order) else {
            throw HostProxyError.primaryServiceUnavailable
        }
        guard Self.isSafeServiceName(service) else {
            throw HostProxyError.unsupportedServiceName(service)
        }
        return service
    }

    func readSnapshot(serviceName: String) async throws -> HostProxySnapshot {
        let web = try await networksetup(["-getwebproxy", serviceName])
        let secure = try await networksetup(["-getsecurewebproxy", serviceName])
        return HostProxySnapshot(
            serviceName: serviceName,
            web: Self.parseProxySetting(web),
            secureWeb: Self.parseProxySetting(secure)
        )
    }

    // MARK: - Writing

    /// Points the host proxy at Lens, remembering the previous configuration first.
    ///
    /// A snapshot is only taken the first time so that attaching a second simulator
    /// never records Lens's own settings as the value to restore.
    func apply(port: Int, host: String = "127.0.0.1") async throws {
        guard (1...65_535).contains(port) else { throw HostProxyError.invalidPort(port) }
        guard Self.isSafeHost(host) else { throw HostProxyError.invalidHost(host) }

        let service = try await primaryServiceName()
        var didStoreSnapshot = false
        if storedSnapshot() == nil {
            store(try await readSnapshot(serviceName: service))
            didStoreSnapshot = true
        }
        do {
            try await authorize(
                commands: [
                    ["-setwebproxy", service, host, String(port)],
                    ["-setsecurewebproxy", service, host, String(port)],
                    ["-setwebproxystate", service, "on"],
                    ["-setsecurewebproxystate", service, "on"]
                ],
                reason: "Lens needs administrator rights to route iOS simulator traffic through its proxy."
            )
        } catch {
            // Nothing was changed, so keeping the snapshot would make the next launch ask
            // for a password to "restore" settings Lens never touched.
            if didStoreSnapshot { clearStoredSnapshot() }
            throw error
        }
        appliedPort = port
    }

    /// Restores the configuration captured before Lens changed it.
    func restore() async throws {
        guard let snapshot = storedSnapshot() else {
            appliedPort = nil
            return
        }
        var commands: [[String]] = []
        if !snapshot.web.host.isEmpty {
            commands.append(["-setwebproxy", snapshot.serviceName, snapshot.web.host, String(snapshot.web.port)])
        }
        if !snapshot.secureWeb.host.isEmpty {
            commands.append(
                ["-setsecurewebproxy", snapshot.serviceName, snapshot.secureWeb.host, String(snapshot.secureWeb.port)]
            )
        }
        commands.append(["-setwebproxystate", snapshot.serviceName, snapshot.web.isEnabled ? "on" : "off"])
        commands.append(
            ["-setsecurewebproxystate", snapshot.serviceName, snapshot.secureWeb.isEnabled ? "on" : "off"]
        )
        try await authorize(
            commands: commands,
            reason: "Lens needs administrator rights to restore your previous proxy settings."
        )
        clearStoredSnapshot()
        appliedPort = nil
    }

    /// True when a previous Lens run left the host proxy pointing at Lens.
    var hasRecoverableSnapshot: Bool { storedSnapshot() != nil }

    func storedSnapshot() -> HostProxySnapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey) else { return nil }
        return try? JSONDecoder().decode(HostProxySnapshot.self, from: data)
    }

    // MARK: - Parsing

    static func parseDefaultRouteInterface(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == "interface" else { continue }
            let interface = fields[1].trimmingCharacters(in: .whitespaces)
            return interface.isEmpty ? nil : interface
        }
        return nil
    }

    /// `networksetup -listnetworkserviceorder` pairs a service name line with a
    /// following hardware line that names the BSD device.
    static func parseServiceName(forInterface interface: String, in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        for (index, line) in lines.enumerated() {
            guard line.contains("Device: \(interface))") else { continue }
            guard index > 0 else { return nil }
            let serviceLine = lines[index - 1].trimmingCharacters(in: .whitespaces)
            guard let range = serviceLine.range(of: #"^\(\*?\d+\)\s*"#, options: .regularExpression) else { continue }
            let name = String(serviceLine[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    static func parseProxySetting(_ output: String) -> HostProxySetting {
        var isEnabled = false
        var host = ""
        var port = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            switch fields[0].trimmingCharacters(in: .whitespaces) {
            case "Enabled": isEnabled = value == "Yes"
            case "Server": host = value
            case "Port": port = Int(value) ?? 0
            default: break
            }
        }
        return HostProxySetting(isEnabled: isEnabled, host: host, port: port)
    }

    /// Network service names reach a shell, so anything outside this set is refused
    /// rather than escaped.
    static func isSafeServiceName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { character in
            character.isLetter || character.isNumber || " -_.()/".contains(character)
        }
    }

    static func isSafeHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 255 && host.allSatisfy { character in
            character.isLetter || character.isNumber || ".-:".contains(character)
        }
    }

    /// Wraps every argument in single quotes so a service name such as
    /// `Wi-Fi (USB 10/100/1000 LAN)` survives `/bin/sh`.
    static func shellCommand(_ arguments: [String]) -> String {
        (["/usr/sbin/networksetup"] + arguments)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }

    static func appleScript(for commands: [[String]]) -> String {
        let shell = commands.map(shellCommand).joined(separator: " && ")
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    // MARK: - Helpers

    private func authorize(commands: [[String]], reason: String) async throws {
        guard !commands.isEmpty else { return }
        try await authorizer.run(script: Self.appleScript(for: commands), reason: reason)
    }

    private func store(_ snapshot: HostProxySnapshot) {
        defaults.set(try? JSONEncoder().encode(snapshot), forKey: Self.snapshotKey)
    }

    private func clearStoredSnapshot() {
        defaults.removeObject(forKey: Self.snapshotKey)
    }

    private func networksetup(_ arguments: [String]) async throws -> String {
        try await networksetupSibling(URL(fileURLWithPath: "/usr/sbin/networksetup"), arguments: arguments)
    }

    private func networksetupSibling(_ executable: URL, arguments: [String]) async throws -> String {
        let result = try await runner.run(executable, arguments: arguments, input: nil, timeout: 10)
        guard result.status == 0 else {
            throw HostProxyError.commandFailed(
                executable.lastPathComponent,
                result.errorOutput.isEmpty ? result.output : result.errorOutput
            )
        }
        return result.output
    }
}

// MARK: - Authorization

protocol PrivilegedCommandAuthorizing: Sendable {
    func run(script: String, reason: String) async throws
}

/// Runs a privileged command through the standard macOS authorization dialog.
struct AppleScriptPrivilegedAuthorizer: PrivilegedCommandAuthorizing {
    private let runner: any CommandRunning

    init(runner: any CommandRunning = CommandRunner()) {
        self.runner = runner
    }

    func run(script: String, reason: String) async throws {
        let result = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script],
            input: nil,
            // Generous: the user has to read the dialog and type a password.
            timeout: 180
        )
        guard result.status == 0 else {
            let message = result.errorOutput.isEmpty ? result.output : result.errorOutput
            if message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled") {
                throw HostProxyError.authorizationDeclined
            }
            throw HostProxyError.commandFailed("networksetup", message)
        }
    }
}

enum HostProxyError: LocalizedError, Equatable {
    case primaryServiceUnavailable
    case unsupportedServiceName(String)
    case invalidPort(Int)
    case invalidHost(String)
    case authorizationDeclined
    case commandFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .primaryServiceUnavailable:
            "Lens could not determine the active network service. Connect to a network and try again."
        case let .unsupportedServiceName(name):
            "The network service \"\(name)\" contains characters Lens will not pass to a privileged command."
        case let .invalidPort(port):
            "\(port) is not a usable proxy port."
        case let .invalidHost(host):
            "\"\(host)\" is not a usable proxy host."
        case .authorizationDeclined:
            "Administrator approval is required to route iOS simulator traffic through Lens."
        case let .commandFailed(tool, message):
            "\(tool) failed: \(message)"
        }
    }
}
