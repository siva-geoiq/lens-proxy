import XCTest
@testable import Lens

@MainActor
final class CoreTests: XCTestCase {
    func testADBDeviceParserPreservesWirelessSerialContainingSpaces() {
        let output = """
        List of devices attached
        adb-9b010059305330363400ec8d2a3f5c-6AgM3P (2)._adb-tls-connect._tcp\tdevice product:serenity_p_in model:25028PC03I device:serenity transport_id:344

        """

        XCTAssertEqual(
            DeviceManager.parseConnectedDeviceSerials(output),
            ["adb-9b010059305330363400ec8d2a3f5c-6AgM3P (2)._adb-tls-connect._tcp"]
        )
    }

    func testADBDeviceParserExcludesUnauthorizedAndOfflineDevices() {
        let output = """
        List of devices attached
        emulator-5554\tdevice product:sdk_gphone64_arm64 model:sdk_gphone64_arm64
        R58M123456\tunauthorized usb:1-1
        10.0.0.2:5555\toffline transport_id:3
        """

        XCTAssertEqual(DeviceManager.parseConnectedDeviceSerials(output), ["emulator-5554"])
    }

    func testADBMDNSParserReturnsTLSConnectEndpoints() {
        let output = """
        List of discovered mdns services
        adb-serial-1\t_adb-tls-connect._tcp\t10.211.32.130:33437
        adb-serial-1\t_adb-tls-pairing._tcp\t10.211.32.130:37123
        """

        XCTAssertEqual(DeviceManager.parseMDNSConnectEndpoints(output), ["10.211.32.130:33437"])
    }

    func testDeviceDeduplicationUsesHardwareSerialAndPrefersCanonicalTransport() {
        let duplicate = makeDevice(
            serial: "adb-hardware-session (2)._adb-tls-connect._tcp",
            attached: false
        )
        let canonical = makeDevice(
            serial: "adb-hardware-session._adb-tls-connect._tcp",
            attached: false
        )

        let result = DeviceManager.deduplicatedDevices([
            (hardwareID: "hardware", device: duplicate),
            (hardwareID: "hardware", device: canonical)
        ])

        XCTAssertEqual(result.map(\.serial), [canonical.serial])
    }

    func testDeviceDeduplicationKeepsAttachedTransport() {
        let attachedDuplicate = makeDevice(
            serial: "adb-hardware-session (2)._adb-tls-connect._tcp",
            attached: true
        )
        let canonical = makeDevice(
            serial: "adb-hardware-session._adb-tls-connect._tcp",
            attached: false
        )

        let result = DeviceManager.deduplicatedDevices([
            (hardwareID: "hardware", device: attachedDuplicate),
            (hardwareID: "hardware", device: canonical)
        ])

        XCTAssertEqual(result.map(\.serial), [attachedDuplicate.serial])
    }

    func testMappingIgnoresQueryByDefaultAndCanMatchItExplicitly() throws {
        var rule = makeRule(path: "/v1/config", query: "env=preprod")
        let differentQuery = try XCTUnwrap(URL(string: "https://example.com/v1/config?env=production"))
        XCTAssertTrue(rule.matches(method: "POST", url: differentQuery))

        rule.matchQuery = true
        XCTAssertFalse(rule.matches(method: "POST", url: differentQuery))
        let matchingQuery = try XCTUnwrap(URL(string: "https://example.com/v1/config?env=preprod"))
        XCTAssertTrue(rule.matches(method: "POST", url: matchingQuery))
    }

    func testFirstEnabledMatchingRuleWins() throws {
        var disabled = makeRule(name: "Disabled")
        disabled.enabled = false
        let first = makeRule(name: "First")
        let second = makeRule(name: "Second")
        let url = try XCTUnwrap(URL(string: "https://example.com/v1/config"))
        let match = [disabled, first, second].first { $0.matches(method: "POST", url: url) }
        XCTAssertEqual(match?.name, "First")
    }

    func testCopiedHeadersStripTransportEncodingFields() {
        let headers = [
            HeaderField(name: "Content-Type", value: "application/json"),
            HeaderField(name: "Content-Length", value: "100"),
            HeaderField(name: "transfer-encoding", value: "chunked"),
            HeaderField(name: "CONTENT-ENCODING", value: "gzip")
        ]
        XCTAssertEqual(MappingRule.sanitizedResponseHeaders(headers).map(\.name), ["Content-Type"])
    }

    func testCopiedRequestHeadersStripTransportManagedFields() {
        let headers = [
            HeaderField(name: "Authorization", value: "Bearer token"),
            HeaderField(name: "Host", value: "example.com"),
            HeaderField(name: "Content-Length", value: "100"),
            HeaderField(name: "Transfer-Encoding", value: "chunked")
        ]

        XCTAssertEqual(MappingRule.sanitizedRequestHeaders(headers).map(\.name), ["Authorization"])
    }

    func testLegacyResponseMappingDecodesWithLocalResponseBehavior() throws {
        let encoded = try JSONEncoder().encode(makeRule())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["behavior", "rewriteHeaders", "requestHeaders", "rewriteBody", "requestBody"] {
            object.removeValue(forKey: key)
        }

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MappingRule.self, from: legacyData)

        XCTAssertEqual(decoded.behavior, .localResponse)
        XCTAssertFalse(decoded.rewriteHeaders)
        XCTAssertFalse(decoded.rewriteBody)
    }

    func testMappingStorePersistsIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("mappings.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = MappingStore(fileURL: fileURL)
        firstStore.addBlank()
        let secondStore = MappingStore(fileURL: fileURL)
        XCTAssertEqual(secondStore.rules.count, 1)
        XCTAssertEqual(secondStore.rules.first?.name, "New local response")
    }

    func testJSONTreeValueRoundTripPreservesEditableTypes() throws {
        let source = Data(#"{"name":"Lens","count":2,"ratio":1.5,"enabled":true,"missing":null,"items":[1,"two"]}"#.utf8)
        let document = try JSONValue.decodeJSON(from: source)

        XCTAssertEqual(
            document,
            .object([
                "name": .string("Lens"),
                "count": .number(2),
                "ratio": .number(1.5),
                "enabled": .bool(true),
                "missing": .null,
                "items": .array([.number(1), .string("two")])
            ])
        )
        XCTAssertEqual(try JSONValue.decodeJSON(from: document.encodedJSON()), document)
    }

    func testJSONSyntaxViewerBuildsColoredTokensAndFoldsByPath() throws {
        let source = Data(#"{"result":{"enabled":true,"count":2},"state":null}"#.utf8)
        let document = try JSONValue.decodeJSON(from: source)

        let expanded = JSONSyntaxLineBuilder.lines(for: document, collapsedPaths: [])
        XCTAssertTrue(expanded.contains { $0.tokens.contains(JSONSyntaxToken(text: #""enabled""#, kind: .key)) })
        XCTAssertTrue(expanded.contains { $0.tokens.contains(JSONSyntaxToken(text: "true", kind: .boolean)) })
        XCTAssertTrue(expanded.contains { $0.tokens.contains(JSONSyntaxToken(text: "2", kind: .number)) })
        XCTAssertTrue(expanded.contains { $0.tokens.contains(JSONSyntaxToken(text: "null", kind: .null)) })

        let collapsed = JSONSyntaxLineBuilder.lines(for: document, collapsedPaths: ["$/result"])
        XCTAssertFalse(collapsed.contains { $0.plainText.contains("enabled") })
        XCTAssertTrue(collapsed.contains { $0.id == "$/result:folded" && $0.plainText.contains("2 fields") })
        XCTAssertLessThan(collapsed.count, expanded.count)
    }

    func testTreeEditsCreateOneMockThenUpdateIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("mappings.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MappingStore(fileURL: fileURL)
        let flow = makeFlow(id: "tree-flow", host: "api.example", mimeType: "application/json")
        let firstBody = BodyPayload(
            data: Data(#"{"enabled":true}"#.utf8),
            isText: true,
            truncated: false,
            mimeType: "application/json"
        )
        let secondBody = BodyPayload(
            data: Data(#"{"enabled":false}"#.utf8),
            isText: true,
            truncated: false,
            mimeType: "application/json"
        )

        let firstID = store.upsertResponseBody(firstBody, from: flow)
        let secondID = store.upsertResponseBody(secondBody, from: flow)

        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules.first?.sourceFlowID, flow.id)
        XCTAssertEqual(store.rules.first?.responseBody.data, secondBody.data)
        XCTAssertEqual(store.selectedRuleID, firstID)
    }

    func testRequestTreeEditsCreateOneBodyOnlyRewriteThenUpdateIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("mappings.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MappingStore(fileURL: fileURL)
        var flow = makeFlow(id: "request-tree-flow", host: "api.example", mimeType: "application/json")
        flow.method = "POST"
        flow.requestHeaders = [HeaderField(name: "Authorization", value: "dynamic")]
        flow.requestBody = BodyPayload(
            data: Data(#"{"enabled":false}"#.utf8),
            isText: true,
            truncated: false,
            mimeType: "application/json"
        )
        let firstBody = BodyPayload(
            data: Data(#"{"enabled":true}"#.utf8),
            isText: true,
            truncated: false,
            mimeType: "application/json"
        )
        let secondBody = BodyPayload(
            data: Data(#"{"enabled":false}"#.utf8),
            isText: true,
            truncated: false,
            mimeType: "application/json"
        )

        let firstID = store.upsertRequestBody(firstBody, from: flow)
        let secondID = store.upsertRequestBody(secondBody, from: flow)

        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules.first?.behavior, .rewriteRequest)
        XCTAssertEqual(store.rules.first?.sourceFlowID, flow.id)
        XCTAssertEqual(store.rules.first?.requestBody.data, secondBody.data)
        XCTAssertEqual(store.rules.first?.rewriteBody, true)
        XCTAssertEqual(store.rules.first?.rewriteHeaders, false)
        XCTAssertEqual(store.rules.first?.requestHeaders, [])
    }

    func testHeaderRewriteDoesNotFreezeCapturedRequestBody() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("mappings.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = MappingStore(fileURL: fileURL)
        var flow = makeFlow(id: "request-header-flow", host: "api.example")
        flow.requestHeaders = [
            HeaderField(name: "Content-Type", value: "application/json"),
            HeaderField(name: "Content-Length", value: "12")
        ]
        flow.requestBody = BodyPayload(
            data: Data(#"{"live":true}"#.utf8),
            isText: true,
            truncated: false,
            mimeType: "application/json"
        )

        _ = store.createRequestHeaderRewrite(from: flow)

        XCTAssertEqual(store.rules.first?.behavior, .rewriteRequest)
        XCTAssertEqual(store.rules.first?.rewriteHeaders, true)
        XCTAssertEqual(store.rules.first?.requestHeaders.map(\.name), ["Content-Type"])
        XCTAssertEqual(store.rules.first?.rewriteBody, false)
    }

    func testFlowFilteringByHostKindAndSearch() {
        let store = CaptureStore()
        store.upsert(makeFlow(id: "json", host: "firebase.example", mimeType: "application/json"))
        store.upsert(makeFlow(id: "image", host: "cdn.example", mimeType: "image/png"))

        store.selectedKind = .json
        XCTAssertEqual(store.filteredFlows.map(\.id), ["json"])
        store.selectedKind = .all
        store.selectedScope = .host(deviceID: nil, name: "cdn.example")
        XCTAssertEqual(store.filteredFlows.map(\.id), ["image"])
        store.selectedScope = .allTraffic
        store.presentGlobalSearch()
        store.searchText = "firebase"
        XCTAssertEqual(store.filteredFlows.map(\.id), ["json"])
    }

    func testGlobalSearchScansAllFlowContentAndIgnoresSidebarScope() {
        let store = CaptureStore()
        var flow = makeFlow(id: "searchable", host: "api.example", mimeType: "application/json")
        flow.clientAddress = "10.20.30.40"
        flow.requestHeaders = [HeaderField(name: "X-Trace-ID", value: "trace-abc-123")]
        flow.requestBody = BodyPayload(data: Data("{\"searchRequestKey\":\"request value\"}".utf8), isText: true, truncated: false, mimeType: "application/json")
        flow.responseHeaders = [HeaderField(name: "X-Search-Response", value: "response-header-value")]
        flow.responseBody = BodyPayload(data: Data("{\"remoteConfigState\":\"enabled\"}".utf8), isText: true, truncated: false, mimeType: "application/json")
        flow.responseReason = "Searchable Reason"
        flow.mappedRuleName = "Global Search Mapping"
        flow.websocketMessages = [WebSocketFrame(id: "frame", fromClient: false, isText: true, content: "socket-search-payload", timestamp: 42)]
        store.upsert(flow)
        store.selectedScope = .host(deviceID: nil, name: "different.example")
        store.selectedKind = .media
        store.presentGlobalSearch()

        let queries = [
            "10.20.30.40",
            "trace-abc-123",
            "searchRequestKey",
            "response-header-value",
            "remoteConfigState",
            "Searchable Reason",
            "Global Search Mapping",
            "socket-search-payload",
            "curl -X GET",
            "--data-raw"
        ]
        for query in queries {
            store.searchText = query
            XCTAssertEqual(store.filteredFlows.map(\.id), ["searchable"], "Expected a match for \(query)")
        }

        store.dismissGlobalSearch()
        XCTAssertTrue(store.searchText.isEmpty)
        XCTAssertTrue(store.filteredFlows.isEmpty)
    }

    func testLoopbackFlowsAreAttributedToTheOnlyConnectedEmulator() {
        let store = CaptureStore()
        let flow = makeFlow(id: "emulator", host: "api.example")
        let emulator = DeviceTarget(
            serial: "emulator-5554",
            model: "Pixel API 35",
            apiLevel: 35,
            kind: .emulator,
            rootState: .available,
            isAttached: true,
            previousProxy: nil,
            caInstalled: true,
            networkAddresses: ["10.0.2.15"]
        )

        store.upsert(store.attributed(flow, to: [emulator]))
        XCTAssertEqual(store.flows.first?.deviceID, "emulator-5554")
        XCTAssertEqual(store.flows.first?.clientDisplayName, "Pixel API 35")
        XCTAssertEqual(store.hosts(forDeviceID: "emulator-5554").first?.name, "api.example")
        XCTAssertTrue(store.hosts(forDeviceID: nil).isEmpty)
    }

    func testOldBodiesAreEvictedButMetadataRemains() {
        let store = CaptureStore(maximumBodyBytes: 5)
        store.upsert(makeFlow(id: "old", host: "one.example", body: Data(repeating: 1, count: 4)))
        store.upsert(makeFlow(id: "new", host: "two.example", body: Data(repeating: 2, count: 4)))

        XCTAssertEqual(store.flows.count, 2)
        XCTAssertEqual(store.flows[0].host, "one.example")
        XCTAssertTrue(store.flows[0].responseBody?.truncated == true)
        XCTAssertEqual(store.flows[0].responseBody?.data.count, 0)
        XCTAssertEqual(store.flows[1].responseBody?.data.count, 4)
    }

    func testJSONLineFramerHandlesFragmentedAndMultipleMessages() {
        var framer = JSONLineFramer()
        XCTAssertTrue(framer.append(Data("{\"a\":".utf8)).isEmpty)
        let lines = framer.append(Data("1}\n{\"b\":2}\n".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "{\"a\":1}")
        XCTAssertEqual(String(data: lines[1], encoding: .utf8), "{\"b\":2}")
    }

    func testRememberedEmulatorSurvivesCleanupUntilManuallyForgotten() throws {
        let suiteName = "LensTests.DeviceAttachment.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DeviceAttachmentPreferences(defaults: defaults)

        preferences.remember(emulatorSerial: "emulator-5554")
        XCTAssertEqual(preferences.lastEmulatorSerial, "emulator-5554")

        preferences.forget(emulatorSerial: "another-emulator")
        XCTAssertEqual(preferences.lastEmulatorSerial, "emulator-5554")

        preferences.forget(emulatorSerial: "emulator-5554")
        XCTAssertNil(preferences.lastEmulatorSerial)
    }

    func testRememberedPhysicalDeviceIsAutoSyncCandidateAcrossWirelessTransports() throws {
        let suiteName = "LensTests.RememberedPhysicalDevice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DeviceAttachmentPreferences(defaults: defaults)

        preferences.remember(deviceID: "stable-hardware-id")

        var reconnectedDevice = makeDevice(serial: "adb-new-wireless-session", attached: false)
        reconnectedDevice.hardwareID = "stable-hardware-id"
        let manager = DeviceManager(defaults: defaults)
        manager.prepareUITestDevices([reconnectedDevice])

        XCTAssertEqual(manager.rememberedDetachedDevices.map(\.serial), ["adb-new-wireless-session"])

        preferences.forget(
            deviceID: reconnectedDevice.aliasKey,
            transportID: reconnectedDevice.serial
        )
        XCTAssertTrue(manager.rememberedDetachedDevices.isEmpty)
    }

    func testLegacyPhysicalAttachmentSnapshotBecomesAutoSyncPreference() throws {
        let suiteName = "LensTests.LegacyPhysicalAttachment.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = ProxySnapshot(host: nil, port: nil)
        defaults.set(
            try JSONEncoder().encode(["adb-existing-wireless-session": snapshot]),
            forKey: "attachedProxySnapshots"
        )

        let manager = DeviceManager(defaults: defaults)
        let reconnectedDevice = makeDevice(
            serial: "adb-existing-wireless-session",
            attached: false
        )
        manager.prepareUITestDevices([reconnectedDevice])

        XCTAssertEqual(
            manager.rememberedDetachedDevices.map(\.serial),
            ["adb-existing-wireless-session"]
        )
    }

    func testDeviceAliasPersistsByHardwareIdentityAcrossWirelessTransports() throws {
        let suiteName = "LensTests.DeviceAliases.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var firstTransport = makeDevice(serial: "adb-wireless-session-one", attached: false)
        firstTransport.hardwareID = "stable-hardware-id"
        let firstManager = DeviceManager(defaults: defaults)
        firstManager.prepareUITestDevices([firstTransport])
        firstManager.rename(firstTransport, to: "  QA Pixel  ")

        XCTAssertEqual(firstManager.devices.first?.displayName, "QA Pixel")

        var secondTransport = makeDevice(serial: "adb-wireless-session-two", attached: false)
        secondTransport.hardwareID = "stable-hardware-id"
        let restoredManager = DeviceManager(defaults: defaults)
        restoredManager.prepareUITestDevices([secondTransport])

        XCTAssertEqual(restoredManager.devices.first?.displayName, "QA Pixel")
        restoredManager.resetName(for: try XCTUnwrap(restoredManager.devices.first))
        XCTAssertEqual(restoredManager.devices.first?.displayName, secondTransport.model)
    }

    func testEngineResolvesOnlyBundledMitmdump() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let executableURL = bundleURL.appendingPathComponent(EngineProcessManager.bundledRuntimeRelativePath)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertNil(EngineProcessManager.bundledMitmdumpURL(in: bundleURL))

        XCTAssertTrue(FileManager.default.createFile(atPath: executableURL.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        XCTAssertEqual(EngineProcessManager.bundledMitmdumpURL(in: bundleURL), executableURL)
    }

    func testRuntimePathsResolveBundledADBAndOwnCertificateDirectory() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundleURL = rootURL.appendingPathComponent("Lens.app")
        let supportURL = rootURL.appendingPathComponent("Application Support/Lens")
        let paths = LensRuntimePaths(applicationBundleURL: bundleURL, applicationSupportDirectory: supportURL)
        let adbURL = bundleURL.appendingPathComponent(LensRuntimePaths.bundledADBRelativePath)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(at: adbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: adbURL.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        try paths.prepare()

        XCTAssertEqual(paths.bundledADBURL(), adbURL)
        XCTAssertEqual(paths.certificateURL, supportURL.appendingPathComponent("mitmproxy/mitmproxy-ca-cert.cer"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.mitmproxyConfigurationDirectory.path))
    }

    private func makeRule(name: String = "Rule", path: String = "/v1/config", query: String? = nil) -> MappingRule {
        MappingRule(
            id: UUID(), name: name, enabled: true, order: 0, method: "POST", scheme: "https",
            host: "example.com", port: 443, path: path, matchQuery: false, query: query,
            statusCode: 200, responseHeaders: [], responseBody: .empty, sourceFlowID: nil
        )
    }

    private func makeDevice(serial: String, attached: Bool) -> DeviceTarget {
        DeviceTarget(
            serial: serial,
            model: "25028PC03I",
            apiLevel: 35,
            kind: .physical,
            rootState: .unknown,
            isAttached: attached,
            previousProxy: nil,
            caInstalled: false,
            networkAddresses: ["10.211.32.130"]
        )
    }

    private func makeFlow(
        id: String,
        host: String,
        mimeType: String = "application/octet-stream",
        body: Data = Data("{}".utf8)
    ) -> FlowRecord {
        FlowRecord(
            id: id, clientAddress: "127.0.0.1", method: "GET", scheme: "https", host: host,
            port: 443, path: "/", url: "https://\(host)/", requestHeaders: [], requestBody: nil,
            responseStatus: 200, responseReason: "OK", responseHeaders: [],
            responseBody: BodyPayload(data: body, isText: true, truncated: false, mimeType: mimeType),
            startedAt: 0, endedAt: 1, duration: 1, size: body.count,
            mappedRuleID: nil, mappedRuleName: nil, error: nil, websocketMessages: []
        )
    }
}
