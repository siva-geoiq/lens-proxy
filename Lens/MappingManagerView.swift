import SwiftUI

struct MappingManagerView: View {
    @Environment(LensModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
                                set: { _ in mappings.toggle(rule.id) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.name).lineLimit(1)
                                Text(rule.matchSummary)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(rule.id)
                        .contextMenu {
                            Button("Duplicate") { mappings.duplicate(rule.id) }
                            Button("Delete", role: .destructive) { mappings.remove(rule.id) }
                        }
                    }
                    .onMove(perform: mappings.move)
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            .toolbar {
                ToolbarItemGroup {
                    Button { mappings.addBlank() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add mapping")
                        .help("Add local mapping")
                    Button {
                        if let id = mappings.selectedRuleID { mappings.remove(id) }
                    } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete mapping")
                    .help("Delete selected mapping")
                    .disabled(mappings.selectedRuleID == nil)
                }
            }
        } detail: {
            if let id = mappings.selectedRuleID,
               let rule = mappings.rules.first(where: { $0.id == id }) {
                MappingEditorView(rule: rule) { mappings.update($0) }
                    .id(rule.id)
            } else {
                ContentUnavailableView("Select a mapping", systemImage: "arrow.triangle.branch", description: Text("Create a mapping or choose one from the sidebar."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("First enabled matching rule wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            .background(.bar)
        }
    }
}

private struct MappingEditorView: View {
    @State private var draft: MappingRule
    @State private var bodyText: String
    let onSave: (MappingRule) -> Void

    init(rule: MappingRule, onSave: @escaping (MappingRule) -> Void) {
        _draft = State(initialValue: rule)
        _bodyText = State(initialValue: rule.responseBody.formattedText)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $draft.name)
                Toggle("Enabled", isOn: $draft.enabled)
                LabeledContent("Request") {
                    HStack {
                        TextField("Method", text: $draft.method).frame(width: 80)
                        TextField("Scheme", text: $draft.scheme).frame(width: 90)
                        TextField("Host", text: $draft.host)
                        TextField("Port", value: $draft.port, format: .number).frame(width: 70)
                    }
                }
                TextField("Path", text: $draft.path)
                Toggle("Match query parameters", isOn: $draft.matchQuery)
                if draft.matchQuery {
                    TextField("Query", text: Binding($draft.query, replacingNilWith: ""))
                }
                TextField("Response status", value: $draft.statusCode, format: .number)
            }
            .formStyle(.grouped)
            .frame(maxHeight: 300)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Response headers").font(.headline)
                    HeaderEditor(headers: $draft.responseHeaders)
                }
                .padding(10)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Response body").font(.headline)
                        Spacer()
                        Text(draft.responseBody.mimeType ?? "Unknown type").foregroundStyle(.secondary)
                    }
                    CodeTextView(text: $bodyText, isEditable: draft.responseBody.isText)
                }
                .padding(10)
            }
            Divider()
            HStack {
                Text(draft.matchSummary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Revert") { resetBody() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
    }

    private func resetBody() {
        bodyText = draft.responseBody.formattedText
    }

    private func save() {
        if draft.responseBody.isText {
            draft.responseBody.data = Data(bodyText.utf8)
        }
        draft.method = draft.method.uppercased()
        if !draft.path.hasPrefix("/") { draft.path = "/" + draft.path }
        onSave(draft)
    }
}

private struct HeaderEditor: View {
    @Binding var headers: [HeaderField]

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
                    .help("Remove response header")
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
