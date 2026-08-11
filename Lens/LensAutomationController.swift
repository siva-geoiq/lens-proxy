import Foundation

struct LensAPIEvent: Codable, Sendable {
    var id: UInt64
    var type: String
    var timestamp: Double
    var payload: JSONValue
}

struct LensFlowSummary: Codable, Sendable {
    var id: String
    var method: String
    var scheme: String
    var host: String
    var port: Int
    var path: String
    var url: String
    var clientAddress: String
    var clientName: String
    var status: Int?
    var startedAt: Double
    var duration: Double?
    var size: Int
    var deviceID: String?
    var deviceName: String?
    var mappedRuleID: UUID?
    var mappedRuleName: String?
    var rewrittenRuleID: UUID?
    var rewrittenRuleName: String?
    var requestBody: LensBodyMetadata?
    var responseBody: LensBodyMetadata?
    var websocketFrameCount: Int
    var hasAndroidContext: Bool

    init(flow: FlowRecord) {
        id = flow.id
        method = flow.method
        scheme = flow.scheme
        host = flow.host
        port = flow.port
        path = flow.path
        url = flow.url
        clientAddress = flow.clientAddress
        clientName = flow.clientDisplayName
        status = flow.responseStatus
        startedAt = flow.startedAt
        duration = flow.duration
        size = flow.size
        deviceID = flow.deviceID
        deviceName = flow.deviceName
        mappedRuleID = flow.mappedRuleID
        mappedRuleName = flow.mappedRuleName
        rewrittenRuleID = flow.rewrittenRuleID
        rewrittenRuleName = flow.rewrittenRuleName
        requestBody = flow.requestBody.map(LensBodyMetadata.init)
        responseBody = flow.responseBody.map(LensBodyMetadata.init)
        websocketFrameCount = flow.websocketMessages.count
        hasAndroidContext = flow.androidContext != nil
    }
}

struct LensBodyMetadata: Codable, Sendable {
    var byteCount: Int
    var mimeType: String?
    var isText: Bool
    var truncated: Bool

    init(body: BodyPayload) {
        byteCount = body.data.count
        mimeType = body.mimeType
        isText = body.isText
        truncated = body.truncated
    }
}

struct LensFlowDetail: Codable, Sendable {
    var summary: LensFlowSummary
    var requestHeaders: [HeaderField]
    var responseReason: String?
    var responseHeaders: [HeaderField]
    var endedAt: Double?
    var error: String?
    var websocketMessages: [WebSocketFrame]
    var androidContext: AndroidRequestContext?

    init(flow: FlowRecord) {
        summary = LensFlowSummary(flow: flow)
        requestHeaders = flow.requestHeaders
        responseReason = flow.responseReason
        responseHeaders = flow.responseHeaders
        endedAt = flow.endedAt
        error = flow.error
        websocketMessages = flow.websocketMessages
        androidContext = flow.androidContext
    }
}

struct LensInspectionSnapshot: Codable, Sendable {
    var available: Bool
    var selection: String
    var selectedPackage: String?
    var state: String
    var message: String
    var processes: [DebuggableProcess]
}

@MainActor
protocol DeepInspectionAutomationProviding: AnyObject {
    var isAvailable: Bool { get }
    func snapshot(for device: DeviceTarget) -> LensInspectionSnapshot
    func setSelection(mode: String, package: String?, for device: DeviceTarget) throws
}

@MainActor
final class AndroidDeepInspectionAutomationAdapter: DeepInspectionAutomationProviding {
    private let manager: AndroidInspectorManager

    init(manager: AndroidInspectorManager) {
        self.manager = manager
    }

    var isAvailable: Bool { true }

    func snapshot(for device: DeviceTarget) -> LensInspectionSnapshot {
        let selection = manager.selection(for: device)
        let selectionValue: (String, String?) = switch selection {
        case .automatic: ("automatic", nil)
        case let .package(package): ("package", package)
        case .off: ("off", nil)
        }
        let state = manager.state(for: device)
        let stateName: String = switch state {
        case .idle: "idle"
        case .discovering: "discovering"
        case .attaching: "attaching"
        case .active: "active"
        case .unsupported: "unsupported"
        case .conflict: "conflict"
        case .failed: "failed"
        }
        return LensInspectionSnapshot(
            available: true,
            selection: selectionValue.0,
            selectedPackage: selectionValue.1,
            state: stateName,
            message: state.label,
            processes: manager.processes(for: device)
        )
    }

    func setSelection(mode: String, package: String?, for device: DeviceTarget) throws {
        let selection: DeepInspectionSelection
        switch mode {
        case "automatic": selection = .automatic
        case "off": selection = .off
        case "package":
            guard let package, !package.isEmpty else {
                throw LensAutomationError.invalidInput("A package is required for package inspection mode.")
            }
            selection = .package(package)
        default:
            throw LensAutomationError.invalidInput("Inspection mode must be automatic, package, or off.")
        }
        manager.setSelection(selection, for: device)
    }
}

enum LensAutomationError: LocalizedError {
    case notFound(String)
    case invalidInput(String)
    case conflict(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .notFound(message), let .invalidInput(message), let .conflict(message), let .unavailable(message): message
        }
    }
}

@MainActor
final class LensAutomationController {
    nonisolated static let apiVersion = "1"

    private unowned let model: LensModel
    private let inspectionProvider: DeepInspectionAutomationProviding
    private var nextEventID: UInt64 = 1
    var eventSink: ((LensAPIEvent) -> Void)?

    init(model: LensModel, inspectionProvider: DeepInspectionAutomationProviding? = nil) {
        self.model = model
        self.inspectionProvider = inspectionProvider ?? AndroidDeepInspectionAutomationAdapter(manager: model.inspector)
    }

    var engineLog: String { model.engineLog }
    var hasAttachedDevices: Bool { model.devices.devices.contains(where: \.isAttached) }
    var mappings: [MappingRule] { model.mappings.rules }
    var mappingRevision: Int { model.mappings.revision }
    var devices: [DeviceTarget] { model.devices.devices }
    var activeVPNPackage: String? { model.devices.activeVPNPackage }

    func publish(type: String, payload: JSONValue = .object([:])) {
        let event = LensAPIEvent(
            id: nextEventID,
            type: type,
            timestamp: Date().timeIntervalSince1970,
            payload: payload
        )
        nextEventID &+= 1
        eventSink?(event)
    }

    func status() throws -> JSONValue {
        let engine: JSONValue
        switch model.engineState {
        case .stopped: engine = .object(["state": .string("stopped")])
        case .starting: engine = .object(["state": .string("starting")])
        case let .running(port): engine = .object(["state": .string("running"), "port": .number(Double(port))])
        case let .failed(message): engine = .object(["state": .string("failed"), "message": .string(message)])
        }
        return .object([
            "apiVersion": .string(Self.apiVersion),
            "engine": engine,
            "capturePaused": .bool(model.captures.isCapturePaused),
            "removeConditionalHeaders": .bool(model.isNoCachingEnabled),
            "flowCount": .number(Double(model.captures.flows.count)),
            "mappingCount": .number(Double(model.mappings.rules.count)),
            "deviceCount": .number(Double(model.devices.devices.count))
        ])
    }

    func capabilities() -> JSONValue {
        .object([
            "engine": .bool(true),
            "capture": .bool(true),
            "flows": .bool(true),
            "globalSearch": .bool(true),
            "responseMapping": .bool(true),
            "requestRewriting": .bool(true),
            "sessions": .bool(true),
            "androidDevices": .bool(true),
            "androidDeepInspection": .object([
                "available": .bool(inspectionProvider.isAvailable),
                "version": .number(1)
            ]),
            "pinned": .bool(false),
            "savedSidebar": .bool(false)
        ])
    }

    func startEngine() {
        model.startEngine()
        publish(type: "engine.command", payload: .object(["command": .string("start")]))
    }

    func stopEngine() async {
        await model.devices.restoreAttachedDevicesAndWait()
        model.stopEngine()
        publish(type: "engine.command", payload: .object(["command": .string("stop")]))
    }

    func restartEngine() async {
        model.stopEngine()
        try? await Task.sleep(for: .milliseconds(300))
        model.startEngine()
        publish(type: "engine.command", payload: .object(["command": .string("restart")]))
    }

    func setProxyPort(_ port: Int) throws {
        guard (1...65_535).contains(port) else {
            throw LensAutomationError.invalidInput("Proxy port must be between 1 and 65535.")
        }
        model.applyEngineSettings(proxyPort: port)
        publish(type: "settings.updated", payload: .object(["proxyPort": .number(Double(port))]))
    }

    func setCapturePaused(_ paused: Bool) {
        if model.captures.isCapturePaused != paused { model.toggleCapture() }
        publish(type: "capture.state", payload: .object(["paused": .bool(paused)]))
    }

    func clearCapture() {
        model.clearFlows()
        publish(type: "capture.cleared")
    }

    func setRemoveConditionalHeaders(_ enabled: Bool) {
        model.setNoCaching(enabled)
        publish(type: "capture.options", payload: .object(["removeConditionalHeaders": .bool(enabled)]))
    }

    func flow(id: String) throws -> FlowRecord {
        guard let flow = model.captures.flows.first(where: { $0.id == id }) else {
            throw LensAutomationError.notFound("Flow \(id) was not found.")
        }
        return flow
    }

    func filteredFlows(query: [String: String]) -> [FlowRecord] {
        var flows = model.captures.flows
        if let deviceID = query["deviceId"] { flows = flows.filter { $0.deviceID == deviceID } }
        if let host = query["host"] { flows = flows.filter { $0.host.caseInsensitiveCompare(host) == .orderedSame } }
        if let method = query["method"] { flows = flows.filter { $0.method.caseInsensitiveCompare(method) == .orderedSame } }
        if let scheme = query["scheme"] { flows = flows.filter { $0.scheme.caseInsensitiveCompare(scheme) == .orderedSame } }
        if let kind = query["kind"] {
            flows = flows.filter { flow in
                switch kind.lowercased() {
                case "websocket": !flow.websocketMessages.isEmpty
                case "json": flow.requestBody?.isJSON == true || flow.responseBody?.isJSON == true
                case "media": flow.responseBody?.mimeType?.lowercased().hasPrefix("image/") == true ||
                    flow.responseBody?.mimeType?.lowercased().hasPrefix("video/") == true ||
                    flow.responseBody?.mimeType?.lowercased().hasPrefix("audio/") == true
                default: true
                }
            }
        }
        if let search = query["search"], !search.isEmpty { flows = flows.filter { $0.matchesGlobalSearch(search) } }
        return flows.sorted { $0.startedAt > $1.startedAt }
    }

    func curl(for flow: FlowRecord) -> String {
        var parts = ["curl", "--request", shellQuote(flow.method), "--url", shellQuote(flow.url)]
        for header in flow.requestHeaders {
            parts += ["--header", shellQuote("\(header.name): \(header.value)")]
        }
        if let body = flow.requestBody, !body.data.isEmpty {
            if let text = body.text { parts += ["--data-raw", shellQuote(text)] }
            else { parts += ["--data-binary", "'<binary body omitted>'"] }
        }
        return parts.joined(separator: " ")
    }

    func createMapping(from flowID: String, behavior: MappingBehavior) throws -> UUID {
        let source = try flow(id: flowID)
        let id = behavior == .localResponse ? model.mappings.create(from: source) : model.mappings.createRequestRewrite(from: source)
        publish(type: "mapping.changed", payload: .object(["id": .string(id.uuidString), "action": .string("created")]))
        return id
    }

    func addMapping(_ rule: MappingRule) -> UUID {
        let id = model.mappings.add(rule)
        publish(type: "mapping.changed", payload: .object(["id": .string(id.uuidString), "action": .string("created")]))
        return id
    }

    func addBlankMapping(behavior: MappingBehavior) -> UUID {
        let id = model.mappings.addBlank(behavior: behavior)
        publish(type: "mapping.changed", payload: .object(["id": .string(id.uuidString), "action": .string("created")]))
        return id
    }

    func moveMappings(fromOffsets: IndexSet, toOffset: Int) {
        model.mappings.move(fromOffsets: fromOffsets, toOffset: toOffset)
        publish(type: "mapping.changed", payload: .object(["action": .string("reordered")]))
    }

    func updateMapping(_ rule: MappingRule) throws {
        guard model.mappings.rules.contains(where: { $0.id == rule.id }) else {
            throw LensAutomationError.notFound("Mapping \(rule.id) was not found.")
        }
        model.mappings.update(rule)
        publish(type: "mapping.changed", payload: .object(["id": .string(rule.id.uuidString), "action": .string("updated")]))
    }

    func setMappingEnabled(id: UUID, enabled: Bool) throws {
        guard var rule = model.mappings.rules.first(where: { $0.id == id }) else {
            throw LensAutomationError.notFound("Mapping \(id) was not found.")
        }
        rule.enabled = enabled
        model.mappings.update(rule)
        publish(type: "mapping.changed", payload: .object(["id": .string(id.uuidString), "action": .string(enabled ? "enabled" : "disabled")]))
    }

    func duplicateMapping(id: UUID) throws -> UUID {
        guard let newID = model.mappings.duplicate(id) else {
            throw LensAutomationError.notFound("Mapping \(id) was not found.")
        }
        publish(type: "mapping.changed", payload: .object(["id": .string(newID.uuidString), "action": .string("duplicated")]))
        return newID
    }

    func deleteMapping(id: UUID) throws {
        guard model.mappings.rules.contains(where: { $0.id == id }) else {
            throw LensAutomationError.notFound("Mapping \(id) was not found.")
        }
        model.mappings.remove(id)
        publish(type: "mapping.changed", payload: .object(["id": .string(id.uuidString), "action": .string("deleted")]))
    }

    func reorderMappings(ids: [UUID]) throws {
        guard model.mappings.reorder(ids: ids) else {
            throw LensAutomationError.invalidInput("Mapping order must contain every current mapping exactly once.")
        }
        publish(type: "mapping.changed", payload: .object(["action": .string("reordered")]))
    }

    func saveSession(path: String) throws {
        try validateAbsolutePath(path)
        model.saveSession(at: URL(fileURLWithPath: path))
        publish(type: "session.saved", payload: .object(["path": .string(path)]))
    }

    func openSession(path: String) throws {
        try validateAbsolutePath(path)
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw LensAutomationError.invalidInput("The session file is not readable.")
        }
        model.openSession(at: URL(fileURLWithPath: path))
        publish(type: "session.opened", payload: .object(["path": .string(path)]))
    }

    func refreshDevices() async {
        await model.refreshDevices()
        publishDevices()
    }

    func device(serial: String) throws -> DeviceTarget {
        guard let device = model.devices.devices.first(where: { $0.serial == serial }) else {
            throw LensAutomationError.notFound("Device \(serial) was not found.")
        }
        return device
    }

    func renameDevice(serial: String, name: String?) throws {
        let target = try device(serial: serial)
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.devices.rename(target, to: name)
        } else {
            model.devices.resetName(for: target)
        }
        publishDevices()
    }

    func attachDevice(serial: String, stopConflictingVPN: Bool) async throws {
        try await model.attachForAutomation(serial: serial, stopConflictingVPN: stopConflictingVPN)
        publishDevices()
    }

    func detachDevice(serial: String) async throws {
        let target = try device(serial: serial)
        try await model.devices.detach(target)
        publishDevices()
    }

    func inspection(serial: String) throws -> LensInspectionSnapshot {
        inspectionProvider.snapshot(for: try device(serial: serial))
    }

    func setInspection(serial: String, mode: String, package: String?) throws {
        let target = try device(serial: serial)
        try inspectionProvider.setSelection(mode: mode, package: package, for: target)
        let snapshot = inspectionProvider.snapshot(for: target)
        publish(type: "inspection.state", payload: (try? JSONValue(snapshot)) ?? .object([:]))
    }

    func setInspection(_ selection: DeepInspectionSelection, for device: DeviceTarget) {
        let values: (String, String?) = switch selection {
        case .automatic: ("automatic", nil)
        case let .package(package): ("package", package)
        case .off: ("off", nil)
        }
        try? setInspection(serial: device.serial, mode: values.0, package: values.1)
    }

    func requestAttach(_ device: DeviceTarget, stopConflictingVPN: Bool = false) {
        model.attach(device, stopConflictingVPN: stopConflictingVPN)
    }

    func requestDetach(_ device: DeviceTarget) {
        model.detach(device)
    }

    func publishFlow(_ flow: FlowRecord) {
        publish(type: "flow.upsert", payload: (try? JSONValue(LensFlowSummary(flow: flow))) ?? .object([:]))
    }

    func publishDevices() {
        publish(type: "devices.changed", payload: (try? JSONValue(model.devices.devices)) ?? .array([]))
    }

    private func validateAbsolutePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw LensAutomationError.invalidInput("Session paths must be absolute filesystem paths.")
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
