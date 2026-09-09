import Foundation
import Observation

@MainActor
@Observable
final class MappingStore {
    private(set) var rules: [MappingRule] = []
    private(set) var revision = 0
    var selectedRuleID: UUID?
    var searchText = ""
    var onRulesChanged: (([MappingRule]) -> Void)?

    private let fileURL: URL

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lens", isDirectory: true)
            try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
            self.fileURL = baseURL.appendingPathComponent("mappings.json")
        }
        load()
    }

    var filteredRules: [MappingRule] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rules }
        return rules.filter {
            $0.name.localizedCaseInsensitiveContains(needle) ||
                $0.matchSummary.localizedCaseInsensitiveContains(needle)
        }
    }

    func create(from flow: FlowRecord) -> UUID {
        let rule = MappingRule.from(flow: flow, order: rules.count)
        rules.append(rule)
        selectedRuleID = rule.id
        persistAndNotify()
        return rule.id
    }

    func createRequestRewrite(from flow: FlowRecord) -> UUID {
        if let index = existingRuleIndex(for: flow, behavior: .rewriteRequest) {
            let existingID = rules[index].id
            selectedRuleID = existingID
            return existingID
        }

        let rule = MappingRule.requestRewrite(from: flow, order: rules.count)
        rules.append(rule)
        selectedRuleID = rule.id
        persistAndNotify()
        return rule.id
    }

    func createRequestHeaderRewrite(from flow: FlowRecord) -> UUID {
        if let index = existingRuleIndex(for: flow, behavior: .rewriteRequest) {
            let existingID = rules[index].id
            selectedRuleID = existingID
            return existingID
        }

        var rule = MappingRule.requestRewrite(from: flow, order: rules.count)
        rule.rewriteBody = false
        rules.append(rule)
        selectedRuleID = rule.id
        persistAndNotify()
        return rule.id
    }

    /// Finds the rule a flow's edits belong to.
    ///
    /// A captured flow names the rule that served it, but that rule may since have
    /// been deleted. Falling back to the flow that created a rule keeps every edit
    /// on one rule instead of leaving a stale identifier to spawn a duplicate for
    /// each change.
    private func existingRuleIndex(for flow: FlowRecord, behavior: MappingBehavior) -> Int? {
        let capturedRuleID = behavior == .rewriteRequest ? flow.rewrittenRuleID : flow.mappedRuleID
        if let capturedRuleID,
           let index = rules.firstIndex(where: { $0.id == capturedRuleID && $0.behavior == behavior }) {
            return index
        }
        return rules.firstIndex { $0.sourceFlowID == flow.id && $0.behavior == behavior }
    }

    /// Creates a local response mapping for a captured flow, or updates the
    /// mapping that produced it. This keeps repeated Tree edits attached to a
    /// single rule instead of adding a new mock for every field change.
    func upsertResponseBody(_ responseBody: BodyPayload, from flow: FlowRecord) -> UUID {
        if let index = existingRuleIndex(for: flow, behavior: .localResponse) {
            rules[index].responseBody = responseBody
            let existingID = rules[index].id
            selectedRuleID = existingID
            persistAndNotify()
            return existingID
        }

        var rule = MappingRule.from(flow: flow, order: rules.count)
        rule.responseBody = responseBody
        rules.append(rule)
        selectedRuleID = rule.id
        persistAndNotify()
        return rule.id
    }

    /// Creates a request rewrite for a captured flow, or updates the request
    /// rewrite that produced it. Tree edits rewrite only the body so unrelated
    /// dynamic headers continue to pass through unchanged.
    func upsertRequestBody(_ requestBody: BodyPayload, from flow: FlowRecord) -> UUID {
        if let index = existingRuleIndex(for: flow, behavior: .rewriteRequest) {
            rules[index].behavior = .rewriteRequest
            rules[index].rewriteBody = true
            rules[index].requestBody = requestBody
            let existingID = rules[index].id
            selectedRuleID = existingID
            persistAndNotify()
            return existingID
        }

        var rule = MappingRule.requestRewrite(from: flow, order: rules.count)
        rule.rewriteHeaders = false
        rule.requestHeaders = []
        rule.rewriteBody = true
        rule.requestBody = requestBody
        rules.append(rule)
        selectedRuleID = rule.id
        persistAndNotify()
        return rule.id
    }

    @discardableResult
    func addBlank(behavior: MappingBehavior = .localResponse) -> UUID {
        let rule = MappingRule(
            id: UUID(),
            name: behavior == .localResponse ? "New local response" : "New request rewrite",
            enabled: true,
            order: rules.count,
            method: "GET",
            scheme: "https",
            host: "example.com",
            port: 443,
            path: "/",
            matchQuery: false,
            query: nil,
            statusCode: 200,
            responseHeaders: [HeaderField(name: "Content-Type", value: "application/json")],
            responseBody: BodyPayload(data: Data("{}".utf8), isText: true, truncated: false, mimeType: "application/json"),
            sourceFlowID: nil,
            behavior: behavior,
            rewriteHeaders: behavior == .rewriteRequest,
            requestHeaders: [],
            rewriteBody: false,
            requestBody: .empty
        )
        rules.append(rule)
        selectedRuleID = rule.id
        persistAndNotify()
        return rule.id
    }

    @discardableResult
    func add(_ rule: MappingRule) -> UUID {
        var addedRule = sanitized(rule)
        if rules.contains(where: { $0.id == addedRule.id }) {
            addedRule.id = UUID()
        }
        addedRule.order = rules.count
        rules.append(addedRule)
        selectedRuleID = addedRule.id
        persistAndNotify()
        return addedRule.id
    }

    func update(_ rule: MappingRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = sanitized(rule)
        persistAndNotify()
    }

    /// Keeps values that reach the engine within the range it can honour, whether
    /// they arrive from the editor or the automation API.
    private func sanitized(_ rule: MappingRule) -> MappingRule {
        var result = rule
        result.delayMilliseconds = NetworkProfile.clampDelay(result.delayMilliseconds)
        return result
    }

    func toggle(_ id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled.toggle()
        persistAndNotify()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> UUID? {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = rules[index]
        copy.id = UUID()
        copy.name += " Copy"
        copy.order = index + 1
        rules.insert(copy, at: index + 1)
        normalizeOrder()
        selectedRuleID = copy.id
        persistAndNotify()
        return copy.id
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        normalizeOrder()
        if selectedRuleID == id { selectedRuleID = rules.first?.id }
        persistAndNotify()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        let movingRules = fromOffsets.sorted().map { rules[$0] }
        rules = rules.enumerated()
            .filter { !fromOffsets.contains($0.offset) }
            .map(\.element)
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let insertionIndex = min(max(0, toOffset - removedBeforeDestination), rules.count)
        rules.insert(contentsOf: movingRules, at: insertionIndex)
        normalizeOrder()
        persistAndNotify()
    }

    @discardableResult
    func reorder(ids: [UUID]) -> Bool {
        guard ids.count == rules.count, Set(ids) == Set(rules.map(\.id)) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        rules = ids.compactMap { byID[$0] }
        normalizeOrder()
        persistAndNotify()
        return true
    }

    private func normalizeOrder() {
        for index in rules.indices { rules[index].order = index }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MappingRule].self, from: data) else { return }
        rules = decoded.sorted { $0.order < $1.order }
        revision = rules.isEmpty ? 0 : 1
    }

    private func persistAndNotify() {
        revision &+= 1
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: fileURL, options: .atomic)
        }
        onRulesChanged?(rules)
    }
}
