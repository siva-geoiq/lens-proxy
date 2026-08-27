import SwiftUI

struct SettingsView: View {
    @Environment(LensModel.self) private var model
    @State private var proxyPort = 8080
    private let exporter = AgentSkillExporter()

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
            Section("iOS") {
                LabeledContent("Xcode tools") {
                    if let developerPath = model.devices.xcodeDeveloperPath {
                        Label(developerPath, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else {
                        Label("Not found — install Xcode", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                LabeledContent("System proxy") {
                    Text(
                        model.devices.hostProxy.isApplied
                            ? "Routed to Lens for attached simulators"
                            : "Untouched"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Section("Agent API") {
                LabeledContent("Status") {
                    Label(apiStatus, systemImage: apiStatusIcon)
                        .foregroundStyle(apiStatusColor)
                }
                LabeledContent("Access") {
                    Text("Authenticated localhost only")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Clients") {
                    Text("\(model.apiServer.connectedClients)")
                        .monospacedDigit()
                }
                HStack {
                    Button("Rotate API Token") {
                        do { try model.apiServer.rotateToken() }
                        catch { model.lastError = error.localizedDescription }
                    }
                    .help("Invalidate current agent connections and create a new Keychain token")
                    Button("Export OpenAPI…") {
                        do { try exporter.exportOpenAPI() }
                        catch { model.lastError = error.localizedDescription }
                    }
                    .help("Export the Lens API schema")
                    Button("Export Agent Skill…") {
                        do { try exporter.exportSkill() }
                        catch { model.lastError = error.localizedDescription }
                    }
                    .help("Export the portable lens-operator skill for a coding agent")
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
        Task {
            do { try await model.automation.setProxyPort(proxyPort) }
            catch { model.lastError = error.localizedDescription }
        }
    }

    private var apiStatus: String {
        switch model.apiServer.state {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case let .running(port): "Listening on 127.0.0.1:\(port)"
        case let .failed(message): "Failed: \(message)"
        }
    }

    private var apiStatusIcon: String {
        switch model.apiServer.state {
        case .running: "checkmark.circle.fill"
        case .starting: "hourglass"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "circle"
        }
    }

    private var apiStatusColor: Color {
        switch model.apiServer.state {
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}
