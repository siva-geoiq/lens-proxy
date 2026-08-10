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
    var error: String?
    var websocketMessages: [WebSocketFrame]
    var deviceID: String? = nil
    var deviceName: String? = nil

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
              path == (url.path.isEmpty ? "/" : url.path) else { return false }
        return !matchQuery || (query ?? "") == (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
    }

    static func sanitizedResponseHeaders(_ headers: [HeaderField]) -> [HeaderField] {
        let blockedHeaders = Set(["content-length", "transfer-encoding", "content-encoding"])
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

enum JSONValue: Codable, Sendable {
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
}

enum EngineState: Equatable, Sendable {
    case stopped
    case starting
    case running(port: Int)
    case failed(String)
}
