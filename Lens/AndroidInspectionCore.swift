import Foundation

struct AndroidAgentTrace: Codable, Hashable, Sendable {
    var sequence: UInt64
    var requestIdentity: Int? = nil
    var method: String
    var url: String
    var processName: String
    var pid: Int
    var threadName: String
    var capturedAt: Double
    var correlationHeaders: [String: String]
    var stackFrames: [AndroidStackFrame]
}

struct AndroidActivitySnapshot: Hashable, Sendable {
    var packageName: String
    var activityName: String
    var observedAt: Double
}

enum AndroidInspectionParser {
    static func jdwpPIDs(_ output: String) -> [Int] {
        output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    }

    static func processes(_ output: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            if let pid = Int(fields[0]) {
                result[pid] = String(fields[1])
            } else if fields.count >= 9, let pid = Int(fields[1]) {
                result[pid] = String(fields.last!)
            }
        }
        return result
    }

    static func activityEvent(_ line: String, observedAt: Double = Date().timeIntervalSince1970) -> AndroidActivitySnapshot? {
        guard line.contains("wm_set_resumed_activity"),
              let open = line.lastIndex(of: "["),
              let close = line[open...].firstIndex(of: "]") else { return nil }
        let fields = line[line.index(after: open)..<close].split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return nil }
        let component = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = component.firstIndex(of: "/") else { return nil }
        let packageName = String(component[..<slash])
        var activity = String(component[component.index(after: slash)...])
        if activity.hasPrefix(".") { activity = packageName + activity }
        guard !packageName.isEmpty, !activity.isEmpty else { return nil }
        return AndroidActivitySnapshot(packageName: packageName, activityName: activity, observedAt: observedAt)
    }

    static func foregroundActivity(_ output: String, observedAt: Double = Date().timeIntervalSince1970) -> AndroidActivitySnapshot? {
        for line in output.split(whereSeparator: \.isNewline) where line.contains("mCurrentFocus=") || line.contains("mFocusedApp=") {
            guard let range = line.range(of: #"([A-Za-z0-9_.$-]+)/([A-Za-z0-9_.$-]+)"#, options: .regularExpression) else { continue }
            let component = String(line[range])
            guard let slash = component.firstIndex(of: "/") else { continue }
            let packageName = String(component[..<slash])
            var activity = String(component[component.index(after: slash)...])
            if activity.hasPrefix(".") { activity = packageName + activity }
            return AndroidActivitySnapshot(packageName: packageName, activityName: activity, observedAt: observedAt)
        }
        return nil
    }
}

@MainActor
final class AndroidTraceCorrelator {
    private struct PendingTrace {
        var deviceID: String
        var packageName: String
        var trace: AndroidAgentTrace
        var receivedAt: Double
        var activity: AndroidActivitySnapshot?
    }

    private var traces: [PendingTrace] = []
    private var contextsByFlowID: [String: AndroidRequestContext] = [:]
    private let maximumAge: TimeInterval

    init(maximumAge: TimeInterval = 5) {
        self.maximumAge = maximumAge
    }

    func ingest(
        _ trace: AndroidAgentTrace,
        deviceID: String,
        packageName: String,
        activity: AndroidActivitySnapshot?,
        receivedAt: Double = Date().timeIntervalSince1970
    ) {
        if let requestIdentity = trace.requestIdentity,
           traces.contains(where: {
               $0.deviceID == deviceID &&
                   $0.trace.pid == trace.pid &&
                   $0.trace.requestIdentity == requestIdentity
           }) {
            return
        }
        traces.append(PendingTrace(deviceID: deviceID, packageName: packageName, trace: trace, receivedAt: receivedAt, activity: activity))
        prune(now: receivedAt)
    }

    func context(for flow: FlowRecord, now: Double = Date().timeIntervalSince1970) -> AndroidRequestContext? {
        if let context = contextsByFlowID[flow.id] { return context }
        guard let deviceID = flow.deviceID else { return nil }
        prune(now: now)
        let key = normalizedKey(method: flow.method, url: flow.url)
        let candidates = traces.enumerated().filter { _, candidate in
            candidate.deviceID == deviceID &&
                normalizedKey(method: candidate.trace.method, url: candidate.trace.url) == key &&
                abs(flow.startedAt - candidate.receivedAt) <= maximumAge
        }
        guard !candidates.isEmpty else { return nil }

        let headerMatches = candidates.filter { _, candidate in
            guard !candidate.trace.correlationHeaders.isEmpty else { return false }
            let flowHeaders = Dictionary(uniqueKeysWithValues: flow.requestHeaders.map { ($0.name.lowercased(), $0.value) })
            return candidate.trace.correlationHeaders.contains { name, value in flowHeaders[name.lowercased()] == value }
        }
        let resolved = headerMatches.count == 1 ? headerMatches : candidates
        guard resolved.count == 1, let (index, candidate) = resolved.first else {
            let observed = candidates.min(by: { abs(flow.startedAt - $0.element.receivedAt) < abs(flow.startedAt - $1.element.receivedAt) })?.element
            return AndroidRequestContext(
                status: .ambiguous,
                confidence: .none,
                packageName: observed?.packageName ?? "",
                processName: observed?.trace.processName ?? "",
                pid: observed?.trace.pid ?? 0,
                threadName: observed?.trace.threadName ?? "",
                foregroundActivity: observed?.activity?.packageName == observed?.packageName ? observed?.activity?.activityName : nil,
                primaryCallSite: nil,
                stackFrames: [],
                capturedAt: observed?.receivedAt ?? flow.startedAt,
                correlationDelayMilliseconds: nil
            )
        }

        traces.remove(at: index)
        let primary = candidate.trace.stackFrames.first(where: { !$0.isFramework })
        let context = AndroidRequestContext(
            status: .captured,
            confidence: .high,
            packageName: candidate.packageName,
            processName: candidate.trace.processName,
            pid: candidate.trace.pid,
            threadName: candidate.trace.threadName,
            foregroundActivity: candidate.activity?.packageName == candidate.packageName ? candidate.activity?.activityName : nil,
            primaryCallSite: primary,
            stackFrames: candidate.trace.stackFrames,
            capturedAt: candidate.receivedAt,
            correlationDelayMilliseconds: max(0, (flow.startedAt - candidate.receivedAt) * 1_000)
        )
        contextsByFlowID[flow.id] = context
        return context
    }

    func remember(_ context: AndroidRequestContext, for flowID: String) {
        contextsByFlowID[flowID] = context
    }

    func clear() {
        traces.removeAll(keepingCapacity: true)
        contextsByFlowID.removeAll(keepingCapacity: true)
    }

    private func prune(now: Double) {
        traces.removeAll { now - $0.receivedAt > maximumAge }
    }

    private func normalizedKey(method: String, url: String) -> String {
        guard let components = URLComponents(string: url) else { return "\(method.uppercased()) \(url)" }
        let scheme = components.scheme?.lowercased() ?? ""
        let host = components.host?.lowercased() ?? ""
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return "\(method.uppercased()) \(scheme)://\(host):\(port)\(path)\(query)"
    }
}
