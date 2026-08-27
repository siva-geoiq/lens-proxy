import Darwin
import XCTest
@testable import Lens

/// Hosts used by the interception probes.
///
/// Deliberately not a `.local` name: macOS excludes `*.local` from proxying, which would
/// make the simulator bypass Lens entirely and hide a real failure.
private enum ProbeHost {
    static let mapped = "lens-ios-e2e.test"
    /// A real, resolvable host, so mitmproxy's upstream connection succeeds and only the
    /// client side of TLS is under test.
    static let decryption = "www.googleapis.com"
}

/// Proves that Lens actually intercepts iOS traffic, rather than that it believes it does.
///
/// The simulator test drives a throwaway simulator through the real attach path: boot,
/// trust the Lens CA, point the Mac's system proxy at the running mitmdump, then make the
/// simulator itself issue requests and assert the decrypted flows arrive attributed to
/// that simulator. Because the host proxy is a system setting, macOS asks for
/// administrator approval when the test attaches and again when it detaches.
///
/// Run with:
///     LENS_RUN_IOS_E2E=1 xcodebuild ... -only-testing:LensTests/IOSDeviceEndToEndTests test
@MainActor
final class IOSDeviceEndToEndTests: XCTestCase {

    // MARK: - Simulator interception

    func testSimulatorAttachRoutesAndDecryptsTrafficAttributedToTheSimulator() async throws {
        try requireEndToEndOptIn()
        let toolchain = try requireToolchain()

        let proxyPort = try unusedTCPPort()
        let engine = EngineProcessManager()
        let bridge = BridgeClient()
        let results = CapturedFlows()
        let mappingsConfigured = expectation(description: "Mappings configured")
        let simulatorProbeCaptured = expectation(description: "Simulator HTTPS probe captured")
        let macProbeCaptured = expectation(description: "Mac-origin probe captured")

        let simulatorBody = Data(#"{"source":"ios-simulator"}"#.utf8)
        let macBody = Data(#"{"source":"this-mac"}"#.utf8)
        // Safari on iOS applies HTTPS-First, so a simulator probe must be requested over
        // HTTPS against a resolvable host; that also makes it a real decryption test.
        let rules = [
            makeRule(
                name: "iOS Simulator Probe",
                method: "GET",
                scheme: "https",
                host: ProbeHost.decryption,
                port: 443,
                path: "/lens-ios-e2e-simulator",
                body: simulatorBody,
                order: 0
            ),
            makeRule(
                name: "Mac Origin Probe",
                method: "GET",
                scheme: "http",
                host: ProbeHost.mapped,
                port: 80,
                path: "/mac-probe",
                body: macBody,
                order: 1
            )
        ]

        bridge.onEnvelope = { envelope in
            switch envelope.type {
            case "authenticated":
                bridge.send(type: "setMappings", payload: ["rules": rules], requestID: "ios-e2e-mappings")
            case "mappingsUpdated":
                mappingsConfigured.fulfill()
            case "flowUpsert":
                guard let payload = envelope.payload,
                      let flow = try? payload.decode(FlowRecord.self),
                      flow.responseStatus != nil,
                      results.record(flow) else { return }
                switch flow.mappedRuleName {
                case "iOS Simulator Probe": simulatorProbeCaptured.fulfill()
                case "Mac Origin Probe": macProbeCaptured.fulfill()
                default: break
                }
            case "clientError", "engineError":
                XCTFail(envelope.error?.message ?? "Unexpected bridge error")
            default:
                break
            }
        }

        _ = try engine.start(
            proxyPort: proxyPort,
            onControlPort: { port, controlToken in bridge.connect(port: port, token: controlToken) },
            onLog: { _ in },
            onExit: { _ in }
        )
        defer {
            bridge.disconnect()
            engine.stop()
        }
        await fulfillment(of: [mappingsConfigured], timeout: 20)

        // A throwaway simulator keeps the developer's own simulators untouched.
        let udid = try await createThrowawaySimulator(toolchain: toolchain)
        var simulatorDeleted = false
        defer {
            if !simulatorDeleted {
                let deletion = Task.detached { try? await Self.deleteSimulator(udid: udid, toolchain: toolchain) }
                _ = deletion
            }
        }

        let suiteName = "LensTests.IOSDeviceE2E.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deviceManager = DeviceManager(defaults: defaults)
        let captures = CaptureStore()
        captures.simulatorUDIDResolver = { port in deviceManager.simulatorUDIDByClientPort[port] }

        let proxyBefore = try await readHostProxyState(of: deviceManager)
        try await deviceManager.bootSimulator(udid: udid)
        let target = try XCTUnwrap(
            deviceManager.devices.first { $0.serial == udid },
            "Lens did not discover the booted simulator"
        )
        XCTAssertEqual(target.platform, .ios)
        XCTAssertEqual(target.kind, .emulator)
        XCTAssertEqual(target.attachmentMode, .automatic)

        var attached = false
        do {
            // Raises the administrator prompt: this is the real attach path.
            try await deviceManager.attach(target, proxyPort: proxyPort)
            attached = true
            XCTAssertTrue(deviceManager.hostProxy.isApplied)
            XCTAssertEqual(deviceManager.hostProxy.appliedPort, proxyPort)
            XCTAssertTrue(
                deviceManager.devices.first { $0.serial == udid }?.isAttached == true,
                "The simulator should be marked attached"
            )

            // Safari inside the simulator uses CFNetwork, so it honours the host proxy
            // and the trust store Lens just wrote to.
            try await openURL(
                "https://\(ProbeHost.decryption)/lens-ios-e2e-simulator",
                udid: udid,
                toolchain: toolchain
            )
            // The Mac's own request goes through the same proxy on the same loopback
            // address, which is exactly what attribution has to separate.
            _ = try await runCurl(proxyPort: proxyPort, arguments: ["http://\(ProbeHost.mapped)/mac-probe"])
            await fulfillment(of: [simulatorProbeCaptured, macProbeCaptured], timeout: 120)

            let simulatorFlow = try XCTUnwrap(results.flow(mappedBy: "iOS Simulator Probe"))
            XCTAssertEqual(
                simulatorFlow.responseBody?.data,
                simulatorBody,
                "An HTTPS flow can only be rewritten if the simulator trusted the Lens certificate"
            )
            XCTAssertEqual(simulatorFlow.scheme, "https")
            XCTAssertEqual(
                simulatorFlow.clientAddress,
                "127.0.0.1",
                "Simulator traffic shares the Mac's loopback address, which is why attribution needs the client port"
            )
            XCTAssertNotNil(simulatorFlow.clientPort, "The engine must report the client port for attribution")

            // Attribution has to survive the socket closing, so allow the rolling
            // monitor a moment to catch up before asserting.
            let attributedSimulatorFlow = try await eventuallyAttributed(
                flow: simulatorFlow,
                to: udid,
                captures: captures,
                deviceManager: deviceManager
            )
            XCTAssertEqual(attributedSimulatorFlow.deviceID, udid)
            XCTAssertEqual(attributedSimulatorFlow.deviceName, target.displayName)

            let macFlow = try XCTUnwrap(results.flow(mappedBy: "Mac Origin Probe"))
            XCTAssertEqual(macFlow.responseBody?.data, macBody, "Plain HTTP mappings must still apply")
            XCTAssertNil(
                captures.attributed(macFlow, to: deviceManager.devices).deviceID,
                "This Mac's own request must not be attributed to the simulator"
            )
        } catch {
            if attached { try? await deviceManager.detach(target) }
            try? await Self.deleteSimulator(udid: udid, toolchain: toolchain)
            simulatorDeleted = true
            throw error
        }

        // Detaching restores the proxy configuration captured before the test.
        try await deviceManager.detach(target)
        XCTAssertFalse(deviceManager.hostProxy.isApplied)
        XCTAssertNil(deviceManager.hostProxy.storedSnapshot())
        let proxyAfter = try await readHostProxyState(of: deviceManager)
        XCTAssertEqual(proxyAfter, proxyBefore, "Lens must leave the Mac's proxy settings exactly as it found them")

        try await Self.deleteSimulator(udid: udid, toolchain: toolchain)
        simulatorDeleted = true
    }

    // MARK: - Physical device interception

    /// Verifies a manually configured iPhone or iPad.
    ///
    /// Apple exposes no way to set a device's Wi-Fi proxy from the Mac, so this test
    /// waits for the device's own traffic to arrive after the user configures it.
    ///
    /// Opt in by creating `/private/tmp/lens-run-ios-device-e2e`; the proxy port is read
    /// from that file so the address can be shared with the user before the run starts,
    /// and defaults to 18089. `xcodebuild` does not forward the shell environment to the
    /// test process, which is why this is a file rather than a variable.
    func testGuidedPhysicalDeviceCapturesAndAttributesTraffic() async throws {
        let markerURL = URL(fileURLWithPath: "/private/tmp/lens-run-ios-device-e2e")
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip(
                "Create /private/tmp/lens-run-ios-device-e2e (optionally containing a port) and put an iPhone on this Mac's Wi-Fi to run the guided device interception test."
            )
        }
        let markerPort = (try? String(contentsOf: markerURL, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let toolchain = try requireToolchain()
        let devices = try await IOSDeviceService(
            toolchainProvider: { toolchain }
        ).discoverPhysicalDevices()
        let connected = devices.filter(\.isConnected)
        guard let phone = connected.first else {
            XCTFail(
                "No connected iOS device. Paired devices: \(devices.map(\.name).joined(separator: ", ")). Connect one over USB or Wi-Fi and retry."
            )
            return
        }

        let proxyPort = markerPort ?? 18_089
        let engine = EngineProcessManager()
        let bridge = BridgeClient()
        let results = CapturedFlows()
        let mappingsConfigured = expectation(description: "Mappings configured")
        let deviceProbeCaptured = expectation(description: "Physical device traffic captured")
        let body = Data(#"{"source":"ios-physical-device"}"#.utf8)
        // HTTPS on a resolvable host: Safari on iOS upgrades plain HTTP, and a rewritten
        // HTTPS response is only possible once the device trusts the Lens certificate,
        // so this single probe proves routing and decryption together.
        let rules = [
            makeRule(
                name: "iOS Device Probe",
                method: "GET",
                scheme: "https",
                host: ProbeHost.decryption,
                port: 443,
                path: "/lens-ios-e2e-device",
                body: body,
                order: 0
            )
        ]

        bridge.onEnvelope = { envelope in
            switch envelope.type {
            case "authenticated":
                bridge.send(type: "setMappings", payload: ["rules": rules], requestID: "ios-device-mappings")
            case "mappingsUpdated":
                mappingsConfigured.fulfill()
            case "flowUpsert":
                guard let payload = envelope.payload,
                      let flow = try? payload.decode(FlowRecord.self),
                      flow.responseStatus != nil,
                      results.record(flow) else { return }
                if flow.mappedRuleName == "iOS Device Probe" { deviceProbeCaptured.fulfill() }
            default:
                break
            }
        }

        _ = try engine.start(
            proxyPort: proxyPort,
            onControlPort: { port, controlToken in bridge.connect(port: port, token: controlToken) },
            onLog: { _ in },
            onExit: { _ in }
        )
        defer {
            bridge.disconnect()
            engine.stop()
        }
        await fulfillment(of: [mappingsConfigured], timeout: 20)

        let suiteName = "LensTests.IOSPhysicalE2E.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deviceManager = DeviceManager(defaults: defaults)
        let captures = CaptureStore()
        await deviceManager.refresh()

        let target = try XCTUnwrap(
            deviceManager.devices.first { $0.serial == phone.identifier },
            "Lens did not list the connected iPhone"
        )
        XCTAssertEqual(target.platform, .ios)
        XCTAssertEqual(target.kind, .physical)
        XCTAssertEqual(
            target.attachmentMode,
            .guided,
            "A physical device cannot be configured programmatically and must use the guided path"
        )

        try await deviceManager.attach(target, proxyPort: proxyPort)
        let hostAddress = try deviceManager.hostAddressForGuidedSetup()
        print(
            """

            ==================== ACTION REQUIRED ON \(phone.name) ====================
            1. Join this Mac's Wi-Fi network.
            2. Settings → Wi-Fi → (i) → Configure Proxy → Manual
                   Server: \(hostAddress)
                   Port:   \(proxyPort)
               Save.
            3. Safari → http://mitm.it → install the iOS profile, then
               Settings → General → VPN & Device Management → install it, then
               Settings → General → About → Certificate Trust Settings → enable it.
            4. Safari → https://\(ProbeHost.decryption)/lens-ios-e2e-device
            =========================================================================

            """
        )

        do {
            await fulfillment(of: [deviceProbeCaptured], timeout: 900)
            let flow = try XCTUnwrap(results.flow(mappedBy: "iOS Device Probe"))
            XCTAssertEqual(
                flow.responseBody?.data,
                body,
                "An HTTPS response can only be rewritten once the device trusts the Lens certificate"
            )
            XCTAssertEqual(flow.scheme, "https")
            XCTAssertNotEqual(flow.clientAddress, "127.0.0.1", "A physical device arrives from a LAN address")

            // Lens learns the device's address from its first request.
            deviceManager.bindGuidedDeviceIfNeeded(clientAddress: flow.clientAddress)
            let attributed = captures.attributed(flow, to: deviceManager.devices)
            XCTAssertEqual(attributed.deviceID, phone.identifier)
            XCTAssertEqual(
                deviceManager.devices.first { $0.serial == phone.identifier }?.networkAddresses,
                [flow.clientAddress]
            )
        } catch {
            try? await deviceManager.detach(target)
            throw error
        }

        try await deviceManager.detach(target)
        XCTAssertFalse(deviceManager.devices.first { $0.serial == phone.identifier }?.isAttached == true)
        print("\nRemove the manual Wi-Fi proxy on \(phone.name) to restore direct networking.\n")
    }

    // MARK: - Simulator lifecycle

    private func createThrowawaySimulator(toolchain: XcodeToolchain) async throws -> String {
        let listing = try await CommandRunner().run(
            toolchain.simctlURL,
            arguments: ["list", "devices", "--json"],
            input: nil,
            timeout: 30
        )
        let (deviceType, runtime) = try XCTUnwrap(
            Self.newestIOSDeviceTypeAndRuntime(Data(listing.output.utf8)),
            "No available iOS simulator to clone a device type from"
        )
        let created = try await CommandRunner().run(
            toolchain.simctlURL,
            arguments: ["create", "Lens-iOS-E2E-\(UUID().uuidString.prefix(8))", deviceType, runtime],
            input: nil,
            timeout: 120
        )
        XCTAssertEqual(created.status, 0, created.errorOutput)
        let udid = created.output.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(udid.count, 36, "simctl create should return a UDID, got \(udid)")
        return udid
    }

    /// Picks a device type and runtime from the highest iOS runtime present.
    static func newestIOSDeviceTypeAndRuntime(_ data: Data) -> (deviceType: String, runtime: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = root["devices"] as? [String: Any] else { return nil }
        let iosRuntimes = devicesByRuntime.keys.filter { $0.contains(".iOS-") }.sorted { lhs, rhs in
            IOSDeviceService.osVersion(fromRuntimeIdentifier: lhs)
                .compare(IOSDeviceService.osVersion(fromRuntimeIdentifier: rhs), options: .numeric) == .orderedAscending
        }
        for runtime in iosRuntimes.reversed() {
            guard let entries = devicesByRuntime[runtime] as? [[String: Any]] else { continue }
            let iPhone = entries.first { entry in
                entry["isAvailable"] as? Bool != false
                    && (entry["deviceTypeIdentifier"] as? String)?.contains("iPhone") == true
            }
            guard let deviceType = (iPhone ?? entries.first { $0["isAvailable"] as? Bool != false })?[
                "deviceTypeIdentifier"
            ] as? String else { continue }
            return (deviceType, runtime)
        }
        return nil
    }

    private static func deleteSimulator(udid: String, toolchain: XcodeToolchain) async throws {
        _ = try? await CommandRunner().run(
            toolchain.simctlURL, arguments: ["shutdown", udid], input: nil, timeout: 60
        )
        _ = try? await CommandRunner().run(
            toolchain.simctlURL, arguments: ["delete", udid], input: nil, timeout: 60
        )
    }

    /// Safari's first launch in a fresh simulator can outlast a single `openurl`, and a
    /// timed-out command may still have delivered the URL, so a retry is safe.
    private func openURL(_ url: String, udid: String, toolchain: XcodeToolchain) async throws {
        for attempt in 0..<2 {
            let result = try await CommandRunner().run(
                toolchain.simctlURL, arguments: ["openurl", udid, url], input: nil, timeout: 90
            )
            if result.status == 0 { return }
            if attempt == 1 {
                XCTFail("simctl openurl \(url) failed: \(result.errorOutput.isEmpty ? result.output : result.errorOutput)")
            }
            try await Task.sleep(for: .seconds(3))
        }
    }

    // MARK: - Helpers

    private func requireEndToEndOptIn() throws {
        let environment = ProcessInfo.processInfo.environment
        let markerURL = URL(fileURLWithPath: "/private/tmp/lens-run-ios-e2e")
        guard environment["LENS_RUN_IOS_E2E"] == "1" || FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip(
                "Set LENS_RUN_IOS_E2E=1 or create /private/tmp/lens-run-ios-e2e to run the iOS simulator interception test. It changes the macOS system proxy and asks for administrator approval twice."
            )
        }
    }

    private func requireToolchain() throws -> XcodeToolchain {
        guard let toolchain = XcodeToolchain.resolve() else {
            throw XCTSkip("Xcode with simctl was not found on this machine.")
        }
        return toolchain
    }

    private func readHostProxyState(of deviceManager: DeviceManager) async throws -> HostProxySnapshot {
        let service = try await deviceManager.hostProxy.primaryServiceName()
        return try await deviceManager.hostProxy.readSnapshot(serviceName: service)
    }

    /// Socket ownership is sampled on a timer, so give it a few cycles.
    private func eventuallyAttributed(
        flow: FlowRecord,
        to udid: String,
        captures: CaptureStore,
        deviceManager: DeviceManager
    ) async throws -> FlowRecord {
        var attributed = captures.attributed(flow, to: deviceManager.devices)
        for _ in 0..<20 where attributed.deviceID != udid {
            try await Task.sleep(for: .milliseconds(500))
            attributed = captures.attributed(flow, to: deviceManager.devices)
        }
        return attributed
    }

    private func makeRule(
        name: String,
        method: String,
        scheme: String,
        host: String,
        port: Int,
        path: String,
        body: Data,
        order: Int
    ) -> MappingRule {
        MappingRule(
            id: UUID(),
            name: name,
            enabled: true,
            order: order,
            method: method,
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            matchQuery: false,
            query: nil,
            statusCode: 200,
            responseHeaders: [HeaderField(name: "Content-Type", value: "application/json")],
            responseBody: BodyPayload(data: body, isText: true, truncated: false, mimeType: "application/json"),
            sourceFlowID: nil
        )
    }

    private func runCurl(proxyPort: Int, arguments: [String]) async throws -> Data {
        let result = try await CommandRunner().run(
            URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "--silent", "--show-error", "--fail",
                "--connect-timeout", "5", "--max-time", "15", "--insecure",
                "--proxy", "http://127.0.0.1:\(proxyPort)"
            ] + arguments
        )
        XCTAssertEqual(result.status, 0, result.errorOutput)
        return Data(result.output.utf8)
    }

    private func unusedTCPPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: 0,
            sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Thread-safe record of the flows the engine reported.
private final class CapturedFlows: @unchecked Sendable {
    private let lock = NSLock()
    private var flowsByMappingName: [String: [FlowRecord]] = [:]
    private var storedOnRecord: (@Sendable (FlowRecord) -> Void)?

    var onRecord: (@Sendable (FlowRecord) -> Void)? {
        get { lock.withLock { storedOnRecord } }
        set { lock.withLock { storedOnRecord = newValue } }
    }

    /// Returns true the first time each flow reaches a completed state.
    func record(_ flow: FlowRecord) -> Bool {
        guard let mappingName = flow.mappedRuleName else { return false }
        let (isNew, observer): (Bool, (@Sendable (FlowRecord) -> Void)?) = lock.withLock {
            var flows = flowsByMappingName[mappingName] ?? []
            let isNew = !flows.contains { $0.id == flow.id }
            flows.removeAll { $0.id == flow.id }
            flows.append(flow)
            flowsByMappingName[mappingName] = flows
            return (isNew, storedOnRecord)
        }
        if isNew { observer?(flow) }
        return isNew
    }

    func flow(mappedBy name: String) -> FlowRecord? {
        lock.withLock { flowsByMappingName[name]?.first }
    }

    func latestFlow(mappedBy name: String, excluding excludedID: String) -> FlowRecord? {
        lock.withLock { flowsByMappingName[name]?.last { $0.id != excludedID } }
    }
}
