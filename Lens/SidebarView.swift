import SwiftUI

struct SidebarView: View {
    @Environment(LensModel.self) private var model
    @State private var expandedDeviceIDs = Set<String>()
    @State private var hostSearchText = ""

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
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.model).lineLimit(1)
                    Text(device.serial)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !deviceFlows.isEmpty {
                    Text("\(deviceFlows.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(device.model), \(device.serial)")
        .accessibilityValue("\(deviceFlows.count) requests, \(isExpanded ? "expanded" : "collapsed")")
        .help(isExpanded ? "Collapse device hosts" : "Expand device hosts")

        if isExpanded {
            HStack {
                Label("All hosts", systemImage: "network")
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
            Image(systemName: "circle.hexagongrid")
                .foregroundStyle(.secondary)
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
