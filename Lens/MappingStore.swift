import Foundation
import Observation

@MainActor
@Observable
final class MappingStore {
    private(set) var rules: [MappingRule] = []
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

    func addBlank() {
        let rule = MappingRule(
            id: UUID(),
            name: "New mapping",
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
            sourceFlowID: nil
        )
        rules.append(rule)
        selectedRuleID = rule.id
        persistAndNotify()
    }

    func update(_ rule: MappingRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        persistAndNotify()
    }

    func toggle(_ id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled.toggle()
        persistAndNotify()
    }

    func duplicate(_ id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        var copy = rules[index]
        copy.id = UUID()
        copy.name += " Copy"
        copy.order = index + 1
        rules.insert(copy, at: index + 1)
        normalizeOrder()
        selectedRuleID = copy.id
        persistAndNotify()
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

    private func normalizeOrder() {
        for index in rules.indices { rules[index].order = index }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MappingRule].self, from: data) else { return }
        rules = decoded.sorted { $0.order < $1.order }
    }

    private func persistAndNotify() {
        if let data = try? JSONEncoder().encode(rules) {
            try? data.write(to: fileURL, options: .atomic)
        }
        onRulesChanged?(rules)
    }
}
