import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(LensModel.self) private var model
    @State private var proxyPort = 8080
    @State private var mitmdumpPath = ""
    @State private var adbPath = ""

    var body: some View {
        Form {
            Section("Proxy Engine") {
                TextField("Proxy port", value: $proxyPort, format: .number)
                pathRow(title: "mitmdump", value: $mitmdumpPath, executableName: "mitmdump")
            }
            Section("Android") {
                pathRow(title: "ADB", value: $adbPath, executableName: "adb")
            }
            HStack {
                Spacer()
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(1...65_535).contains(proxyPort))
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onAppear {
            proxyPort = model.proxyPort
            mitmdumpPath = UserDefaults.standard.string(forKey: "mitmdumpPath") ?? ""
            adbPath = model.devices.adbPath ?? ""
        }
    }

    private func pathRow(title: String, value: Binding<String>, executableName: String) -> some View {
        LabeledContent(title) {
            HStack {
                TextField("Auto-detect", text: value)
                Button("Choose…") {
                    if let path = chooseExecutable(named: executableName) { value.wrappedValue = path }
                }
            }
        }
    }

    private func chooseExecutable(named name: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose \(name)"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func apply() {
        let selectedMitmdump = mitmdumpPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedADB = adbPath.trimmingCharacters(in: .whitespacesAndNewlines)
        model.devices.useADB(at: selectedADB.isEmpty ? nil : selectedADB)
        model.applyEngineSettings(
            proxyPort: proxyPort,
            mitmdumpPath: selectedMitmdump.isEmpty ? nil : selectedMitmdump
        )
    }
}
