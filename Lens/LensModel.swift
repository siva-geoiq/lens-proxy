import AppKit
import Foundation
import Network
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class LensModel {
    let captures: CaptureStore
    let mappings: MappingStore
    let devices: DeviceManager

    private let engine: EngineProcessManager
    private let bridge: BridgeClient
    private var bridgeToken = ""

    var engineState: EngineState = .stopped
    var engineLog = ""
    var lastError: String?
    var proxyPort: Int
    var showingMappings = false
    var showingDevices = false

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
        Task {
            await refreshDevices()
            await devices.recoverPreviousAttachments()
            captures.attributeFlows(to: devices.devices)
        }
        do {
            bridgeToken = try engine.start(
                proxyPort: proxyPort,
                onControlPort: { [weak self] port in
                    Task { @MainActor in
                        guard let self else { return }
                        self.bridge.connect(port: port, token: self.bridgeToken)
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
        captures.upsert(
            FlowRecord(
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
        )
        captures.selectedFlowID = "ui-fixture-flow"
    }

    func refreshDevices() async {
        await devices.refresh()
        captures.attributeFlows(to: devices.devices)
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
        Task {
            do {
                try await devices.attach(device, proxyPort: proxyPort, stopConflictingVPN: stopConflictingVPN)
            } catch {
                lastError = error.localizedDescription
            }
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
            case "flowUpsert":
                guard let payload = envelope.payload else { return }
                let flow = try payload.decode(FlowRecord.self)
                captures.upsert(captures.attributed(flow, to: devices.devices))
            case "sessionReset":
                captures.clear()
            case "captureState":
                guard let payload = envelope.payload,
                      case let .object(object) = payload,
                      case let .bool(enabled) = object["enabled"] else { return }
                captures.isCapturePaused = !enabled
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

    private func appendLog(_ line: String) {
        engineLog += line + "\n"
        if engineLog.count > 20_000 { engineLog.removeFirst(engineLog.count - 20_000) }
    }
}
