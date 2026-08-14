import Darwin
import XCTest
@testable import Lens

@MainActor
final class EngineDeviceEndToEndTests: XCTestCase {
    func testWildcardMappingServesMultipleProductPaths() async throws {
        let proxyPort = try unusedTCPPort()
        let engine = EngineProcessManager()
        let bridge = BridgeClient()
        let mappingsUpdated = expectation(description: "Wildcard mapping accepted")
        let responseBody = Data(#"{"source":"wildcard-mapping"}"#.utf8)
        let rules = [
            makeRule(
                name: "Wildcard product mapping",
                method: "GET",
                scheme: "http",
                host: "wildcard-mapping.lens.test",
                port: 80,
                path: "/v2/products/*",
                body: responseBody,
                order: 0
            )
        ]

        bridge.onEnvelope = { envelope in
            switch envelope.type {
            case "authenticated":
                bridge.send(type: "setMappings", payload: ["rules": rules], requestID: "wildcard-mappings")
            case "mappingsUpdated":
                mappingsUpdated.fulfill()
            case "clientError", "engineError":
                XCTFail(envelope.error?.message ?? "Unexpected bridge error")
            default:
                break
            }
        }

        _ = try engine.start(
            proxyPort: proxyPort,
            onControlPort: { port, controlToken in
                bridge.connect(port: port, token: controlToken)
            },
            onLog: { _ in },
            onExit: { _ in }
        )
        defer {
            bridge.disconnect()
            engine.stop()
        }

        await fulfillment(of: [mappingsUpdated], timeout: 15)
        for path in [
            "/v2/products/137152/similar-products",
            "/v2/products/category/eyeglasses"
        ] {
            let response = try await runCurl(
                proxyPort: proxyPort,
                arguments: ["http://wildcard-mapping.lens.test\(path)?page=0&page-size=30"]
            )
            XCTAssertEqual(response, responseBody)
        }
    }

    func testBridgeAcceptsLargeMappingSnapshotAndRemainsConnected() async throws {
        let proxyPort = try unusedTCPPort()
        let engine = EngineProcessManager()
        let bridge = BridgeClient()
        let mappingsUpdated = expectation(description: "Large mapping snapshot accepted")
        let followUpCommandHandled = expectation(description: "Bridge remains connected")
        let largeBody = Data(repeating: 0x41, count: 256 * 1024)
        let rules = [
            makeRule(
                name: "Large bridge mapping",
                method: "GET",
                scheme: "https",
                host: "large-mapping.lens.test",
                port: 443,
                path: "/payload",
                body: largeBody,
                order: 0
            )
        ]
        XCTAssertGreaterThan(try JSONEncoder().encode(rules).count, 64 * 1024)

        bridge.onEnvelope = { envelope in
            switch envelope.type {
            case "authenticated":
                bridge.send(type: "setMappings", payload: ["rules": rules], requestID: "large-mappings")
            case "mappingsUpdated":
                mappingsUpdated.fulfill()
                bridge.send(type: "setNoCaching", payload: ["enabled": true], requestID: "after-large-mappings")
            case "noCachingState":
                followUpCommandHandled.fulfill()
            case "clientError", "engineError":
                XCTFail(envelope.error?.message ?? "Unexpected bridge error")
            default:
                break
            }
        }

        _ = try engine.start(
            proxyPort: proxyPort,
            onControlPort: { port, controlToken in
                bridge.connect(port: port, token: controlToken)
            },
            onLog: { _ in },
            onExit: { _ in }
        )
        defer {
            bridge.disconnect()
            engine.stop()
        }

        await fulfillment(of: [mappingsUpdated, followUpCommandHandled], timeout: 15)
    }

    func testSharedPreferencesReadEditRelaunchAndRestore() async throws {
        let environment = ProcessInfo.processInfo.environment
        let markerURL = URL(fileURLWithPath: "/private/tmp/lens-run-shared-prefs-e2e")
        guard environment["LENS_RUN_SHARED_PREFS_E2E"] == "1" || FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip("Set LENS_RUN_SHARED_PREFS_E2E=1 or create /private/tmp/lens-run-shared-prefs-e2e to run the reversible Shared Preferences device test.")
        }
        let markerSerial = try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = environment["LENS_E2E_DEVICE"] ?? markerSerial.flatMap { $0.isEmpty ? nil : $0 } ?? "emulator-5554"
        let packageName = environment["LENS_E2E_PACKAGE"] ?? "com.lenskart.app"
        let service = AndroidSharedPreferencesService()
        let apps = try await service.discoverApps(deviceSerial: serial)
        XCTAssertTrue(apps.contains(packageName))
        let initial = try await service.loadPackage(deviceSerial: serial, packageName: packageName)
        let preferredFile = initial.files.first(where: { $0.name == "godel.xml" && $0.isEditable })
            ?? initial.files.first(where: \.isEditable)
        let file = try XCTUnwrap(preferredFile)
        let smokeKey = "__lens_shared_preferences_smoke_test__"
        XCTAssertFalse(file.entries.contains { $0.key == smokeKey })
        let modifiedEntries = file.entries + [
            AndroidPreferenceEntry(key: smokeKey, type: .string, value: .string("verified"))
        ]

        do {
            _ = try await service.apply(
                deviceSerial: serial,
                packageName: packageName,
                expectedRevision: initial.revision,
                replacements: [AndroidPreferenceFileReplacement(fileName: file.name, entries: modifiedEntries)]
            )
            let observed = try await service.loadPackage(deviceSerial: serial, packageName: packageName)
            XCTAssertEqual(
                observed.files.first(where: { $0.name == file.name })?.entries.first(where: { $0.key == smokeKey })?.value,
                .string("verified")
            )
            _ = try await service.apply(
                deviceSerial: serial,
                packageName: packageName,
                expectedRevision: observed.revision,
                replacements: [AndroidPreferenceFileReplacement(fileName: file.name, entries: file.entries)]
            )
        } catch {
            let originalError = error
            for _ in 0..<3 {
                guard let current = try? await service.loadPackage(deviceSerial: serial, packageName: packageName) else { continue }
                guard current.files.first(where: { $0.name == file.name })?.entries.contains(where: { $0.key == smokeKey }) == true else {
                    break
                }
                if (try? await service.apply(
                    deviceSerial: serial,
                    packageName: packageName,
                    expectedRevision: current.revision,
                    replacements: [AndroidPreferenceFileReplacement(fileName: file.name, entries: file.entries)]
                )) != nil {
                    break
                }
            }
            throw originalError
        }

        let restored = try await service.loadPackage(deviceSerial: serial, packageName: packageName)
        XCTAssertFalse(
            restored.files.first(where: { $0.name == file.name })?.entries.contains(where: { $0.key == smokeKey }) == true
        )
    }

    func testAttachCaptureNoCachingAndExactEndpointMappings() async throws {
        let environment = ProcessInfo.processInfo.environment
        let markerURL = URL(fileURLWithPath: "/private/tmp/lens-run-device-e2e")
        guard environment["LENS_RUN_DEVICE_E2E"] == "1" || FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip("Set LENS_RUN_DEVICE_E2E=1 or create /private/tmp/lens-run-device-e2e to run the mitmdump and emulator integration test.")
        }

        let markerSerial = try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = environment["LENS_E2E_DEVICE"] ?? markerSerial.flatMap { $0.isEmpty ? nil : $0 } ?? "emulator-5554"
        let proxyPort = Int(environment["LENS_E2E_PROXY_PORT"] ?? "18080") ?? 18_080
        let engine = EngineProcessManager()
        let bridge = BridgeClient()
        let results = EngineIntegrationResults()
        let bridgeConfigured = expectation(description: "No Caching and mappings configured")
        bridgeConfigured.expectedFulfillmentCount = 2
        let firebaseMapped = expectation(description: "Firebase Remote Config mapping hit")
        let bottomNavMapped = expectation(description: "Bottom-nav mapping hit")
        let emulatorProbeMapped = expectation(description: "Attached emulator traffic captured")

        let firebaseBody = Data(#"{"state":"UPDATE","templateVersion":"lens-e2e"}"#.utf8)
        let bottomNavBody = Data(#"{"result":{"bottomBarHarmonyItems":{"items":[]}},"status":200}"#.utf8)
        let emulatorProbeBody = Data(#"{"source":"emulator"}"#.utf8)
        let rules = [
            makeRule(
                name: "Firebase Remote Config E2E",
                method: "POST",
                scheme: "https",
                host: "firebaseremoteconfig.googleapis.com",
                port: 443,
                path: "/v1/projects/446182039508/namespaces/firebase:fetch",
                body: firebaseBody,
                order: 0
            ),
            makeRule(
                name: "Android Bottom Nav E2E",
                method: "GET",
                scheme: "https",
                host: "api-gateway.juno.lenskart.com",
                port: 443,
                path: "/v1/cms/static/android-bottom-nav",
                body: bottomNavBody,
                order: 1
            ),
            makeRule(
                name: "Emulator Attachment Probe",
                method: "GET",
                scheme: "http",
                host: "lens.e2e.local",
                port: 80,
                path: "/probe",
                body: emulatorProbeBody,
                order: 2
            )
        ]

        bridge.onEnvelope = { envelope in
            switch envelope.type {
            case "authenticated":
                bridge.send(type: "setNoCaching", payload: ["enabled": true], requestID: "e2e-no-caching")
                bridge.send(type: "setMappings", payload: ["rules": rules], requestID: "e2e-mappings")
            case "noCachingState", "mappingsUpdated":
                bridgeConfigured.fulfill()
            case "flowUpsert":
                guard let payload = envelope.payload,
                      let flow = try? payload.decode(FlowRecord.self),
                      flow.responseStatus != nil else { return }
                guard results.record(flow) else { return }
                switch flow.mappedRuleName {
                case "Firebase Remote Config E2E": firebaseMapped.fulfill()
                case "Android Bottom Nav E2E": bottomNavMapped.fulfill()
                case "Emulator Attachment Probe": emulatorProbeMapped.fulfill()
                default: break
                }
            default:
                break
            }
        }

        let token = try engine.start(
            proxyPort: proxyPort,
            onControlPort: { port, controlToken in
                bridge.connect(port: port, token: controlToken)
            },
            onLog: { _ in },
            onExit: { _ in }
        )
        XCTAssertFalse(token.isEmpty)
        defer {
            bridge.disconnect()
            engine.stop()
        }

        await fulfillment(of: [bridgeConfigured], timeout: 15)

        let suiteName = "LensTests.DeviceE2E.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let deviceManager = DeviceManager(defaults: defaults)
        await deviceManager.refresh()
        let device = try XCTUnwrap(deviceManager.devices.first(where: { $0.serial == serial }))
        try await deviceManager.attach(device, proxyPort: proxyPort)

        do {
            let adbPath = try XCTUnwrap(deviceManager.adbPath)
            let probeCommand = "printf 'GET http://lens.e2e.local/probe HTTP/1.1\\r\\nHost: lens.e2e.local\\r\\nConnection: close\\r\\n\\r\\n' | nc 10.0.2.2 \(proxyPort)"
            let probe = try await CommandRunner().run(
                URL(fileURLWithPath: adbPath),
                arguments: ["-s", serial, "shell", probeCommand],
                timeout: 10
            )
            XCTAssertEqual(probe.status, 0, probe.errorOutput)

            let firebase = try await runCurl(
                proxyPort: proxyPort,
                arguments: [
                    "--request", "POST",
                    "--header", "Content-Type: application/json",
                    "--header", "If-None-Match: stale-e2e-etag",
                    "--data", "{}",
                    "https://firebaseremoteconfig.googleapis.com/v1/projects/446182039508/namespaces/firebase:fetch"
                ]
            )
            XCTAssertEqual(firebase, firebaseBody)

            let bottomNav = try await runCurl(
                proxyPort: proxyPort,
                arguments: ["https://api-gateway.juno.lenskart.com/v1/cms/static/android-bottom-nav"]
            )
            XCTAssertEqual(bottomNav, bottomNavBody)

            await fulfillment(of: [emulatorProbeMapped, firebaseMapped, bottomNavMapped], timeout: 15)

            let firebaseFlow = try XCTUnwrap(results.flow(mappedBy: "Firebase Remote Config E2E"))
            XCTAssertFalse(firebaseFlow.requestHeaders.contains { $0.name.caseInsensitiveCompare("If-None-Match") == .orderedSame })
            XCTAssertEqual(firebaseFlow.responseBody?.data, firebaseBody)
            XCTAssertEqual(results.flow(mappedBy: "Android Bottom Nav E2E")?.responseBody?.data, bottomNavBody)

            let probeFlow = try XCTUnwrap(results.flow(mappedBy: "Emulator Attachment Probe"))
            XCTAssertEqual(probeFlow.responseBody?.data, emulatorProbeBody)
            let attributedProbe = CaptureStore().attributed(probeFlow, to: deviceManager.devices)
            XCTAssertEqual(attributedProbe.deviceID, serial)
        } catch {
            try? await deviceManager.detach(device)
            await shutdown(bridge)
            throw error
        }

        try await deviceManager.detach(device)
        XCTAssertFalse(deviceManager.devices.first(where: { $0.serial == serial })?.isAttached == true)
        await shutdown(bridge)
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
                "--silent",
                "--show-error",
                "--fail",
                "--connect-timeout", "5",
                "--max-time", "15",
                "--insecure",
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

    private func shutdown(_ bridge: BridgeClient) async {
        bridge.send(type: "shutdown")
        try? await Task.sleep(for: .seconds(1))
    }
}

private final class EngineIntegrationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var flowsByMappingName: [String: FlowRecord] = [:]

    func record(_ flow: FlowRecord) -> Bool {
        guard let mappingName = flow.mappedRuleName else { return false }
        return lock.withLock {
            let isFirstCompletedUpdate = flowsByMappingName[mappingName] == nil
            flowsByMappingName[mappingName] = flow
            return isFirstCompletedUpdate
        }
    }

    func flow(mappedBy name: String) -> FlowRecord? {
        lock.withLock { flowsByMappingName[name] }
    }
}
