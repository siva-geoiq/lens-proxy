import SwiftUI

struct SettingsView: View {
    @Environment(LensModel.self) private var model
    @State private var proxyPort = 8080

    var body: some View {
        Form {
            Section("Proxy Engine") {
                TextField("Proxy port", value: $proxyPort, format: .number)
                LabeledContent("Runtime") {
                    Label("Bundled mitmproxy 12.x", systemImage: "shippingbox.fill")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Android") {
                LabeledContent("Runtime") {
                    Label("Bundled ADB 37.0.1", systemImage: "shippingbox.fill")
                        .foregroundStyle(.secondary)
                }
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
        }
    }

    private func apply() {
        model.applyEngineSettings(proxyPort: proxyPort)
    }
}
