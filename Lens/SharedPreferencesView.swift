import SwiftUI

struct SharedPreferencesView: View {
    @Environment(LensModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let device: DeviceTarget

    @State private var apps: [String] = []
    @State private var selectedPackage: String?
    @State private var snapshot: AndroidPreferencePackageSnapshot?
    @State private var drafts: [String: [AndroidPreferenceEntry]] = [:]
    @State private var selectedFileName: String?
    @State private var selectedEntryKey: String?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var showsApplyConfirmation = false
    @State private var showsDiscardConfirmation = false
    @State private var pendingDiscardAction: PendingDiscardAction?
    @State private var pendingPackage: String?

    @State private var editorOriginalKey: String?
    @State private var editorKey = ""
    @State private var editorType = AndroidPreferenceType.string
    @State private var editorText = ""
    @State private var editorBoolean = false

    private enum PendingDiscardAction {
        case refresh
        case close
        case switchPackage
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading && snapshot == nil {
                ProgressView("Finding debuggable apps…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apps.isEmpty {
                ContentUnavailableView(
                    "No debuggable apps",
                    systemImage: "shippingbox.and.arrow.backward",
                    description: Text("Install a debug build that allows Android run-as, then refresh.")
                )
            } else if let snapshot {
                editor(snapshot)
            } else {
                ContentUnavailableView("Select a debug app", systemImage: "shippingbox")
            }
            Divider()
            footer
        }
        .frame(minWidth: 1_000, minHeight: 680)
        .task { await loadApps() }
        .interactiveDismissDisabled(isDirty)
        .alert("Shared Preferences", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("Dismiss", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Shared Preferences Updated", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("OK", role: .cancel) { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .confirmationDialog(
            "Apply staged Shared Preferences changes?",
            isPresented: $showsApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop App, Apply, and Relaunch") { Task { await applyChanges() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Lens will update \(changeCount) key change(s) across \(replacements.count) file(s).")
        }
        .confirmationDialog(
            "Discard staged changes?",
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { performDiscardAction() }
            Button("Keep Editing", role: .cancel) {
                pendingDiscardAction = nil
                pendingPackage = nil
            }
        } message: {
            Text("Your staged Shared Preferences edits have not been applied to Android.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Shared Preferences").font(.title2.bold())
                Text("\(device.displayName) · \(device.serial)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(apps, id: \.self) { package in
                    Button {
                        requestPackageChange(package)
                    } label: {
                        Label(package, systemImage: selectedPackage == package ? "checkmark" : "shippingbox")
                    }
                }
            } label: {
                Label(selectedPackage ?? "Select debug app", systemImage: "shippingbox")
                    .lineLimit(1)
                    .frame(width: 330, alignment: .leading)
            }
            .disabled(isLoading)
            Button {
                requestRefresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
        .padding()
    }

    private func editor(_ snapshot: AndroidPreferencePackageSnapshot) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Preference files")
                    .font(.headline)
                    .padding(12)
                Divider()
                if snapshot.files.isEmpty {
                    ContentUnavailableView(
                        "No preference files",
                        systemImage: "doc",
                        description: Text("This app has not created a shared_prefs XML file yet.")
                    )
                } else {
                    List(selection: $selectedFileName) {
                        ForEach(snapshot.files) { file in
                            HStack {
                                Image(systemName: file.parseError == nil ? "doc.text" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(file.parseError == nil ? Color.secondary : Color.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name).lineLimit(1)
                                    Text(file.parseError == nil ? "\(drafts[file.name]?.count ?? file.entries.count) keys" : "Read-only · malformed")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if fileIsDirty(file.name) {
                                    Circle().fill(.orange).frame(width: 7, height: 7)
                                }
                            }
                            .tag(file.name)
                        }
                    }
                }
            }
            .frame(minWidth: 250, idealWidth: 285, maxWidth: 340)

            preferenceDetail(snapshot)
                .frame(minWidth: 650, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selectedFileName) {
            selectedEntryKey = nil
            clearEntryEditor()
        }
    }

    @ViewBuilder
    private func preferenceDetail(_ snapshot: AndroidPreferencePackageSnapshot) -> some View {
        if let file = selectedFile(in: snapshot) {
            if let parseError = file.parseError {
                ContentUnavailableView(
                    "Cannot edit \(file.name)",
                    systemImage: "exclamationmark.triangle",
                    description: Text(parseError)
                )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        TextField("Filter keys", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            beginAddingEntry()
                        } label: {
                            Label("Add Key", systemImage: "plus")
                        }
                        Button(role: .destructive) {
                            deleteSelectedEntry()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selectedEntryKey == nil)
                    }
                    .padding(12)
                    Divider()
                    HSplitView {
                        List(selection: $selectedEntryKey) {
                            ForEach(filteredEntries) { entry in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.key).font(.system(.body, design: .monospaced))
                                        Text(entry.displayValue)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(entry.type.title)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(.quaternary, in: Capsule())
                                }
                                .tag(entry.key)
                            }
                        }
                        .onChange(of: selectedEntryKey) {
                            if let key = selectedEntryKey,
                               let entry = currentEntries.first(where: { $0.key == key }) {
                                loadEntryEditor(entry)
                            }
                        }

                        entryEditor
                            .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a preference file", systemImage: "doc.text")
        }
    }

    private var entryEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editorOriginalKey == nil ? "New key" : "Edit key")
                .font(.headline)
            TextField("Key", text: $editorKey)
                .textFieldStyle(.roundedBorder)
            Picker("Type", selection: $editorType) {
                ForEach(AndroidPreferenceType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            valueEditor
            if let editorError {
                Label(editorError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") {
                    selectedEntryKey = nil
                    clearEntryEditor()
                }
                Spacer()
                Button("Stage Entry") { stageEntry() }
                    .buttonStyle(.borderedProminent)
                    .disabled(editorError != nil)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch editorType {
        case .boolean:
            Toggle("Value", isOn: $editorBoolean)
        case .stringSet:
            VStack(alignment: .leading, spacing: 5) {
                Text("One value per line").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $editorText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150)
                    .border(.quaternary)
            }
        case .string:
            TextEditor(text: $editorText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .border(.quaternary)
        case .int, .long, .float:
            TextField("Value", text: $editorText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var footer: some View {
        HStack {
            if isLoading { ProgressView().controlSize(.small) }
            if isDirty {
                Label("\(changeCount) staged key change(s) in \(replacements.count) file(s)", systemImage: "pencil.circle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("No staged changes").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Discard") { discardDrafts() }
                .disabled(!isDirty || isLoading)
            Button("Close") { requestClose() }
                .keyboardShortcut(.cancelAction)
            Button("Review and Apply") { showsApplyConfirmation = true }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || isLoading)
        }
        .padding()
    }

    private var currentEntries: [AndroidPreferenceEntry] {
        guard let selectedFileName else { return [] }
        return drafts[selectedFileName] ?? snapshot?.files.first(where: { $0.name == selectedFileName })?.entries ?? []
    }

    private var filteredEntries: [AndroidPreferenceEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = query.isEmpty ? currentEntries : currentEntries.filter {
            $0.key.localizedCaseInsensitiveContains(query) || $0.displayValue.localizedCaseInsensitiveContains(query)
        }
        return values.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    private var replacements: [AndroidPreferenceFileReplacement] {
        guard let snapshot else { return [] }
        return snapshot.files.compactMap { file in
            guard let entries = drafts[file.name], entries != file.entries else { return nil }
            return AndroidPreferenceFileReplacement(fileName: file.name, entries: entries)
        }
    }

    private var isDirty: Bool { !replacements.isEmpty }

    private var changeCount: Int {
        guard let snapshot else { return 0 }
        return replacements.reduce(0) { total, replacement in
            let original = snapshot.files.first(where: { $0.name == replacement.fileName })?.entries ?? []
            let originalByKey = Dictionary(uniqueKeysWithValues: original.map { ($0.key, $0) })
            let replacementByKey = Dictionary(uniqueKeysWithValues: replacement.entries.map { ($0.key, $0) })
            let keys = Set(originalByKey.keys).union(replacementByKey.keys)
            return total + keys.filter { originalByKey[$0] != replacementByKey[$0] }.count
        }
    }

    private var editorError: String? {
        guard editorOriginalKey != nil || !editorKey.isEmpty else { return nil }
        do {
            let entry = try makeEditorEntry()
            if currentEntries.contains(where: { $0.key == entry.key && $0.key != editorOriginalKey }) {
                return "That key already exists in this file."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func selectedFile(in snapshot: AndroidPreferencePackageSnapshot) -> AndroidPreferenceFile? {
        guard let selectedFileName else { return nil }
        return snapshot.files.first(where: { $0.name == selectedFileName })
    }

    private func fileIsDirty(_ fileName: String) -> Bool {
        guard let draft = drafts[fileName],
              let original = snapshot?.files.first(where: { $0.name == fileName })?.entries else { return false }
        return draft != original
    }

    private func loadApps(select package: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        do {
            apps = try await model.sharedPreferences.discoverApps(deviceSerial: device.serial)
            guard let target = package.flatMap({ apps.contains($0) ? $0 : nil }) ?? apps.first else {
                selectedPackage = nil
                snapshot = nil
                drafts = [:]
                return
            }
            selectedPackage = target
            try await loadPackage(target)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPackage(_ package: String) async throws {
        let loaded = try await model.sharedPreferences.loadPackage(deviceSerial: device.serial, packageName: package)
        snapshot = loaded
        drafts = Dictionary(uniqueKeysWithValues: loaded.files.filter(\.isEditable).map { ($0.name, $0.entries) })
        selectedFileName = loaded.files.first?.name
        selectedEntryKey = nil
        clearEntryEditor()
    }

    private func requestPackageChange(_ package: String) {
        guard package != selectedPackage else { return }
        if isDirty {
            pendingPackage = package
            pendingDiscardAction = .switchPackage
            showsDiscardConfirmation = true
        } else {
            selectedPackage = package
            Task {
                isLoading = true
                defer { isLoading = false }
                do { try await loadPackage(package) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func requestRefresh() {
        if isDirty {
            pendingDiscardAction = .refresh
            showsDiscardConfirmation = true
        } else {
            Task { await loadApps(select: selectedPackage) }
        }
    }

    private func requestClose() {
        if isDirty {
            pendingDiscardAction = .close
            showsDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func performDiscardAction() {
        let action = pendingDiscardAction
        let package = pendingPackage
        pendingDiscardAction = nil
        pendingPackage = nil
        switch action {
        case .refresh:
            Task { await loadApps(select: selectedPackage) }
        case .close:
            discardDrafts()
            dismiss()
        case .switchPackage:
            guard let package else { return }
            discardDrafts()
            selectedPackage = package
            Task {
                isLoading = true
                defer { isLoading = false }
                do { try await loadPackage(package) }
                catch { errorMessage = error.localizedDescription }
            }
        case nil:
            break
        }
    }

    private func discardDrafts() {
        guard let snapshot else { return }
        drafts = Dictionary(uniqueKeysWithValues: snapshot.files.filter(\.isEditable).map { ($0.name, $0.entries) })
        selectedEntryKey = nil
        clearEntryEditor()
    }

    private func beginAddingEntry() {
        editorOriginalKey = nil
        editorKey = ""
        editorType = .string
        editorText = ""
        editorBoolean = false
        selectedEntryKey = nil
    }

    private func loadEntryEditor(_ entry: AndroidPreferenceEntry) {
        editorOriginalKey = entry.key
        editorKey = entry.key
        editorType = entry.type
        switch entry.value {
        case let .string(value): editorText = value
        case let .stringSet(values): editorText = values.joined(separator: "\n")
        case let .boolean(value): editorBoolean = value; editorText = ""
        case let .int(value): editorText = String(value)
        case let .long(value): editorText = value
        case let .float(value): editorText = String(Float(value))
        }
    }

    private func clearEntryEditor() {
        editorOriginalKey = nil
        editorKey = ""
        editorType = .string
        editorText = ""
        editorBoolean = false
    }

    private func makeEditorEntry() throws -> AndroidPreferenceEntry {
        try AndroidSharedPreferencesCodec.validateKey(editorKey)
        let value: AndroidPreferenceValue
        switch editorType {
        case .string:
            value = .string(editorText)
        case .stringSet:
            value = .stringSet(editorText.isEmpty ? [] : editorText.components(separatedBy: .newlines))
        case .boolean:
            value = .boolean(editorBoolean)
        case .int:
            guard let parsed = Int(editorText) else { throw AndroidSharedPreferencesError.invalidValue(editorKey) }
            value = .int(parsed)
        case .long:
            guard Int64(editorText) != nil else { throw AndroidSharedPreferencesError.invalidValue(editorKey) }
            value = .long(editorText)
        case .float:
            guard let parsed = Double(editorText), parsed.isFinite else { throw AndroidSharedPreferencesError.invalidValue(editorKey) }
            value = .float(parsed)
        }
        let entry = AndroidPreferenceEntry(key: editorKey, type: editorType, value: value)
        try AndroidSharedPreferencesCodec.validate(entry)
        return entry
    }

    private func stageEntry() {
        do {
            let entry = try makeEditorEntry()
            guard let selectedFileName else { return }
            var entries = currentEntries
            if let original = editorOriginalKey,
               let index = entries.firstIndex(where: { $0.key == original }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
            guard Set(entries.map(\.key)).count == entries.count else {
                throw AndroidSharedPreferencesError.duplicateKey(entry.key)
            }
            drafts[selectedFileName] = entries
            selectedEntryKey = entry.key
            loadEntryEditor(entry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedEntry() {
        guard let selectedFileName, let selectedEntryKey else { return }
        drafts[selectedFileName] = currentEntries.filter { $0.key != selectedEntryKey }
        self.selectedEntryKey = nil
        clearEntryEditor()
    }

    private func applyChanges() async {
        guard let snapshot, let package = selectedPackage else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await model.automation.applySharedPreferences(
                serial: device.serial,
                packageName: package,
                expectedRevision: snapshot.revision,
                replacements: replacements
            )
            resultMessage = result.message
            try await loadPackage(package)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
