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

protocol AndroidCommandRunning: Sendable {
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

extension CommandRunner: AndroidCommandRunning {}

@MainActor
@Observable
final class DeviceManager {
    private(set) var devices: [DeviceTarget] = []
    private(set) var isRefreshing = false
    private(set) var activeVPNPackage: String?
    var adbPath: String? { runtimePaths.bundledADBURL()?.path }
    var onDevicesChanged: (([DeviceTarget]) -> Void)?

    private let runner: any AndroidCommandRunning
    private let preferences: DeviceAttachmentPreferences
    private let defaults: UserDefaults
    private let runtimePaths: LensRuntimePaths
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
        runner: any AndroidCommandRunning = CommandRunner()
    ) {
        self.defaults = defaults
        self.runtimePaths = runtimePaths
        self.runner = runner
        preferences = DeviceAttachmentPreferences(defaults: defaults)
        loadSnapshots()
        migrateAttachmentSnapshotsToRememberedDevices()
        loadDeviceAliases()
    }

    var rememberedDetachedDevices: [DeviceTarget] {
        devices.filter { target in
            !target.isAttached && preferences.isRemembered(
                deviceID: target.aliasKey,
                transportID: target.serial
            )
        }
    }

    var preferredDetachedDevice: DeviceTarget? {
        if let remembered = rememberedDetachedDevices.first {
            return remembered
        }
        return devices.first { $0.kind == .emulator && !$0.isAttached }
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
            replaceDevices(with: Self.deduplicatedDevices(candidates))
            await refreshVPNState()
        } catch DeviceManagerError.adbNotFound {
            replaceDevices(with: [])
        } catch {
            // A tracker event will retry after transient ADB/server failures.
            // Preserve the last snapshot instead of flashing an empty sidebar.
        }
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

    func detach(_ target: DeviceTarget, forgetRememberedDevice: Bool = true) async throws {
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
        guard !attachedSnapshots.isEmpty else { return ProxyRestorationReport() }
        await refresh()
        return await restoreAttachedDevicesAndWait()
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
        guard let first = devices.first else {
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
