import SwiftUI

struct JSONTreeEditorView: View {
    /// The edits the user has made but not saved, held by the caller so switching
    /// inspector tabs does not throw them away. `nil` means the tree shows exactly
    /// what Lens has stored.
    @Binding var draft: JSONValue?
    @State private var collapsedPaths: Set<String> = []

    let isEditable: Bool
    let editingDescription: String
    let saveTitle: String
    /// Called once per Save, never per keystroke, so one editing session produces
    /// one mapping update instead of one per character typed.
    let onSave: (JSONValue) -> Void
    private let savedDocument: JSONValue
    private let parseError: String?

    init(
        data: Data,
        draft: Binding<JSONValue?>,
        isEditable: Bool,
        editingDescription: String? = nil,
        saveTitle: String = "Save",
        onSave: @escaping (JSONValue) -> Void
    ) {
        _draft = draft
        self.isEditable = isEditable
        self.editingDescription = editingDescription ?? (isEditable
            ? "Edit any value, then Save to create or update this response's Local Mapping."
            : "JSON values are read-only.")
        self.saveTitle = saveTitle
        self.onSave = onSave
        do {
            savedDocument = try JSONValue.decodeJSON(from: data)
            parseError = nil
        } catch {
            savedDocument = .null
            parseError = error.localizedDescription
        }
    }

    private var hasUnsavedChanges: Bool {
        guard isEditable, let draft else { return false }
        return draft != savedDocument
    }

    /// Edits go to the draft; everything else reads the stored document.
    private var document: Binding<JSONValue> {
        Binding(
            get: { draft ?? savedDocument },
            set: { draft = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isEditable ? "wand.and.sparkles" : "lock.fill")
                Text(editingDescription)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.35))

            if let parseError {
                ContentUnavailableView(
                    "JSON tree unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(parseError)
                )
            } else {
                GeometryReader { viewport in
                    ScrollView([.horizontal, .vertical]) {
                        JSONTreeNodeView(
                            name: "JSON",
                            path: "$",
                            value: document,
                            isEditable: isEditable,
                            collapsedPaths: $collapsedPaths
                        )
                            .frame(
                                minWidth: max(0, viewport.size.width - 20),
                                minHeight: max(0, viewport.size.height - 20),
                                alignment: .topLeading
                            )
                            .padding(10)
                    }
                    .frame(
                        width: viewport.size.width,
                        height: viewport.size.height,
                        alignment: .topLeading
                    )
                }
                if isEditable { editorToolbar }
            }
        }
    }

    private var editorToolbar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if hasUnsavedChanges {
                    Label("Unsaved changes", systemImage: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("No unsaved changes")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { draft = nil }
                    .accessibilityIdentifier("json-tree-revert")
                    .disabled(!hasUnsavedChanges)
                Button(saveTitle) { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("json-tree-save")
                    .disabled(!hasUnsavedChanges)
                    .help("Apply these edits to the mapping (\u{2318}\u{21A9})")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }

    private func save() {
        guard hasUnsavedChanges, let edited = draft else { return }
        // Saving stores this document, so the draft is no longer a departure from it.
        draft = nil
        onSave(edited)
    }
}

private struct JSONTreeNodeView: View {
    let name: String
    let path: String
    @Binding var value: JSONValue
    let isEditable: Bool
    @Binding var collapsedPaths: Set<String>

    @ViewBuilder
    var body: some View {
        switch value {
        case let .object(object):
            VStack(alignment: .leading, spacing: 2) {
                disclosureButton(
                    icon: "curlybraces",
                    type: "object",
                    detail: "\(object.count) fields",
                    color: .purple
                )
                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(object.keys.sorted(), id: \.self) { key in
                            JSONTreeNodeView(
                                name: key,
                                path: childPath(for: key),
                                value: objectValueBinding(for: key),
                                isEditable: isEditable,
                                collapsedPaths: $collapsedPaths
                            )
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

        case let .array(array):
            VStack(alignment: .leading, spacing: 2) {
                disclosureButton(
                    icon: "square.stack.3d.up",
                    type: "array",
                    detail: "\(array.count) items",
                    color: .pink
                )
                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(array.indices, id: \.self) { index in
                            JSONTreeNodeView(
                                name: "[\(index)]",
                                path: "\(path)/\(index)",
                                value: arrayValueBinding(at: index),
                                isEditable: isEditable,
                                collapsedPaths: $collapsedPaths
                            )
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

        case .string:
            HStack(spacing: 8) {
                nodeLabel(icon: "textformat", type: "string", color: .green)
                TextField("String value", text: stringBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160, maxWidth: .infinity)
                    .disabled(!isEditable)
                    .accessibilityLabel("\(name), string value")
                    .help(isEditable ? "Edit the string value" : "Request values are read-only")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .number:
            HStack(spacing: 8) {
                nodeLabel(icon: "number", type: "number", color: .blue)
                TextField("Number value", value: numberBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .disabled(!isEditable)
                    .accessibilityLabel("\(name), number value")
                Stepper("Adjust \(name)", value: numberBinding, step: numberStep)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!isEditable)
                    .help(isEditable ? "Increment or decrement the number" : "Request values are read-only")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .bool:
            HStack(spacing: 8) {
                nodeLabel(icon: "switch.2", type: "boolean", color: .orange)
                Toggle("\(name) value", isOn: boolBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(!isEditable)
                    .help(isEditable ? "Toggle the Boolean value" : "Request values are read-only")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .null:
            HStack(spacing: 8) {
                nodeLabel(icon: "nosign", type: "null", color: .secondary)
                Text("null")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isExpanded: Bool {
        !collapsedPaths.contains(path)
    }

    private func disclosureButton(
        icon: String,
        type: String,
        detail: String,
        color: Color
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                if isExpanded {
                    collapsedPaths.insert(path)
                } else {
                    collapsedPaths.remove(path)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                nodeLabel(icon: icon, type: type, detail: detail, color: color)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(name)")
        .help("\(isExpanded ? "Collapse" : "Expand") \(name)")
    }

    private func childPath(for key: String) -> String {
        let escapedKey = key
            .replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
        return "\(path)/\(escapedKey)"
    }

    private func nodeLabel(
        icon: String,
        type: String,
        detail: String? = nil,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 14)
            Text(name)
                .font(.system(.body, design: .monospaced, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 90, idealWidth: 150, maxWidth: 220, alignment: .leading)
                .help(name)
            Text(type)
                .font(.caption2.monospaced())
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color.opacity(0.12), in: Capsule())
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var stringBinding: Binding<String> {
        let source = $value
        return Binding(
            get: {
                guard case let .string(value) = source.wrappedValue else { return "" }
                return value
            },
            set: { source.wrappedValue = .string($0) }
        )
    }

    private var numberBinding: Binding<Double> {
        let source = $value
        return Binding(
            get: {
                guard case let .number(value) = source.wrappedValue else { return 0 }
                return value
            },
            set: { source.wrappedValue = .number($0) }
        )
    }

    private var boolBinding: Binding<Bool> {
        let source = $value
        return Binding(
            get: {
                guard case let .bool(value) = source.wrappedValue else { return false }
                return value
            },
            set: { source.wrappedValue = .bool($0) }
        )
    }

    private var numberStep: Double {
        guard case let .number(number) = value else { return 1 }
        return number.rounded() == number ? 1 : 0.1
    }

    private func objectValueBinding(for key: String) -> Binding<JSONValue> {
        let source = $value
        return Binding(
            get: {
                guard case let .object(object) = source.wrappedValue else { return .null }
                return object[key] ?? .null
            },
            set: { newValue in
                guard case let .object(currentObject) = source.wrappedValue else { return }
                var object = currentObject
                object[key] = newValue
                source.wrappedValue = .object(object)
            }
        )
    }

    private func arrayValueBinding(at index: Int) -> Binding<JSONValue> {
        let source = $value
        return Binding(
            get: {
                guard case let .array(array) = source.wrappedValue,
                      array.indices.contains(index) else { return .null }
                return array[index]
            },
            set: { newValue in
                guard case let .array(currentArray) = source.wrappedValue,
                      currentArray.indices.contains(index) else { return }
                var array = currentArray
                array[index] = newValue
                source.wrappedValue = .array(array)
            }
        )
    }
}
