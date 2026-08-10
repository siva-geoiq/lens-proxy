import SwiftUI

struct ContentView: View {
    @Environment(LensModel.self) private var model

    var body: some View {
        @Bindable var captures = model.captures
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 380)
        } detail: {
            VStack(spacing: 0) {
                FlowFilterBar()
                Divider()
                VSplitView {
                    FlowTableView()
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 220)
                    FlowInspectorView(flow: captures.selectedFlow)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 260)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                Divider()
                StatusBarView()
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .frame(minWidth: 1_180, minHeight: 720)
        .toolbar { toolbarContent }
        .sheet(isPresented: Bindable(model).showingMappings) {
            MappingManagerView()
                .frame(minWidth: 980, minHeight: 650)
        }
        .sheet(isPresented: Bindable(model).showingDevices) {
            DeviceManagerView()
                .frame(minWidth: 680, minHeight: 480)
        }
        .alert(
            "Lens",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
            if case .failed = model.engineState {
                Button("Retry") { model.startEngine() }
            }
            Button("Dismiss", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: model.toggleCapture) {
                Label(model.captures.isCapturePaused ? "Resume" : "Pause", systemImage: model.captures.isCapturePaused ? "play.fill" : "pause.fill")
            }
            .help(model.captures.isCapturePaused ? "Resume capture" : "Pause capture")
            .keyboardShortcut("b", modifiers: .command)
            Button(action: model.clearFlows) {
                Label("Clear", systemImage: "trash")
            }
            .help("Clear captured requests")
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
        ToolbarItem(placement: .principal) {
            EngineStatusView()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.openSession) {
                Label("Open", systemImage: "folder")
            }
            .help("Open capture session")
            Button(action: model.saveSession) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save capture session")
            Button { model.showingMappings = true } label: {
                Label("Map Local", systemImage: "arrow.triangle.branch")
            }
            .help("Manage local mappings")
            Button { model.showingDevices = true } label: {
                Label("Devices", systemImage: "iphone.and.arrow.forward")
            }
            .help("Manage Android devices")
        }
    }
}

private struct EngineStatusView: View {
    @Environment(LensModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.7), radius: 3)
            Text(statusText)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }

    private var statusColor: Color {
        switch model.engineState {
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private var statusText: String {
        switch model.engineState {
        case let .running(port): "Lens · Listening on :\(port)"
        case .starting: "Starting mitmproxy…"
        case let .failed(message): "Engine error · \(message)"
        case .stopped: "Stopped"
        }
    }
}

#Preview {
    ContentView()
        .environment(LensModel())
}
