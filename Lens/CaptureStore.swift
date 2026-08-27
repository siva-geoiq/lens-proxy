import Foundation
import Observation

enum GlobalSearchPhase: Equatable, Sendable {
    case idle
    case searching
    case completed
}

@MainActor
@Observable
final class CaptureStore {
    private(set) var flows: [FlowRecord] = []
    var selectedFlowID: String?
    var selectedScope: CaptureScope? = .allTraffic
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            searchQueryDidChange()
        }
    }
    private(set) var isGlobalSearchPresented = false
    private(set) var globalSearchFocusRequest = 0
    private(set) var searchPhase: GlobalSearchPhase = .idle
    private(set) var searchMatches: [FlowSearchMatch] = []
    private(set) var captureRevision: UInt64 = 0
    var selectedKind: FlowKind = .all
    var isCapturePaused = false
    private var indexByID: [String: Int] = [:]
    private var totalBodyBytes = 0
    @ObservationIgnored private let searchService: FlowSearchService
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private(set) var searchGeneration: UInt64 = 0
    @ObservationIgnored private var searchNeedsRefresh = false

    let maximumBodyBytes: Int

    init(
        maximumBodyBytes: Int = 500 * 1024 * 1024,
        searchService: FlowSearchService = FlowSearchService()
    ) {
        self.maximumBodyBytes = maximumBodyBytes
        self.searchService = searchService
    }

    var selectedFlow: FlowRecord? {
        guard let selectedFlowID else { return nil }
        return flows.first { $0.id == selectedFlowID }
    }

    /// Resolves a loopback client port to the iOS simulator UDID that owns it.
    /// Set by `LensModel`; nil when no simulator is attached.
    @ObservationIgnored var simulatorUDIDResolver: (@MainActor (Int) -> String?)?

    func flows(forDeviceID deviceID: String?) -> [FlowRecord] {
        flows.filter { $0.deviceID == deviceID }
    }

    func hosts(forDeviceID deviceID: String?) -> [(name: String, count: Int)] {
        Dictionary(grouping: flows(forDeviceID: deviceID), by: \.host)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var filteredFlows: [FlowRecord] {
        flows.filter { flow in
            let matchesScope = switch selectedScope ?? .allTraffic {
            case .allTraffic: true
            case .local: flow.deviceID == nil
            case let .device(deviceID): flow.deviceID == deviceID
            case let .host(deviceID, host): flow.deviceID == deviceID && flow.host == host
            }
            let matchesKind = switch selectedKind {
            case .all: true
            case .http: flow.scheme == "http"
            case .https: flow.scheme == "https"
            case .webSocket: !flow.websocketMessages.isEmpty
            case .json:
                flow.responseBody?.mimeType?.localizedCaseInsensitiveContains("json") == true ||
                    flow.requestBody?.mimeType?.localizedCaseInsensitiveContains("json") == true
            case .media:
                flow.responseBody?.mimeType?.hasPrefix("image/") == true ||
                    flow.responseBody?.mimeType?.hasPrefix("video/") == true ||
                    flow.responseBody?.mimeType?.hasPrefix("audio/") == true
            case .other: isOther(flow)
            }
            return matchesScope && matchesKind
        }
    }

    var isGlobalSearchActive: Bool {
        isGlobalSearchPresented && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func presentGlobalSearch() {
        isGlobalSearchPresented = true
        globalSearchFocusRequest &+= 1
        searchQueryDidChange()
    }

    func dismissGlobalSearch() {
        isGlobalSearchPresented = false
        searchText = ""
    }

    func flow(id: String) -> FlowRecord? {
        guard let index = indexByID[id], flows.indices.contains(index) else { return nil }
        return flows[index]
    }

    func search(query: String, in flows: [FlowRecord]) async -> FlowSearchResult {
        await searchService.search(
            FlowSearchRequest(query: query, flows: flows, captureRevision: captureRevision)
        )
    }

    private func isOther(_ flow: FlowRecord) -> Bool {
        let mimeType = flow.responseBody?.mimeType?.lowercased() ?? ""
        let isMedia = mimeType.hasPrefix("image/") || mimeType.hasPrefix("video/") || mimeType.hasPrefix("audio/")
        let isJSON = mimeType.contains("json") || flow.requestBody?.mimeType?.localizedCaseInsensitiveContains("json") == true
        return flow.websocketMessages.isEmpty && !isMedia && !isJSON
    }

    func upsert(_ flow: FlowRecord) {
        if let index = indexByID[flow.id] {
            totalBodyBytes -= flows[index].bodyByteCount
            flows[index] = flow
            totalBodyBytes += flow.bodyByteCount
        } else {
            indexByID[flow.id] = flows.count
            flows.append(flow)
            totalBodyBytes += flow.bodyByteCount
        }
        evictBodiesIfNeeded()
        captureDidChange()
    }

    func attributeFlows(to devices: [DeviceTarget]) {
        var didChange = false
        for index in flows.indices {
            let updated = attributed(flows[index], to: devices)
            guard updated.deviceID != flows[index].deviceID ||
                    updated.deviceName != flows[index].deviceName else { continue }
            flows[index] = updated
            didChange = true
        }
        if didChange { captureDidChange() }
    }

    func attributed(_ flow: FlowRecord, to devices: [DeviceTarget]) -> FlowRecord {
        var result = flow
        let matchedDevice = matchingDevice(for: flow, in: devices)
        result.deviceID = matchedDevice?.serial
        result.deviceName = matchedDevice?.displayName
        return result
    }

    private func matchingDevice(for flow: FlowRecord, in devices: [DeviceTarget]) -> DeviceTarget? {
        if let device = devices.first(where: { $0.networkAddresses.contains(flow.clientAddress) }) {
            return device
        }
        guard isLoopback(flow.clientAddress) else { return nil }

        // An iOS simulator shares the Mac's loopback address with every other simulator
        // and with the Mac's own apps, so the owning process decides.
        if let port = flow.clientPort,
           let udid = simulatorUDIDResolver?(port),
           let device = devices.first(where: { $0.serial == udid }) {
            return device
        }

        // Android emulators have no such resolver; a single emulator is unambiguous.
        let androidEmulators = devices.filter { $0.platform == .android && $0.kind == .emulator }
        return androidEmulators.count == 1 ? androidEmulators.first : nil
    }

    func clear() {
        flows.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        totalBodyBytes = 0
        selectedFlowID = nil
        selectedScope = .allTraffic
        captureRevision &+= 1
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        searchMatches = []
        searchNeedsRefresh = false
        searchPhase = isGlobalSearchActive ? .completed : .idle
    }

    private func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1" || address == "localhost"
    }

    private func evictBodiesIfNeeded() {
        guard totalBodyBytes > maximumBodyBytes else { return }
        for index in flows.indices where totalBodyBytes > maximumBodyBytes {
            let removedBytes = flows[index].bodyByteCount
            guard removedBytes > 0 else { continue }
            if flows[index].requestBody != nil {
                flows[index].requestBody = BodyPayload(data: Data(), isText: true, truncated: true, mimeType: nil)
            }
            if flows[index].responseBody != nil {
                flows[index].responseBody = BodyPayload(data: Data(), isText: true, truncated: true, mimeType: nil)
            }
            totalBodyBytes -= removedBytes
        }
    }

    private func searchQueryDidChange() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchNeedsRefresh = false
        searchMatches = []

        let query = normalizedSearchText
        guard isGlobalSearchPresented, !query.isEmpty else {
            searchPhase = .idle
            searchTask = nil
            return
        }
        searchPhase = .searching
        startSearch(query: query, generation: searchGeneration, debounce: .milliseconds(150))
    }

    private func captureDidChange() {
        captureRevision &+= 1
        guard isGlobalSearchActive else { return }
        searchNeedsRefresh = true
        guard searchPhase != .searching else { return }
        searchPhase = .searching
        startSearch(query: normalizedSearchText, generation: searchGeneration, debounce: .milliseconds(75))
    }

    private func startSearch(query: String, generation: UInt64, debounce: Duration) {
        searchTask?.cancel()
        let service = searchService
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.isGlobalSearchPresented,
                  generation == self.searchGeneration,
                  query == self.normalizedSearchText else { return }

            let request = FlowSearchRequest(
                query: query,
                flows: self.flows,
                captureRevision: self.captureRevision
            )
            self.searchNeedsRefresh = false
            let result = await service.search(request)
            guard !Task.isCancelled else { return }
            self.completeSearch(result, generation: generation)
        }
    }

    private func completeSearch(_ result: FlowSearchResult, generation: UInt64) {
        guard isGlobalSearchPresented,
              generation == searchGeneration,
              result.query == normalizedSearchText else { return }

        if searchNeedsRefresh || result.captureRevision != captureRevision {
            searchPhase = .searching
            startSearch(query: normalizedSearchText, generation: generation, debounce: .milliseconds(75))
            return
        }

        searchMatches = result.matches.filter { indexByID[$0.flowID] != nil }
        searchPhase = .completed
        searchTask = nil
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
