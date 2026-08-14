import SwiftUI

struct MappingManagerView: View {
    @Environment(LensModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRule: MappingRule?
    @State private var editorGeneration = 0
    @State private var saveError: String?

    var body: some View {
        @Bindable var mappings = model.mappings
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("Filter mappings", text: $mappings.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(9)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .padding(10)
                List(selection: $mappings.selectedRuleID) {
                    ForEach(mappings.filteredRules) { rule in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { rule.enabled },
                                set: { enabled in try? model.automation.setMappingEnabled(id: rule.id, enabled: enabled) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Image(systemName: rule.behavior.systemImage)
                                        .foregroundStyle(rule.behavior == .rewriteRequest ? .blue : .orange)
                                    Text(rule.name).lineLimit(1)
                                }
                                Text(rule.matchSummary)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(rule.id)
                        .contextMenu {
                            Button("Duplicate") { _ = try? model.automation.duplicateMapping(id: rule.id) }
                            Button("Delete", role: .destructive) { try? model.automation.deleteMapping(id: rule.id) }
                        }
                    }
                    .onMove(perform: model.automation.moveMappings)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("Local Response", systemImage: MappingBehavior.localResponse.systemImage) {
                            _ = model.automation.addBlankMapping(behavior: .localResponse)
                        }
                        Button("Request Rewrite", systemImage: MappingBehavior.rewriteRequest.systemImage) {
                            _ = model.automation.addBlankMapping(behavior: .rewriteRequest)
                        }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add mapping")
                        .help("Add a local response or request rewrite")
                    Button {
                        if let id = mappings.selectedRuleID { try? model.automation.deleteMapping(id: id) }
                    } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete mapping")
                    .help("Delete selected mapping")
                    .disabled(mappings.selectedRuleID == nil)
                }
            }
        } detail: {
            if let id = mappings.selectedRuleID,
               let rule = mappings.rules.first(where: { $0.id == id }) {
                MappingEditorView(rule: rule) { pendingRule = $0 }
                    .id("\(rule.id.uuidString)-\(editorGeneration)")
            } else {
                ContentUnavailableView("Select a mapping", systemImage: "arrow.triangle.branch", description: Text("Create a mapping or choose one from the sidebar."))
            }
        }
        .onChange(of: mappings.selectedRuleID) { oldID, _ in
            if savePendingRule(for: oldID) {
                pendingRule = nil
                editorGeneration += 1
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("First enabled matching rule of each behavior wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { revertPendingRule() }
                    .accessibilityIdentifier("mapping-editor-revert")
                    .disabled(!hasPendingChanges)
                Button("Save") { savePendingRule() }
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityIdentifier("mapping-editor-save")
                    .disabled(!hasPendingChanges)
                Button("Done") { saveAndDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("mapping-editor-done")
            }
            .padding(10)
            .background(.bar)
        }
        .interactiveDismissDisabled(hasPendingChanges)
        .alert("Mapping could not be saved", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    private var hasPendingChanges: Bool {
        guard let pendingRule,
              let storedRule = model.mappings.rules.first(where: { $0.id == pendingRule.id }) else { return false }
        return pendingRule != storedRule
    }

    @discardableResult
    private func savePendingRule(for ruleID: UUID? = nil) -> Bool {
        guard let pendingRule,
              ruleID == nil || pendingRule.id == ruleID,
              model.mappings.rules.first(where: { $0.id == pendingRule.id }) != pendingRule else { return true }
        do {
            try model.automation.updateMapping(pendingRule)
            self.pendingRule = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func revertPendingRule() {
        pendingRule = nil
        editorGeneration += 1
    }

    private func saveAndDismiss() {
        if savePendingRule() { dismiss() }
    }
}

struct MappingEditorDraft: Equatable {
    var rule: MappingRule
    var responseBodyText: String
    var requestBodyText: String

    init(rule: MappingRule) {
        self.rule = rule
        responseBodyText = rule.responseBody.formattedText
        requestBodyText = rule.requestBody.formattedText
    }

    var preparedRule: MappingRule {
        var result = rule
        if result.responseBody.isText {
            result.responseBody.data = Data(responseBodyText.utf8)
        }
        if result.requestBody.isText {
            result.requestBody.data = Data(requestBodyText.utf8)
        }
        result.method = result.method.uppercased()
        if !result.path.hasPrefix("/") { result.path = "/" + result.path }
        return result
    }
}

private struct MappingEditorView: View {
    @State private var editor: MappingEditorDraft
    let onDraftChange: (MappingRule) -> Void

    init(rule: MappingRule, onDraftChange: @escaping (MappingRule) -> Void) {
        _editor = State(initialValue: MappingEditorDraft(rule: rule))
        self.onDraftChange = onDraftChange
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $editor.rule.name)
                Toggle("Enabled", isOn: $editor.rule.enabled)
                Picker("Behavior", selection: $editor.rule.behavior) {
                    ForEach(MappingBehavior.allCases) { behavior in
                        Label(behavior.title, systemImage: behavior.systemImage).tag(behavior)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Request") {
                    HStack {
                        TextField("Method", text: $editor.rule.method).frame(width: 80)
                        TextField("Scheme", text: $editor.rule.scheme).frame(width: 90)
                        TextField("Host", text: $editor.rule.host)
                        TextField("Port", value: $editor.rule.port, format: .number).frame(width: 70)
                    }
                }
                LabeledContent("Path") {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Path", text: $editor.rule.path)
                            .labelsHidden()
                        Text("Use * to match any characters, including / — for example, /v2/products/*")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Match query parameters", isOn: $editor.rule.matchQuery)
                if editor.rule.matchQuery {
                    TextField("Query", text: Binding($editor.rule.query, replacingNilWith: ""))
                }
                if editor.rule.behavior == .localResponse {
                    TextField("Response status", value: $editor.rule.statusCode, format: .number)
                } else {
                    Toggle("Replace request headers", isOn: $editor.rule.rewriteHeaders)
                    Toggle("Replace request body", isOn: $editor.rule.rewriteBody)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 300)
            Divider()
            HSplitView {
                if editor.rule.behavior == .localResponse {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Response headers").font(.headline)
                        HeaderEditor(headers: $editor.rule.responseHeaders, subject: "response")
                    }
                    .padding(10)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Response body").font(.headline)
                            Spacer()
                            Text(editor.rule.responseBody.mimeType ?? "Unknown type").foregroundStyle(.secondary)
                        }
                        CodeTextView(text: $editor.responseBodyText, isEditable: editor.rule.responseBody.isText)
                            .accessibilityLabel("Response body")
                    }
                    .padding(10)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Request headers").font(.headline)
                        HeaderEditor(headers: $editor.rule.requestHeaders, subject: "request")
                            .disabled(!editor.rule.rewriteHeaders)
                    }
                    .padding(10)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Request body").font(.headline)
                            Spacer()
                            Text(editor.rule.requestBody.mimeType ?? "Unknown type").foregroundStyle(.secondary)
                        }
                        CodeTextView(
                            text: $editor.requestBodyText,
                            isEditable: editor.rule.rewriteBody && editor.rule.requestBody.isText
                        )
                        .accessibilityLabel("Request body")
                    }
                    .padding(10)
                }
            }
        }
        .onChange(of: editor) { _, editor in
            onDraftChange(editor.preparedRule)
        }
    }
}

private struct HeaderEditor: View {
    @Binding var headers: [HeaderField]
    let subject: String

    var body: some View {
        List {
            ForEach($headers) { $header in
                HStack {
                    TextField("Name", text: $header.name)
                    TextField("Value", text: $header.value)
                    Button { headers.removeAll { $0.id == header.id } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove header")
                    .help("Remove \(subject) header")
                }
            }
        }
        HStack {
            Button("Add Header") { headers.append(HeaderField(name: "", value: "")) }
            Spacer()
        }
    }
}

private extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith replacement: String) {
        self.init(
            get: { source.wrappedValue ?? replacement },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
