import Foundation

struct SimulatorDevice: Hashable, Sendable {
    var udid: String
    var name: String
    var runtimeIdentifier: String
    var osVersion: String
    var isBooted: Bool
    var dataPath: String?

    var runtimeName: String {
        osVersion.isEmpty ? "iOS" : "iOS \(osVersion)"
    }
}

struct PhysicalIOSDevice: Hashable, Sendable {
    /// CoreDevice identifier, used as the transport ID for `devicectl` commands.
    var identifier: String
    /// Hardware UDID, stable across pairings and used as the alias key.
    var hardwareUDID: String
    var name: String
    var marketingName: String
    var osVersion: String
    var isConnected: Bool
}

/// Discovers iOS simulators and physical iOS devices through Xcode's command line tools.
///
/// Unlike ADB, neither tool can be bundled with Lens, so every call fails cleanly with
/// `toolchainMissing` when Xcode is not installed.
struct IOSDeviceService: Sendable {
    private let runner: any CommandRunning
    private let toolchainProvider: @Sendable () -> XcodeToolchain?

    init(
        runner: any CommandRunning = CommandRunner(),
        toolchainProvider: @escaping @Sendable () -> XcodeToolchain? = { XcodeToolchain.resolve() }
    ) {
        self.runner = runner
        self.toolchainProvider = toolchainProvider
    }

    var isAvailable: Bool { toolchainProvider() != nil }
    var developerDirectoryPath: String? { toolchainProvider()?.developerDirectory.path }

    // MARK: - Discovery

    func discoverSimulators() async throws -> [SimulatorDevice] {
        let toolchain = try requireToolchain()
        let result = try await runner.run(
            toolchain.simctlURL,
            arguments: ["list", "devices", "--json"],
            input: nil,
            timeout: 15
        )
        guard result.status == 0 else {
            throw IOSDeviceError.commandFailed("simctl list", result.errorOutput.isEmpty ? result.output : result.errorOutput)
        }
        return Self.parseSimulators(Data(result.output.utf8))
    }

    func discoverPhysicalDevices() async throws -> [PhysicalIOSDevice] {
        let toolchain = try requireToolchain()
        guard FileManager.default.isExecutableFile(atPath: toolchain.devicectlURL.path) else { return [] }
        // devicectl only emits JSON to a file, never to standard output.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lens-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let result = try await runner.run(
            toolchain.devicectlURL,
            arguments: ["list", "devices", "--json-output", outputURL.path],
            input: nil,
            timeout: 20
        )
        guard let data = try? Data(contentsOf: outputURL) else {
            guard result.status == 0 else {
                throw IOSDeviceError.commandFailed(
                    "devicectl list",
                    result.errorOutput.isEmpty ? result.output : result.errorOutput
                )
            }
            return []
        }
        return Self.parsePhysicalDevices(data)
    }

    // MARK: - Simulator control

    /// Boots a simulator and waits for the OS to finish coming up.
    ///
    /// `simctl boot` returns as soon as the device state flips to `Booted`, long before
    /// SpringBoard can open a URL. `bootstatus -b` boots if needed and returns only once
    /// booting has actually completed.
    func boot(simulator udid: String) async throws {
        let toolchain = try requireToolchain()
        let result = try await runner.run(
            toolchain.simctlURL,
            arguments: ["bootstatus", udid, "-b"],
            input: nil,
            timeout: 300
        )
        // A simulator that another process already booted is a success for Lens.
        guard result.status == 0 || Self.describesAlreadyBooted(result) else {
            throw IOSDeviceError.bootFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
        }
    }

    func waitUntilBooted(udid: String, timeout: Duration = .seconds(90)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if try await discoverSimulators().first(where: { $0.udid == udid })?.isBooted == true { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw IOSDeviceError.bootTimedOut(udid)
    }

    /// Adds the mitmproxy CA to a simulator's trusted root store.
    ///
    /// `simctl keychain` rejects a shut-down simulator, so callers must boot first.
    func installRootCertificate(udid: String, certificateURL: URL) async throws {
        let toolchain = try requireToolchain()
        guard FileManager.default.fileExists(atPath: certificateURL.path) else {
            throw IOSDeviceError.certificateMissing
        }
        let result = try await runner.run(
            toolchain.simctlURL,
            arguments: ["keychain", udid, "add-root-cert", certificateURL.path],
            input: nil,
            timeout: 30
        )
        guard result.status == 0 else {
            throw IOSDeviceError.certificateInstallFailed(
                result.errorOutput.isEmpty ? result.output : result.errorOutput
            )
        }
    }

    func openURL(_ url: String, onSimulator udid: String) async throws {
        let toolchain = try requireToolchain()
        let result = try await runner.run(
            toolchain.simctlURL,
            arguments: ["openurl", udid, url],
            input: nil,
            timeout: 60
        )
        guard result.status == 0 else {
            throw IOSDeviceError.commandFailed("simctl openurl", result.errorOutput.isEmpty ? result.output : result.errorOutput)
        }
    }

    // MARK: - Parsing

    static func parseSimulators(_ data: Data) -> [SimulatorDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: Any] else { return [] }

        var simulators: [SimulatorDevice] = []
        for runtimeIdentifier in devicesByRuntime.keys.sorted() {
            // Lens debugs iOS and iPadOS apps; watchOS, tvOS and visionOS runtimes are noise.
            guard runtimeIdentifier.contains(".iOS-"),
                  let entries = devicesByRuntime[runtimeIdentifier] as? [[String: Any]] else { continue }
            let osVersion = osVersion(fromRuntimeIdentifier: runtimeIdentifier)
            for entry in entries {
                guard let udid = entry["udid"] as? String,
                      let name = entry["name"] as? String,
                      entry["isAvailable"] as? Bool != false else { continue }
                simulators.append(
                    SimulatorDevice(
                        udid: udid,
                        name: name,
                        runtimeIdentifier: runtimeIdentifier,
                        osVersion: osVersion,
                        isBooted: (entry["state"] as? String) == "Booted",
                        dataPath: entry["dataPath"] as? String
                    )
                )
            }
        }
        return simulators
    }

    static func parsePhysicalDevices(_ data: Data) -> [PhysicalIOSDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let entries = result["devices"] as? [[String: Any]] else { return [] }

        return entries.compactMap { entry in
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = entry["deviceProperties"] as? [String: Any] ?? [:]
            let connection = entry["connectionProperties"] as? [String: Any] ?? [:]
            guard let identifier = entry["identifier"] as? String,
                  (hardware["platform"] as? String) == "iOS",
                  (hardware["reality"] as? String) != "simulated" else { return nil }
            let name = (properties["name"] as? String) ?? (hardware["marketingName"] as? String) ?? identifier
            return PhysicalIOSDevice(
                identifier: identifier,
                hardwareUDID: (hardware["udid"] as? String) ?? identifier,
                name: name,
                marketingName: (hardware["marketingName"] as? String) ?? name,
                osVersion: (properties["osVersionNumber"] as? String) ?? "",
                // A paired but unplugged iPhone reports an unavailable tunnel.
                isConnected: (connection["tunnelState"] as? String).map { $0 != "unavailable" } ?? false
            )
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-5` becomes `26.5`.
    static func osVersion(fromRuntimeIdentifier identifier: String) -> String {
        guard let range = identifier.range(of: ".iOS-") else { return "" }
        return identifier[range.upperBound...].replacingOccurrences(of: "-", with: ".")
    }

    private static func describesAlreadyBooted(_ result: CommandResult) -> Bool {
        let text = result.errorOutput + result.output
        return text.contains("Unable to boot device in current state: Booted")
            || text.contains("current state: Booted")
    }

    private func requireToolchain() throws -> XcodeToolchain {
        guard let toolchain = toolchainProvider() else { throw IOSDeviceError.toolchainMissing }
        return toolchain
    }
}

enum IOSDeviceError: LocalizedError, Equatable {
    case toolchainMissing
    case commandFailed(String, String)
    case bootFailed(String)
    case bootTimedOut(String)
    case certificateMissing
    case certificateInstallFailed(String)
    case guidedAttachmentRequired(String)

    var errorDescription: String? {
        switch self {
        case .toolchainMissing:
            "Xcode was not found. Install Xcode to let Lens discover iOS simulators and devices."
        case let .commandFailed(tool, message):
            "\(tool) failed: \(message)"
        case let .bootFailed(message):
            "Lens could not boot the simulator: \(message)"
        case let .bootTimedOut(udid):
            "Simulator \(udid) did not finish booting in time."
        case .certificateMissing:
            "The Lens certificate is not ready yet. Start the proxy engine and try again."
        case let .certificateInstallFailed(message):
            "Lens could not add its certificate to the simulator's trust store: \(message)"
        case let .guidedAttachmentRequired(name):
            "\(name) is a physical iPhone or iPad. Configure its Wi-Fi proxy manually to route traffic through Lens."
        }
    }
}
