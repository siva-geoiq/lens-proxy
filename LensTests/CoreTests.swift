import Darwin
import XCTest
@testable import Lens

@MainActor
final class CoreTests: XCTestCase {
    func testSharedPreferencesCodecRoundTripsEveryAndroidTypeAndExactLong() throws {
        let source = Data(#"""
        <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
        <map>
            <string name="escaped">Lens &amp; Android &lt;debug&gt;</string>
            <set name="empty"></set>
            <set name="regions"><string>IN</string><string>SG</string></set>
            <boolean name="enabled" value="true" />
            <int name="attempts" value="-42" />
            <long name="timestamp" value="9223372036854775807" />
            <float name="ratio" value="1.25" />
        </map>
        """#.utf8)

        let entries = try AndroidSharedPreferencesCodec.parse(source)
        XCTAssertEqual(entries.first(where: { $0.key == "escaped" })?.value, .string("Lens & Android <debug>"))
        XCTAssertEqual(entries.first(where: { $0.key == "empty" })?.value, .stringSet([]))
        XCTAssertEqual(entries.first(where: { $0.key == "regions" })?.value, .stringSet(["IN", "SG"]))
        XCTAssertEqual(entries.first(where: { $0.key == "enabled" })?.value, .boolean(true))
        XCTAssertEqual(entries.first(where: { $0.key == "attempts" })?.value, .int(-42))
        XCTAssertEqual(entries.first(where: { $0.key == "timestamp" })?.value, .long("9223372036854775807"))
        XCTAssertEqual(entries.first(where: { $0.key == "ratio" })?.value, .float(1.25))

        let serialized = try AndroidSharedPreferencesCodec.serialize(entries)
        XCTAssertEqual(try AndroidSharedPreferencesCodec.parse(serialized), entries)
        let json = try JSONEncoder().encode(entries.first(where: { $0.key == "timestamp" }))
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains(#""9223372036854775807""#))
    }

    func testSharedPreferencesCodecRejectsMalformedDuplicateAndUnsupportedEntries() {
        for xml in [
            #"<map><string name="same">one</string><string name="same">two</string></map>"#,
            #"<map><double name="unsupported" value="1.0" /></map>"#,
            #"<not-map />"#
        ] {
            XCTAssertThrowsError(try AndroidSharedPreferencesCodec.parse(Data(xml.utf8)))
        }
        XCTAssertThrowsError(
            try AndroidSharedPreferencesCodec.serialize([
                AndroidPreferenceEntry(key: "too-large", type: .int, value: .int(Int(Int32.max) + 1))
            ])
        )
        XCTAssertThrowsError(
            try AndroidSharedPreferencesCodec.serialize([
                AndroidPreferenceEntry(key: "mismatch", type: .boolean, value: .string("true"))
            ])
        )
    }

    func testSharedPreferencesRejectUnsafePackageAndFileIdentifiers() {
        XCTAssertTrue(AndroidSharedPreferencesService.isValidPackage("com.example.debug"))
        XCTAssertFalse(AndroidSharedPreferencesService.isValidPackage("single"))
        XCTAssertFalse(AndroidSharedPreferencesService.isValidPackage("com.example;stop"))
        XCTAssertFalse(AndroidSharedPreferencesService.isValidPackage("com.exämple.debug"))
        XCTAssertTrue(AndroidSharedPreferencesService.isValidFileName("feature-flags_v2.xml"))
        XCTAssertTrue(AndroidSharedPreferencesService.isValidFileName("WizRocket_ARP:TEST+debug.xml"))
        XCTAssertFalse(AndroidSharedPreferencesService.isValidFileName("../settings.xml"))
        XCTAssertFalse(AndroidSharedPreferencesService.isValidFileName("settings\n.xml"))
    }

    func testSharedPreferencesApplyUsesAtomicWriteAndRelaunches() async throws {
        let original = #"<?xml version='1.0' encoding='utf-8' standalone='yes' ?><map><boolean name="enabled" value="false" /></map>"#
        let updated = #"""
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <boolean name="enabled" value="true" />
</map>
"""#
        let runner = FakeAndroidCommandRunner(responses: [
            .success(), .success("settings.xml\0"), .success(original),
            .success(),
            .success("com.example.debug/.MainActivity\n"), .success(),
            .success(), .success("settings.xml\0"), .success(original),
            .success(), .success(), .success(),
            .success(), .success("settings.xml\0"), .success(updated), .success()
        ])
        let service = try makeSharedPreferencesService(runner: runner)
        let initial = try await service.loadPackage(deviceSerial: "emulator-5554", packageName: "com.example.debug")

        let result = try await service.apply(
            deviceSerial: "emulator-5554",
            packageName: "com.example.debug",
            expectedRevision: initial.revision,
            replacements: [
                AndroidPreferenceFileReplacement(
                    fileName: "settings.xml",
                    entries: [AndroidPreferenceEntry(key: "enabled", type: .boolean, value: .boolean(true))]
                )
            ]
        )

        XCTAssertTrue(result.relaunched)
        XCTAssertEqual(result.changedFileCount, 1)
        let calls = await runner.recordedCalls()
        XCTAssertTrue(calls.contains { $0.arguments.contains("force-stop") })
        XCTAssertTrue(calls.contains { $0.arguments.firstIndex(of: "exec-in") != nil && $0.input != nil })
        XCTAssertTrue(calls.contains { $0.arguments.contains(where: { $0.contains("mv shared_prefs/settings.xml") }) })
        XCTAssertTrue(calls.contains { $0.arguments.contains("com.example.debug/.MainActivity") })
    }

    func testSharedPreferencesApplyRollsBackAfterWriteFailure() async throws {
        let original = #"<map><int name="count" value="1" /></map>"#
        let runner = FakeAndroidCommandRunner(responses: [
            .success(), .success("settings.xml\0"), .success(original)
        ])
        let service = try makeSharedPreferencesService(runner: runner)
        let initial = try await service.loadPackage(deviceSerial: "emulator-5554", packageName: "com.example.debug")
        await runner.append([
            .success(),
            .success("com.example.debug/.MainActivity\n"), .success(),
            .success(), .success("settings.xml\0"), .success(original),
            .success(),
            CommandResult(output: "", errorOutput: "write failed", status: 1),
            .success(), .success()
        ])

        do {
            _ = try await service.apply(
                deviceSerial: "emulator-5554",
                packageName: "com.example.debug",
                expectedRevision: initial.revision,
                replacements: [
                    AndroidPreferenceFileReplacement(
                        fileName: "settings.xml",
                        entries: [AndroidPreferenceEntry(key: "count", type: .int, value: .int(2))]
                    )
                ]
            )
            XCTFail("Expected apply to fail")
        } catch let error as AndroidSharedPreferencesError {
            guard case let .applyFailed(_, rollbackSucceeded) = error else {
                return XCTFail("Expected applyFailed, got \(error)")
            }
            XCTAssertTrue(rollbackSucceeded)
        }
        let calls = await runner.recordedCalls()
        XCTAssertTrue(calls.contains { $0.arguments.contains(where: { $0.contains("lens-backup") && $0.contains("mv") }) })
    }

    func testSharedPreferencesRejectsStaleRevisionBeforeWritingAndRelaunches() async throws {
        let original = #"<map><boolean name="enabled" value="true" /></map>"#
        let runner = FakeAndroidCommandRunner(responses: [
            .success(), .success("com.example.debug/.MainActivity\n"), .success(),
            .success(), .success("settings.xml\0"), .success(original), .success()
        ])
        let service = try makeSharedPreferencesService(runner: runner)
        do {
            _ = try await service.apply(
                deviceSerial: "emulator-5554",
                packageName: "com.example.debug",
                expectedRevision: "stale",
                replacements: [AndroidPreferenceFileReplacement(fileName: "settings.xml", entries: [])]
            )
            XCTFail("Expected stale revision")
        } catch let error as AndroidSharedPreferencesError {
            guard case .staleRevision = error else { return XCTFail("Expected staleRevision") }
        }
        let calls = await runner.recordedCalls()
        XCTAssertTrue(calls.contains { $0.arguments.contains("force-stop") })
        XCTAssertFalse(calls.contains { $0.arguments.contains("exec-in") })
        XCTAssertTrue(calls.contains { $0.arguments.contains("com.example.debug/.MainActivity") })
    }

    func testSharedPreferencesRechecksRevisionAfterStoppingBeforeWriting() async throws {
        let original = #"<map><boolean name="enabled" value="true" /></map>"#
        let changed = #"<map><boolean name="enabled" value="false" /></map>"#
        let runner = FakeAndroidCommandRunner(responses: [
            .success(), .success("settings.xml\0"), .success(original),
            .success(),
            .success("com.example.debug/.MainActivity\n"), .success(),
            .success(), .success("settings.xml\0"), .success(changed),
            .success()
        ])
        let service = try makeSharedPreferencesService(runner: runner)
        let initial = try await service.loadPackage(deviceSerial: "emulator-5554", packageName: "com.example.debug")
        do {
            _ = try await service.apply(
                deviceSerial: "emulator-5554",
                packageName: "com.example.debug",
                expectedRevision: initial.revision,
                replacements: [AndroidPreferenceFileReplacement(fileName: "settings.xml", entries: [])]
            )
            XCTFail("Expected stopped-state revision mismatch")
        } catch let error as AndroidSharedPreferencesError {
            guard case .staleRevision = error else { return XCTFail("Expected staleRevision") }
        }
        let calls = await runner.recordedCalls()
        XCTAssertTrue(calls.contains { $0.arguments.contains("force-stop") })
        XCTAssertFalse(calls.contains { $0.arguments.contains("exec-in") })
        XCTAssertTrue(calls.contains { $0.arguments.contains("com.example.debug/.MainActivity") })
    }

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

    func testMappingEditorDraftPersistsEditedResponseBodyExactly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("mappings.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var rule = makeRule(path: "v1/config")
        rule.method = "post"
        rule.responseBody = BodyPayload(
            data: Data(#"{"original":true}"#.utf8),
            isText: true,
            truncated: false,
            mimeType: "application/json"
        )
        var draft = MappingEditorDraft(rule: rule)
        draft.responseBodyText = #"{"edited":true,"message":"saved from the editor"}"#

        let prepared = draft.preparedRule
        let store = MappingStore(fileURL: fileURL)
        store.add(rule)
        store.update(prepared)
        let reloaded = try XCTUnwrap(MappingStore(fileURL: fileURL).rules.first)

        XCTAssertEqual(String(decoding: reloaded.responseBody.data, as: UTF8.self), draft.responseBodyText)
        XCTAssertEqual(reloaded.method, "POST")
        XCTAssertEqual(reloaded.path, "/v1/config")
    }

    func testMappingEditorDraftDoesNotReplaceBinaryBodyWithDisplayText() {
        var rule = makeRule()
        let binaryData = Data([0x00, 0x01, 0xfe, 0xff])
        rule.responseBody = BodyPayload(
            data: binaryData,
            isText: false,
            truncated: false,
            mimeType: "application/octet-stream"
        )
        var draft = MappingEditorDraft(rule: rule)
        draft.responseBodyText = "not the binary payload"

        XCTAssertEqual(draft.preparedRule.responseBody.data, binaryData)
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

    func testFlowFilteringByHostKindAndSearch() async {
        let store = CaptureStore()
        store.upsert(makeFlow(id: "json", host: "firebase.example", mimeType: "application/json"))
        store.upsert(makeFlow(id: "image", host: "cdn.example", mimeType: "image/png"))

        store.selectedKind = .json
        XCTAssertEqual(store.filteredFlows.map(\.id), ["json"])
        store.selectedKind = .all
        store.selectedScope = .host(deviceID: nil, name: "cdn.example")
        XCTAssertEqual(store.filteredFlows.map(\.id), ["image"])
        store.selectedScope = .allTraffic
        let result = await store.search(query: "firebase", in: store.flows)
        XCTAssertEqual(result.matches.map(\.flowID), ["json"])
    }

    func testGlobalSearchScansAllFlowContentAndIgnoresSidebarScope() async {
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
            "curl --request GET",
            "curl --url https://api.example/",
            "--header 'X-Trace-ID: trace-abc-123'",
            "-H 'X-Trace-ID: trace-abc-123'",
            "--data-raw"
        ]
        for query in queries {
            let result = await store.search(query: query, in: store.flows)
            XCTAssertEqual(result.matches.map(\.flowID), ["searchable"], "Expected a match for \(query)")
        }

        store.dismissGlobalSearch()
        XCTAssertTrue(store.searchText.isEmpty)
        XCTAssertTrue(store.filteredFlows.isEmpty)
    }

    func testGlobalSearchPublishesOnlyLatestDebouncedQueryAndRefreshesForNewFlows() async {
        let store = CaptureStore()
        store.upsert(makeFlow(id: "firebase", host: "firebase.example"))
        store.upsert(makeFlow(id: "cdn", host: "cdn.example"))
        store.presentGlobalSearch()

        store.searchText = "firebase"
        store.searchText = "cdn"
        let publishedLatestQuery = await waitForSearch(store, matching: ["cdn"])
        XCTAssertTrue(publishedLatestQuery)

        store.searchText = "arrived-later"
        let publishedEmptyResult = await waitForSearch(store, matching: [])
        XCTAssertTrue(publishedEmptyResult)
        var newFlow = makeFlow(id: "live", host: "api.example")
        newFlow.responseBody = BodyPayload(
            data: Data(#"{"state":"arrived-later"}"#.utf8),
            isText: true,
            truncated: false,
            mimeType: "application/json"
        )
        store.upsert(newFlow)

        let refreshedForLiveFlow = await waitForSearch(store, matching: ["live"])
        XCTAssertTrue(refreshedForLiveFlow)
    }

    func testGlobalSearchClearCancelsPendingWorkAndReleasesMatches() async {
        let store = CaptureStore()
        let body = Data(repeating: UInt8(ascii: "a"), count: 2 * 1024 * 1024)
        for index in 0..<20 {
            store.upsert(makeFlow(id: "large-\(index)", host: "api.example", body: body))
        }
        store.presentGlobalSearch()
        store.searchText = "not-present"
        store.clear()

        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(store.searchMatches.isEmpty)
        XCTAssertEqual(store.searchPhase, .completed)
    }

    func testFlowSearchHandlesDiacriticsBinaryHexAndBoundedBodyPreviews() async {
        let service = FlowSearchService()
        var unicode = makeFlow(
            id: "unicode",
            host: "api.example",
            body: Data(#"{"label":"Café configuration"}"#.utf8)
        )
        unicode.responseBody?.isText = true
        var binary = makeFlow(id: "binary", host: "cdn.example", body: Data([0xde, 0xad, 0xbe, 0xef]))
        binary.responseBody?.isText = false
        binary.requestBody = BodyPayload(
            data: Data([0xca, 0xfe]),
            isText: false,
            truncated: false,
            mimeType: "application/octet-stream"
        )
        let longBody = Data((String(repeating: "a", count: 2_000) + "needle" + String(repeating: "z", count: 2_000)).utf8)
        let long = makeFlow(id: "long", host: "body.example", body: longBody)

        let diacriticResult = await service.search(
            FlowSearchRequest(query: "CAFE", flows: [unicode, binary, long], captureRevision: 1)
        )
        XCTAssertEqual(diacriticResult.matches.map(\.flowID), ["unicode"])

        let binaryResult = await service.search(
            FlowSearchRequest(query: "de ad be", flows: [unicode, binary, long], captureRevision: 1)
        )
        XCTAssertEqual(binaryResult.matches.map(\.flowID), ["binary"])

        let binaryCurlResult = await service.search(
            FlowSearchRequest(query: "--data-binary", flows: [unicode, binary, long], captureRevision: 1)
        )
        XCTAssertEqual(binaryCurlResult.matches.map(\.flowID), ["binary"])
        XCTAssertEqual(binaryCurlResult.matches.first?.field, .curl)

        let previewResult = await service.search(
            FlowSearchRequest(query: "needle", flows: [unicode, binary, long], captureRevision: 1)
        )
        let preview = try? XCTUnwrap(previewResult.matches.first?.preview)
        XCTAssertEqual(previewResult.matches.map(\.flowID), ["long"])
        XCTAssertLessThan(preview?.count ?? .max, 220)
    }

    func testAutomationSearchUsesSharedServiceAfterStructuredFilters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let captures = CaptureStore()
        var matching = makeFlow(id: "matching", host: "api.example")
        matching.responseBody = BodyPayload(
            data: Data(#"{"needle":true}"#.utf8),
            isText: true,
            truncated: false,
            mimeType: "application/json"
        )
        captures.upsert(matching)
        captures.upsert(makeFlow(id: "other-host", host: "other.example", body: Data("needle".utf8)))
        let model = LensModel(
            captures: captures,
            mappings: MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        )
        let controller = LensAutomationController(model: model)

        let result = await controller.filteredFlows(query: ["host": "api.example", "search": "needle"])
        let whitespaceResult = await controller.filteredFlows(query: ["search": "   "])

        XCTAssertEqual(result.map(\.id), ["matching"])
        XCTAssertEqual(Set(whitespaceResult.map(\.id)), ["matching", "other-host"])
    }

    func testAutomationSearchDoesNotStallMainActorHeartbeat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let captures = CaptureStore()
        let body = Data(repeating: UInt8(ascii: "a"), count: 256 * 1024)
        for index in 0..<200 {
            var uniqueBody = body
            uniqueBody[0] = UInt8(ascii: "a") + UInt8(index % 26)
            captures.upsert(makeFlow(id: "api-perf-\(index)", host: "api.example", body: uniqueBody))
        }
        let model = LensModel(
            captures: captures,
            mappings: MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        )
        let controller = LensAutomationController(model: model)
        let heartbeat = expectation(description: "main actor remained responsive")

        let searchTask = Task { @MainActor in
            Task { @MainActor in heartbeat.fulfill() }
            return await controller.filteredFlows(query: ["search": "not-present-anywhere"])
        }

        await fulfillment(of: [heartbeat], timeout: 0.05)
        let result = await searchTask.value
        XCTAssertTrue(result.isEmpty)
    }

    func testFlowSearchHundredMegabyteBenchmarkAndMainActorDispatch() async {
        let body = Data((String(repeating: "a", count: 256 * 1024 - 16) + "lens-perf-tail").utf8)
        let flows = (0..<400).map { index in
            var uniqueBody = body
            uniqueBody[0] = UInt8(ascii: "a") + UInt8(index % 26)
            return makeFlow(id: "perf-\(index)", host: "perf.example", body: uniqueBody)
        }
        let store = CaptureStore()
        flows.forEach(store.upsert)
        store.presentGlobalSearch()

        let dispatchStart = ContinuousClock.now
        store.searchText = "zzzz-not-present-anywhere"
        let dispatchDuration = dispatchStart.duration(to: .now)
        XCTAssertLessThan(seconds(dispatchDuration), 0.016)
        store.dismissGlobalSearch()

        let service = FlowSearchService()
        var pageTouch: UInt8 = 0
        for flow in flows {
            flow.responseBody?.data.withUnsafeBytes { bytes in
                for offset in stride(from: 0, to: bytes.count, by: 4_096) {
                    pageTouch ^= bytes[offset]
                }
            }
        }
        XCTAssertNotEqual(pageTouch, UInt8.max)
        let residentBeforeSearch = residentMemoryBytes()
        let memoryMonitor = Task.detached { () -> UInt64 in
            var peak = residentMemoryBytes()
            while !Task.isCancelled {
                peak = max(peak, residentMemoryBytes())
                try? await Task.sleep(for: .milliseconds(1))
            }
            return peak
        }
        let searchStart = ContinuousClock.now
        let result = await service.search(
            FlowSearchRequest(query: "zzzz-not-present-anywhere", flows: flows, captureRevision: 1)
        )
        let searchDuration = searchStart.duration(to: .now)

        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertLessThan(seconds(searchDuration), 0.25)

        let tailSearchStart = ContinuousClock.now
        let tailResult = await service.search(
            FlowSearchRequest(query: "lens-perf-tail", flows: flows, captureRevision: 1)
        )
        let tailSearchDuration = tailSearchStart.duration(to: .now)
        memoryMonitor.cancel()
        let peakResidentMemory = await memoryMonitor.value

        XCTAssertEqual(tailResult.matches.count, 400)
        XCTAssertTrue(tailResult.matches.allSatisfy { $0.field == .responseBody })
        XCTAssertLessThan(seconds(tailSearchDuration), 0.25)
        XCTAssertLessThan(peakResidentMemory - residentBeforeSearch, 25 * 1024 * 1024)
    }

    func testCurlCommandIncludesCapturedRequestAndShellEscapesValues() {
        var flow = makeFlow(id: "curl", host: "api.example")
        flow.method = "POST"
        flow.url = "https://api.example/v1/search?query=lens test"
        flow.requestHeaders = [
            HeaderField(name: "Content-Type", value: "application/json"),
            HeaderField(name: "X-Owner", value: "Lens's tester")
        ]
        flow.requestBody = BodyPayload(
            data: Data("{\"name\":\"Lens's request\"}".utf8),
            isText: true,
            truncated: false,
            mimeType: "application/json"
        )

        XCTAssertEqual(
            flow.curlCommand,
            "curl --request 'POST' --url 'https://api.example/v1/search?query=lens test' " +
                "--header 'Content-Type: application/json' --header 'X-Owner: Lens'\\''s tester' " +
                "--data-raw '{\"name\":\"Lens'\\''s request\"}'"
        )
    }

    func testCurlCommandMarksBinaryBodyAsOmitted() {
        var flow = makeFlow(id: "curl-binary", host: "upload.example")
        flow.method = "PUT"
        flow.requestBody = BodyPayload(
            data: Data([0x00, 0xFF]),
            isText: false,
            truncated: false,
            mimeType: "application/octet-stream"
        )

        XCTAssertTrue(flow.curlCommand.hasSuffix("--data-binary '<binary body omitted>'"))
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

    func testAgentFramerHandlesFragmentedAndMultipleMessages() throws {
        let first = Data(#"{"type":"trace"}"#.utf8)
        let second = Data(#"{"type":"status"}"#.utf8)
        let bytes = framed(first) + framed(second)
        var framer = LengthPrefixedJSONFramer()

        XCTAssertTrue(try framer.append(Data(bytes.prefix(3))).isEmpty)
        XCTAssertTrue(try framer.append(Data(bytes[3..<8])).isEmpty)
        let frames = try framer.append(Data(bytes.dropFirst(8)))

        XCTAssertEqual(frames, [first, second])
    }

    func testAgentFramerRejectsOversizedFramesBeforeAllocatingPayload() {
        var framer = LengthPrefixedJSONFramer()
        let oversizedLength = 4 * 1024 * 1024 + 1
        let header = Data([
            UInt8((oversizedLength >> 24) & 0xff),
            UInt8((oversizedLength >> 16) & 0xff),
            UInt8((oversizedLength >> 8) & 0xff),
            UInt8(oversizedLength & 0xff)
        ])

        XCTAssertThrowsError(try framer.append(header))
    }

    func testAndroidInspectionParsesProcessesAndForegroundActivity() {
        let processes = AndroidInspectionParser.processes("""
          PID NAME
         4205 com.lenskart.app
         4210 com.lenskart.app:push
        """)
        let event = AndroidInspectionParser.activityEvent(
            "08-11 13:00:00.000  1000  1000 I wm_set_resumed_activity: [0,com.lenskart.app/.home.ui.HomeBottomNavActivity,resumeTopActivity]",
            observedAt: 100
        )
        let seeded = AndroidInspectionParser.foregroundActivity(
            "mCurrentFocus=Window{abc u0 com.lenskart.app/com.lenskart.app.home.ui.HomeBottomNavActivity}",
            observedAt: 101
        )

        XCTAssertEqual(processes[4205], "com.lenskart.app")
        XCTAssertEqual(processes[4210], "com.lenskart.app:push")
        XCTAssertEqual(event?.packageName, "com.lenskart.app")
        XCTAssertEqual(event?.activityName, "com.lenskart.app.home.ui.HomeBottomNavActivity")
        XCTAssertEqual(seeded?.activityName, "com.lenskart.app.home.ui.HomeBottomNavActivity")
    }

    func testAndroidTraceCorrelationUsesSafeRequestIDToResolveConcurrentIdenticalRequests() {
        let correlator = AndroidTraceCorrelator(maximumAge: 5)
        let url = "https://api.example.com/v1/items?page=1"
        correlator.ingest(
            makeTrace(sequence: 1, url: url, requestID: "request-one"),
            deviceID: "device-1",
            packageName: "com.lenskart.app",
            activity: makeActivity(),
            receivedAt: 100
        )
        correlator.ingest(
            makeTrace(sequence: 2, url: url, requestID: "request-two"),
            deviceID: "device-1",
            packageName: "com.lenskart.app",
            activity: makeActivity(),
            receivedAt: 100.01
        )
        var flow = makeFlow(id: "matched", host: "api.example.com")
        flow.url = url
        flow.path = "/v1/items?page=1"
        flow.startedAt = 100.02
        flow.deviceID = "device-1"
        flow.requestHeaders = [HeaderField(name: "X-Request-ID", value: "request-two")]

        let context = correlator.context(for: flow, now: 100.02)

        XCTAssertEqual(context?.status, .captured)
        XCTAssertEqual(context?.confidence, .high)
        XCTAssertEqual(context?.foregroundActivity, "com.lenskart.app.home.ui.HomeBottomNavActivity")
        XCTAssertEqual(context?.primaryCallSite?.methodName, "loadBottomNavigation")
    }

    func testAndroidTraceCorrelationDoesNotGuessBetweenIdenticalRequests() {
        let correlator = AndroidTraceCorrelator(maximumAge: 5)
        let url = "https://api.example.com/v1/items"
        correlator.ingest(
            makeTrace(sequence: 1, url: url),
            deviceID: "device-1",
            packageName: "com.lenskart.app",
            activity: makeActivity(),
            receivedAt: 100
        )
        correlator.ingest(
            makeTrace(sequence: 2, url: url),
            deviceID: "device-1",
            packageName: "com.lenskart.app",
            activity: makeActivity(),
            receivedAt: 100.01
        )
        var flow = makeFlow(id: "ambiguous", host: "api.example.com")
        flow.url = url
        flow.path = "/v1/items"
        flow.startedAt = 100.02
        flow.deviceID = "device-1"

        let context = correlator.context(for: flow, now: 100.02)

        XCTAssertEqual(context?.status, .ambiguous)
        XCTAssertNil(context?.primaryCallSite)
        XCTAssertTrue(context?.stackFrames.isEmpty == true)
    }

    func testAndroidContextSurvivesSessionEncodingAndParticipatesInGlobalSearch() async throws {
        var flow = makeFlow(id: "android-context", host: "api.example.com")
        flow.androidContext = AndroidRequestContext(
            status: .captured,
            confidence: .high,
            packageName: "com.lenskart.app",
            processName: "com.lenskart.app",
            pid: 4205,
            threadName: "DefaultDispatcher-worker-1",
            foregroundActivity: "com.lenskart.app.home.ui.HomeBottomNavActivity",
            primaryCallSite: makeApplicationFrame(),
            stackFrames: [makeApplicationFrame()],
            capturedAt: 100,
            correlationDelayMilliseconds: 12
        )

        let decoded = try JSONDecoder().decode(FlowRecord.self, from: JSONEncoder().encode(flow))
        let service = FlowSearchService()

        XCTAssertEqual(decoded.androidContext, flow.androidContext)
        for query in ["HomeBottomNavActivity", "loadBottomNavigation", "HomeRepository.kt:142"] {
            let result = await service.search(
                FlowSearchRequest(query: query, flows: [decoded], captureRevision: 1)
            )
            XCTAssertEqual(result.matches.map(\.flowID), [decoded.id])
            XCTAssertEqual(result.matches.first?.field, .android)
        }
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

    func testHTTPParserWaitsForFragmentedBodyAndNormalizesHeaders() throws {
        let prefix = Data("PUT /v1/capture/options HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 33\r\n\r\n".utf8)
        let body = Data(#"{"removeConditionalHeaders":true}"#.utf8)
        var partial = prefix
        partial.append(body.prefix(8))
        XCTAssertNil(try LensHTTPParser.parse(partial))

        var complete = prefix
        complete.append(body)
        let request = try XCTUnwrap(LensHTTPParser.parse(complete))
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/v1/capture/options")
        XCTAssertEqual(request.header("CONTENT-TYPE"), "application/json")
        XCTAssertEqual(request.body, body)
    }

    func testHTTPParserRejectsChunkedAndOversizedRequests() {
        let chunked = Data("POST /v1/status HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        XCTAssertThrowsError(try LensHTTPParser.parse(chunked))

        let oversized = Data(repeating: 0, count: LensHTTPParser.maximumRequestBytes + 1)
        XCTAssertThrowsError(try LensHTTPParser.parse(oversized))
    }

    func testConfirmationIsOneUseAndBoundToRequestPayload() throws {
        let store = LensConfirmationStore()
        let request = LensHTTPRequest(
            method: "POST",
            target: "/v1/capture/clear",
            path: "/v1/capture/clear",
            query: [:],
            headers: [:],
            body: Data()
        )
        var confirmationID: String?
        XCTAssertThrowsError(try store.authorize(request: request, summary: "Clear flows")) { error in
            guard let problem = error as? LensAPIProblem,
                  case let .object(details)? = problem.details,
                  case let .string(identifier)? = details["confirmationId"] else {
                return XCTFail("Expected a confirmation challenge")
            }
            confirmationID = identifier
        }
        var confirmed = request
        confirmed.headers["x-lens-confirmation"] = try XCTUnwrap(confirmationID)
        XCTAssertNoThrow(try store.authorize(request: confirmed, summary: "Clear flows"))
        XCTAssertThrowsError(try store.authorize(request: confirmed, summary: "Clear flows"))
    }

    func testMappingRevisionChangesAndReorderRejectsIncompleteIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        let first = store.addBlank()
        let revision = store.revision
        let second = store.addBlank(behavior: .rewriteRequest)
        XCTAssertGreaterThan(store.revision, revision)
        XCTAssertFalse(store.reorder(ids: [first]))
        XCTAssertTrue(store.reorder(ids: [second, first]))
        XCTAssertEqual(store.rules.map(\.id), [second, first])
    }

    func testOpenAPIIsValidJSONAndDocumentsEveryRoutedArea() throws {
        let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: projectRoot.appendingPathComponent("Lens/Resources/openapi.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let paths = try XCTUnwrap(object["paths"] as? [String: Any])
        for path in [
            "/v1/status", "/v1/events", "/v1/engine/start", "/v1/capture/options",
            "/v1/flows", "/v1/search", "/v1/mappings", "/v1/sessions/save",
            "/v1/devices", "/v1/devices/{serial}/inspection",
            "/v1/devices/{serial}/shared-preferences/apps",
            "/v1/devices/{serial}/shared-preferences/{package}",
            "/v1/devices/{serial}/shared-preferences/{package}/{file}",
            "/v1/devices/{serial}/shared-preferences/{package}/apply"
        ] {
            XCTAssertNotNil(paths[path], "OpenAPI is missing \(path)")
        }
    }

    func testSharedPreferencesAPIDiscoversAppsAndReturnsPackageETag() async throws {
        let xml = #"<map><long name="exact" value="9223372036854775807" /></map>"#
        let runner = FakeAndroidCommandRunner(responses: [
            .success("com.example.debug\n"),
            .success(), .success("settings.xml\0"), .success(xml)
        ])
        let fixture = try makeSharedPreferencesRouter(runner: runner)
        let router = fixture.router
        defer { withExtendedLifetime(fixture.model) {} }

        let apps = await router.route(
            LensHTTPRequest(
                method: "GET",
                target: "/v1/devices/emulator-5554/shared-preferences/apps",
                path: "/v1/devices/emulator-5554/shared-preferences/apps",
                query: [:], headers: [:], body: Data()
            ),
            requestID: "apps"
        )
        XCTAssertEqual(apps.status, 200)
        XCTAssertTrue(String(decoding: apps.body, as: UTF8.self).contains("com.example.debug"))

        let package = await router.route(
            LensHTTPRequest(
                method: "GET",
                target: "/v1/devices/emulator-5554/shared-preferences/com.example.debug",
                path: "/v1/devices/emulator-5554/shared-preferences/com.example.debug",
                query: [:], headers: [:], body: Data()
            ),
            requestID: "package"
        )
        XCTAssertEqual(package.status, 200)
        XCTAssertNotNil(package.headers["ETag"])
        XCTAssertTrue(String(decoding: package.body, as: UTF8.self).contains(#""9223372036854775807""#))
    }

    func testSharedPreferencesAPIRequiresRevisionIdempotencyAndConfirmation() async throws {
        let runner = FakeAndroidCommandRunner(responses: [
            .success(), .success("settings.xml\0"), .success("<map></map>"),
            .success(), .success("settings.xml\0"), .success("<map></map>")
        ])
        let fixture = try makeSharedPreferencesRouter(runner: runner)
        let router = fixture.router
        defer { withExtendedLifetime(fixture.model) {} }
        let body = Data(#"{"files":[{"fileName":"settings.xml","entries":[]}]}"#.utf8)
        let path = "/v1/devices/emulator-5554/shared-preferences/com.example.debug/apply"
        let packagePath = "/v1/devices/emulator-5554/shared-preferences/com.example.debug"
        let package = await router.route(
            LensHTTPRequest(method: "GET", target: packagePath, path: packagePath, query: [:], headers: [:], body: Data()),
            requestID: "package"
        )
        let revision = try XCTUnwrap(package.headers["ETag"])

        var request = LensHTTPRequest(
            method: "POST", target: path, path: path, query: [:], headers: [:], body: body
        )
        let missingRevision = await router.route(request, requestID: "revision")
        XCTAssertEqual(missingRevision.status, 428)
        XCTAssertTrue(String(decoding: missingRevision.body, as: UTF8.self).contains("precondition_required"))

        request.headers["if-match"] = revision
        let missingIdempotency = await router.route(request, requestID: "idempotency")
        XCTAssertEqual(missingIdempotency.status, 428)
        XCTAssertTrue(String(decoding: missingIdempotency.body, as: UTF8.self).contains("idempotency_key_required"))

        request.headers["idempotency-key"] = "shared-prefs-test"
        let confirmation = await router.route(request, requestID: "confirmation")
        XCTAssertEqual(confirmation.status, 409)
        XCTAssertTrue(String(decoding: confirmation.body, as: UTF8.self).contains("confirmation_required"))
    }

    private func makeSharedPreferencesService(
        runner: any AndroidCommandRunning
    ) throws -> AndroidSharedPreferencesService {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let adb = bundle.appendingPathComponent(LensRuntimePaths.bundledADBRelativePath)
        try FileManager.default.createDirectory(at: adb.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: adb.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        return AndroidSharedPreferencesService(
            runner: runner,
            runtimePaths: LensRuntimePaths(
                applicationBundleURL: bundle,
                applicationSupportDirectory: bundle.appendingPathComponent("support")
            )
        )
    }

    private func makeSharedPreferencesRouter(
        runner: any AndroidCommandRunning
    ) throws -> (router: LensAPIRouter, model: LensModel) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LensTests.SharedPreferences.\(UUID().uuidString)"))
        let devices = DeviceManager(defaults: defaults)
        devices.prepareUITestDevices([
            DeviceTarget(
                serial: "emulator-5554",
                model: "Pixel",
                apiLevel: 35,
                kind: .emulator,
                rootState: .available,
                isAttached: false,
                previousProxy: nil,
                caInstalled: false
            )
        ])
        let model = LensModel(
            devices: devices,
            sharedPreferences: try makeSharedPreferencesService(runner: runner)
        )
        return (LensAPIRouter(controller: model.automation), model)
    }

    private func waitForSearch(_ store: CaptureStore, matching expectedIDs: [String]) async -> Bool {
        for _ in 0..<300 {
            if store.searchPhase == .completed, store.searchMatches.map(\.flowID) == expectedIDs {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
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

    private func framed(_ payload: Data) -> Data {
        var data = Data([
            UInt8((payload.count >> 24) & 0xff),
            UInt8((payload.count >> 16) & 0xff),
            UInt8((payload.count >> 8) & 0xff),
            UInt8(payload.count & 0xff)
        ])
        data.append(payload)
        return data
    }

    private func makeTrace(sequence: UInt64, url: String, requestID: String? = nil) -> AndroidAgentTrace {
        AndroidAgentTrace(
            sequence: sequence,
            method: "GET",
            url: url,
            processName: "com.lenskart.app",
            pid: 4205,
            threadName: "DefaultDispatcher-worker-1",
            capturedAt: 100,
            correlationHeaders: requestID.map { ["x-request-id": $0] } ?? [:],
            stackFrames: [
                AndroidStackFrame(
                    className: "okhttp3.RealCall",
                    methodName: "execute",
                    signature: "()Lokhttp3/Response;",
                    sourceFile: "RealCall.kt",
                    lineNumber: 153,
                    isFramework: true
                ),
                makeApplicationFrame()
            ]
        )
    }

    private func makeActivity() -> AndroidActivitySnapshot {
        AndroidActivitySnapshot(
            packageName: "com.lenskart.app",
            activityName: "com.lenskart.app.home.ui.HomeBottomNavActivity",
            observedAt: 99
        )
    }

    private func makeApplicationFrame() -> AndroidStackFrame {
        AndroidStackFrame(
            className: "com.lenskart.app.home.data.HomeRepository",
            methodName: "loadBottomNavigation",
            signature: "()V",
            sourceFile: "HomeRepository.kt",
            lineNumber: 142,
            isFramework: false
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

private actor FakeAndroidCommandRunner: AndroidCommandRunning {
    struct Call: Sendable {
        var arguments: [String]
        var input: Data?
        var timeout: TimeInterval?
    }

    private var responses: [CommandResult]
    private var calls: [Call] = []

    init(responses: [CommandResult]) {
        self.responses = responses
    }

    func run(
        _ executable: URL,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval?
    ) async throws -> CommandResult {
        calls.append(Call(arguments: arguments, input: input, timeout: timeout))
        guard !responses.isEmpty else {
            return CommandResult(output: "", errorOutput: "Missing fake response", status: 1)
        }
        return responses.removeFirst()
    }

    func append(_ values: [CommandResult]) {
        responses.append(contentsOf: values)
    }

    func prepend(_ values: [CommandResult]) {
        responses.insert(contentsOf: values, at: 0)
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

private extension CommandResult {
    static func success(_ output: String = "") -> CommandResult {
        CommandResult(output: output, errorOutput: "", status: 0)
    }
}

private func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
        }
    }
    return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}
