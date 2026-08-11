import XCTest
@testable import Lens

@MainActor
final class CoreTests: XCTestCase {
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

    func testMappingStorePersistsIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileURL = directory.appendingPathComponent("mappings.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = MappingStore(fileURL: fileURL)
        firstStore.addBlank()
        let secondStore = MappingStore(fileURL: fileURL)
        XCTAssertEqual(secondStore.rules.count, 1)
        XCTAssertEqual(secondStore.rules.first?.name, "New mapping")
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
        store.searchText = "firebase"
        XCTAssertEqual(store.filteredFlows.map(\.id), ["json"])
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

    private func makeRule(name: String = "Rule", path: String = "/v1/config", query: String? = nil) -> MappingRule {
        MappingRule(
            id: UUID(), name: name, enabled: true, order: 0, method: "POST", scheme: "https",
            host: "example.com", port: 443, path: path, matchQuery: false, query: query,
            statusCode: 200, responseHeaders: [], responseBody: .empty, sourceFlowID: nil
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
