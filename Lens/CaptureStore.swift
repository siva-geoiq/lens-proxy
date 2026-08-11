import Foundation
import Observation

@MainActor
@Observable
final class CaptureStore {
    private(set) var flows: [FlowRecord] = []
    var selectedFlowID: String?
    var selectedScope: CaptureScope? = .allTraffic
    var searchText = ""
    private(set) var isGlobalSearchPresented = false
    private(set) var globalSearchFocusRequest = 0
    var selectedKind: FlowKind = .all
    var isCapturePaused = false
    private var indexByID: [String: Int] = [:]
    private var totalBodyBytes = 0

    let maximumBodyBytes: Int

    init(maximumBodyBytes: Int = 500 * 1024 * 1024) {
        self.maximumBodyBytes = maximumBodyBytes
    }

    var selectedFlow: FlowRecord? {
        guard let selectedFlowID else { return nil }
        return flows.first { $0.id == selectedFlowID }
    }

    func flows(forDeviceID deviceID: String?) -> [FlowRecord] {
        flows.filter { $0.deviceID == deviceID }
    }

    func hosts(forDeviceID deviceID: String?) -> [(name: String, count: Int)] {
        Dictionary(grouping: flows(forDeviceID: deviceID), by: \.host)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var filteredFlows: [FlowRecord] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isGlobalSearchPresented, !needle.isEmpty {
            return flows.filter { $0.matchesGlobalSearch(needle) }
        }
        return flows.filter { flow in
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
    }

    func dismissGlobalSearch() {
        searchText = ""
        isGlobalSearchPresented = false
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
    }

    func attributeFlows(to devices: [DeviceTarget]) {
        for index in flows.indices {
            flows[index] = attributed(flows[index], to: devices)
        }
    }

    func attributed(_ flow: FlowRecord, to devices: [DeviceTarget]) -> FlowRecord {
        var result = flow
        let emulators = devices.filter { $0.kind == .emulator }
        let matchedDevice = devices.first { device in
            device.networkAddresses.contains(flow.clientAddress) ||
                (isLoopback(flow.clientAddress) && device.kind == .emulator && emulators.count == 1)
        }
        result.deviceID = matchedDevice?.serial
        result.deviceName = matchedDevice?.displayName
        return result
    }

    func clear() {
        flows.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        totalBodyBytes = 0
        selectedFlowID = nil
        selectedScope = .allTraffic
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
}
