import Foundation

/// Maps loopback proxy connections back to the iOS simulator that opened them.
///
/// Simulator traffic reaches Lens from `127.0.0.1`, indistinguishable at IP level from
/// the Mac's own apps and from every other booted simulator. The connecting socket is
/// owned by a real host process, though, and every simulator process descends from a
/// per-device `launchd_sim` whose command line names the device:
///
///     launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/<UDID>/data/var/run/launchd_bootstrap.plist
///
/// So a client port resolves to a UDID by finding the owning PID and walking its parent
/// chain. Sockets are short lived, so a rolling monitor samples them while a simulator
/// is attached and retains what it saw long enough for the flow to arrive.
actor SimulatorTrafficAttribution {
    static let defaultSampleInterval = Duration.milliseconds(400)
    /// A flow can reach Lens well after its socket closed, so entries outlive the socket.
    static let retention: TimeInterval = 120

    private let runner: any CommandRunning
    private let sampleInterval: Duration
    private var udidByClientPort: [Int: (udid: String, observedAt: Date)] = [:]
    private var monitorTask: Task<Void, Never>?
    private var monitoredPort: Int?
    private var onMapChanged: (@Sendable ([Int: String]) -> Void)?

    init(
        runner: any CommandRunning = CommandRunner(),
        sampleInterval: Duration = SimulatorTrafficAttribution.defaultSampleInterval
    ) {
        self.runner = runner
        self.sampleInterval = sampleInterval
    }

    // MARK: - Monitoring

    /// Flow attribution runs on the main actor and cannot await this actor, so the
    /// resolved map is pushed out after every sample instead.
    func setMapObserver(_ observer: (@Sendable ([Int: String]) -> Void)?) {
        onMapChanged = observer
    }

    func startMonitoring(proxyPort: Int) {
        guard monitoredPort != proxyPort || monitorTask == nil else { return }
        stopMonitoring()
        monitoredPort = proxyPort
        monitorTask = Task { [weak self, sampleInterval] in
            while !Task.isCancelled {
                await self?.sample(proxyPort: proxyPort)
                try? await Task.sleep(for: sampleInterval)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        monitoredPort = nil
        udidByClientPort.removeAll()
        onMapChanged?([:])
    }

    func udid(forClientPort port: Int) -> String? {
        udidByClientPort[port]?.udid
    }

    /// Takes one sample of the sockets connected to the proxy. Exposed for tests.
    func sample(proxyPort: Int, now: Date = Date()) async {
        guard let sockets = try? await clientSockets(proxyPort: proxyPort), !sockets.isEmpty else {
            expireEntries(now: now)
            return
        }
        let unresolved = sockets.filter { udidByClientPort[$0.clientPort] == nil }
        guard !unresolved.isEmpty else {
            expireEntries(now: now)
            return
        }
        guard let table = try? await processTable() else {
            expireEntries(now: now)
            return
        }
        let udidByLaunchdSim = Self.parseLaunchdSimulators(table)
        guard !udidByLaunchdSim.isEmpty else {
            expireEntries(now: now)
            return
        }
        let parents = Self.parseParents(table)
        var resolvedAny = false
        for socket in unresolved {
            guard let udid = Self.resolveUDID(
                pid: socket.pid,
                parents: parents,
                udidByLaunchdSim: udidByLaunchdSim
            ) else { continue }
            udidByClientPort[socket.clientPort] = (udid, now)
            resolvedAny = true
        }
        publishIfNeeded(changed: resolvedAny)
        expireEntries(now: now)
    }

    private func expireEntries(now: Date) {
        let before = udidByClientPort.count
        udidByClientPort = udidByClientPort.filter { now.timeIntervalSince($0.value.observedAt) < Self.retention }
        publishIfNeeded(changed: udidByClientPort.count != before)
    }

    private func publishIfNeeded(changed: Bool) {
        guard changed, let onMapChanged else { return }
        onMapChanged(udidByClientPort.mapValues(\.udid))
    }

    private func clientSockets(proxyPort: Int) async throws -> [ClientSocket] {
        let result = try await runner.run(
            URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP@127.0.0.1:\(proxyPort)", "-sTCP:ESTABLISHED"],
            input: nil,
            timeout: 5
        )
        return Self.parseClientSockets(result.output, proxyPort: proxyPort)
    }

    private func processTable() async throws -> String {
        let result = try await runner.run(
            URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-Ao", "pid=,ppid=,command="],
            input: nil,
            timeout: 5
        )
        return result.output
    }

    // MARK: - Parsing

    struct ClientSocket: Hashable, Sendable {
        var pid: Int
        var clientPort: Int
    }

    /// Keeps only rows where the *remote* endpoint is the proxy, which is the connecting
    /// side. The proxy's own accepted sockets appear with the ports reversed.
    static func parseClientSockets(_ output: String, proxyPort: Int) -> [ClientSocket] {
        var sockets: Set<ClientSocket> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 9, let pid = Int(fields[1]) else { continue }
            guard let name = fields.last(where: { $0.contains("->") }) else { continue }
            let endpoints = name.components(separatedBy: "->")
            guard endpoints.count == 2,
                  let localPort = port(fromEndpoint: endpoints[0]),
                  let remotePort = port(fromEndpoint: endpoints[1]),
                  remotePort == proxyPort, localPort != proxyPort else { continue }
            sockets.insert(ClientSocket(pid: pid, clientPort: localPort))
        }
        return Array(sockets)
    }

    static func port(fromEndpoint endpoint: String) -> Int? {
        guard let separator = endpoint.lastIndex(of: ":") else { return nil }
        return Int(endpoint[endpoint.index(after: separator)...])
    }

    /// `pid -> ppid` for the whole process table.
    static func parseParents(_ table: String) -> [Int: Int] {
        var parents: [Int: Int] = [:]
        for line in table.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let pid = Int(fields[0]), let parent = Int(fields[1]) else { continue }
            parents[pid] = parent
        }
        return parents
    }

    /// `launchd_sim pid -> simulator UDID`, one entry per booted simulator.
    static func parseLaunchdSimulators(_ table: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in table.split(whereSeparator: \.isNewline) {
            guard line.contains("launchd_sim") else { continue }
            let fields = line.split(whereSeparator: \.isWhitespace)
            // Match the executable itself, not an unrelated command line that merely
            // mentions launchd_sim.
            guard fields.count >= 3, let pid = Int(fields[0]), fields[2].hasSuffix("launchd_sim") else { continue }
            guard let udid = udid(inPath: String(line)) else { continue }
            result[pid] = udid
        }
        return result
    }

    /// Extracts the UDID from any `CoreSimulator/Devices/<UDID>` path.
    static func udid(inPath path: String) -> String? {
        guard let range = path.range(of: "CoreSimulator/Devices/") else { return nil }
        let remainder = path[range.upperBound...]
        let candidate = String(remainder.prefix { $0.isHexDigit || $0 == "-" })
        return candidate.count == 36 ? candidate.uppercased() : nil
    }

    static func resolveUDID(
        pid: Int,
        parents: [Int: Int],
        udidByLaunchdSim: [Int: String],
        maximumDepth: Int = 12
    ) -> String? {
        var current = pid
        for _ in 0..<maximumDepth {
            if let udid = udidByLaunchdSim[current] { return udid }
            guard let parent = parents[current], parent != current, parent > 1 else { return nil }
            current = parent
        }
        return nil
    }
}
