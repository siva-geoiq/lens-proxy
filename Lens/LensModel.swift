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

    private let engine: EngineProcessManager
    private let bridge: BridgeClient
    private let logger = Logger(subsystem: "com.lenskart.lens.Lens", category: "Attachment")
    private var devicePreparationTask: Task<Void, Never>?

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
        engine: EngineProcessManager = EngineProcessManager(),
        bridge: BridgeClient = BridgeClient()
    ) {
        self.captures = captures
        self.mappings = mappings
        self.devices = devices
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
        mappings.onRulesChanged = { [weak self] rules in self?.sendMappings(rules) }
    }

    func startEngine() {
        switch engineState {
        case .stopped, .failed:
            break
        case .starting, .running:
            return
        }
        lastError = nil
        engineState = .starting
        devicePreparationTask?.cancel()
        devicePreparationTask = Task {
            for attempt in 0..<10 {
                await refreshDevices(autoAttachRememberedDevice: false)
                if !devices.devices.isEmpty || Task.isCancelled { break }
                logger.info("No Android devices found on discovery attempt \(attempt + 1); retrying")
                try? await Task.sleep(for: .milliseconds(500))
            }
            await devices.recoverPreviousAttachments()
            captures.attributeFlows(to: devices.devices)
            logger.info("Device preparation completed with \(self.devices.devices.count) connected device(s)")
            await autoAttachRememberedEmulator()
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
        captures.attributeFlows(to: devices.devices)
        if autoAttachRememberedDevice {
            await autoAttachRememberedEmulator()
        }
    }

    func stopEngine() {
        bridge.send(type: "shutdown")
        engine.stop()
        bridge.disconnect()
        engineState = .stopped
    }

    func applyEngineSettings(proxyPort: Int, mitmdumpPath: String?) {
        let currentMitmdumpPath = UserDefaults.standard.string(forKey: "mitmdumpPath")
        let shouldRestart = engine.isRunning && (self.proxyPort != proxyPort || currentMitmdumpPath != mitmdumpPath)
        self.proxyPort = proxyPort
        UserDefaults.standard.set(proxyPort, forKey: "proxyPort")
        UserDefaults.standard.set(mitmdumpPath, forKey: "mitmdumpPath")
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
        bridge.send(type: "clearFlows")
    }

    func mapSelectedFlow() {
        guard let flow = captures.selectedFlow else { return }
        _ = mappings.create(from: flow)
        showingMappings = true
    }

    func saveSession() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.nameFieldStringValue = "Lens Session.mitm"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bridge.send(type: "saveSession", payload: ["path": url.path])
    }

    func openSession() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bridge.send(type: "openSession", payload: ["path": url.path])
    }

    func attach(_ device: DeviceTarget, stopConflictingVPN: Bool = false) {
        guard attachingDeviceID == nil else { return }
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
        await devices.restoreAttachedDevicesAndWait()
        stopEngine()
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
                guard envelope.protocolVersion == 1 else {
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
            case "flowUpsert":
                guard let payload = envelope.payload else { return }
                let flow = try payload.decode(FlowRecord.self)
                let pathWithoutQuery = String(flow.path.split(separator: "?", maxSplits: 1).first ?? "")
                let mappingName = flow.mappedRuleName ?? "none"
                logger.info(
                    "Captured \(flow.method, privacy: .public) \(flow.host, privacy: .public)\(pathWithoutQuery, privacy: .public) status \(flow.responseStatus ?? -1) mapping \(mappingName, privacy: .public)"
                )
                captures.upsert(captures.attributed(flow, to: devices.devices))
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

    private func sendMappings(_ rules: [MappingRule]) {
        bridge.send(type: "setMappings", payload: ["rules": rules])
    }

    private func autoAttachRememberedEmulator() async {
        guard engineCanAcceptDeviceTraffic else {
            logger.notice("Skipping auto-attach because the proxy engine is unavailable")
            return
        }
        guard let serial = devices.lastAttachedEmulatorSerial else {
            logger.info("Skipping auto-attach because no emulator is remembered")
            return
        }
        guard let target = devices.devices.first(where: { $0.serial == serial && !$0.isAttached }) else {
            logger.notice("Remembered emulator \(serial, privacy: .public) is unavailable or already attached")
            return
        }
        guard attachingDeviceID == nil else {
            logger.info("Skipping duplicate auto-attach for \(serial, privacy: .public)")
            return
        }
        logger.info("Auto-attaching remembered emulator \(serial, privacy: .public)")
        await attachDevice(target)
    }

    private var engineCanAcceptDeviceTraffic: Bool {
        switch engineState {
        case .starting, .running: true
        case .stopped, .failed: false
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
