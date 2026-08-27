import Foundation
import Network
import Observation

private final class AndroidAgentSession: @unchecked Sendable {
    let process: DebuggableProcess
    let bridge: AgentBridgeClient
    let localPort: Int
    let socketName: String
    let remotePath: String

    init(process: DebuggableProcess, bridge: AgentBridgeClient, localPort: Int, socketName: String, remotePath: String) {
        self.process = process
        self.bridge = bridge
        self.localPort = localPort
        self.socketName = socketName
        self.remotePath = remotePath
    }
}

private final class AndroidActivityMonitor: @unchecked Sendable {
    let process: Process
    let pipe: Pipe
    var buffer = ""

    init(process: Process, pipe: Pipe) {
        self.process = process
        self.pipe = pipe
    }
}

@MainActor
@Observable
final class AndroidInspectorManager {
    private(set) var processesByDevice: [String: [DebuggableProcess]] = [:]
    private(set) var stateByDevice: [String: InspectionState] = [:]
    private(set) var selectionByDevice: [String: DeepInspectionSelection] = [:]

    var onError: ((String) -> Void)?
    var onTrace: (() -> Void)?

    private let runner = CommandRunner()
    private let runtimePaths: LensRuntimePaths
    private let defaults: UserDefaults
    private let correlator: AndroidTraceCorrelator
    private var devicesByID: [String: DeviceTarget] = [:]
    private var monitorTasks: [String: Task<Void, Never>] = [:]
    private var activityMonitors: [String: AndroidActivityMonitor] = [:]
    private var latestActivities: [String: AndroidActivitySnapshot] = [:]
    private var sessions: [String: AndroidAgentSession] = [:]
    private var lastFullProcessScanByDevice: [String: Date] = [:]
    private var refreshingDeviceIDs = Set<String>()

    init(
        defaults: UserDefaults = .standard,
        runtimePaths: LensRuntimePaths = .live(),
        correlator: AndroidTraceCorrelator = AndroidTraceCorrelator()
    ) {
        self.defaults = defaults
        self.runtimePaths = runtimePaths
        self.correlator = correlator
    }

    func updateDevices(_ allDevices: [DeviceTarget]) {
        // Deep Inspection drives an ADB agent, so an iOS target would poll a serial that
        // ADB has never heard of every two seconds.
        let devices = allDevices.filter(\.supportsAndroidTooling)
        devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.serial, $0) })
        let activeIDs = Set(devices.filter(\.isAttached).map(\.serial))
        for id in monitorTasks.keys where !activeIDs.contains(id) {
            stopInspecting(deviceID: id)
        }
        for device in devices where device.isAttached && monitorTasks[device.serial] == nil {
            selectionByDevice[device.serial] = loadSelection(for: device)
            stateByDevice[device.serial] = .discovering
            startActivityMonitor(for: device)
            monitorTasks[device.serial] = Task { [weak self] in
                await self?.removeStaleInspectorArtifacts(on: device)
                while !Task.isCancelled {
                    await self?.refresh(deviceID: device.serial)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    func selection(for device: DeviceTarget) -> DeepInspectionSelection {
        selectionByDevice[device.serial] ?? loadSelection(for: device)
    }

    func setSelection(_ selection: DeepInspectionSelection, for device: DeviceTarget) {
        selectionByDevice[device.serial] = selection
        persistSelection(selection, for: device)
        Task { await refresh(deviceID: device.serial, forceReattach: true) }
    }

    func processes(for device: DeviceTarget) -> [DebuggableProcess] {
        processesByDevice[device.serial] ?? []
    }

    func state(for device: DeviceTarget) -> InspectionState {
        stateByDevice[device.serial] ?? .idle
    }

    func context(for flow: FlowRecord) -> AndroidRequestContext? {
        if let context = flow.androidContext {
            correlator.remember(context, for: flow.id)
            return context
        }
        return correlator.context(for: flow)
    }

    func clear() {
        correlator.clear()
    }

    func stop() async {
        let deviceIDs = Array(monitorTasks.keys)
        for deviceID in deviceIDs { stopInspecting(deviceID: deviceID) }
        for session in sessions.values {
            await cleanUp(session)
        }
        sessions.removeAll()
    }

    private func refresh(deviceID: String, forceReattach: Bool = false) async {
        guard let device = devicesByID[deviceID], device.isAttached else { return }
        guard refreshingDeviceIDs.insert(deviceID).inserted else { return }
        defer { refreshingDeviceIDs.remove(deviceID) }
        do {
            let discovered = try await discoverProcesses(on: device)
            processesByDevice[deviceID] = discovered
            let selection = selectionByDevice[deviceID] ?? .automatic
            let packageName: String?
            switch selection {
            case .off:
                packageName = nil
            case let .package(package):
                packageName = package
            case .automatic:
                if let activity = latestActivities[deviceID], discovered.contains(where: { $0.packageName == activity.packageName }) {
                    packageName = activity.packageName
                } else {
                    let discoveredPackages = Set(discovered.map(\.packageName))
                    packageName = sessions.values.first(where: { $0.process.deviceID == deviceID })?.process.packageName
                        ?? (discoveredPackages.count == 1 ? discoveredPackages.first : nil)
                }
            }

            guard let packageName else {
                await stopSessions(deviceID: deviceID)
                stateByDevice[deviceID] = selection == .off ? .idle : .discovering
                return
            }
            let targets = discovered.filter { $0.packageName == packageName }
            guard !targets.isEmpty else {
                await stopSessions(deviceID: deviceID)
                stateByDevice[deviceID] = .unsupported("\(packageName) is not currently debuggable")
                return
            }
            if forceReattach {
                await stopSessions(deviceID: deviceID)
            }
            let targetIDs = Set(targets.map(\.id))
            for key in sessions.keys where sessions[key]?.process.deviceID == deviceID && !targetIDs.contains(key) {
                if let session = sessions.removeValue(forKey: key) { await cleanUp(session) }
            }
            if targets.contains(where: { sessions[$0.id] == nil }) {
                stateByDevice[deviceID] = .attaching(packageName)
            }
            for target in targets where sessions[target.id] == nil {
                try await attach(target, on: device)
            }
        } catch {
            stateByDevice[deviceID] = .failed(error.localizedDescription)
        }
    }

    private func discoverProcesses(on device: DeviceTarget) async throws -> [DebuggableProcess] {
        let psOutput = try await shell(device.serial, ["ps", "-A", "-o", "PID,NAME"], timeout: 4).output
        let names = AndroidInspectionParser.processes(psOutput)
        let now = Date()
        let shouldScanAll = lastFullProcessScanByDevice[device.serial].map { now.timeIntervalSince($0) >= 30 } ?? true
        let debuggable: [Int: String]
        if shouldScanAll {
            let command = """
            ps -A -o PID,NAME | while read pid name; do \
            pkg=${name%%:*}; case "$pkg" in *.*) \
            if run-as "$pkg" true 2>/dev/null; then echo "$pid $name"; fi;; esac; done
            """
            let result = try await shell(device.serial, [command], timeout: 12)
            guard result.status == 0 else { throw AndroidInspectorError.processDiscoveryFailed(result.errorOutput) }
            debuggable = AndroidInspectionParser.processes(result.output)
            lastFullProcessScanByDevice[device.serial] = now
        } else {
            var packages = Set(processesByDevice[device.serial, default: []].map(\.packageName))
            if let activity = latestActivities[device.serial] { packages.insert(activity.packageName) }
            if case let .package(package) = selectionByDevice[device.serial] { packages.insert(package) }
            var verified = Set<String>()
            for package in packages {
                if try await shell(device.serial, ["run-as", package, "true"], timeout: 3).status == 0 {
                    verified.insert(package)
                }
            }
            debuggable = names.filter { _, processName in
                let packageName = processName.split(separator: ":", maxSplits: 1).first.map(String.init) ?? processName
                return verified.contains(packageName)
            }
        }

        let abi64Output = try await shell(device.serial, ["getprop", "ro.product.cpu.abilist64"], timeout: 4).output
        let abi32Output = try await shell(device.serial, ["getprop", "ro.product.cpu.abilist32"], timeout: 4).output
        let preferred64ABI = abi64Output
            .split(separator: ",")
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "arm64-v8a"
        let preferred32ABI = abi32Output
            .split(separator: ",")
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "armeabi-v7a"
        var result: [DebuggableProcess] = []
        for (pid, processName) in debuggable {
            let packageName = processName.split(separator: ":", maxSplits: 1).first.map(String.init) ?? processName
            let executable = try? await shell(
                device.serial,
                ["run-as", packageName, "readlink", "/proc/\(pid)/exe"],
                timeout: 3
            ).output
            let abi = executable?.contains("app_process32") == true ? preferred32ABI : preferred64ABI
            result.append(
                DebuggableProcess(
                    deviceID: device.serial,
                    packageName: packageName,
                    processName: processName,
                    pid: pid,
                    abi: abi
                )
            )
        }
        return result.sorted { lhs, rhs in
            if lhs.packageName == rhs.packageName { return lhs.processName < rhs.processName }
            return lhs.packageName < rhs.packageName
        }
    }

    private func attach(_ target: DebuggableProcess, on device: DeviceTarget) async throws {
        guard target.abi == "arm64-v8a" || target.abi == "x86_64" else {
            throw AndroidInspectorError.unsupportedABI(target.abi)
        }
        guard let agentURL = runtimePaths.bundledAndroidAgentURL(abi: target.abi) else {
            throw AndroidInspectorError.agentMissing(target.abi)
        }
        let runAs = try await shell(device.serial, ["run-as", target.packageName, "pwd"], timeout: 4)
        guard runAs.status == 0 else { throw AndroidInspectorError.notDebuggable(target.packageName) }
        let dataDirectory = runAs.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteDirectory = "\(dataDirectory)/code_cache/lens-inspector"
        let remotePath = "\(remoteDirectory)/liblens_jvmti.so"
        let temporaryPath = "/data/local/tmp/lens-jvmti-\(target.pid).so"
        rememberInspectedPackage(target.packageName, on: device)
        _ = try await shell(device.serial, ["run-as", target.packageName, "mkdir", "-p", remoteDirectory], timeout: 4)
        _ = try await adb(device.serial, ["push", agentURL.path, temporaryPath], timeout: 15)
        _ = try await shell(device.serial, ["chmod", "0644", temporaryPath], timeout: 4)
        let copy = try await shell(device.serial, ["run-as", target.packageName, "cp", temporaryPath, remotePath], timeout: 6)
        _ = try? await shell(device.serial, ["rm", "-f", temporaryPath], timeout: 4)
        guard copy.status == 0 else { throw AndroidInspectorError.agentCopyFailed(copy.errorOutput) }
        _ = try await shell(device.serial, ["run-as", target.packageName, "chmod", "0700", remotePath], timeout: 4)

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let socketName = "lens-inspector-\(target.pid)-\(token.prefix(8))"
        let forward = try await adb(device.serial, ["forward", "tcp:0", "localabstract:\(socketName)"], timeout: 5)
        guard let localPort = Int(forward.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AndroidInspectorError.forwardFailed(forward.errorOutput)
        }
        let options = "socket=\(socketName),token=\(token),protocol=1"
        let attached = try await shell(device.serial, ["am", "attach-agent", String(target.pid), "\(remotePath)=\(options)"], timeout: 8)
        guard attached.status == 0 else {
            _ = try? await adb(device.serial, ["forward", "--remove", "tcp:\(localPort)"], timeout: 4)
            throw AndroidInspectorError.attachFailed(attached.errorOutput.isEmpty ? attached.output : attached.errorOutput)
        }

        let bridge = AgentBridgeClient()
        bridge.onEnvelope = { [weak self] envelope in
            Task { @MainActor in self?.handle(envelope, process: target) }
        }
        bridge.onStateChange = { [weak self] state in
            if case let .failed(error) = state {
                Task { @MainActor in self?.stateByDevice[target.deviceID] = .failed(error.localizedDescription) }
            }
        }
        let session = AndroidAgentSession(
            process: target,
            bridge: bridge,
            localPort: localPort,
            socketName: socketName,
            remotePath: remotePath
        )
        sessions[target.id] = session
        bridge.connect(port: UInt16(localPort), token: token)
    }

    private func handle(_ envelope: AgentEnvelope, process: DebuggableProcess) {
        if let error = envelope.error {
            stateByDevice[process.deviceID] = .failed(error.message)
            return
        }
        guard envelope.protocolVersion == 1 else {
            stateByDevice[process.deviceID] = .unsupported("Android inspector protocol mismatch")
            return
        }
        switch envelope.type {
        case "authenticated":
            stateByDevice[process.deviceID] = .attaching(process.packageName)
        case "ready":
            stateByDevice[process.deviceID] = .active(process.packageName)
        case "trace":
            guard let payload = envelope.payload else {
                stateByDevice[process.deviceID] = .failed("Android inspector trace was missing its payload")
                return
            }
            let trace: AndroidAgentTrace
            do {
                trace = try payload.decode(AndroidAgentTrace.self)
            } catch {
                stateByDevice[process.deviceID] = .failed("Could not decode Android request context: \(error.localizedDescription)")
                return
            }
            correlator.ingest(
                trace,
                deviceID: process.deviceID,
                packageName: process.packageName,
                activity: latestActivities[process.deviceID]
            )
            onTrace?()
        case "unsupported":
            let message = envelope.payload.flatMap { try? $0.decode([String: String].self)["message"] } ?? "Unsupported OkHttp runtime"
            stateByDevice[process.deviceID] = .unsupported(message)
        default:
            break
        }
    }

    private func startActivityMonitor(for device: DeviceTarget) {
        guard activityMonitors[device.serial] == nil, let adbURL = runtimePaths.bundledADBURL() else { return }
        Task {
            if let snapshot = try? await shell(device.serial, ["dumpsys", "window"], timeout: 5).output,
               let activity = AndroidInspectionParser.foregroundActivity(snapshot) {
                latestActivities[device.serial] = activity
            }
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = adbURL
        process.arguments = ["-s", device.serial, "logcat", "-b", "events", "-v", "brief", "wm_set_resumed_activity:I", "*:S"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let monitor = AndroidActivityMonitor(process: process, pipe: pipe)
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak monitor] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), let monitor else { return }
            Task { @MainActor in
                monitor.buffer += text
                let lines = monitor.buffer.components(separatedBy: .newlines)
                monitor.buffer = lines.last ?? ""
                for line in lines.dropLast() {
                    if let activity = AndroidInspectionParser.activityEvent(line) {
                        self?.latestActivities[device.serial] = activity
                        Task { await self?.refresh(deviceID: device.serial) }
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.activityMonitors.removeValue(forKey: device.serial) }
        }
        do {
            try process.run()
            activityMonitors[device.serial] = monitor
        } catch {
            stateByDevice[device.serial] = .failed("Could not track Android activities: \(error.localizedDescription)")
        }
    }

    private func stopInspecting(deviceID: String) {
        monitorTasks.removeValue(forKey: deviceID)?.cancel()
        if let monitor = activityMonitors.removeValue(forKey: deviceID) {
            monitor.pipe.fileHandleForReading.readabilityHandler = nil
            if monitor.process.isRunning { monitor.process.terminate() }
        }
        Task { await stopSessions(deviceID: deviceID) }
        processesByDevice.removeValue(forKey: deviceID)
        lastFullProcessScanByDevice.removeValue(forKey: deviceID)
        stateByDevice[deviceID] = .idle
    }

    private func stopSessions(deviceID: String) async {
        let keys = sessions.keys.filter { sessions[$0]?.process.deviceID == deviceID }
        for key in keys {
            if let session = sessions.removeValue(forKey: key) { await cleanUp(session) }
        }
    }

    private func cleanUp(_ session: AndroidAgentSession) async {
        session.bridge.send(type: "shutdown")
        session.bridge.disconnect()
        _ = try? await adb(session.process.deviceID, ["forward", "--remove", "tcp:\(session.localPort)"], timeout: 4)
        _ = try? await shell(
            session.process.deviceID,
            ["run-as", session.process.packageName, "rm", "-rf", (session.remotePath as NSString).deletingLastPathComponent],
            timeout: 4
        )
    }

    private func removeStaleInspectorArtifacts(on device: DeviceTarget) async {
        if let forwards = try? await adb(device.serial, ["forward", "--list"], timeout: 4).output {
            for line in forwards.split(whereSeparator: \.isNewline) {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 3,
                      fields[0] == Substring(device.serial),
                      fields[2].hasPrefix("localabstract:lens-inspector-") else { continue }
                _ = try? await adb(device.serial, ["forward", "--remove", String(fields[1])], timeout: 4)
            }
        }
        for packageName in rememberedInspectedPackages(on: device) {
            if let result = try? await shell(
                device.serial,
                ["run-as", packageName, "rm", "-rf", "code_cache/lens-inspector"],
                timeout: 4
            ), result.status == 0 {
                forgetInspectedPackage(packageName, on: device)
            }
        }
    }

    private func adb(_ serial: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        guard let adbURL = runtimePaths.bundledADBURL() else { throw AndroidInspectorError.adbMissing }
        return try await runner.run(adbURL, arguments: ["-s", serial] + arguments, timeout: timeout)
    }

    private func shell(_ serial: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await adb(serial, ["shell"] + arguments, timeout: timeout)
    }

    private func selectionKey(for device: DeviceTarget) -> String {
        "deepInspectionSelection.\(device.aliasKey)"
    }

    private func loadSelection(for device: DeviceTarget) -> DeepInspectionSelection {
        guard let data = defaults.data(forKey: selectionKey(for: device)),
              let selection = try? JSONDecoder().decode(DeepInspectionSelection.self, from: data) else { return .automatic }
        return selection
    }

    private func persistSelection(_ selection: DeepInspectionSelection, for device: DeviceTarget) {
        defaults.set(try? JSONEncoder().encode(selection), forKey: selectionKey(for: device))
    }

    private func inspectedPackagesKey(for device: DeviceTarget) -> String {
        "lensInspectorPackages.\(device.aliasKey)"
    }

    private func rememberedInspectedPackages(on device: DeviceTarget) -> Set<String> {
        Set(defaults.stringArray(forKey: inspectedPackagesKey(for: device)) ?? [])
    }

    private func rememberInspectedPackage(_ packageName: String, on device: DeviceTarget) {
        var packages = rememberedInspectedPackages(on: device)
        packages.insert(packageName)
        defaults.set(packages.sorted(), forKey: inspectedPackagesKey(for: device))
    }

    private func forgetInspectedPackage(_ packageName: String, on device: DeviceTarget) {
        var packages = rememberedInspectedPackages(on: device)
        packages.remove(packageName)
        defaults.set(packages.sorted(), forKey: inspectedPackagesKey(for: device))
    }
}

enum AndroidInspectorError: LocalizedError {
    case adbMissing
    case agentMissing(String)
    case unsupportedABI(String)
    case notDebuggable(String)
    case agentCopyFailed(String)
    case processDiscoveryFailed(String)
    case forwardFailed(String)
    case attachFailed(String)

    var errorDescription: String? {
        switch self {
        case .adbMissing: "Bundled ADB is unavailable. Reinstall Lens."
        case let .agentMissing(abi): "The bundled Android inspector agent for \(abi) is missing."
        case let .unsupportedABI(abi): "Deep Inspection does not support Android ABI \(abi)."
        case let .notDebuggable(package): "\(package) is not debuggable or does not permit run-as."
        case let .agentCopyFailed(message): "Could not stage the Android inspector agent: \(message)"
        case let .processDiscoveryFailed(message): "Could not discover debuggable Android processes: \(message)"
        case let .forwardFailed(message): "Could not open the Android inspector channel: \(message)"
        case let .attachFailed(message): "Android rejected the inspection agent: \(message)"
        }
    }
}
