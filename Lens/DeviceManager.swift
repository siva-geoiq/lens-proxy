import Darwin
import Foundation
import Observation

struct CommandResult: Sendable {
    var output: String
    var errorOutput: String
    var status: Int32
}

private final class CommandOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.withLock { data = value }
    }

    func value() -> Data {
        lock.withLock { data }
    }
}

/// Runs an external command line tool. Implemented by `CommandRunner` and faked in tests.
protocol CommandRunning: Sendable {
    func run(
        _ executable: URL,
        arguments: [String],
        input: Data?,
        timeout: TimeInterval?
    ) async throws -> CommandResult
}

final class CommandRunner: @unchecked Sendable {
    func run(
        _ executable: URL,
        arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let error = Pipe()
                let standardInput = input.map { _ in Pipe() }
                let outputBuffer = CommandOutputBuffer()
                let errorBuffer = CommandOutputBuffer()
                let readers = DispatchGroup()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = error
                process.standardInput = standardInput
                do {
                    try process.run()
                    readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
                        outputBuffer.store(output.fileHandleForReading.readDataToEndOfFile())
                        readers.leave()
                    }
                    readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
                        errorBuffer.store(error.fileHandleForReading.readDataToEndOfFile())
                        readers.leave()
                    }
                    if let input, let standardInput {
            DispatchQueue.global(qos: .userInitiated).async {
                            try? standardInput.fileHandleForWriting.write(contentsOf: input)
                            try? standardInput.fileHandleForWriting.close()
                        }
                    }
                    if let timeout {
                        let deadline = Date().addingTimeInterval(timeout)
                        while process.isRunning && Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                        if process.isRunning {
                            process.terminate()
                            let terminationDeadline = Date().addingTimeInterval(0.5)
                            while process.isRunning && Date() < terminationDeadline {
                                Thread.sleep(forTimeInterval: 0.01)
                            }
                            if process.isRunning {
                                kill(process.processIdentifier, SIGKILL)
                                process.waitUntilExit()
                            }
                            readers.wait()
                            continuation.resume(throwing: CommandRunnerError.timedOut(executable.lastPathComponent, timeout))
                            return
                        }
                    } else {
                        process.waitUntilExit()
                    }
                    readers.wait()
                    let outputData = outputBuffer.value()
                    let errorData = errorBuffer.value()
                    continuation.resume(
                        returning: CommandResult(
                            output: String(data: outputData, encoding: .utf8) ?? "",
                            errorOutput: String(data: errorData, encoding: .utf8) ?? "",
                            status: process.terminationStatus
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension CommandRunner: CommandRunning {}

/// Retained so existing Android call sites keep reading naturally.
typealias AndroidCommandRunning = CommandRunning

@MainActor
@Observable
final class DeviceManager {
    private(set) var devices: [DeviceTarget] = []
    private(set) var isRefreshing = false
    private(set) var activeVPNPackage: String?
    var adbPath: String? { runtimePaths.bundledADBURL()?.path }
    var onDevicesChanged: (([DeviceTarget]) -> Void)?
    /// Fires when simulator socket ownership changes, so captured flows can be
    /// re-attributed without a full device refresh.
    var onSimulatorAttributionChanged: (() -> Void)?

    /// Loopback client port to simulator UDID, mirrored from the attribution actor so
    /// main-actor flow attribution can read it synchronously.
    private(set) var simulatorUDIDByClientPort: [Int: String] = [:]

    /// Every available simulator, including shut-down ones, so the UI can offer to boot
    /// one. Only booted simulators appear in `devices`.
    private(set) var availableSimulators: [SimulatorDevice] = []

    /// Nil when Xcode is not installed, which is the only reason iOS discovery is empty.
    var xcodeDeveloperPath: String? { iosService.developerDirectoryPath }

    let hostProxy: HostProxyController
    let simulatorAttribution: SimulatorTrafficAttribution

    private let runner: any AndroidCommandRunning
    private let preferences: DeviceAttachmentPreferences
    private let defaults: UserDefaults
    private let runtimePaths: LensRuntimePaths
    private let iosService: IOSDeviceService
    private let guidedAttachments: IOSGuidedAttachmentStore
    private var attachedSnapshots: [String: ProxySnapshot] = [:]
    private var deviceAliases: [String: String] = [:]
    private var overlaySerials = Set<String>()
    private var trackerProcess: Process?
    private var trackerOutput: Pipe?
    private var trackerID: UUID?
    private var trackerRestartTask: Task<Void, Never>?
    private var monitoringEnabled = false
    private var refreshPending = false

    init(
        defaults: UserDefaults = .standard,
        runtimePaths: LensRuntimePaths = .live(),
        runner: any AndroidCommandRunning = CommandRunner(),
        iosService: IOSDeviceService = IOSDeviceService(),
        hostProxy: HostProxyController? = nil,
        simulatorAttribution: SimulatorTrafficAttribution = SimulatorTrafficAttribution()
    ) {
        self.defaults = defaults
        self.runtimePaths = runtimePaths
        self.runner = runner
        self.iosService = iosService
        self.hostProxy = hostProxy ?? HostProxyController(defaults: defaults)
        self.simulatorAttribution = simulatorAttribution
        guidedAttachments = IOSGuidedAttachmentStore(defaults: defaults)
        preferences = DeviceAttachmentPreferences(defaults: defaults)
        loadSnapshots()
        migrateAttachmentSnapshotsToRememberedDevices()
        loadDeviceAliases()
    }

    /// Devices Lens may reattach without being asked.
    ///
    /// iOS is excluded on purpose: attaching a simulator changes a system setting and
    /// raises an administrator prompt, which must never happen unattended at launch.
    var rememberedDetachedDevices: [DeviceTarget] {
        devices.filter { target in
            target.platform == .android && !target.isAttached && preferences.isRemembered(
                deviceID: target.aliasKey,
                transportID: target.serial
            )
        }
    }

    var preferredDetachedDevice: DeviceTarget? {
        if let remembered = rememberedDetachedDevices.first {
            return remembered
        }
        return devices.first { $0.platform == .android && $0.kind == .emulator && !$0.isAttached }
    }

    func refresh() async {
        if isRefreshing {
            refreshPending = true
            return
        }
        isRefreshing = true
        repeat {
            refreshPending = false
            await performRefresh()
        } while refreshPending
        isRefreshing = false
    }

    func startMonitoring() {
        guard !monitoringEnabled else { return }
        monitoringEnabled = true
        launchTracker()
        Task { await refresh() }
    }

    func rename(_ target: DeviceTarget, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            resetName(for: target)
            return
        }
        deviceAliases[target.aliasKey] = name
        persistDeviceAliases()
        updateDevice(target.serial) { $0.customName = name }
    }

    func resetName(for target: DeviceTarget) {
        deviceAliases.removeValue(forKey: target.aliasKey)
        persistDeviceAliases()
        updateDevice(target.serial) { $0.customName = nil }
    }

    func stopMonitoring() {
        monitoringEnabled = false
        trackerRestartTask?.cancel()
        trackerRestartTask = nil
        trackerOutput?.fileHandleForReading.readabilityHandler = nil
        trackerProcess?.terminationHandler = nil
        if trackerProcess?.isRunning == true {
            trackerProcess?.terminate()
        }
        trackerProcess = nil
        trackerOutput = nil
        trackerID = nil
    }

    private func performRefresh() async {
        let android = await discoverAndroidDevices()
        let ios = await discoverIOSDevices()
        switch android {
        case let .some(discovered):
            replaceDevices(with: discovered + ios)
        case .none:
            // A transient ADB failure must not flash the Android devices out of the
            // sidebar, so reuse the last known Android list and refresh iOS only.
            replaceDevices(with: devices.filter { $0.platform == .android } + ios)
        }
        await refreshVPNState()
    }

    /// Returns nil when ADB failed transiently and the previous list should stand.
    private func discoverAndroidDevices() async -> [DeviceTarget]? {
        do {
            let serials = try await discoverConnectedSerials()
            var candidates: [(hardwareID: String, device: DeviceTarget)] = []
            for serial in serials {
                // A connected device should remain visible even when one optional
                // metadata probe is unavailable or the wireless link is briefly slow.
                let model = await optionalShellOutput(serial, ["getprop", "ro.product.model"])
                let apiText = await optionalShellOutput(serial, ["getprop", "ro.build.version.sdk"])
                let rootOutput = await optionalShellOutput(serial, ["id", "-u"])
                let hardwareSerial = await optionalShellOutput(serial, ["getprop", "ro.serialno"])
                let addressOutput = (try? await shell(serial, ["ip", "-o", "-4", "addr", "show", "scope", "global"]).output) ?? ""
                let networkAddresses = addressOutput
                    .split(whereSeparator: \.isWhitespace)
                    .compactMap { field -> String? in
                        guard field.contains("/"), let address = field.split(separator: "/").first,
                              address.split(separator: ".").count == 4 else { return nil }
                        return String(address)
                    }
                let kind: DeviceKind = serial.hasPrefix("emulator-") ? .emulator : .physical
                let stableHardwareID = hardwareSerial.isEmpty || hardwareSerial == "unknown" ? nil : hardwareSerial
                let snapshotKey = stableHardwareID ?? serial
                let storedSnapshot = attachedSnapshots[snapshotKey] ?? attachedSnapshots[serial]
                let device = DeviceTarget(
                        serial: serial,
                        model: model.isEmpty ? serial : model,
                        apiLevel: Int(apiText) ?? 0,
                        kind: kind,
                        rootState: rootOutput == "0" ? .available : .unknown,
                        isAttached: storedSnapshot != nil,
                        previousProxy: storedSnapshot,
                        caInstalled: false,
                        networkAddresses: networkAddresses,
                        hardwareID: stableHardwareID
                    )
                candidates.append(
                    (
                        hardwareID: stableHardwareID ?? serial,
                        device: device
                    )
                )
            }
            return Self.deduplicatedDevices(candidates)
        } catch DeviceManagerError.adbNotFound {
            return []
        } catch {
            // A tracker event will retry after transient ADB/server failures.
            // Preserve the last snapshot instead of flashing an empty sidebar.
            return nil
        }
    }

    /// Booted simulators, connected iPhones, and any device still under a guided
    /// attachment even though Xcode no longer reports it.
    private func discoverIOSDevices() async -> [DeviceTarget] {
        var discovered: [DeviceTarget] = []
        var seenIdentifiers = Set<String>()

        let simulators = (try? await iosService.discoverSimulators()) ?? []
        if availableSimulators != simulators { availableSimulators = simulators }
        for simulator in simulators where simulator.isBooted {
            let storedSnapshot = attachedSnapshots[simulator.udid]
            discovered.append(
                DeviceTarget(
                    serial: simulator.udid,
                    model: simulator.name,
                    apiLevel: 0,
                    kind: .emulator,
                    // The trust store is writable, so a simulator always supports
                    // decryption once Lens installs its certificate.
                    rootState: .available,
                    isAttached: storedSnapshot != nil,
                    previousProxy: nil,
                    caInstalled: storedSnapshot != nil,
                    networkAddresses: [],
                    hardwareID: simulator.udid,
                    platform: .ios,
                    osVersion: simulator.osVersion,
                    attachmentMode: .automatic
                )
            )
            seenIdentifiers.insert(simulator.udid)
        }

        let guided = guidedAttachments.all()
        for device in (try? await iosService.discoverPhysicalDevices()) ?? [] {
            guard device.isConnected || guided.contains(where: { $0.identifier == device.identifier }) else { continue }
            let attachment = guided.first { $0.identifier == device.identifier }
            discovered.append(
                Self.guidedTarget(
                    identifier: device.identifier,
                    hardwareUDID: device.hardwareUDID,
                    name: device.name,
                    osVersion: device.osVersion,
                    isAttached: attachment != nil,
                    boundAddress: attachment?.boundAddress
                )
            )
            seenIdentifiers.insert(device.identifier)
        }

        // An attached iPhone keeps proxying after it is unplugged, so keep showing it.
        for attachment in guided where !seenIdentifiers.contains(attachment.identifier) {
            discovered.append(
                Self.guidedTarget(
                    identifier: attachment.identifier,
                    hardwareUDID: attachment.hardwareUDID,
                    name: attachment.name,
                    osVersion: attachment.osVersion,
                    isAttached: true,
                    boundAddress: attachment.boundAddress
                )
            )
        }
        return discovered
    }

    private static func guidedTarget(
        identifier: String,
        hardwareUDID: String,
        name: String,
        osVersion: String,
        isAttached: Bool,
        boundAddress: String?
    ) -> DeviceTarget {
        DeviceTarget(
            serial: identifier,
            model: name,
            apiLevel: 0,
            kind: .physical,
            // Certificate trust is the user's job on a physical device.
            rootState: .unknown,
            isAttached: isAttached,
            previousProxy: nil,
            caInstalled: false,
            networkAddresses: boundAddress.map { [$0] } ?? [],
            hardwareID: hardwareUDID,
            platform: .ios,
            osVersion: osVersion,
            attachmentMode: .guided
        )
    }

    static func parseConnectedDeviceSerials(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard !line.hasPrefix("List of devices attached") else { return nil }

            // ADB uses a tab between the serial and state. Wireless mDNS serials
            // may themselves contain spaces, so splitting on whitespace loses them.
            if let separator = line.firstIndex(of: "\t") {
                let serial = line[..<separator].trimmingCharacters(in: .whitespaces)
                let state = line[line.index(after: separator)...]
                    .split(whereSeparator: \.isWhitespace)
                    .first
                return state == "device" && !serial.isEmpty ? serial : nil
            }

            // Keep a fallback for ADB variants that render the delimiter as spaces.
            guard let stateRange = line.range(
                of: #"\s+device(?:\s|$)"#,
                options: .regularExpression
            ) else { return nil }
            let serial = line[..<stateRange.lowerBound].trimmingCharacters(in: .whitespaces)
            return serial.isEmpty ? nil : serial
        }
    }

    static func parseMDNSConnectEndpoints(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(whereSeparator: \.isWhitespace)
            guard fields.contains(where: { $0 == "_adb-tls-connect._tcp" }),
                  let endpoint = fields.last,
                  endpoint.contains(":") else { return nil }
            return String(endpoint)
        }
    }

    static func deduplicatedDevices(
        _ candidates: [(hardwareID: String, device: DeviceTarget)]
    ) -> [DeviceTarget] {
        var hardwareIDs: [String] = []
        var devicesByHardwareID: [String: DeviceTarget] = [:]
        for candidate in candidates {
            guard let existing = devicesByHardwareID[candidate.hardwareID] else {
                hardwareIDs.append(candidate.hardwareID)
                devicesByHardwareID[candidate.hardwareID] = candidate.device
                continue
            }
            if shouldPrefer(candidate.device, over: existing) {
                devicesByHardwareID[candidate.hardwareID] = candidate.device
            }
        }
        return hardwareIDs.compactMap { devicesByHardwareID[$0] }
    }

    private static func shouldPrefer(_ candidate: DeviceTarget, over existing: DeviceTarget) -> Bool {
        if candidate.isAttached != existing.isAttached {
            return candidate.isAttached
        }
        return transportRank(candidate.serial) < transportRank(existing.serial)
    }

    private static func transportRank(_ serial: String) -> Int {
        if serial.hasPrefix("emulator-") { return 0 }
        if !serial.contains("._adb-tls-connect._tcp") && !serial.contains(":") { return 0 }
        if serial.range(of: #" \(\d+\)\._adb-tls-connect\._tcp$"#, options: .regularExpression) != nil {
            return 3
        }
        if serial.contains("._adb-tls-connect._tcp") { return 1 }
        return 2
    }

    func attach(_ target: DeviceTarget, proxyPort: Int, stopConflictingVPN: Bool = false) async throws {
        switch target.platform {
        case .android:
            try await attachAndroid(target, proxyPort: proxyPort, stopConflictingVPN: stopConflictingVPN)
        case .ios:
            try await attachIOS(target, proxyPort: proxyPort)
        }
    }

    func detach(_ target: DeviceTarget, forgetRememberedDevice: Bool = true) async throws {
        switch target.platform {
        case .android:
            try await detachAndroid(target, forgetRememberedDevice: forgetRememberedDevice)
        case .ios:
            try await detachIOS(target, forgetRememberedDevice: forgetRememberedDevice)
        }
    }

    // MARK: - iOS attachment

    /// Boots the simulator if needed, trusts the Lens certificate inside it, then points
    /// the Mac's system proxy at Lens because a simulator shares the host network stack.
    private func attachIOS(_ target: DeviceTarget, proxyPort: Int) async throws {
        guard !target.isAttached, attachedSnapshots[target.aliasKey] == nil else {
            throw DeviceManagerError.alreadyAttached(target.serial)
        }
        guard target.attachmentMode == .automatic else {
            try attachGuidedIOS(target)
            return
        }

        try Task.checkCancellation()
        try await iosService.boot(simulator: target.serial)
        try await iosService.waitUntilBooted(udid: target.serial)

        try Task.checkCancellation()
        try await waitForCertificate()
        try await iosService.installRootCertificate(
            udid: target.serial,
            certificateURL: runtimePaths.certificateURL
        )

        try Task.checkCancellation()
        // Nothing needs undoing if this fails: the certificate is inert until traffic
        // is actually proxied.
        try await hostProxy.apply(port: proxyPort)
        await simulatorAttribution.setMapObserver { [weak self] map in
            Task { @MainActor [weak self] in
                guard let self, self.simulatorUDIDByClientPort != map else { return }
                self.simulatorUDIDByClientPort = map
                self.onSimulatorAttributionChanged?()
            }
        }
        await simulatorAttribution.startMonitoring(proxyPort: proxyPort)

        // An empty snapshot marks the attachment as live across refreshes. The proxy
        // settings to restore live in the host proxy snapshot, not here.
        attachedSnapshots[target.aliasKey] = ProxySnapshot(host: nil, port: nil)
        persistSnapshots()
        updateDevice(target.serial) {
            $0.isAttached = true
            $0.caInstalled = true
            $0.rootState = .available
        }
    }

    /// Records a manual attachment for a physical device. The user configures the Wi-Fi
    /// proxy and certificate on the device itself.
    private func attachGuidedIOS(_ target: DeviceTarget) throws {
        guidedAttachments.save(
            GuidedIOSAttachment(
                identifier: target.serial,
                hardwareUDID: target.hardwareID ?? target.serial,
                name: target.model,
                marketingName: target.model,
                osVersion: target.osVersion,
                boundAddress: target.networkAddresses.first
            )
        )
        updateDevice(target.serial) { $0.isAttached = true }
    }

    private func detachIOS(_ target: DeviceTarget, forgetRememberedDevice: Bool) async throws {
        if forgetRememberedDevice {
            preferences.forget(deviceID: target.aliasKey, transportID: target.serial)
        }
        if target.attachmentMode == .guided {
            guidedAttachments.remove(identifier: target.serial)
            updateDevice(target.serial) { $0.isAttached = false }
            return
        }

        attachedSnapshots.removeValue(forKey: target.aliasKey)
        attachedSnapshots.removeValue(forKey: target.serial)
        persistSnapshots()
        updateDevice(target.serial) {
            $0.isAttached = false
            $0.caInstalled = false
        }
        // The host proxy is shared by every attached simulator, so only the last one out
        // restores it.
        if !hasAttachedSimulator {
            await simulatorAttribution.stopMonitoring()
            try await hostProxy.restore()
        }
    }

    /// True while any simulator still needs the host proxy pointed at Lens.
    private var hasAttachedSimulator: Bool {
        devices.contains { $0.isSimulator && $0.isAttached }
    }

    /// Records the address a guided device's traffic arrives from, so later flows are
    /// attributed without waiting for another probe.
    func bindGuidedDevice(serial: String, address: String) {
        guard guidedAttachments.contains(identifier: serial) else { return }
        guidedAttachments.bind(identifier: serial, address: address)
        updateDevice(serial) {
            if !$0.networkAddresses.contains(address) { $0.networkAddresses.append(address) }
        }
    }

    /// Boots a simulator so it appears in `devices` and can be attached.
    func bootSimulator(udid: String) async throws {
        try await iosService.boot(simulator: udid)
        try await iosService.waitUntilBooted(udid: udid)
        await refresh()
    }

    /// The address a physical device must point its Wi-Fi proxy at.
    func hostAddressForGuidedSetup() throws -> String {
        try localIPAddress()
    }

    /// Learns a guided device's address from its first captured flow.
    ///
    /// Only applied when exactly one guided device is still unbound, so traffic is never
    /// attributed to the wrong iPhone.
    func bindGuidedDeviceIfNeeded(clientAddress: String) {
        guard !clientAddress.isEmpty, clientAddress != "Unknown" else { return }
        guard !devices.contains(where: { $0.networkAddresses.contains(clientAddress) }) else { return }
        let unbound = devices.filter {
            $0.platform == .ios && $0.attachmentMode == .guided && $0.isAttached && $0.networkAddresses.isEmpty
        }
        guard unbound.count == 1, let target = unbound.first else { return }
        bindGuidedDevice(serial: target.serial, address: clientAddress)
    }

    // MARK: - Android attachment

    private func attachAndroid(_ target: DeviceTarget, proxyPort: Int, stopConflictingVPN: Bool) async throws {
        guard !target.isAttached,
              attachedSnapshots[target.aliasKey] == nil,
              attachedSnapshots[target.serial] == nil else {
            throw DeviceManagerError.alreadyAttached(target.serial)
        }
        if let activeVPNPackage, !activeVPNPackage.isEmpty {
            guard stopConflictingVPN else { throw DeviceManagerError.vpnConflict(activeVPNPackage) }
            _ = try await shell(target.serial, ["am", "force-stop", activeVPNPackage])
        }

        let snapshot = try await readProxy(target.serial)
        attachedSnapshots[target.aliasKey] = snapshot
        if target.aliasKey != target.serial {
            attachedSnapshots.removeValue(forKey: target.serial)
        }
        persistSnapshots()

        var proxyMutationStarted = false
        do {
            try Task.checkCancellation()
            var rootAvailable = target.rootState == .available
            if target.kind == .emulator && !rootAvailable {
                let root = try await adb(["-s", target.serial, "root"], timeout: 10)
                if root.status == 0 {
                    _ = try await adb(["-s", target.serial, "wait-for-device"], timeout: 10)
                    rootAvailable = try await shell(
                        target.serial,
                        ["id", "-u"],
                        timeout: Self.proxyCommandTimeout
                    ).output.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
                }
            }

            try Task.checkCancellation()
            if rootAvailable {
                try await waitForCertificate()
                try await installCA(on: target)
            }

            try Task.checkCancellation()
            let proxyHost = target.kind == .emulator ? "10.0.2.2" : try localIPAddress()
            // A timed-out ADB command may have reached Android even when it did not
            // return a result, so treat the first proxy write as a mutation attempt.
            proxyMutationStarted = true
            _ = try await shell(
                target.serial,
                ["settings", "put", "global", "http_proxy", "\(proxyHost):\(proxyPort)"],
                timeout: Self.proxyCommandTimeout
            )
            _ = try await shell(
                target.serial,
                ["settings", "put", "global", "global_http_proxy_host", proxyHost],
                timeout: Self.proxyCommandTimeout
            )
            _ = try await shell(
                target.serial,
                ["settings", "put", "global", "global_http_proxy_port", String(proxyPort)],
                timeout: Self.proxyCommandTimeout
            )

            try Task.checkCancellation()
            if !rootAvailable {
                _ = try await shell(
                    target.serial,
                    ["am", "start", "-a", "android.intent.action.VIEW", "-d", "http://mitm.it"],
                    timeout: 10
                )
            }

            updateDevice(target.serial) {
                $0.isAttached = true
                $0.previousProxy = snapshot
                $0.rootState = rootAvailable ? .available : .unavailable
                $0.caInstalled = rootAvailable
            }
            preferences.remember(deviceID: target.aliasKey)
            if target.kind == .emulator {
                preferences.remember(emulatorSerial: target.serial)
            }
        } catch {
            if proxyMutationStarted {
                do {
                    try await restoreProxySettings(for: target, snapshot: snapshot)
                } catch let rollbackError {
                    updateDevice(target.serial) {
                        $0.isAttached = true
                        $0.previousProxy = snapshot
                    }
                    throw DeviceManagerError.attachmentRollbackFailed(
                        original: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
            }
            attachedSnapshots.removeValue(forKey: target.aliasKey)
            attachedSnapshots.removeValue(forKey: target.serial)
            persistSnapshots()
            updateDevice(target.serial) {
                $0.isAttached = false
                $0.previousProxy = nil
                $0.caInstalled = false
            }
            throw error
        }
    }

    private func detachAndroid(_ target: DeviceTarget, forgetRememberedDevice: Bool) async throws {
        if forgetRememberedDevice {
            preferences.forget(deviceID: target.aliasKey, transportID: target.serial)
        }
        let snapshot = attachedSnapshots[target.aliasKey] ?? attachedSnapshots[target.serial] ?? target.previousProxy
        try await restoreProxySettings(for: target, snapshot: snapshot)
        try? await removeCA(from: target)
        attachedSnapshots.removeValue(forKey: target.aliasKey)
        attachedSnapshots.removeValue(forKey: target.serial)
        persistSnapshots()
        updateDevice(target.serial) {
            $0.isAttached = false
            $0.previousProxy = nil
            $0.caInstalled = false
        }
    }

    func restoreAttachedDevices() {
        Task { await restoreAttachedDevicesAndWait() }
    }

    func restoreAttachedDevicesAndWait() async -> ProxyRestorationReport {
        var report = ProxyRestorationReport()
        let targets = devices.filter { target in
            target.isAttached || attachedSnapshots[target.aliasKey] != nil || attachedSnapshots[target.serial] != nil
        }
        for target in targets {
            do {
                try await detach(target, forgetRememberedDevice: false)
                report.restoredSerials.append(target.serial)
            } catch {
                report.failures.append(
                    ProxyRestorationFailure(serial: target.serial, message: error.localizedDescription)
                )
            }
        }
        return report
    }

    func recoverPreviousAttachments() async -> ProxyRestorationReport {
        guard !attachedSnapshots.isEmpty || hostProxy.hasRecoverableSnapshot else {
            return ProxyRestorationReport()
        }
        await refresh()
        var report = await restoreAttachedDevicesAndWait()
        // A crash can leave the Mac pointing at a Lens proxy that is no longer running,
        // with no simulator left in the list to detach.
        if hostProxy.hasRecoverableSnapshot, !hasAttachedSimulator {
            do {
                await simulatorAttribution.stopMonitoring()
                try await hostProxy.restore()
            } catch {
                report.failures.append(
                    ProxyRestorationFailure(serial: "macOS system proxy", message: error.localizedDescription)
                )
            }
        }
        return report
    }

    func prepareUITestDevices(_ fixtures: [DeviceTarget]) {
        replaceDevices(with: fixtures)
    }

    private func readProxy(_ serial: String) async throws -> ProxySnapshot {
        let output = try await shell(
            serial,
            ["settings", "get", "global", "http_proxy"],
            timeout: Self.proxyCommandTimeout
        )
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, output != "null", output != ":0",
              let separator = output.lastIndex(of: ":"),
              let port = Int(output[output.index(after: separator)...]) else {
            return ProxySnapshot(host: nil, port: nil)
        }
        return ProxySnapshot(host: String(output[..<separator]), port: port)
    }

    private func restoreProxySettings(for target: DeviceTarget, snapshot: ProxySnapshot?) async throws {
        if let host = snapshot?.host, let port = snapshot?.port {
            _ = try await shell(
                target.serial,
                ["settings", "put", "global", "http_proxy", "\(host):\(port)"],
                timeout: Self.proxyCommandTimeout
            )
            _ = try await shell(
                target.serial,
                ["settings", "put", "global", "global_http_proxy_host", host],
                timeout: Self.proxyCommandTimeout
            )
            _ = try await shell(
                target.serial,
                ["settings", "put", "global", "global_http_proxy_port", String(port)],
                timeout: Self.proxyCommandTimeout
            )
        } else {
            _ = try await shell(
                target.serial,
                ["settings", "put", "global", "http_proxy", ":0"],
                timeout: Self.proxyCommandTimeout
            )
            _ = try await shell(
                target.serial,
                ["settings", "delete", "global", "global_http_proxy_host"],
                timeout: Self.proxyCommandTimeout
            )
            _ = try await shell(
                target.serial,
                ["settings", "delete", "global", "global_http_proxy_port"],
                timeout: Self.proxyCommandTimeout
            )
        }
    }

    private func installCA(on target: DeviceTarget) async throws {
        let certificate = runtimePaths.certificateURL
        guard FileManager.default.fileExists(atPath: certificate.path) else {
            throw DeviceManagerError.certificateMissing
        }
        let hashResult = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["x509", "-inform", "PEM", "-subject_hash_old", "-in", certificate.path, "-noout"],
            input: nil,
            timeout: 5
        )
        let hash = hashResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { throw DeviceManagerError.certificateHashFailed }
        let filename = "\(hash).0"
        _ = try await adb(["-s", target.serial, "push", certificate.path, "/data/local/tmp/\(filename)"])

        if target.apiLevel >= 34 {
            let certificateDirectory = "/apex/com.android.conscrypt/cacerts"
            let overlayDirectory = "/data/local/tmp/lens-cacerts"
            let markerPath = "\(overlayDirectory)/.lens-overlay"
            _ = try await shell(target.serial, ["mkdir", "-p", overlayDirectory])
            _ = try await shellCommand(target.serial, "cp \(certificateDirectory)/*.0 \(overlayDirectory)/ 2>/dev/null || true")
            _ = try await shell(target.serial, ["cp", "/data/local/tmp/\(filename)", "\(overlayDirectory)/\(filename)"])
            _ = try await shell(target.serial, ["chmod", "755", overlayDirectory])
            _ = try await shellCommand(target.serial, "chmod 644 \(overlayDirectory)/*.0")
            _ = try await shell(target.serial, ["touch", markerPath])

            let mountState = try await shell(target.serial, ["mount"])
            if !mountState.output.contains("tmpfs on \(certificateDirectory)") {
                _ = try await shell(target.serial, ["mount", "-t", "tmpfs", "tmpfs", certificateDirectory])
                overlaySerials.insert(target.serial)
            }
            try await populateCertificateOverlay(
                serial: target.serial,
                namespacePID: nil,
                sourceDirectory: overlayDirectory,
                certificateDirectory: certificateDirectory,
                filename: filename
            )

            let zygoteOutput = try await shell(target.serial, ["pidof", "zygote", "zygote64"])
            for pid in zygoteOutput.output.split(whereSeparator: \.isWhitespace).map(String.init) {
                let namespaceMounts = try await shell(
                    target.serial,
                    ["nsenter", "--mount=/proc/\(pid)/ns/mnt", "--", "mount"]
                )
                if !namespaceMounts.output.contains("tmpfs on \(certificateDirectory)") {
                    _ = try await shell(
                        target.serial,
                        ["nsenter", "--mount=/proc/\(pid)/ns/mnt", "--", "mount", "-t", "tmpfs", "tmpfs", certificateDirectory]
                    )
                }
                try await populateCertificateOverlay(
                    serial: target.serial,
                    namespacePID: pid,
                    sourceDirectory: overlayDirectory,
                    certificateDirectory: certificateDirectory,
                    filename: filename
                )
            }
        } else {
            _ = try? await adb(["-s", target.serial, "remount"])
            _ = try await shell(target.serial, ["cp", "/data/local/tmp/\(filename)", "/system/etc/security/cacerts/\(filename)"])
            _ = try await shell(target.serial, ["chmod", "644", "/system/etc/security/cacerts/\(filename)"])
        }
    }

    private func removeCA(from target: DeviceTarget) async throws {
        let certificate = runtimePaths.certificateURL
        guard FileManager.default.fileExists(atPath: certificate.path) else { return }
        let hash = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: ["x509", "-inform", "PEM", "-subject_hash_old", "-in", certificate.path, "-noout"],
            input: nil,
            timeout: 5
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else { return }
        _ = try? await shell(target.serial, ["rm", "-f", "/system/etc/security/cacerts/\(hash).0"])
        _ = try? await shell(target.serial, ["rm", "-f", "/data/local/tmp/\(hash).0"])
        let certificateDirectory = "/apex/com.android.conscrypt/cacerts"
        let overlayDirectory = "/data/local/tmp/lens-cacerts"
        let marker = try? await shell(target.serial, ["test", "-f", "\(overlayDirectory)/.lens-overlay"])
        if marker?.status == 0 {
            let zygoteOutput = try? await shell(target.serial, ["pidof", "zygote", "zygote64"])
            for pid in zygoteOutput?.output.split(whereSeparator: \.isWhitespace).map(String.init) ?? [] {
                _ = try? await shell(
                    target.serial,
                    ["nsenter", "--mount=/proc/\(pid)/ns/mnt", "--", "umount", certificateDirectory]
                )
            }
            _ = try? await shell(target.serial, ["umount", certificateDirectory])
            _ = try? await shell(target.serial, ["rm", "-rf", overlayDirectory])
            overlaySerials.remove(target.serial)
        } else {
            _ = try? await shell(target.serial, ["rm", "-f", "\(certificateDirectory)/\(hash).0"])
        }
    }

    private func populateCertificateOverlay(
        serial: String,
        namespacePID: String?,
        sourceDirectory: String,
        certificateDirectory: String,
        filename: String
    ) async throws {
        let namespacePrefix = namespacePID.map { ["nsenter", "--mount=/proc/\($0)/ns/mnt", "--"] } ?? []
        _ = try await shell(
            serial,
            namespacePrefix + ["cp", "-a", "\(sourceDirectory)/.", "\(certificateDirectory)/"]
        )
        _ = try await shell(serial, namespacePrefix + ["chmod", "644", "\(certificateDirectory)/\(filename)"])
        _ = try await shell(
            serial,
            namespacePrefix + ["chcon", "u:object_r:system_security_cacerts_file:s0", "\(certificateDirectory)/\(filename)"]
        )
    }

    private func refreshVPNState() async {
        guard let first = devices.first(where: { $0.platform == .android }) else {
            activeVPNPackage = nil
            return
        }
        guard let output = try? await shell(first.serial, ["dumpsys", "connectivity"], timeout: 3).output,
              let range = output.range(of: "VPN:") else {
            activeVPNPackage = nil
            return
        }
        let suffix = output[range.upperBound...]
        activeVPNPackage = String(suffix.prefix { !$0.isWhitespace && $0 != "}" })
    }

    private func shell(_ serial: String, _ arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandResult {
        try await adb(["-s", serial, "shell"] + arguments, timeout: timeout)
    }

    private func optionalShellOutput(_ serial: String, _ arguments: [String]) async -> String {
        guard let result = try? await shell(serial, arguments, timeout: 3) else { return "" }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func launchTracker() {
        guard monitoringEnabled, trackerProcess == nil,
              let adbURL = runtimePaths.bundledADBURL() else { return }

        let process = Process()
        let output = Pipe()
        let identifier = UUID()
        process.executableURL = adbURL
        process.arguments = ["track-devices", "-l"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard !handle.availableData.isEmpty else { return }
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.trackerDidTerminate(identifier: identifier)
            }
        }

        trackerProcess = process
        trackerOutput = output
        trackerID = identifier
        do {
            try process.run()
        } catch {
            trackerProcess = nil
            trackerOutput = nil
            trackerID = nil
            scheduleTrackerRestart()
        }
    }

    private func trackerDidTerminate(identifier: UUID) {
        guard trackerID == identifier else { return }
        trackerOutput?.fileHandleForReading.readabilityHandler = nil
        trackerProcess = nil
        trackerOutput = nil
        trackerID = nil
        scheduleTrackerRestart()
    }

    private func scheduleTrackerRestart() {
        guard monitoringEnabled else { return }
        trackerRestartTask?.cancel()
        trackerRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.launchTracker()
        }
    }

    private func discoverConnectedSerials() async throws -> [String] {
        var result = try await adb(["devices", "-l"], timeout: 5)
        var serials = Self.parseConnectedDeviceSerials(result.output)
        guard serials.isEmpty,
              let services = try? await adb(["mdns", "services"], timeout: 5) else {
            return serials
        }

        let endpoints = Self.parseMDNSConnectEndpoints(services.output)
        guard !endpoints.isEmpty else { return serials }
        for endpoint in endpoints {
            _ = try? await adb(["connect", endpoint], timeout: 5)
        }
        result = try await adb(["devices", "-l"], timeout: 5)
        serials = Self.parseConnectedDeviceSerials(result.output)
        return serials
    }

    private func shellCommand(_ serial: String, _ command: String) async throws -> CommandResult {
        try await adb(["-s", serial, "shell", command])
    }

    private func adb(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandResult {
        guard let adbURL = runtimePaths.bundledADBURL() else { throw DeviceManagerError.adbNotFound }
        let result = try await runner.run(adbURL, arguments: arguments, input: nil, timeout: timeout)
        if result.status != 0 {
            throw DeviceManagerError.commandFailed(result.errorOutput.isEmpty ? result.output : result.errorOutput)
        }
        return result
    }

    private func waitForCertificate(timeout: Duration = .seconds(10)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !FileManager.default.fileExists(atPath: runtimePaths.certificateURL.path) {
            guard clock.now < deadline else { throw DeviceManagerError.certificateMissing }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func localIPAddress() throws -> String {
        var address: String?
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { throw DeviceManagerError.localAddressUnavailable }
        defer { freeifaddrs(pointer) }
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  interface.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.pointee.ifa_addr,
                socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                address = String(decoding: bytes, as: UTF8.self)
                let name = String(cString: interface.pointee.ifa_name)
                if name == "en0" { break }
            }
        }
        guard let address else { throw DeviceManagerError.localAddressUnavailable }
        return address
    }

    private func updateDevice(_ serial: String, mutation: (inout DeviceTarget) -> Void) {
        guard let index = devices.firstIndex(where: { $0.serial == serial }) else { return }
        mutation(&devices[index])
        onDevicesChanged?(devices)
    }

    private func replaceDevices(with discovered: [DeviceTarget]) {
        let renamedDevices = discovered.map { device in
            var renamedDevice = device
            if let alias = deviceAliases[device.aliasKey] {
                renamedDevice.customName = alias
            }
            return renamedDevice
        }
        guard devices != renamedDevices else { return }
        devices = renamedDevices
        onDevicesChanged?(devices)
    }

    private func loadSnapshots() {
        guard let data = defaults.data(forKey: "attachedProxySnapshots"),
              let snapshots = try? JSONDecoder().decode([String: ProxySnapshot].self, from: data) else { return }
        attachedSnapshots = snapshots
    }

    private func migrateAttachmentSnapshotsToRememberedDevices() {
        for deviceID in attachedSnapshots.keys {
            preferences.remember(deviceID: deviceID)
        }
    }

    private func persistSnapshots() {
        defaults.set(try? JSONEncoder().encode(attachedSnapshots), forKey: "attachedProxySnapshots")
    }

    private func loadDeviceAliases() {
        guard let data = defaults.data(forKey: "deviceAliases"),
              let aliases = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        deviceAliases = aliases
    }

    private func persistDeviceAliases() {
        defaults.set(try? JSONEncoder().encode(deviceAliases), forKey: "deviceAliases")
    }

    private static let proxyCommandTimeout: TimeInterval = 5
}

struct ProxyRestorationFailure: Hashable, Sendable {
    var serial: String
    var message: String
}

struct ProxyRestorationReport: Hashable, Sendable {
    var restoredSerials: [String] = []
    var failures: [ProxyRestorationFailure] = []

    var isComplete: Bool { failures.isEmpty }

    var failureSummary: String {
        failures.map { "\($0.serial): \($0.message)" }.joined(separator: "\n")
    }
}

enum CommandRunnerError: LocalizedError {
    case timedOut(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .timedOut(command, timeout):
            "\(command) did not finish within \(timeout.formatted()) seconds."
        }
    }
}

enum DeviceManagerError: LocalizedError {
    case adbNotFound
    case commandFailed(String)
    case certificateMissing
    case certificateHashFailed
    case localAddressUnavailable
    case vpnConflict(String)
    case alreadyAttached(String)
    case attachmentRollbackFailed(original: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound: "The bundled ADB runtime is missing or cannot be executed. Reinstall Lens."
        case let .commandFailed(message): message.trimmingCharacters(in: .whitespacesAndNewlines)
        case .certificateMissing: "The mitmproxy CA is missing. Start mitmproxy once to generate it."
        case .certificateHashFailed: "Could not calculate the mitmproxy CA certificate hash."
        case .localAddressUnavailable: "No reachable Mac LAN address was found for the physical device."
        case let .vpnConflict(package): "A device VPN is active (\(package)). Confirm stopping it before attaching Lens."
        case let .alreadyAttached(serial): "Device \(serial) is already attached to Lens."
        case let .attachmentRollbackFailed(original, rollback):
            "Attachment failed (\(original)) and Lens could not restore the previous Android proxy (\(rollback))."
        }
    }
}
