import AppKit
import Foundation
import Network
import Observation
import OSLog
import UniformTypeIdentifiers

@MainActor
@Observable
final class LensModel {
    let captures: CaptureStore
    let mappings: MappingStore
    let devices: DeviceManager
    let inspector: AndroidInspectorManager
    @ObservationIgnored lazy var automation = LensAutomationController(model: self)
    @ObservationIgnored lazy var apiServer = LensAPIServer(controller: automation)

    private let engine: EngineProcessManager
    private let bridge: BridgeClient
    private let logger = Logger(subsystem: "com.lenskart.lens.Lens", category: "Attachment")
    private var devicePreparationTask: Task<Void, Never>?
    private var allowsAutomaticDeviceSync = true
    private var isPreparingDevices = false
    private var isAutoSyncingRememberedDevices = false

    var engineState: EngineState = .stopped
    var engineLog = ""
    var lastError: String?
    var proxyPort: Int
    var isNoCachingEnabled: Bool
    var showingMappings = false
    var showingDevices = false
    var attachingDeviceID: String?

    var detachedDevice: DeviceTarget? {
        devices.preferredDetachedDevice
    }

    init(
        captures: CaptureStore = CaptureStore(),
        mappings: MappingStore = MappingStore(),
        devices: DeviceManager = DeviceManager(),
        inspector: AndroidInspectorManager = AndroidInspectorManager(),
        engine: EngineProcessManager = EngineProcessManager(),
        bridge: BridgeClient = BridgeClient()
    ) {
        self.captures = captures
        self.mappings = mappings
        self.devices = devices
        self.inspector = inspector
        self.engine = engine
        self.bridge = bridge
        let storedPort = UserDefaults.standard.integer(forKey: "proxyPort")
        proxyPort = storedPort == 0 ? 8080 : storedPort
        isNoCachingEnabled = UserDefaults.standard.bool(forKey: "noCachingEnabled")
        bridge.onEnvelope = { [weak self] envelope in
            Task { @MainActor in self?.handle(envelope) }
        }
        bridge.onStateChange = { [weak self] state in
            if case let .failed(error) = state {
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        }
        mappings.onRulesChanged = { [weak self] rules in
            guard let self else { return }
            self.sendMappings(rules)
            self.automation.publish(
                type: "mappings.snapshot",
                payload: (try? JSONValue(rules)) ?? .array([])
            )
        }
        devices.onDevicesChanged = { [weak self] devices in
            guard let self else { return }
            self.captures.attributeFlows(to: devices)
            self.inspector.updateDevices(devices)
            self.automation.publishDevices()
            Task { await self.autoAttachRememberedDevices() }
        }
        inspector.onError = { [weak self] message in self?.lastError = message }
        inspector.onTrace = { [weak self] in self?.applyPendingAndroidContexts() }
    }

    func startAutomationAPI() {
        apiServer.start()
    }

    func startEngine() {
        allowsAutomaticDeviceSync = true
        devices.startMonitoring()
        switch engineState {
        case .stopped, .failed:
            break
        case .starting, .running:
            return
        }
        lastError = nil
        engineState = .starting
        devicePreparationTask?.cancel()
        isPreparingDevices = true
        devicePreparationTask = Task {
            defer { self.isPreparingDevices = false }
            for attempt in 0..<10 {
                await refreshDevices(autoAttachRememberedDevice: false)
                if !devices.devices.isEmpty || Task.isCancelled { break }
                logger.info("No Android devices found on discovery attempt \(attempt + 1); retrying")
                try? await Task.sleep(for: .milliseconds(500))
            }
            await devices.recoverPreviousAttachments()
            captures.attributeFlows(to: devices.devices)
            logger.info("Device preparation completed with \(self.devices.devices.count) connected device(s)")
            await autoAttachRememberedDevices(allowDuringPreparation: true)
        }
        do {
            _ = try engine.start(
                proxyPort: proxyPort,
                onControlPort: { [weak self] port, token in
                    Task { @MainActor in
                        guard let self else { return }
                        self.bridge.connect(port: port, token: token)
                    }
                },
                onLog: { [weak self] line in
                    Task { @MainActor in self?.appendLog(line) }
                },
                onExit: { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        self.bridge.disconnect()
                        if status == 0 { self.engineState = .stopped }
                        else { self.engineState = .failed("mitmdump exited with status \(status).") }
                    }
                }
            )
        } catch {
            engineState = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func prepareUITestFixture() {
        engineState = .running(port: proxyPort)
        let emulator = DeviceTarget(
            serial: "emulator-5554",
            model: "sdk_gphone64_arm64",
            apiLevel: 35,
            kind: .emulator,
            rootState: .available,
            isAttached: false,
            previousProxy: nil,
            caInstalled: false,
            networkAddresses: ["10.0.2.15"]
        )
        devices.prepareUITestDevices([emulator])
        let flow = FlowRecord(
                id: "ui-fixture-flow",
                clientAddress: "10.0.2.15",
                method: "POST",
                scheme: "https",
                host: "firebaseremoteconfig.googleapis.com",
                port: 443,
                path: "/v1/projects/446182039508/namespaces/firebase:fetch",
                url: "https://firebaseremoteconfig.googleapis.com/v1/projects/446182039508/namespaces/firebase:fetch",
                requestHeaders: [HeaderField(name: "Content-Type", value: "application/json")],
                requestBody: BodyPayload(data: Data("{\"appVersion\":\"5.8.9\"}".utf8), isText: true, truncated: false, mimeType: "application/json"),
                responseStatus: 200,
                responseReason: "OK",
                responseHeaders: [HeaderField(name: "Content-Type", value: "application/json")],
                responseBody: BodyPayload(data: Data("{\"state\":\"NO_CHANGE\"}".utf8), isText: true, truncated: false, mimeType: "application/json"),
                startedAt: Date().timeIntervalSince1970,
                endedAt: Date().timeIntervalSince1970 + 0.04,
                duration: 0.04,
                size: 21,
                mappedRuleID: nil,
                mappedRuleName: nil,
                error: nil,
                websocketMessages: []
        )
        captures.upsert(captures.attributed(flow, to: devices.devices))
        captures.selectedFlowID = "ui-fixture-flow"
    }

    func refreshDevices(autoAttachRememberedDevice: Bool = true) async {
        await devices.refresh()
        if autoAttachRememberedDevice {
            await autoAttachRememberedDevices()
        }
    }

    func stopEngine() {
        allowsAutomaticDeviceSync = false
        bridge.send(type: "shutdown")
        engine.stop()
        bridge.disconnect()
        engineState = .stopped
    }

    func applyEngineSettings(proxyPort: Int) {
        let shouldRestart = engine.isRunning && self.proxyPort != proxyPort
        self.proxyPort = proxyPort
        UserDefaults.standard.set(proxyPort, forKey: "proxyPort")
        if shouldRestart {
            stopEngine()
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                startEngine()
            }
        } else if !engine.isRunning {
            engineState = .stopped
            startEngine()
        }
    }

    func toggleCapture() {
        captures.isCapturePaused.toggle()
        bridge.send(type: "setCaptureEnabled", payload: ["enabled": !captures.isCapturePaused])
    }

    func setNoCaching(_ enabled: Bool) {
        isNoCachingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "noCachingEnabled")
        bridge.send(type: "setNoCaching", payload: ["enabled": enabled])
    }

    func toggleNoCaching() {
        setNoCaching(!isNoCachingEnabled)
    }

    func clearFlows() {
        captures.clear()
        inspector.clear()
        bridge.send(type: "clearFlows")
    }

    func mapSelectedFlow() {
        guard let flow = captures.selectedFlow else { return }
        _ = mappings.create(from: flow)
        showingMappings = true
    }

    func rewriteSelectedRequest() {
        guard let flow = captures.selectedFlow else { return }
        _ = mappings.createRequestRewrite(from: flow)
        showingMappings = true
    }

    @discardableResult
    func createRequestHeaderRewrite(for flow: FlowRecord) -> UUID {
        mappings.createRequestHeaderRewrite(from: flow)
    }

    @discardableResult
    func updateMockResponse(for flow: FlowRecord, json: JSONValue) -> UUID? {
        do {
            var responseBody = flow.responseBody ?? .empty
            responseBody.data = try json.encodedJSON()
            responseBody.isText = true
            responseBody.truncated = false
            responseBody.mimeType = responseBody.mimeType ?? "application/json"
            return mappings.upsertResponseBody(responseBody, from: flow)
        } catch {
            lastError = "Could not update the JSON mock: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func updateRequestRewrite(for flow: FlowRecord, json: JSONValue) -> UUID? {
        do {
            var requestBody = flow.requestBody ?? .empty
            requestBody.data = try json.encodedJSON()
            requestBody.isText = true
            requestBody.truncated = false
            requestBody.mimeType = requestBody.mimeType ?? "application/json"
            return mappings.upsertRequestBody(requestBody, from: flow)
        } catch {
            lastError = "Could not update the request rewrite: \(error.localizedDescription)"
            return nil
        }
    }

    func saveSession() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "Lens Session.mitm"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try automation.saveSession(path: url.path) }
        catch { lastError = error.localizedDescription }
    }

    func saveSession(at url: URL) {
        bridge.send(type: "saveSession", payload: ["path": url.path])
    }

    func openSession() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try automation.openSession(path: url.path) }
        catch { lastError = error.localizedDescription }
    }

    func openSession(at url: URL) {
        bridge.send(type: "openSession", payload: ["path": url.path])
    }

    func attach(_ device: DeviceTarget, stopConflictingVPN: Bool = false) {
        guard attachingDeviceID == nil else { return }
        guard case .running = engineState else {
            lastError = "Wait for the Lens proxy engine to finish starting before attaching a device."
            return
        }
        Task {
            await attachDevice(device, stopConflictingVPN: stopConflictingVPN)
        }
    }

    func detach(_ device: DeviceTarget) {
        Task {
            do {
                try await devices.detach(device)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func shutdown() async {
        apiServer.stop()
        allowsAutomaticDeviceSync = false
        devicePreparationTask?.cancel()
        devices.stopMonitoring()
        await inspector.stop()
        await devices.restoreAttachedDevicesAndWait()
        stopEngine()
    }

    func attachForAutomation(serial: String, stopConflictingVPN: Bool = false) async throws {
        guard attachingDeviceID == nil else {
            throw LensAutomationError.conflict("Another device attachment is already in progress.")
        }
        guard case .running = engineState else {
            throw LensAutomationError.unavailable("The Lens proxy engine is not running.")
        }
        guard let device = devices.devices.first(where: { $0.serial == serial }) else {
            throw LensAutomationError.notFound("Device \(serial) was not found.")
        }
        attachingDeviceID = serial
        defer { attachingDeviceID = nil }
        try await devices.attach(device, proxyPort: proxyPort, stopConflictingVPN: stopConflictingVPN)
        captures.attributeFlows(to: devices.devices)
    }

#if DEBUG
    func attachDeviceForEndToEndTest(serial: String) async {
        for _ in 0..<100 {
            if case .running = engineState,
               let device = devices.devices.first(where: { $0.serial == serial }) {
                await attachDevice(device)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        lastError = "The end-to-end device \(serial) was not ready to attach."
    }
#endif

    private func handle(_ envelope: BridgeEnvelope) {
        if let error = envelope.error {
            lastError = error.message
            return
        }
        do {
            switch envelope.type {
            case "hello":
                guard envelope.protocolVersion == 2 else {
                    engineState = .failed("Lens bridge protocol \(envelope.protocolVersion) is incompatible with this app.")
                    bridge.disconnect()
                    engine.stop()
                    return
                }
                if let payload = envelope.payload,
                   case let .object(object) = payload,
                   case let .string(version) = object["mitmproxyVersion"],
                   version.split(separator: ".").first != "12" {
                    engineState = .failed("Lens requires mitmproxy 12.x; found \(version).")
                    bridge.disconnect()
                    engine.stop()
                }
            case "authenticated":
                engineState = .running(port: proxyPort)
                sendMappings(mappings.rules)
                bridge.send(type: "setNoCaching", payload: ["enabled": isNoCachingEnabled])
                Task { await autoAttachRememberedDevices() }
            case "flowUpsert":
                guard let payload = envelope.payload else { return }
                var flow = captures.attributed(try payload.decode(FlowRecord.self), to: devices.devices)
                if flow.androidContext == nil, let context = inspector.context(for: flow) {
                    flow.androidContext = context
                    bridge.send(
                        type: "annotateFlow",
                        payload: FlowAnnotationPayload(flowID: flow.id, androidContext: context)
                    )
                } else if let context = flow.androidContext {
                    _ = inspector.context(for: flow)
                    flow.androidContext = context
                }
                let pathWithoutQuery = String(flow.path.split(separator: "?", maxSplits: 1).first ?? "")
                let mappingName = flow.mappedRuleName ?? "none"
                let rewriteName = flow.rewrittenRuleName ?? "none"
                logger.info(
                    "Captured \(flow.method, privacy: .public) \(flow.host, privacy: .public)\(pathWithoutQuery, privacy: .public) status \(flow.responseStatus ?? -1) mapping \(mappingName, privacy: .public) rewrite \(rewriteName, privacy: .public)"
                )
                captures.upsert(flow)
                automation.publishFlow(flow)
            case "sessionReset":
                captures.clear()
            case "captureState":
                guard let payload = envelope.payload,
                      case let .object(object) = payload,
                      case let .bool(enabled) = object["enabled"] else { return }
                captures.isCapturePaused = !enabled
            case "noCachingState":
                guard let payload = envelope.payload,
                      case let .object(object) = payload,
                      case let .bool(enabled) = object["enabled"] else { return }
                isNoCachingEnabled = enabled
                UserDefaults.standard.set(enabled, forKey: "noCachingEnabled")
            case "engineError", "clientError":
                lastError = envelope.error?.message ?? "An engine communication error occurred."
            default:
                break
            }
        } catch {
            lastError = "Could not decode \(envelope.type): \(error.localizedDescription)"
        }
    }

    private func applyPendingAndroidContexts() {
        for var flow in captures.flows where flow.androidContext == nil {
            guard let context = inspector.context(for: flow) else { continue }
            flow.androidContext = context
            captures.upsert(flow)
            bridge.send(
                type: "annotateFlow",
                payload: FlowAnnotationPayload(flowID: flow.id, androidContext: context)
            )
        }
    }

    private func sendMappings(_ rules: [MappingRule]) {
        bridge.send(type: "setMappings", payload: ["rules": rules])
    }

    private func autoAttachRememberedDevices(allowDuringPreparation: Bool = false) async {
        guard allowsAutomaticDeviceSync else { return }
        guard allowDuringPreparation || !isPreparingDevices else { return }
        guard engineCanAcceptDeviceTraffic else {
            logger.notice("Skipping auto-attach because the proxy engine is unavailable")
            return
        }
        guard attachingDeviceID == nil, !isAutoSyncingRememberedDevices else { return }
        let targets = devices.rememberedDetachedDevices
        guard !targets.isEmpty else { return }

        isAutoSyncingRememberedDevices = true
        defer { isAutoSyncingRememberedDevices = false }
        for rememberedTarget in targets {
            guard allowsAutomaticDeviceSync, engineCanAcceptDeviceTraffic else { break }
            guard let currentTarget = devices.devices.first(where: {
                $0.aliasKey == rememberedTarget.aliasKey && !$0.isAttached
            }) else { continue }
            logger.info("Auto-syncing remembered device \(currentTarget.serial, privacy: .public)")
            await attachDevice(currentTarget)
        }
    }

    private var engineCanAcceptDeviceTraffic: Bool {
        switch engineState {
        case .running: true
        case .starting, .stopped, .failed: false
        }
    }

    private func attachDevice(_ device: DeviceTarget, stopConflictingVPN: Bool = false) async {
        attachingDeviceID = device.serial
        defer { attachingDeviceID = nil }
        do {
            try await devices.attach(device, proxyPort: proxyPort, stopConflictingVPN: stopConflictingVPN)
            captures.attributeFlows(to: devices.devices)
            logger.info("Attached \(device.serial, privacy: .public) to proxy port \(self.proxyPort)")
        } catch {
            logger.error("Failed to attach \(device.serial, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    private func appendLog(_ line: String) {
        engineLog += line + "\n"
        if engineLog.count > 20_000 { engineLog.removeFirst(engineLog.count - 20_000) }
    }
}
