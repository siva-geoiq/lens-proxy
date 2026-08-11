import Darwin
import Foundation
import Observation

struct CommandResult: Sendable {
    var output: String
    var errorOutput: String
    var status: Int32
}

final class CommandRunner: @unchecked Sendable {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let error = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = error
                do {
                    try process.run()
                    if let timeout {
                        let deadline = Date().addingTimeInterval(timeout)
                        while process.isRunning && Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        if process.isRunning {
                            process.terminate()
                            let terminationDeadline = Date().addingTimeInterval(0.5)
                            while process.isRunning && Date() < terminationDeadline {
                                Thread.sleep(forTimeInterval: 0.01)
                            }
                            if process.isRunning {
                                kill(process.processIdentifier, SIGKILL)
                                process.waitUntilExit()
                            }
                            continuation.resume(throwing: CommandRunnerError.timedOut(executable.lastPathComponent, timeout))
                            return
                        }
                    } else {
                        process.waitUntilExit()
                    }
                    let outputData = output.fileHandleForReading.readDataToEndOfFile()
                    let errorData = error.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(
                        returning: CommandResult(
                            output: String(data: outputData, encoding: .utf8) ?? "",
                            errorOutput: String(data: errorData, encoding: .utf8) ?? "",
                            status: process.terminationStatus
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
@Observable
final class DeviceManager {
    private(set) var devices: [DeviceTarget] = []
    private(set) var isRefreshing = false
    private(set) var activeVPNPackage: String?
    var adbPath: String?

    private let runner = CommandRunner()
    private let preferences: DeviceAttachmentPreferences
    private let defaults: UserDefaults
    private var attachedSnapshots: [String: ProxySnapshot] = [:]
    private var overlaySerials = Set<String>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = DeviceAttachmentPreferences(defaults: defaults)
        adbPath = locateADB()?.path
        loadSnapshots()
    }

    var lastAttachedEmulatorSerial: String? {
        preferences.lastEmulatorSerial
    }

    var preferredDetachedDevice: DeviceTarget? {
        if let serial = preferences.lastEmulatorSerial,
           let remembered = devices.first(where: { $0.serial == serial && !$0.isAttached }) {
            return remembered
        }
        return devices.first { $0.kind == .emulator && !$0.isAttached }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await adb(["devices", "-l"])
            let serials = result.output
                .split(separator: "\n")
                .dropFirst()
                .compactMap { line -> String? in
                    let fields = line.split(separator: " ")
                    guard fields.count > 1, fields[1] == "device" else { return nil }
                    return String(fields[0])
                }
            var discovered: [DeviceTarget] = []
            for serial in serials {
                let model = try await shell(serial, ["getprop", "ro.product.model"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
                let apiText = try await shell(serial, ["getprop", "ro.build.version.sdk"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
                let rootOutput = try await shell(serial, ["id", "-u"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
                let addressOutput = (try? await shell(serial, ["ip", "-o", "-4", "addr", "show", "scope", "global"]).output) ?? ""
                let networkAddresses = addressOutput
                    .split(whereSeparator: \.isWhitespace)
                    .compactMap { field -> String? in
                        guard field.contains("/"), let address = field.split(separator: "/").first,
                              address.split(separator: ".").count == 4 else { return nil }
                        return String(address)
                    }
                let kind: DeviceKind = serial.hasPrefix("emulator-") ? .emulator : .physical
                discovered.append(
                    DeviceTarget(
                        serial: serial,
                        model: model.isEmpty ? serial : model,
                        apiLevel: Int(apiText) ?? 0,
                        kind: kind,
                        rootState: rootOutput == "0" ? .available : .unknown,
                        isAttached: attachedSnapshots[serial] != nil,
                        previousProxy: attachedSnapshots[serial],
                        caInstalled: false,
                        networkAddresses: networkAddresses
                    )
                )
            }
            devices = discovered
            await refreshVPNState()
        } catch {
            devices = []
        }
    }

    func attach(_ target: DeviceTarget, proxyPort: Int, stopConflictingVPN: Bool = false) async throws {
        if let activeVPNPackage, !activeVPNPackage.isEmpty {
            guard stopConflictingVPN else { throw DeviceManagerError.vpnConflict(activeVPNPackage) }
            _ = try await shell(target.serial, ["am", "force-stop", activeVPNPackage])
        }

        let snapshot = try await readProxy(target.serial)
        attachedSnapshots[target.serial] = snapshot
        persistSnapshots()

        var rootAvailable = target.rootState == .available
        if target.kind == .emulator && !rootAvailable {
            let root = try await adb(["-s", target.serial, "root"])
            if root.status == 0 {
                _ = try await adb(["-s", target.serial, "wait-for-device"])
                rootAvailable = try await shell(target.serial, ["id", "-u"]).output.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
            }
        }

        if rootAvailable {
            try await installCA(on: target)
        }

        let proxyHost = target.kind == .emulator ? "10.0.2.2" : try localIPAddress()
        _ = try await shell(target.serial, ["settings", "put", "global", "http_proxy", "\(proxyHost):\(proxyPort)"])
        _ = try await shell(target.serial, ["settings", "put", "global", "global_http_proxy_host", proxyHost])
        _ = try await shell(target.serial, ["settings", "put", "global", "global_http_proxy_port", String(proxyPort)])

        if !rootAvailable {
            _ = try await shell(target.serial, ["am", "start", "-a", "android.intent.action.VIEW", "-d", "http://mitm.it"])
        }

        updateDevice(target.serial) {
            $0.isAttached = true
            $0.previousProxy = snapshot
            $0.rootState = rootAvailable ? .available : .unavailable
            $0.caInstalled = rootAvailable
        }
        if target.kind == .emulator {
            preferences.remember(emulatorSerial: target.serial)
        }
    }

    func detach(_ target: DeviceTarget, forgetRememberedDevice: Bool = true) async throws {
        let snapshot = attachedSnapshots[target.serial] ?? target.previousProxy
        if let host = snapshot?.host, let port = snapshot?.port {
            _ = try await shell(target.serial, ["settings", "put", "global", "http_proxy", "\(host):\(port)"])
            _ = try await shell(target.serial, ["settings", "put", "global", "global_http_proxy_host", host])
            _ = try await shell(target.serial, ["settings", "put", "global", "global_http_proxy_port", String(port)])
        } else {
            _ = try await shell(target.serial, ["settings", "put", "global", "http_proxy", ":0"])
            _ = try await shell(target.serial, ["settings", "delete", "global", "global_http_proxy_host"])
            _ = try await shell(target.serial, ["settings", "delete", "global", "global_http_proxy_port"])
        }
        try? await removeCA(from: target)
        attachedSnapshots.removeValue(forKey: target.serial)
        persistSnapshots()
        updateDevice(target.serial) {
            $0.isAttached = false
            $0.previousProxy = nil
            $0.caInstalled = false
        }
        if forgetRememberedDevice, target.kind == .emulator {
            preferences.forget(emulatorSerial: target.serial)
        }
    }

    @discardableResult
    func autoAttachLastEmulator(proxyPort: Int) async throws -> Bool {
        guard let serial = preferences.lastEmulatorSerial,
              let target = devices.first(where: { $0.serial == serial && $0.kind == .emulator }) else {
            return false
        }
        guard !target.isAttached else { return true }
        try await attach(target, proxyPort: proxyPort)
        return true
    }

    func restoreAttachedDevices() {
        Task { await restoreAttachedDevicesAndWait() }
    }

    func restoreAttachedDevicesAndWait() async {
        for target in devices.filter(\.isAttached) {
            try? await detach(target, forgetRememberedDevice: false)
        }
    }

    func recoverPreviousAttachments() async {
        guard !attachedSnapshots.isEmpty else { return }
        await refresh()
        await restoreAttachedDevicesAndWait()
    }

    func useADB(at path: String?) {
        adbPath = path
        defaults.set(path, forKey: "adbPath")
    }

#if DEBUG
    func prepareUITestDevices(_ fixtures: [DeviceTarget]) {
        devices = fixtures
    }
#endif

    private func readProxy(_ serial: String) async throws -> ProxySnapshot {
        let output = try await shell(serial, ["settings", "get", "global", "http_proxy"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output != "null", output != ":0",
              let separator = output.lastIndex(of: ":"),
              let port = Int(output[output.index(after: separator)...]) else {
            return ProxySnapshot(host: nil, port: nil)
        }
        return ProxySnapshot(host: String(output[..<separator]), port: port)
    }

    private func installCA(on target: DeviceTarget) async throws {
        let certificate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mitmproxy/mitmproxy-ca-cert.cer")
        guard FileManager.default.fileExists(atPath: certificate.path) else {
            throw DeviceManagerError.certificateMissing
        }
        let hashResult = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["x509", "-inform", "PEM", "-subject_hash_old", "-in", certificate.path, "-noout"]
        )
        let hash = hashResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { throw DeviceManagerError.certificateHashFailed }
        let filename = "\(hash).0"
        _ = try await adb(["-s", target.serial, "push", certificate.path, "/data/local/tmp/\(filename)"])

        if target.apiLevel >= 34 {
            let certificateDirectory = "/apex/com.android.conscrypt/cacerts"
            let overlayDirectory = "/data/local/tmp/lens-cacerts"
            let markerPath = "\(overlayDirectory)/.lens-overlay"
            _ = try await shell(target.serial, ["mkdir", "-p", overlayDirectory])
            _ = try await shellCommand(target.serial, "cp \(certificateDirectory)/*.0 \(overlayDirectory)/ 2>/dev/null || true")
            _ = try await shell(target.serial, ["cp", "/data/local/tmp/\(filename)", "\(overlayDirectory)/\(filename)"])
            _ = try await shell(target.serial, ["chmod", "755", overlayDirectory])
            _ = try await shellCommand(target.serial, "chmod 644 \(overlayDirectory)/*.0")
            _ = try await shell(target.serial, ["touch", markerPath])

            let mountState = try await shell(target.serial, ["mount"])
            if !mountState.output.contains("tmpfs on \(certificateDirectory)") {
                _ = try await shell(target.serial, ["mount", "-t", "tmpfs", "tmpfs", certificateDirectory])
                overlaySerials.insert(target.serial)
            }
            try await populateCertificateOverlay(
                serial: target.serial,
                namespacePID: nil,
                sourceDirectory: overlayDirectory,
                certificateDirectory: certificateDirectory,
                filename: filename
            )

            let zygoteOutput = try await shell(target.serial, ["pidof", "zygote", "zygote64"])
            for pid in zygoteOutput.output.split(whereSeparator: \.isWhitespace).map(String.init) {
                let namespaceMounts = try await shell(
                    target.serial,
                    ["nsenter", "--mount=/proc/\(pid)/ns/mnt", "--", "mount"]
                )
                if !namespaceMounts.output.contains("tmpfs on \(certificateDirectory)") {
                    _ = try await shell(
                        target.serial,
                        ["nsenter", "--mount=/proc/\(pid)/ns/mnt", "--", "mount", "-t", "tmpfs", "tmpfs", certificateDirectory]
                    )
                }
                try await populateCertificateOverlay(
                    serial: target.serial,
                    namespacePID: pid,
                    sourceDirectory: overlayDirectory,
                    certificateDirectory: certificateDirectory,
                    filename: filename
                )
            }
        } else {
            _ = try? await adb(["-s", target.serial, "remount"])
            _ = try await shell(target.serial, ["cp", "/data/local/tmp/\(filename)", "/system/etc/security/cacerts/\(filename)"])
            _ = try await shell(target.serial, ["chmod", "644", "/system/etc/security/cacerts/\(filename)"])
        }
    }

    private func removeCA(from target: DeviceTarget) async throws {
        let certificate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mitmproxy/mitmproxy-ca-cert.cer")
        guard FileManager.default.fileExists(atPath: certificate.path) else { return }
        let hash = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["x509", "-inform", "PEM", "-subject_hash_old", "-in", certificate.path, "-noout"]
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { return }
        _ = try? await shell(target.serial, ["rm", "-f", "/system/etc/security/cacerts/\(hash).0"])
        _ = try? await shell(target.serial, ["rm", "-f", "/data/local/tmp/\(hash).0"])
        let certificateDirectory = "/apex/com.android.conscrypt/cacerts"
        let overlayDirectory = "/data/local/tmp/lens-cacerts"
        let marker = try? await shell(target.serial, ["test", "-f", "\(overlayDirectory)/.lens-overlay"])
        if marker?.status == 0 {
            let zygoteOutput = try? await shell(target.serial, ["pidof", "zygote", "zygote64"])
            for pid in zygoteOutput?.output.split(whereSeparator: \.isWhitespace).map(String.init) ?? [] {
                _ = try? await shell(
                    target.serial,
                    ["nsenter", "--mount=/proc/\(pid)/ns/mnt", "--", "umount", certificateDirectory]
                )
            }
            _ = try? await shell(target.serial, ["umount", certificateDirectory])
            _ = try? await shell(target.serial, ["rm", "-rf", overlayDirectory])
            overlaySerials.remove(target.serial)
        } else {
            _ = try? await shell(target.serial, ["rm", "-f", "\(certificateDirectory)/\(hash).0"])
        }
    }

    private func populateCertificateOverlay(
        serial: String,
        namespacePID: String?,
        sourceDirectory: String,
        certificateDirectory: String,
        filename: String
    ) async throws {
        let namespacePrefix = namespacePID.map { ["nsenter", "--mount=/proc/\($0)/ns/mnt", "--"] } ?? []
        _ = try await shell(
            serial,
            namespacePrefix + ["cp", "-a", "\(sourceDirectory)/.", "\(certificateDirectory)/"]
        )
        _ = try await shell(serial, namespacePrefix + ["chmod", "644", "\(certificateDirectory)/\(filename)"])
        _ = try await shell(
            serial,
            namespacePrefix + ["chcon", "u:object_r:system_security_cacerts_file:s0", "\(certificateDirectory)/\(filename)"]
        )
    }

    private func refreshVPNState() async {
        guard let first = devices.first else {
            activeVPNPackage = nil
            return
        }
        guard let output = try? await shell(first.serial, ["dumpsys", "connectivity"], timeout: 3).output,
              let range = output.range(of: "VPN:") else {
            activeVPNPackage = nil
            return
        }
        let suffix = output[range.upperBound...]
        activeVPNPackage = String(suffix.prefix { !$0.isWhitespace && $0 != "}" })
    }

    private func shell(_ serial: String, _ arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandResult {
        try await adb(["-s", serial, "shell"] + arguments, timeout: timeout)
    }

    private func shellCommand(_ serial: String, _ command: String) async throws -> CommandResult {
        try await adb(["-s", serial, "shell", command])
    }

    private func adb(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandResult {
        guard let adbPath else { throw DeviceManagerError.adbNotFound }
        let result = try await runner.run(URL(fileURLWithPath: adbPath), arguments: arguments, timeout: timeout)
        if result.status != 0 {
            throw DeviceManagerError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
        }
        return result
    }

    private func locateADB() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            defaults.string(forKey: "adbPath"),
            environment["ANDROID_HOME"].map { "\($0)/platform-tools/adb" },
            environment["ANDROID_SDK_ROOT"].map { "\($0)/platform-tools/adb" },
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path,
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb"
        ].compactMap { $0 }
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func localIPAddress() throws -> String {
        var address: String?
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { throw DeviceManagerError.localAddressUnavailable }
        defer { freeifaddrs(pointer) }
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  interface.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.pointee.ifa_addr,
                socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                address = String(decoding: bytes, as: UTF8.self)
                let name = String(cString: interface.pointee.ifa_name)
                if name == "en0" { break }
            }
        }
        guard let address else { throw DeviceManagerError.localAddressUnavailable }
        return address
    }

    private func updateDevice(_ serial: String, mutation: (inout DeviceTarget) -> Void) {
        guard let index = devices.firstIndex(where: { $0.serial == serial }) else { return }
        mutation(&devices[index])
    }

    private func loadSnapshots() {
        guard let data = defaults.data(forKey: "attachedProxySnapshots"),
              let snapshots = try? JSONDecoder().decode([String: ProxySnapshot].self, from: data) else { return }
        attachedSnapshots = snapshots
    }

    private func persistSnapshots() {
        defaults.set(try? JSONEncoder().encode(attachedSnapshots), forKey: "attachedProxySnapshots")
    }
}

enum CommandRunnerError: LocalizedError {
    case timedOut(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command, timeout):
            "\(command) did not finish within \(timeout.formatted()) seconds."
        }
    }
}

enum DeviceManagerError: LocalizedError {
    case adbNotFound
    case commandFailed(String)
    case certificateMissing
    case certificateHashFailed
    case localAddressUnavailable
    case vpnConflict(String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound: "ADB was not found. Select it in Settings or install Android platform-tools."
        case let .commandFailed(message): message.trimmingCharacters(in: .whitespacesAndNewlines)
        case .certificateMissing: "The mitmproxy CA is missing. Start mitmproxy once to generate it."
        case .certificateHashFailed: "Could not calculate the mitmproxy CA certificate hash."
        case .localAddressUnavailable: "No reachable Mac LAN address was found for the physical device."
        case let .vpnConflict(package): "A device VPN is active (\(package)). Confirm stopping it before attaching Lens."
        }
    }
}
