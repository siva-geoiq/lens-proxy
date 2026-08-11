import SwiftUI

struct SidebarView: View {
    @Environment(LensModel.self) private var model
    @State private var expandedDeviceIDs = Set<String>()
    @State private var hostSearchText = ""
    @State private var renamingDevice: DeviceTarget?

    var body: some View {
        @Bindable var captures = model.captures
        List(selection: $captures.selectedScope) {
            Section("Favorites") {
                Label("Pinned", systemImage: "pin.fill")
                Label("Saved", systemImage: "tray.and.arrow.down.fill")
            }
            Section("Traffic") {
                HStack {
                    Label("All traffic", systemImage: "network")
                    Spacer()
                    Text("\(captures.flows.count)").foregroundStyle(.secondary)
                }
                .tag(CaptureScope.allTraffic)
            }
            Section("Remote devices") {
                if model.devices.devices.isEmpty {
                    Button {
                        model.showingDevices = true
                    } label: {
                        Label("Attach a device", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(model.devices.devices) { device in
                        deviceSection(device, captures: captures)
                    }
                }
            }
            Section("Local machine") {
                HStack {
                    Label("All hosts", systemImage: "desktopcomputer")
                    Spacer()
                    Text("\(captures.flows(forDeviceID: nil).count)").foregroundStyle(.secondary)
                }
                .tag(CaptureScope.local)
                ForEach(filteredHosts(captures.hosts(forDeviceID: nil)), id: \.name) { host in
                    hostRow(host)
                        .tag(CaptureScope.host(deviceID: nil, name: host.name))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                TextField("Filter hosts", text: $hostSearchText)
                    .textFieldStyle(.plain)
            }
            .padding(9)
            .background(.bar)
        }
        .task {
            await model.refreshDevices()
            expandedDeviceIDs.formUnion(model.devices.devices.map(\.serial))
            if model.devices.devices.count == 1,
               let device = model.devices.devices.first,
               captures.flows.contains(where: { $0.deviceID == device.serial }) {
                captures.selectedScope = .device(device.serial)
            }
        }
        .sheet(item: $renamingDevice) { device in
            DeviceRenameView(device: device)
                .frame(width: 430)
        }
    }

    @ViewBuilder
    private func deviceSection(_ device: DeviceTarget, captures: CaptureStore) -> some View {
        let deviceFlows = captures.flows(forDeviceID: device.serial)
        let isExpanded = expandedDeviceIDs.contains(device.serial)

        Button {
            withAnimation(.snappy(duration: 0.18)) {
                if isExpanded { expandedDeviceIDs.remove(device.serial) }
                else { expandedDeviceIDs.insert(device.serial) }
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                    .accessibilityHidden(true)
                Image(systemName: device.kind == .emulator ? "apps.iphone" : "iphone")
                    .foregroundStyle(deviceFlows.isEmpty ? Color.secondary : Color.blue)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(device.displayName)
                    .lineLimit(1)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    if !deviceFlows.isEmpty {
                        Text("\(deviceFlows.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    DeviceConnectionIndicator(
                        device: device,
                        isSyncing: model.attachingDeviceID == device.serial
                    )
                    if device.isAttached {
                        DeepInspectionStatusView(device: device, compact: true)
                    }
                }
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(device.displayName), \(device.model), \(device.serial)")
        .accessibilityValue("\(deviceFlows.count) requests, \(isExpanded ? "expanded" : "collapsed")")
        .help(isExpanded ? "Collapse device hosts" : "Expand device hosts")
        .contextMenu {
            Button {
                renamingDevice = device
            } label: {
                Label("Rename Device…", systemImage: "pencil")
            }

            if device.customName != nil {
                Button {
                    model.devices.resetName(for: device)
                } label: {
                    Label("Reset Device Name", systemImage: "arrow.uturn.backward")
                }
            }

            Divider()

            Button {
                captures.selectedScope = .device(device.serial)
            } label: {
                Label("Show Device Traffic", systemImage: "network")
            }

            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    if isExpanded { expandedDeviceIDs.remove(device.serial) }
                    else { expandedDeviceIDs.insert(device.serial) }
                }
            } label: {
                Label(
                    isExpanded ? "Collapse Hosts" : "Expand Hosts",
                    systemImage: isExpanded ? "chevron.up" : "chevron.down"
                )
            }

            Divider()

            DeepInspectionMenu(device: device)
                .disabled(!device.isAttached)

            Divider()

            if device.isAttached {
                Button(role: .destructive) {
                    model.detach(device)
                } label: {
                    Label("Detach from Lens", systemImage: "iphone.slash")
                }
            } else {
                Button {
                    model.attach(device)
                } label: {
                    Label("Attach to Lens", systemImage: "iphone.and.arrow.forward")
                }
                .disabled(model.attachingDeviceID != nil)
            }

            Button {
                model.showingDevices = true
            } label: {
                Label("Manage Devices…", systemImage: "slider.horizontal.3")
            }

            Divider()

            Button {
                Task { await model.refreshDevices() }
            } label: {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
            }
        }

        if isExpanded {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
                Text("All hosts")
                Spacer()
                Text("\(deviceFlows.count)").foregroundStyle(.secondary)
            }
            .padding(.leading, 36)
            .tag(CaptureScope.device(device.serial))
            ForEach(filteredHosts(captures.hosts(forDeviceID: device.serial)), id: \.name) { host in
                hostRow(host)
                    .padding(.leading, 36)
                    .tag(CaptureScope.host(deviceID: device.serial, name: host.name))
            }
        }
    }

    private func hostRow(_ host: (name: String, count: Int)) -> some View {
        HStack {
            DomainHostIcon()
            Text(host.name).lineLimit(1)
            Spacer()
            Text("\(host.count)")
                .foregroundStyle(.secondary)
        }
    }

    private func filteredHosts(_ hosts: [(name: String, count: Int)]) -> [(name: String, count: Int)] {
        let query = hostSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return hosts }
        return hosts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

private struct DomainHostIcon: View {
    var body: some View {
        Image(systemName: "bolt.circle")
            .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }
}

struct DeviceConnectionIndicator: View {
    let device: DeviceTarget
    var isSyncing = false

    var body: some View {
        HStack(spacing: 4) {
            if isSyncing {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 9, height: 9)
            } else {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 7, height: 7)
            }
            Text(statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isSyncing || device.isAttached ? indicatorColor : .secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(device.displayName) connection status")
        .accessibilityValue(accessibilityStatus)
        .help(helpText)
    }

    private var indicatorColor: Color {
        if isSyncing { return .orange }
        return device.isAttached ? .green : .blue
    }

    private var statusText: String {
        if isSyncing { return "Syncing…" }
        return device.isAttached ? "Synced" : "Connected"
    }

    private var accessibilityStatus: String {
        if isSyncing {
            return "Connected through ADB and currently syncing with the Lens proxy"
        }
        return device.isAttached
            ? "Connected through ADB and synced with the Lens proxy"
            : "Connected through ADB, but not synced with the Lens proxy"
    }

    private var helpText: String {
        if isSyncing {
            return "Syncing: Lens is configuring this device's proxy and certificate"
        }
        return device.isAttached
            ? "Synced: traffic from this device is routed through Lens"
            : "Connected through ADB, but traffic is not routed through Lens. Open Devices and choose Attach."
    }
}
