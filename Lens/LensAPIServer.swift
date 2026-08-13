import CryptoKit
import Foundation
@preconcurrency import Network
import Observation
import Security

struct LensHTTPRequest: Sendable {
    var method: String
    var target: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

struct LensHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(status: Int = 200, value: JSONValue, requestID: String, headers: [String: String] = [:]) -> LensHTTPResponse {
        let envelope = JSONValue.object([
            "apiVersion": .string(LensAutomationController.apiVersion),
            "requestId": .string(requestID),
            "data": value
        ])
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json; charset=utf-8"
        return LensHTTPResponse(status: status, headers: responseHeaders, body: (try? envelope.encodedJSON(prettyPrinted: false)) ?? Data())
    }

    static func error(_ problem: LensAPIProblem, requestID: String) -> LensHTTPResponse {
        var errorObject: [String: JSONValue] = [
            "code": .string(problem.code),
            "message": .string(problem.message)
        ]
        if let details = problem.details { errorObject["details"] = details }
        let envelope = JSONValue.object([
            "apiVersion": .string(LensAutomationController.apiVersion),
            "requestId": .string(requestID),
            "error": .object(errorObject)
        ])
        return LensHTTPResponse(
            status: problem.status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: (try? envelope.encodedJSON(prettyPrinted: false)) ?? Data()
        )
    }
}

struct LensAPIProblem: Error, Sendable {
    var status: Int
    var code: String
    var message: String
    var details: JSONValue?

    static func badRequest(_ message: String) -> LensAPIProblem {
        LensAPIProblem(status: 400, code: "invalid_request", message: message)
    }

    static func notFound(_ message: String) -> LensAPIProblem {
        LensAPIProblem(status: 404, code: "not_found", message: message)
    }
}

enum LensHTTPParser {
    static let maximumRequestBytes = 12 * 1024 * 1024

    static func parse(_ data: Data) throws -> LensHTTPRequest? {
        guard data.count <= maximumRequestBytes else {
            throw LensAPIProblem(status: 413, code: "request_too_large", message: "Requests are limited to 12 MB.")
        }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }
        guard let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw LensAPIProblem.badRequest("HTTP headers must be UTF-8.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw LensAPIProblem.badRequest("Missing request line.") }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/1.") else {
            throw LensAPIProblem.badRequest("Only HTTP/1.x requests are supported.")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw LensAPIProblem.badRequest("Malformed HTTP header.") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil {
            throw LensAPIProblem.badRequest("Chunked request bodies are not supported.")
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= maximumRequestBytes else {
            throw LensAPIProblem(status: 413, code: "request_too_large", message: "Requests are limited to 12 MB.")
        }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let target = String(requestParts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            throw LensAPIProblem.badRequest("Malformed request target.")
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name] = value }
        }
        return LensHTTPRequest(
            method: String(requestParts[0]).uppercased(),
            target: target,
            path: components.path,
            query: query,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }
}

struct LensAPIOperation: Codable, Sendable {
    enum State: String, Codable, Sendable { case pending, running, succeeded, failed }

    var id: UUID
    var state: State
    var createdAt: Double
    var completedAt: Double?
    var result: JSONValue?
    var error: BridgeErrorPayload?
}

@MainActor
final class LensAPIOperationStore {
    private(set) var operations: [UUID: LensAPIOperation] = [:]
    private var idempotency: [String: UUID] = [:]
    var eventSink: ((String, JSONValue) -> Void)?

    func start(idempotencyKey: String?, work: @escaping @MainActor () async throws -> JSONValue?) -> LensAPIOperation {
        if let idempotencyKey, let id = idempotency[idempotencyKey], let operation = operations[id] { return operation }
        let id = UUID()
        let operation = LensAPIOperation(id: id, state: .pending, createdAt: Date().timeIntervalSince1970)
        operations[id] = operation
        if let idempotencyKey { idempotency[idempotencyKey] = id }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.operations[id]?.state = .running
            do {
                let result = try await work()
                self.operations[id]?.state = .succeeded
                self.operations[id]?.result = result
            } catch {
                self.operations[id]?.state = .failed
                self.operations[id]?.error = BridgeErrorPayload(code: "operation_failed", message: error.localizedDescription)
            }
            self.operations[id]?.completedAt = Date().timeIntervalSince1970
            if let completed = self.operations[id], let payload = try? JSONValue(completed) {
                self.eventSink?("operation.completed", payload)
            }
        }
        return operation
    }
}

@MainActor
final class LensConfirmationStore {
    private struct Challenge {
        var fingerprint: String
        var expiresAt: Date
        var summary: String
    }

    private var challenges: [String: Challenge] = [:]

    func authorize(request: LensHTTPRequest, summary: String) throws {
        let fingerprint = Self.fingerprint(request)
        if let token = request.header("x-lens-confirmation"),
           let challenge = challenges.removeValue(forKey: token),
           challenge.expiresAt > Date(), challenge.fingerprint == fingerprint {
            return
        }
        challenges = challenges.filter { $0.value.expiresAt > Date() }
        let token = UUID().uuidString
        let expiry = Date().addingTimeInterval(60)
        challenges[token] = Challenge(fingerprint: fingerprint, expiresAt: expiry, summary: summary)
        throw LensAPIProblem(
            status: 409,
            code: "confirmation_required",
            message: summary,
            details: .object([
                "confirmationId": .string(token),
                "expiresAt": .number(expiry.timeIntervalSince1970),
                "summary": .string(summary)
            ])
        )
    }

    private static func fingerprint(_ request: LensHTTPRequest) -> String {
        var data = Data("\(request.method)\n\(request.path)\n".utf8)
        data.append(request.body)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class LensAPIRouter {
    private let controller: LensAutomationController
    private let confirmations = LensConfirmationStore()
    private let operations = LensAPIOperationStore()

    init(controller: LensAutomationController) {
        self.controller = controller
        operations.eventSink = { [weak controller] type, payload in controller?.publish(type: type, payload: payload) }
    }

    func route(_ request: LensHTTPRequest, requestID: String) async -> LensHTTPResponse {
        do {
            return try await perform(request, requestID: requestID)
        } catch let problem as LensAPIProblem {
            return .error(problem, requestID: requestID)
        } catch let error as LensAutomationError {
            let status: Int = switch error {
            case .notFound: 404
            case .invalidInput: 400
            case .conflict: 409
            case .unavailable: 503
            }
            return .error(LensAPIProblem(status: status, code: "automation_error", message: error.localizedDescription), requestID: requestID)
        } catch {
            return .error(LensAPIProblem(status: 500, code: "internal_error", message: error.localizedDescription), requestID: requestID)
        }
    }

    private func perform(_ request: LensHTTPRequest, requestID: String) async throws -> LensHTTPResponse {
        let components = request.path.split(separator: "/").map(String.init)

        if request.method == "GET", request.path == "/v1/status" {
            return .json(value: try controller.status(), requestID: requestID)
        }
        if request.method == "GET", request.path == "/v1/capabilities" {
            return .json(value: controller.capabilities(), requestID: requestID)
        }
        if request.method == "GET", request.path == "/v1/engine/log" {
            return .json(value: .object(["log": .string(controller.engineLog)]), requestID: requestID)
        }
        if request.method == "POST", components == ["v1", "engine", "start"] {
            return operationResponse(request, requestID: requestID) { [controller] in controller.startEngine(); return try controller.status() }
        }
        if request.method == "POST", components == ["v1", "engine", "stop"] {
            if controller.hasAttachedDevices { try confirmations.authorize(request: request, summary: "Stop Lens and restore all attached device proxies.") }
            return operationResponse(request, requestID: requestID) { [controller] in await controller.stopEngine(); return try controller.status() }
        }
        if request.method == "POST", components == ["v1", "engine", "restart"] {
            if controller.hasAttachedDevices { try confirmations.authorize(request: request, summary: "Restart Lens while Android devices are attached.") }
            return operationResponse(request, requestID: requestID) { [controller] in await controller.restartEngine(); return try controller.status() }
        }
        if request.method == "PATCH", components == ["v1", "settings"] {
            struct Input: Decodable { var proxyPort: Int? }
            let input = try decode(Input.self, request)
            if let port = input.proxyPort { try controller.setProxyPort(port) }
            return .json(value: try controller.status(), requestID: requestID)
        }
        if request.method == "POST", components == ["v1", "capture", "pause"] {
            controller.setCapturePaused(true)
            return .json(value: .object(["paused": .bool(true)]), requestID: requestID)
        }
        if request.method == "POST", components == ["v1", "capture", "resume"] {
            controller.setCapturePaused(false)
            return .json(value: .object(["paused": .bool(false)]), requestID: requestID)
        }
        if request.method == "POST", components == ["v1", "capture", "clear"] {
            try confirmations.authorize(request: request, summary: "Clear all captured flows and inspection correlations.")
            controller.clearCapture()
            return .json(value: .object(["cleared": .bool(true)]), requestID: requestID)
        }
        if request.method == "PUT", components == ["v1", "capture", "options"] {
            struct Input: Decodable { var removeConditionalHeaders: Bool }
            let input = try decode(Input.self, request)
            controller.setRemoveConditionalHeaders(input.removeConditionalHeaders)
            return .json(value: .object(["removeConditionalHeaders": .bool(input.removeConditionalHeaders)]), requestID: requestID)
        }
        if request.method == "GET", components == ["v1", "flows"] {
            return try await flowList(request, requestID: requestID)
        }
        if request.method == "GET", components == ["v1", "search"] {
            var query = request.query
            query["search"] = query["q"] ?? ""
            let matches = await controller.filteredFlows(query: query).map(LensFlowSummary.init)
            return .json(value: try JSONValue(["items": matches]), requestID: requestID)
        }
        if components.count >= 3, components[0] == "v1", components[1] == "flows" {
            return try await flowRoute(request, components: components, requestID: requestID)
        }
        if request.method == "GET", components == ["v1", "mappings"] {
            return .json(
                value: .object([
                    "revision": .number(Double(controller.mappingRevision)),
                    "items": (try? JSONValue(controller.mappings)) ?? .array([])
                ]),
                requestID: requestID,
                headers: ["ETag": "\"\(controller.mappingRevision)\""]
            )
        }
        if request.method == "POST", components == ["v1", "mappings"] {
            let rule = try decode(MappingRule.self, request)
            let id = controller.addMapping(rule)
            return .json(status: 201, value: .object(["id": .string(id.uuidString)]), requestID: requestID)
        }
        if request.method == "PUT", components == ["v1", "mappings", "order"] {
            try requireMappingRevision(request)
            struct Input: Decodable { var ids: [UUID] }
            try controller.reorderMappings(ids: decode(Input.self, request).ids)
            return mappingMutationResponse(requestID)
        }
        if components.count >= 3, components[0] == "v1", components[1] == "mappings" {
            return try mappingRoute(request, components: components, requestID: requestID)
        }
        if request.method == "POST", components == ["v1", "sessions", "save"] {
            struct Input: Decodable { var path: String }
            let input = try decode(Input.self, request)
            if FileManager.default.fileExists(atPath: input.path) {
                try confirmations.authorize(request: request, summary: "Overwrite the existing session at \(input.path).")
            }
            return operationResponse(request, requestID: requestID) { [controller] in try controller.saveSession(path: input.path); return .object(["path": .string(input.path)]) }
        }
        if request.method == "POST", components == ["v1", "sessions", "open"] {
            struct Input: Decodable { var path: String }
            let input = try decode(Input.self, request)
            try confirmations.authorize(request: request, summary: "Replace the current capture with session \(input.path).")
            return operationResponse(request, requestID: requestID) { [controller] in try controller.openSession(path: input.path); return .object(["path": .string(input.path)]) }
        }
        if request.method == "GET", components == ["v1", "devices"] {
            return .json(value: try JSONValue(["items": controller.devices]), requestID: requestID)
        }
        if request.method == "POST", components == ["v1", "devices", "refresh"] {
            return operationResponse(request, requestID: requestID) { [controller] in await controller.refreshDevices(); return try JSONValue(controller.devices) }
        }
        if components.count >= 3, components[0] == "v1", components[1] == "devices" {
            return try await deviceRoute(request, components: components, requestID: requestID)
        }
        if request.method == "GET", components.count == 3, components[0] == "v1", components[1] == "operations",
           let id = UUID(uuidString: components[2]), let operation = operations.operations[id] {
            return .json(value: try JSONValue(operation), requestID: requestID)
        }
        throw LensAPIProblem.notFound("No API route matches \(request.method) \(request.path).")
    }

    private func flowList(_ request: LensHTTPRequest, requestID: String) async throws -> LensHTTPResponse {
        let flows = await controller.filteredFlows(query: request.query)
        let limit = min(max(Int(request.query["limit"] ?? "100") ?? 100, 1), 500)
        let offset = decodeCursor(request.query["cursor"]) ?? 0
        guard offset <= flows.count else { throw LensAPIProblem.badRequest("The flow cursor is invalid.") }
        let end = min(offset + limit, flows.count)
        let items = flows[offset..<end].map(LensFlowSummary.init)
        let nextCursor = end < flows.count ? encodeCursor(end) : nil
        return .json(value: .object([
            "items": (try? JSONValue(items)) ?? .array([]),
            "total": .number(Double(flows.count)),
            "nextCursor": nextCursor.map(JSONValue.string) ?? .null
        ]), requestID: requestID)
    }

    private func flowRoute(_ request: LensHTTPRequest, components: [String], requestID: String) async throws -> LensHTTPResponse {
        let flowID = decodePath(components[2])
        let flow = try controller.flow(id: flowID)
        if request.method == "GET", components.count == 3 {
            return .json(value: try JSONValue(LensFlowDetail(flow: flow)), requestID: requestID)
        }
        if request.method == "GET", components.count == 4, components[3] == "curl" {
            return .json(value: .object(["curl": .string(controller.curl(for: flow))]), requestID: requestID)
        }
        if request.method == "GET", components.count == 5, ["request", "response"].contains(components[3]), components[4] == "body" {
            let body = components[3] == "request" ? flow.requestBody : flow.responseBody
            guard let body else { throw LensAPIProblem.notFound("This flow has no \(components[3]) body.") }
            return LensHTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": body.mimeType ?? "application/octet-stream",
                    "X-Lens-Truncated": body.truncated ? "true" : "false",
                    "X-Lens-Text": body.isText ? "true" : "false"
                ],
                body: body.data
            )
        }
        if request.method == "POST", components.count == 4, components[3] == "mappings" {
            struct Input: Decodable { var behavior: MappingBehavior }
            let id = try controller.createMapping(from: flowID, behavior: decode(Input.self, request).behavior)
            return .json(status: 201, value: .object(["id": .string(id.uuidString)]), requestID: requestID)
        }
        throw LensAPIProblem.notFound("No flow operation matches this request.")
    }

    private func mappingRoute(_ request: LensHTTPRequest, components: [String], requestID: String) throws -> LensHTTPResponse {
        guard let id = UUID(uuidString: components[2]) else { throw LensAPIProblem.badRequest("Malformed mapping identifier.") }
        if request.method == "GET", components.count == 3 {
            guard let rule = controller.mappings.first(where: { $0.id == id }) else { throw LensAPIProblem.notFound("Mapping not found.") }
            return .json(value: try JSONValue(rule), requestID: requestID, headers: ["ETag": "\"\(controller.mappingRevision)\""])
        }
        try requireMappingRevision(request)
        if request.method == "PUT", components.count == 3 {
            let rule = try decode(MappingRule.self, request)
            guard rule.id == id else { throw LensAPIProblem.badRequest("The path and body mapping identifiers differ.") }
            try controller.updateMapping(rule)
            return mappingMutationResponse(requestID)
        }
        if request.method == "DELETE", components.count == 3 {
            try confirmations.authorize(request: request, summary: "Delete mapping \(id.uuidString).")
            try controller.deleteMapping(id: id)
            return mappingMutationResponse(requestID)
        }
        if request.method == "POST", components.count == 4, components[3] == "duplicate" {
            let newID = try controller.duplicateMapping(id: id)
            return .json(status: 201, value: .object(["id": .string(newID.uuidString)]), requestID: requestID)
        }
        if request.method == "PUT", components.count == 4, components[3] == "enabled" {
            struct Input: Decodable { var enabled: Bool }
            try controller.setMappingEnabled(id: id, enabled: decode(Input.self, request).enabled)
            return mappingMutationResponse(requestID)
        }
        throw LensAPIProblem.notFound("No mapping operation matches this request.")
    }

    private func deviceRoute(_ request: LensHTTPRequest, components: [String], requestID: String) async throws -> LensHTTPResponse {
        let serial = decodePath(components[2])
        if request.method == "GET", components.count == 3 {
            return .json(value: try JSONValue(controller.device(serial: serial)), requestID: requestID)
        }
        if request.method == "PATCH", components.count == 3 {
            struct Input: Decodable { var name: String? }
            try controller.renameDevice(serial: serial, name: decode(Input.self, request).name)
            return .json(value: try JSONValue(controller.device(serial: serial)), requestID: requestID)
        }
        if request.method == "POST", components.count == 4, components[3] == "attach" {
            struct Input: Decodable { var stopConflictingVPN: Bool? }
            let stopVPN = (try? decode(Input.self, request).stopConflictingVPN) ?? false
            if !stopVPN, let package = controller.activeVPNPackage {
                throw LensAPIProblem(
                    status: 409,
                    code: "vpn_conflict",
                    message: "Android VPN \(package) must be stopped before Lens can attach.",
                    details: .object(["package": .string(package), "retryWithStopConflictingVPN": .bool(true)])
                )
            }
            if stopVPN { try confirmations.authorize(request: request, summary: "Stop the conflicting Android VPN and attach device \(serial).") }
            return operationResponse(request, requestID: requestID) { [controller] in try await controller.attachDevice(serial: serial, stopConflictingVPN: stopVPN); return try JSONValue(controller.device(serial: serial)) }
        }
        if request.method == "POST", components.count == 4, components[3] == "detach" {
            return operationResponse(request, requestID: requestID) { [controller] in try await controller.detachDevice(serial: serial); return try JSONValue(controller.device(serial: serial)) }
        }
        if request.method == "GET", components.count == 4, components[3] == "inspection" {
            return .json(value: try JSONValue(controller.inspection(serial: serial)), requestID: requestID)
        }
        if request.method == "GET", components.count == 5, components[3] == "inspection", components[4] == "processes" {
            return .json(value: try JSONValue(controller.inspection(serial: serial).processes), requestID: requestID)
        }
        if request.method == "PUT", components.count == 4, components[3] == "inspection" {
            struct Input: Decodable { var mode: String; var package: String? }
            let input = try decode(Input.self, request)
            try controller.setInspection(serial: serial, mode: input.mode, package: input.package)
            return .json(value: try JSONValue(controller.inspection(serial: serial)), requestID: requestID)
        }
        throw LensAPIProblem.notFound("No device operation matches this request.")
    }

    private func operationResponse(
        _ request: LensHTTPRequest,
        requestID: String,
        work: @escaping @MainActor () async throws -> JSONValue?
    ) -> LensHTTPResponse {
        let operation = operations.start(idempotencyKey: request.header("idempotency-key"), work: work)
        return .json(status: 202, value: (try? JSONValue(operation)) ?? .object([:]), requestID: requestID)
    }

    private func mappingMutationResponse(_ requestID: String) -> LensHTTPResponse {
        .json(
            value: .object(["revision": .number(Double(controller.mappingRevision))]),
            requestID: requestID,
            headers: ["ETag": "\"\(controller.mappingRevision)\""]
        )
    }

    private func requireMappingRevision(_ request: LensHTTPRequest) throws {
        guard let header = request.header("if-match") else {
            throw LensAPIProblem(status: 428, code: "precondition_required", message: "Supply the mapping ETag in If-Match.")
        }
        let normalized = header.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard Int(normalized) == controller.mappingRevision else {
            throw LensAPIProblem(status: 412, code: "revision_mismatch", message: "Mappings changed; fetch the latest collection and retry.")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: LensHTTPRequest) throws -> T {
        guard !request.body.isEmpty else { throw LensAPIProblem.badRequest("A JSON request body is required.") }
        do { return try JSONDecoder().decode(type, from: request.body) }
        catch { throw LensAPIProblem.badRequest("Invalid JSON body: \(error.localizedDescription)") }
    }

    private func decodePath(_ value: String) -> String { value.removingPercentEncoding ?? value }
    private func encodeCursor(_ offset: Int) -> String { Data(String(offset).utf8).base64EncodedString() }
    private func decodeCursor(_ cursor: String?) -> Int? {
        guard let cursor else { return 0 }
        guard let data = Data(base64Encoded: cursor), let string = String(data: data, encoding: .utf8) else { return nil }
        return Int(string)
    }
}

final class LensAPIKeychainStore: @unchecked Sendable {
    private let service = "com.lenskart.lens.api"
    private let account = "local-automation"

    func token() throws -> String {
        if let existing = try read() { return existing }
        return try rotate()
    }

    func rotate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LensAPIProblem(status: 500, code: "keychain_error", message: "Could not generate an API token.")
        }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let deleteQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(deleteQuery as CFDictionary)
        var addQuery = deleteQuery
        addQuery[kSecValueData as String] = Data(token.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw LensAPIProblem(status: 500, code: "keychain_error", message: "Could not store the API token.")
        }
        return token
    }

    private func read() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw LensAPIProblem(status: 500, code: "keychain_error", message: "Could not read the API token.")
        }
        return token
    }
}

@MainActor
@Observable
final class LensAPIServer {
    enum State: Equatable { case stopped, starting, running(port: UInt16), failed(String) }

    private let controller: LensAutomationController
    private let keychain: LensAPIKeychainStore
    private let router: LensAPIRouter
    private let queue = DispatchQueue(label: "com.lenskart.lens.api")
    private var listener: NWListener?
    private var token = ""
    private var connections: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]
    private var eventClients = Set<UUID>()
    private(set) var events: [LensAPIEvent] = []
    private(set) var state: State = .stopped
    private(set) var connectedClients = 0

    init(controller: LensAutomationController, keychain: LensAPIKeychainStore = LensAPIKeychainStore()) {
        self.controller = controller
        self.keychain = keychain
        router = LensAPIRouter(controller: controller)
    }

    func start() {
        guard state == .stopped else { return }
        state = .starting
        do {
            token = try keychain.token()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in self?.listenerStateChanged(state, port: listener?.port) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            controller.eventSink = { [weak self] event in self?.publish(event) }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        buffers.removeAll()
        eventClients.removeAll()
        connectedClients = 0
        controller.eventSink = nil
        try? FileManager.default.removeItem(at: discoveryURL)
        state = .stopped
    }

    func rotateToken() throws {
        token = try keychain.rotate()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        eventClients.removeAll()
        connectedClients = 0
        publish(type: "api.token_rotated", payload: .object([:]))
    }

    func publish(type: String, payload: JSONValue) {
        controller.publish(type: type, payload: payload)
    }

    func publish(_ event: LensAPIEvent) {
        events.append(event)
        if events.count > 1_000 { events.removeFirst(events.count - 1_000) }
        guard let data = sseData(event) else { return }
        for id in eventClients { send(data, to: id, close: false) }
    }

    var port: UInt16? {
        if case let .running(port) = state { return port }
        return nil
    }

    private func listenerStateChanged(_ listenerState: NWListener.State, port: NWEndpoint.Port?) {
        switch listenerState {
        case .ready:
            guard let port else { state = .failed("The API listener did not publish a port."); return }
            state = .running(port: port.rawValue)
            do { try writeDiscovery(port: port.rawValue) }
            catch {
                listener?.cancel()
                listener = nil
                try? FileManager.default.removeItem(at: discoveryURL)
                state = .failed(error.localizedDescription)
            }
        case let .failed(error):
            state = .failed(error.localizedDescription)
        case .cancelled:
            if state != .stopped { state = .stopped }
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        buffers[id] = Data()
        connectedClients = connections.count
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.removeConnection(id) } }
            if case .cancelled = state { Task { @MainActor in self?.removeConnection(id) } }
        }
        connection.start(queue: queue)
        receive(on: id)
    }

    private func receive(on id: UUID) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.buffers[id, default: Data()].append(data) }
                if let error {
                    self.sendProblem(LensAPIProblem(status: 400, code: "connection_error", message: error.localizedDescription), to: id)
                    return
                }
                do {
                    if let request = try LensHTTPParser.parse(self.buffers[id] ?? Data()) {
                        await self.handle(request, connectionID: id)
                    } else if isComplete {
                        self.sendProblem(.badRequest("Incomplete HTTP request."), to: id)
                    } else {
                        self.receive(on: id)
                    }
                } catch let problem as LensAPIProblem {
                    self.sendProblem(problem, to: id)
                } catch {
                    self.sendProblem(.badRequest(error.localizedDescription), to: id)
                }
            }
        }
    }

    private func handle(_ request: LensHTTPRequest, connectionID: UUID) async {
        let requestID = UUID().uuidString
        guard request.header("origin") == nil else {
            send(.error(LensAPIProblem(status: 403, code: "browser_origin_rejected", message: "Browser-origin requests are not allowed."), requestID: requestID), to: connectionID)
            return
        }
        guard request.header("authorization") == "Bearer \(token)" else {
            send(.error(LensAPIProblem(status: 401, code: "unauthorized", message: "Supply the Lens bearer token."), requestID: requestID), to: connectionID)
            return
        }
        guard request.path == "/v1" || request.path.hasPrefix("/v1/") else {
            send(.error(LensAPIProblem(status: 400, code: "unsupported_version", message: "Use Lens API /v1."), requestID: requestID), to: connectionID)
            return
        }
        if request.method == "GET", request.path == "/v1/openapi.json" {
            let data = Bundle.main.url(forResource: "openapi", withExtension: "json").flatMap { try? Data(contentsOf: $0) } ?? Data("{}".utf8)
            send(LensHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data), to: connectionID)
            return
        }
        if request.method == "GET", request.path == "/v1/events" {
            eventClients.insert(connectionID)
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n"
            send(Data(headers.utf8), to: connectionID, close: false)
            let lastID = request.header("last-event-id").flatMap(UInt64.init) ?? 0
            let replay = events.filter { $0.id > lastID }
            if lastID > 0, let first = events.first, lastID + 1 < first.id {
                let reset = LensAPIEvent(id: first.id, type: "stream.reset_required", timestamp: Date().timeIntervalSince1970, payload: .object([:]))
                if let data = sseData(reset) { send(data, to: connectionID, close: false) }
            }
            for event in replay { if let data = sseData(event) { send(data, to: connectionID, close: false) } }
            return
        }
        send(await router.route(request, requestID: requestID), to: connectionID)
    }

    private func send(_ response: LensHTTPResponse, to id: UUID) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["X-Content-Type-Options"] = "nosniff"
        var text = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(response.body)
        send(data, to: id, close: true)
    }

    private func sendProblem(_ problem: LensAPIProblem, to id: UUID) {
        send(.error(problem, requestID: UUID().uuidString), to: id)
    }

    private func send(_ data: Data, to id: UUID, close: Bool) {
        guard let connection = connections[id] else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            if close { Task { @MainActor in self?.removeConnection(id) } }
        })
    }

    private func removeConnection(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        buffers.removeValue(forKey: id)
        eventClients.remove(id)
        connectedClients = connections.count
    }

    private func sseData(_ event: LensAPIEvent) -> Data? {
        guard let payload = try? JSONEncoder().encode(event) else { return nil }
        return Data("id: \(event.id)\nevent: \(event.type)\ndata: \(String(decoding: payload, as: UTF8.self))\n\n".utf8)
    }

    private func writeDiscovery(port: UInt16) throws {
        let directory = discoveryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let value = JSONValue.object([
            "apiVersion": .string(LensAutomationController.apiVersion),
            "baseURL": .string("http://127.0.0.1:\(port)"),
            "bundleIdentifier": .string("com.lenskart.lens.Lens"),
            "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "startedAt": .number(Date().timeIntervalSince1970)
        ])
        try value.encodedJSON(prettyPrinted: true).write(to: discoveryURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: discoveryURL.path)
    }

    private var discoveryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens", isDirectory: true).appendingPathComponent("api.json")
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 412: "Precondition Failed"
        case 413: "Payload Too Large"
        case 428: "Precondition Required"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Response"
        }
    }
}
