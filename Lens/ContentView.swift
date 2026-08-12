import SwiftUI

struct ContentView: View {
    @Environment(LensModel.self) private var model
    @Environment(LensUpdateController.self) private var updates
    @State private var fullscreenInspector: InspectorPane?
    @State private var requestInspectorTab = "Body"
    @State private var responseInspectorTab = "Body"

    var body: some View {
        @Bindable var captures = model.captures
        ZStack(alignment: .top) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 380)
            } detail: {
                VStack(spacing: 0) {
                    if let availableUpdate = updates.availableUpdate {
                        LensUpdateBanner(update: availableUpdate)
                        Divider()
                    }
                    if fullscreenInspector == nil {
                        if let detachedDevice = model.detachedDevice {
                            DeviceAttachmentBanner(device: detachedDevice)
                            Divider()
                        }
                        FlowFilterBar()
                        Divider()
                        VSplitView {
                            FlowTableView()
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 220)
                            flowInspector(flow: captures.selectedFlow)
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 260)
                        }
                        .frame(minWidth: 0, maxWidth: .infinity)
                    } else {
                        flowInspector(flow: captures.selectedFlow)
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider()
                    StatusBarView()
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }

            if captures.isGlobalSearchPresented {
                GlobalSearchOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .zIndex(100)
            }
        }
        .frame(minWidth: 1_180, minHeight: 720)
        .animation(.easeOut(duration: 0.14), value: captures.isGlobalSearchPresented)
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
                Button("Retry") { model.automation.startEngine() }
            }
            Button("Dismiss", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .onChange(of: captures.selectedFlowID) {
            fullscreenInspector = nil
            requestInspectorTab = "Body"
            responseInspectorTab = "Body"
        }
    }

    private func flowInspector(flow: FlowRecord?) -> some View {
        FlowInspectorView(
            flow: flow,
            fullscreenPane: $fullscreenInspector,
            requestSelectedTab: $requestInspectorTab,
            responseSelectedTab: $responseInspectorTab
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.automation.setCapturePaused(!model.captures.isCapturePaused)
            } label: {
                Label(model.captures.isCapturePaused ? "Resume" : "Pause", systemImage: model.captures.isCapturePaused ? "play.fill" : "pause.fill")
            }
            .help(model.captures.isCapturePaused ? "Resume capture" : "Pause capture")
            .keyboardShortcut("b", modifiers: .command)
            Button(action: model.automation.clearCapture) {
                Label("Clear", systemImage: "trash")
            }
            .help("Clear captured requests")
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
        ToolbarItem(placement: .principal) {
            EngineStatusView()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.captures.presentGlobalSearch() } label: {
                Label("Search All Flows", systemImage: "magnifyingglass")
            }
            .help("Search all captured requests and responses (Command-F)")
            .accessibilityLabel("Search all captured requests and responses")
            Button {
                model.automation.setRemoveConditionalHeaders(!model.isNoCachingEnabled)
            } label: {
                Label(
                    "No Caching",
                    systemImage: model.isNoCachingEnabled ? "externaldrive.fill.badge.xmark" : "externaldrive.badge.xmark"
                )
            }
            .help(model.isNoCachingEnabled ? "Allow conditional cache requests" : "Remove conditional cache headers from requests")
            .accessibilityLabel(model.isNoCachingEnabled ? "Disable No Caching" : "Enable No Caching")
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

private struct LensUpdateBanner: View {
    @Environment(LensUpdateController.self) private var updates
    let update: LensAvailableUpdate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Lens \(update.version) is available")
                    .font(.headline)
                Text("Install the update and relaunch Lens when you’re ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button("Later") {
                updates.dismissAvailableUpdate()
            }
            .help("Dismiss this update reminder until Lens is relaunched")
            Button("Install Update") {
                updates.installAvailableUpdate()
            }
            .buttonStyle(.borderedProminent)
            .help("Download, verify, install, and relaunch Lens")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lens update \(update.version) is available")
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
        .environment(LensUpdateController())
}
