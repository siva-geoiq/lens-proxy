import Foundation

struct HeaderField: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
    }
}

struct BodyPayload: Codable, Hashable, Sendable {
    var data: Data
    var isText: Bool
    var truncated: Bool
    var mimeType: String?

    static let empty = BodyPayload(data: Data(), isText: true, truncated: false, mimeType: nil)

    var text: String? {
        guard isText else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var formattedText: String {
        guard let text else { return hexPreview }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8) else {
            return text
        }
        return result
    }

    var isJSON: Bool {
        guard !data.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    var hexPreview: String {
        data.prefix(4096).enumerated().map { index, byte in
            let prefix = index > 0 && index.isMultiple(of: 16) ? "\n" : ""
            return prefix + String(format: "%02x ", byte)
        }.joined()
    }
}

struct WebSocketFrame: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var fromClient: Bool
    var isText: Bool
    var content: String
    var timestamp: Double
}

enum AndroidContextStatus: String, Codable, Hashable, Sendable {
    case captured
    case activityOnly
    case ambiguous
    case unmatched
}

enum AndroidMatchConfidence: String, Codable, Hashable, Sendable {
    case high
    case observational
    case none
}

struct AndroidStackFrame: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(className)#\(methodName)#\(sourceFile ?? "")#\(lineNumber ?? -1)" }
    var className: String
    var methodName: String
    var signature: String
    var sourceFile: String?
    var lineNumber: Int?
    var isFramework: Bool

    var displayName: String {
        let source = sourceFile.map { file in
            lineNumber.map { "\(file):\($0)" } ?? file
        }
        return "\(className).\(methodName)\(source.map { " (\($0))" } ?? "")"
    }
}

struct AndroidRequestContext: Codable, Hashable, Sendable {
    var status: AndroidContextStatus
    var confidence: AndroidMatchConfidence
    var packageName: String
    var processName: String
    var pid: Int
    var threadName: String
    var foregroundActivity: String?
    var primaryCallSite: AndroidStackFrame?
    var stackFrames: [AndroidStackFrame]
    var capturedAt: Double
    var correlationDelayMilliseconds: Double?

    var stackText: String {
        stackFrames.map(\.displayName).joined(separator: "\n")
    }
}

struct FlowRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var clientAddress: String
    var method: String
    var scheme: String
    var host: String
    var port: Int
    var path: String
    var url: String
    var requestHeaders: [HeaderField]
    var requestBody: BodyPayload?
    var responseStatus: Int?
    var responseReason: String?
    var responseHeaders: [HeaderField]
    var responseBody: BodyPayload?
    var startedAt: Double
    var endedAt: Double?
    var duration: Double?
    var size: Int
    var mappedRuleID: UUID?
    var mappedRuleName: String?
    var rewrittenRuleID: UUID? = nil
    var rewrittenRuleName: String? = nil
    var error: String?
    var websocketMessages: [WebSocketFrame]
    var deviceID: String? = nil
    var deviceName: String? = nil
    var androidContext: AndroidRequestContext? = nil

    var displayURL: String {
        url.removingPercentEncoding ?? url
    }

    var statusText: String {
        if let responseStatus { return String(responseStatus) }
        if error != nil { return "ERR" }
        return "—"
    }

    var clientDisplayName: String {
        deviceName ?? clientAddress
    }

    var bodyByteCount: Int {
        (requestBody?.data.count ?? 0) + (responseBody?.data.count ?? 0)
    }

    var curlCommand: String {
        var parts = ["curl", "--request", Self.shellQuote(method), "--url", Self.shellQuote(url)]
        for header in requestHeaders {
            parts += ["--header", Self.shellQuote("\(header.name): \(header.value)")]
        }
        if let body = requestBody, !body.data.isEmpty {
            if let text = body.text {
                parts += ["--data-raw", Self.shellQuote(text)]
            } else {
                parts += ["--data-binary", "'<binary body omitted>'"]
            }
        }
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum MappingBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case localResponse
    case rewriteRequest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localResponse: "Local Response"
        case .rewriteRequest: "Request Rewrite"
        }
    }

    var systemImage: String {
        switch self {
        case .localResponse: "arrow.turn.down.left"
        case .rewriteRequest: "arrow.right.arrow.left"
        }
    }
}

enum CaptureScope: Hashable, Sendable {
    case allTraffic
    case local
    case device(String)
    case host(deviceID: String?, name: String)
}

enum FlowKind: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case http = "HTTP"
    case https = "HTTPS"
    case webSocket = "WebSocket"
    case json = "JSON"
    case media = "Media"
    case other = "Other"

    var id: String { rawValue }
}

struct MappingRule: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var enabled: Bool
    var order: Int
    var method: String
    var scheme: String
    var host: String
    var port: Int
    var path: String
    var matchQuery: Bool
    var query: String?
    var statusCode: Int
    var responseHeaders: [HeaderField]
    var responseBody: BodyPayload
    var sourceFlowID: String?
    var behavior: MappingBehavior
    var rewriteHeaders: Bool
    var requestHeaders: [HeaderField]
    var rewriteBody: Bool
    var requestBody: BodyPayload

    init(
        id: UUID,
        name: String,
        enabled: Bool,
        order: Int,
        method: String,
        scheme: String,
        host: String,
        port: Int,
        path: String,
        matchQuery: Bool,
        query: String?,
        statusCode: Int,
        responseHeaders: [HeaderField],
        responseBody: BodyPayload,
        sourceFlowID: String?,
        behavior: MappingBehavior = .localResponse,
        rewriteHeaders: Bool = false,
        requestHeaders: [HeaderField] = [],
        rewriteBody: Bool = false,
        requestBody: BodyPayload = .empty
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.order = order
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.matchQuery = matchQuery
        self.query = query
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.sourceFlowID = sourceFlowID
        self.behavior = behavior
        self.rewriteHeaders = rewriteHeaders
        self.requestHeaders = requestHeaders
        self.rewriteBody = rewriteBody
        self.requestBody = requestBody
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, order, method, scheme, host, port, path
        case matchQuery, query, statusCode, responseHeaders, responseBody, sourceFlowID
        case behavior, rewriteHeaders, requestHeaders, rewriteBody, requestBody
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        order = try container.decode(Int.self, forKey: .order)
        method = try container.decode(String.self, forKey: .method)
        scheme = try container.decode(String.self, forKey: .scheme)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        path = try container.decode(String.self, forKey: .path)
        matchQuery = try container.decode(Bool.self, forKey: .matchQuery)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode) ?? 200
        responseHeaders = try container.decodeIfPresent([HeaderField].self, forKey: .responseHeaders) ?? []
        responseBody = try container.decodeIfPresent(BodyPayload.self, forKey: .responseBody) ?? .empty
        sourceFlowID = try container.decodeIfPresent(String.self, forKey: .sourceFlowID)
        behavior = try container.decodeIfPresent(MappingBehavior.self, forKey: .behavior) ?? .localResponse
        rewriteHeaders = try container.decodeIfPresent(Bool.self, forKey: .rewriteHeaders) ?? false
        requestHeaders = try container.decodeIfPresent([HeaderField].self, forKey: .requestHeaders) ?? []
        rewriteBody = try container.decodeIfPresent(Bool.self, forKey: .rewriteBody) ?? false
        requestBody = try container.decodeIfPresent(BodyPayload.self, forKey: .requestBody) ?? .empty
    }

    var matchSummary: String {
        let querySuffix = matchQuery && !(query ?? "").isEmpty ? "?\(query ?? "")" : ""
        return "\(method) \(scheme)://\(host):\(port)\(path)\(querySuffix)"
    }

    func matches(method requestMethod: String, url: URL) -> Bool {
        guard enabled,
              method.caseInsensitiveCompare(requestMethod) == .orderedSame,
              scheme.caseInsensitiveCompare(url.scheme ?? "") == .orderedSame,
              host.caseInsensitiveCompare(url.host ?? "") == .orderedSame else { return false }
        let requestPort = url.port ?? ((url.scheme?.lowercased() == "https") ? 443 : 80)
        guard port == requestPort,
              Self.pathMatches(pattern: path, requestPath: url.path.isEmpty ? "/" : url.path) else { return false }
        return !matchQuery || (query ?? "") == (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
    }

    static func pathMatches(pattern: String, requestPath: String) -> Bool {
        guard pattern.contains("*") else { return pattern == requestPath }

        var patternIndex = pattern.startIndex
        var pathIndex = requestPath.startIndex
        var wildcardIndex: String.Index?
        var wildcardPathIndex: String.Index?

        while pathIndex < requestPath.endIndex {
            if patternIndex < pattern.endIndex, pattern[patternIndex] == requestPath[pathIndex] {
                pattern.formIndex(after: &patternIndex)
                requestPath.formIndex(after: &pathIndex)
            } else if patternIndex < pattern.endIndex, pattern[patternIndex] == "*" {
                wildcardIndex = patternIndex
                pattern.formIndex(after: &patternIndex)
                wildcardPathIndex = pathIndex
            } else if let wildcardIndex, var retryPathIndex = wildcardPathIndex,
                      retryPathIndex < requestPath.endIndex {
                requestPath.formIndex(after: &retryPathIndex)
                wildcardPathIndex = retryPathIndex
                patternIndex = pattern.index(after: wildcardIndex)
                pathIndex = retryPathIndex
            } else {
                return false
            }
        }

        while patternIndex < pattern.endIndex, pattern[patternIndex] == "*" {
            pattern.formIndex(after: &patternIndex)
        }
        return patternIndex == pattern.endIndex
    }

    static func sanitizedResponseHeaders(_ headers: [HeaderField]) -> [HeaderField] {
        let blockedHeaders = Set(["content-length", "transfer-encoding", "content-encoding"])
        return headers.filter { !blockedHeaders.contains($0.name.lowercased()) }
    }

    static func sanitizedRequestHeaders(_ headers: [HeaderField]) -> [HeaderField] {
        let blockedHeaders = Set(["content-length", "transfer-encoding", "host"])
        return headers.filter { !blockedHeaders.contains($0.name.lowercased()) }
    }

    static func from(flow: FlowRecord, order: Int) -> MappingRule {
        let components = URLComponents(string: flow.url)
        return MappingRule(
            id: UUID(),
            name: "Map \(flow.method) \(flow.host)\(flow.path)",
            enabled: true,
            order: order,
            method: flow.method,
            scheme: flow.scheme,
            host: flow.host,
            port: flow.port,
            path: components?.path.isEmpty == false ? components?.path ?? flow.path : flow.path,
            matchQuery: false,
            query: components?.percentEncodedQuery,
            statusCode: flow.responseStatus ?? 200,
            responseHeaders: sanitizedResponseHeaders(flow.responseHeaders),
            responseBody: flow.responseBody ?? .empty,
            sourceFlowID: flow.id
        )
    }

    static func requestRewrite(from flow: FlowRecord, order: Int) -> MappingRule {
        let components = URLComponents(string: flow.url)
        return MappingRule(
            id: UUID(),
            name: "Rewrite \(flow.method) \(flow.host)\(flow.path)",
            enabled: true,
            order: order,
            method: flow.method,
            scheme: flow.scheme,
            host: flow.host,
            port: flow.port,
            path: components?.path.isEmpty == false ? components?.path ?? flow.path : flow.path,
            matchQuery: false,
            query: components?.percentEncodedQuery,
            statusCode: flow.responseStatus ?? 200,
            responseHeaders: [],
            responseBody: .empty,
            sourceFlowID: flow.id,
            behavior: .rewriteRequest,
            rewriteHeaders: true,
            requestHeaders: sanitizedRequestHeaders(flow.requestHeaders),
            rewriteBody: flow.requestBody != nil,
            requestBody: flow.requestBody ?? .empty
        )
    }
}

struct ProxySnapshot: Codable, Hashable, Sendable {
    var host: String?
    var port: Int?

    var displayValue: String {
        guard let host, let port else { return "None" }
        return "\(host):\(port)"
    }
}

enum DeviceKind: String, Codable, Sendable {
    case emulator
    case physical
}

enum RootState: String, Codable, Sendable {
    case available
    case unavailable
    case unknown
}

struct DeviceTarget: Codable, Hashable, Identifiable, Sendable {
    var id: String { serial }
    var serial: String
    var model: String
    var apiLevel: Int
    var kind: DeviceKind
    var rootState: RootState
    var isAttached: Bool
    var previousProxy: ProxySnapshot?
    var caInstalled: Bool
    var networkAddresses: [String] = []
    var hardwareID: String? = nil
    var customName: String? = nil

    var displayName: String {
        let trimmedName = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? model : trimmedName
    }

    var aliasKey: String {
        let trimmedHardwareID = hardwareID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedHardwareID.isEmpty || trimmedHardwareID == "unknown" ? serial : trimmedHardwareID
    }
}

struct DebuggableProcess: Codable, Hashable, Identifiable, Sendable {
    var id: String { "\(deviceID):\(pid)" }
    var deviceID: String
    var packageName: String
    var processName: String
    var pid: Int
    var abi: String
}

enum DeepInspectionSelection: Codable, Hashable, Sendable {
    case automatic
    case package(String)
    case off
}

enum InspectionState: Equatable, Sendable {
    case idle
    case discovering
    case attaching(String)
    case active(String)
    case unsupported(String)
    case conflict(String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Inspection idle"
        case .discovering: "Finding debuggable app…"
        case let .attaching(package): "Inspecting \(package)…"
        case let .active(package): "Inspecting \(package)"
        case let .unsupported(message), let .conflict(message), let .failed(message): message
        }
    }
}

struct AgentEnvelope: Codable, Sendable {
    var protocolVersion: Int
    var token: String?
    var type: String
    var payload: JSONValue?
    var error: BridgeErrorPayload?
}

struct FlowAnnotationPayload: Codable, Sendable {
    var flowID: String
    var androidContext: AndroidRequestContext
}

struct BridgeEnvelope: Codable, Sendable {
    var protocolVersion: Int
    var requestID: String?
    var type: String
    var payload: JSONValue?
    var error: BridgeErrorPayload?
}

struct BridgeErrorPayload: Codable, Sendable {
    var code: String
    var message: String
}

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    static func decodeJSON(from data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encodedJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        }
        return try encoder.encode(self)
    }
}

enum EngineState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: Int)
    case failed(String)
}
