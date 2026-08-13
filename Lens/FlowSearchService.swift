import Foundation
import Darwin

enum FlowSearchField: String, Codable, Hashable, Sendable {
    case method
    case url
    case client
    case status
    case mimeType
    case metadata
    case requestHeader
    case responseHeader
    case requestBody
    case responseBody
    case curl
    case webSocket
    case android

    var label: String {
        switch self {
        case .method: "Method"
        case .url: "URL"
        case .client: "Client"
        case .status: "Status"
        case .mimeType: "Content type"
        case .metadata: "Metadata"
        case .requestHeader: "Request header"
        case .responseHeader: "Response header"
        case .requestBody: "Request body"
        case .responseBody: "Response body"
        case .curl: "cURL"
        case .webSocket: "WebSocket"
        case .android: "Android"
        }
    }
}

struct FlowSearchRequest: Sendable {
    var query: String
    var flows: [FlowRecord]
    var captureRevision: UInt64
}

struct FlowSearchMatch: Identifiable, Hashable, Sendable {
    var flowID: String
    var field: FlowSearchField
    var preview: String?

    var id: String { flowID }
}

struct FlowSearchResult: Sendable {
    var query: String
    var captureRevision: UInt64
    var matches: [FlowSearchMatch]
}

private struct NormalizedFlowSearchQuery: Sendable {
    let text: String
    let foldedASCIIBytes: [UInt8]?

    init(_ text: String) {
        self.text = text
        let bytes = Array(text.utf8)
        foldedASCIIBytes = bytes.allSatisfy { $0 < 0x80 }
            ? bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
            : nil
    }
}

actor FlowSearchService {
    private let maximumWorkers: Int

    init(maximumWorkers: Int = 4) {
        self.maximumWorkers = max(1, maximumWorkers)
    }

    func search(_ request: FlowSearchRequest) async -> FlowSearchResult {
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !request.flows.isEmpty else {
            return FlowSearchResult(query: query, captureRevision: request.captureRevision, matches: [])
        }
        let normalizedQuery = NormalizedFlowSearchQuery(query)

        let workerCount = min(maximumWorkers, request.flows.count)
        let chunkSize = (request.flows.count + workerCount - 1) / workerCount
        let indexedMatches = await withTaskGroup(of: [(Int, FlowSearchMatch)].self) { group in
            for worker in 0..<workerCount {
                let lowerBound = worker * chunkSize
                let upperBound = min(lowerBound + chunkSize, request.flows.count)
                guard lowerBound < upperBound else { continue }
                group.addTask {
                    var matches: [(Int, FlowSearchMatch)] = []
                    matches.reserveCapacity(upperBound - lowerBound)
                    for index in lowerBound..<upperBound {
                        guard !Task.isCancelled else { break }
                        if let match = FlowSearchMatcher.match(flow: request.flows[index], query: normalizedQuery) {
                            matches.append((index, match))
                        }
                    }
                    return matches
                }
            }

            var matches: [(Int, FlowSearchMatch)] = []
            for await chunk in group {
                matches.append(contentsOf: chunk)
            }
            return matches
        }

        let matches = indexedMatches.sorted { $0.0 < $1.0 }.map(\.1)
        return FlowSearchResult(query: query, captureRevision: request.captureRevision, matches: matches)
    }
}

private enum FlowSearchMatcher {
    private struct StringCandidate {
        var field: FlowSearchField
        var value: String
        var showsPreview: Bool
    }

    private struct ASCIIScanResult {
        var offset: Int?
        var containsNonASCII: Bool
    }

    static func match(flow: FlowRecord, query: NormalizedFlowSearchQuery) -> FlowSearchMatch? {
        guard !Task.isCancelled else { return nil }

        let visibleCandidates = [
            StringCandidate(field: .method, value: flow.method, showsPreview: false),
            StringCandidate(field: .url, value: flow.displayURL, showsPreview: false),
            StringCandidate(field: .client, value: flow.clientDisplayName, showsPreview: false),
            StringCandidate(field: .status, value: flow.statusText, showsPreview: false),
            StringCandidate(
                field: .mimeType,
                value: flow.responseBody?.mimeType ?? flow.requestBody?.mimeType ?? "",
                showsPreview: false
            )
        ]
        if let match = firstMatch(in: visibleCandidates, flowID: flow.id, query: query) { return match }

        var metadata = [
            flow.id,
            flow.clientAddress,
            flow.method,
            flow.scheme,
            flow.host,
            String(flow.port),
            flow.path,
            flow.url,
            String(flow.size),
            String(flow.startedAt),
            "\(flow.method) \(flow.path) HTTP"
        ]
        if let value = flow.deviceID { metadata.append(value) }
        if let value = flow.deviceName { metadata.append(value) }
        if let value = flow.responseStatus { metadata.append(String(value)) }
        if let value = flow.responseReason { metadata.append(value) }
        if let value = flow.endedAt { metadata.append(String(value)) }
        if let value = flow.duration { metadata.append(String(value)) }
        if let value = flow.mappedRuleID { metadata.append(value.uuidString) }
        if let value = flow.mappedRuleName { metadata.append(value) }
        if let value = flow.rewrittenRuleID { metadata.append(value.uuidString) }
        if let value = flow.rewrittenRuleName { metadata.append(value) }
        if let value = flow.error { metadata.append(value) }
        if let value = flow.requestBody?.mimeType { metadata.append(value) }
        if let value = flow.responseBody?.mimeType { metadata.append(value) }
        for value in metadata where stringContains(value, query: query) {
            return FlowSearchMatch(flowID: flow.id, field: .metadata, preview: snippet(value, query: query))
        }

        let curlPreamble = [
            "curl -X \(flow.method)",
            "curl --request \(flow.method)",
            "curl --url \(flow.url)",
            "curl --request \(shellQuote(flow.method)) --url \(shellQuote(flow.url))"
        ].joined(separator: " ")
        if stringContains(curlPreamble, query: query) {
            return FlowSearchMatch(flowID: flow.id, field: .curl, preview: snippet(curlPreamble, query: query))
        }

        if let match = headerMatch(
            flow.requestHeaders,
            field: .requestHeader,
            flowID: flow.id,
            query: query,
            includeCurlForms: true
        ) { return match }
        if let match = headerMatch(
            flow.responseHeaders,
            field: .responseHeader,
            flowID: flow.id,
            query: query,
            includeCurlForms: false
        ) { return match }

        if let body = flow.requestBody {
            let curlFlag = body.isText ? "--data-raw" : "--data-binary"
            if stringContains(curlFlag, query: query) {
                return FlowSearchMatch(flowID: flow.id, field: .curl, preview: curlFlag)
            }
            if let match = bodyMatch(body, field: .requestBody, flowID: flow.id, query: query) { return match }
        }
        if let body = flow.responseBody,
           let match = bodyMatch(body, field: .responseBody, flowID: flow.id, query: query) {
            return match
        }

        for frame in flow.websocketMessages {
            guard !Task.isCancelled else { return nil }
            let direction = frame.fromClient ? "client request outgoing" : "server response incoming"
            let value = "\(direction) \(frame.timestamp) \(frame.content)"
            if stringContains(value, query: query) {
                return FlowSearchMatch(flowID: flow.id, field: .webSocket, preview: snippet(value, query: query))
            }
        }

        if let context = flow.androidContext {
            let values = [
                context.packageName,
                context.processName,
                context.threadName,
                context.foregroundActivity ?? "",
                context.primaryCallSite?.displayName ?? "",
                context.stackText,
                context.status.rawValue,
                context.confidence.rawValue
            ]
            for value in values where stringContains(value, query: query) {
                return FlowSearchMatch(flowID: flow.id, field: .android, preview: snippet(value, query: query))
            }
        }
        return nil
    }

    private static func firstMatch(
        in candidates: [StringCandidate],
        flowID: String,
        query: NormalizedFlowSearchQuery
    ) -> FlowSearchMatch? {
        for candidate in candidates where stringContains(candidate.value, query: query) {
            return FlowSearchMatch(
                flowID: flowID,
                field: candidate.field,
                preview: candidate.showsPreview ? snippet(candidate.value, query: query) : nil
            )
        }
        return nil
    }

    private static func headerMatch(
        _ headers: [HeaderField],
        field: FlowSearchField,
        flowID: String,
        query: NormalizedFlowSearchQuery,
        includeCurlForms: Bool
    ) -> FlowSearchMatch? {
        for header in headers {
            guard !Task.isCancelled else { return nil }
            let raw = "\(header.name): \(header.value)"
            if stringContains(raw, query: query) {
                return FlowSearchMatch(flowID: flowID, field: field, preview: snippet(raw, query: query))
            }
            if includeCurlForms {
                let curlForms = "--header \(shellQuote(raw)) -H \(shellQuote(raw))"
                if stringContains(curlForms, query: query) {
                    return FlowSearchMatch(flowID: flowID, field: .curl, preview: snippet(curlForms, query: query))
                }
            }
        }
        return nil
    }

    private static func bodyMatch(
        _ body: BodyPayload,
        field: FlowSearchField,
        flowID: String,
        query: NormalizedFlowSearchQuery
    ) -> FlowSearchMatch? {
        if body.mimeType.map({ stringContains($0, query: query) }) == true {
            return FlowSearchMatch(flowID: flowID, field: .mimeType, preview: nil)
        }
        if body.truncated, stringContains("truncated evicted", query: query) {
            return FlowSearchMatch(flowID: flowID, field: field, preview: "truncated evicted")
        }
        guard !body.data.isEmpty, !Task.isCancelled else { return nil }

        guard body.isText else {
            let preview = body.hexPreview
            guard stringContains(preview, query: query) else { return nil }
            return FlowSearchMatch(flowID: flowID, field: field, preview: snippet(preview, query: query))
        }

        if let foldedASCIIBytes = query.foldedASCIIBytes {
            let scan = asciiCaseInsensitiveOffset(in: body.data, foldedQuery: foldedASCIIBytes)
            if let offset = scan.offset {
                return FlowSearchMatch(
                    flowID: flowID,
                    field: field,
                    preview: dataSnippet(body.data, offset: offset, matchLength: foldedASCIIBytes.count)
                )
            }
            guard scan.containsNonASCII else { return nil }
        }

        guard !Task.isCancelled else { return nil }
        guard let text = String(data: body.data, encoding: .utf8) else {
            let preview = body.hexPreview
            guard stringContains(preview, query: query) else { return nil }
            return FlowSearchMatch(flowID: flowID, field: field, preview: snippet(preview, query: query))
        }
        guard stringContains(text, query: query) else { return nil }
        return FlowSearchMatch(flowID: flowID, field: field, preview: snippet(text, query: query))
    }

    private static func asciiCaseInsensitiveOffset(in data: Data, foldedQuery: [UInt8]) -> ASCIIScanResult {
        guard !foldedQuery.isEmpty else { return ASCIIScanResult(offset: 0, containsNonASCII: false) }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard let baseAddress = bytes.baseAddress else {
                return ASCIIScanResult(offset: nil, containsNonASCII: false)
            }
            guard bytes.count >= foldedQuery.count else {
                return ASCIIScanResult(
                    offset: nil,
                    containsNonASCII: containsNonASCII(baseAddress: baseAddress, count: bytes.count)
                )
            }

            let finalStart = bytes.count - foldedQuery.count
            let firstLowercase = foldedQuery[0]
            let firstUppercase = (97...122).contains(firstLowercase) ? firstLowercase - 32 : firstLowercase
            var searchStart = 0
            while searchStart <= finalStart {
                guard !Task.isCancelled else {
                    return ASCIIScanResult(offset: nil, containsNonASCII: false)
                }
                let remainingCount = min(finalStart - searchStart + 1, 65_536)
                let lowercaseMatch = memchr(baseAddress + searchStart, Int32(firstLowercase), remainingCount)
                    .map { baseAddress.distance(to: $0.assumingMemoryBound(to: UInt8.self)) }
                let uppercaseMatch = firstUppercase == firstLowercase
                    ? nil
                    : memchr(baseAddress + searchStart, Int32(firstUppercase), remainingCount)
                        .map { baseAddress.distance(to: $0.assumingMemoryBound(to: UInt8.self)) }
                guard let start = [lowercaseMatch, uppercaseMatch].compactMap({ $0 }).min() else {
                    searchStart += remainingCount
                    continue
                }

                var matched = true
                for queryIndex in 1..<foldedQuery.count {
                    if queryIndex.isMultiple(of: 65_536), Task.isCancelled { return ASCIIScanResult(offset: nil, containsNonASCII: false) }
                    if asciiFold(bytes[start + queryIndex]) != foldedQuery[queryIndex] {
                        matched = false
                        break
                    }
                }
                if matched { return ASCIIScanResult(offset: start, containsNonASCII: false) }
                searchStart = start + 1
            }
            return ASCIIScanResult(
                offset: nil,
                containsNonASCII: containsNonASCII(baseAddress: baseAddress, count: bytes.count)
            )
        }
    }

    private static func containsNonASCII(baseAddress: UnsafePointer<UInt8>, count: Int) -> Bool {
        let highBitMask: UInt64 = 0x8080_8080_8080_8080
        var index = 0
        while index + MemoryLayout<UInt64>.size <= count {
            if index.isMultiple(of: 65_536), Task.isCancelled { return false }
            let word = UnsafeRawPointer(baseAddress + index).loadUnaligned(as: UInt64.self)
            if word & highBitMask != 0 { return true }
            index += MemoryLayout<UInt64>.size
        }
        while index < count {
            if baseAddress[index] >= 0x80 { return true }
            index += 1
        }
        return false
    }

    private static func asciiFold(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static func stringContains(_ value: String, query: NormalizedFlowSearchQuery) -> Bool {
        value.range(of: query.text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func snippet(_ value: String, query: NormalizedFlowSearchQuery) -> String {
        guard let match = value.range(of: query.text, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return sanitized(value)
        }
        let lowerBound = value.index(match.lowerBound, offsetBy: -70, limitedBy: value.startIndex) ?? value.startIndex
        let upperBound = value.index(match.upperBound, offsetBy: 110, limitedBy: value.endIndex) ?? value.endIndex
        let prefix = lowerBound == value.startIndex ? "" : "…"
        let suffix = upperBound == value.endIndex ? "" : "…"
        return prefix + sanitized(String(value[lowerBound..<upperBound])) + suffix
    }

    private static func dataSnippet(_ data: Data, offset: Int, matchLength: Int) -> String {
        let lowerBound = max(0, offset - 70)
        let upperBound = min(data.count, offset + matchLength + 110)
        let prefix = lowerBound == 0 ? "" : "…"
        let suffix = upperBound == data.count ? "" : "…"
        return prefix + sanitized(String(decoding: data[lowerBound..<upperBound], as: UTF8.self)) + suffix
    }

    private static func sanitized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
