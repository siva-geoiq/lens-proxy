import SwiftUI

struct DeviceManagerView: View {
    @Environment(LensModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingVPNDevice: DeviceTarget?
    @State private var renamingDevice: DeviceTarget?
    @State private var preferencesDevice: DeviceTarget?
    @State private var guidedDevice: DeviceTarget?

    private var androidDevices: [DeviceTarget] {
        model.devices.devices.filter { $0.platform == .android }
    }

    private var iosDevices: [DeviceTarget] {
        model.devices.devices.filter { $0.platform == .ios }
    }

    private var bootableSimulators: [SimulatorDevice] {
        model.devices.availableSimulators.filter { !$0.isBooted }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if model.devices.devices.isEmpty {
                    ContentUnavailableView(
                        "No devices",
                        systemImage: "iphone.slash",
                        description: Text(emptyStateMessage)
                    )
                } else {
                    List {
                        if !androidDevices.isEmpty {
                            Section("Android") {
                                ForEach(androidDevices) { deviceRow($0) }
                            }
                        }
                        if !iosDevices.isEmpty {
                            Section("iOS") {
                                ForEach(iosDevices) { deviceRow($0) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.refreshDevices() }
        .confirmationDialog(
            "Stop the active device VPN?",
            isPresented: Binding(
                get: { pendingVPNDevice != nil },
                set: { if !$0 { pendingVPNDevice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop VPN and Attach", role: .destructive) {
                if let device = pendingVPNDevice { model.automation.requestAttach(device, stopConflictingVPN: true) }
                pendingVPNDevice = nil
            }
            Button("Cancel", role: .cancel) { pendingVPNDevice = nil }
        } message: {
            Text("Lens detected \(model.devices.activeVPNPackage ?? "another VPN"). Stacking interception proxies can make captures unreliable.")
        }
        .sheet(item: $renamingDevice) { device in
            DeviceRenameView(device: device)
                .frame(width: 430)
        }
        .sheet(item: $preferencesDevice) { device in
            SharedPreferencesView(device: device)
        }
        .sheet(item: $guidedDevice) { device in
            IOSGuidedSetupView(device: device)
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Devices").font(.title2.bold())
                Text("Attach an Android device, iOS simulator, or iPhone to route its HTTP(S) traffic through Lens.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !bootableSimulators.isEmpty {
                Menu {
                    ForEach(bootableSimulators, id: \.udid) { simulator in
                        Button("\(simulator.name) · \(simulator.runtimeName)") {
                            model.bootSimulator(udid: simulator.udid)
                        }
                    }
                } label: {
                    Label("Boot Simulator", systemImage: "play.circle")
                }
                .help("Boot an iOS simulator so Lens can attach it")
                .fixedSize()
            }
            Button {
                Task { await model.refreshDevices() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh connected devices")
            .disabled(model.devices.isRefreshing)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            if let vpn = model.devices.activeVPNPackage {
                Label("Active VPN: \(vpn)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if model.devices.hostProxy.isApplied {
                Label(
                    "macOS system proxy routed to Lens on port \(model.proxyPort)",
                    systemImage: "checkmark.shield"
                )
                .foregroundStyle(.secondary)
            } else {
                Label("Proxy port \(model.proxyPort)", systemImage: "network")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var emptyStateMessage: String {
        var reasons: [String] = []
        reasons.append(
            model.devices.adbPath == nil
                ? "Bundled ADB is unavailable. Reinstall Lens."
                : "Start an Android emulator or authorize a connected device."
        )
        reasons.append(
            model.devices.xcodeDeveloperPath == nil
                ? "Install Xcode to discover iOS simulators and iPhones."
                : "Boot an iOS simulator or connect an iPhone."
        )
        return reasons.joined(separator: " ")
    }

    // MARK: - Rows

    @ViewBuilder
    private func deviceRow(_ device: DeviceTarget) -> some View {
        HStack(spacing: 14) {
            Image(systemName: device.symbolName)
                .font(.title2)
                .foregroundStyle(device.isAttached ? .green : .blue)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.displayName).font(.headline)
                Text(deviceDetails(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DeviceConnectionIndicator(
                    device: device,
                    isSyncing: model.attachingDeviceID == device.serial
                )
                if device.isAttached && device.supportsAndroidTooling {
                    DeepInspectionStatusView(device: device)
                }
                if let proxy = device.previousProxy, device.supportsAndroidTooling {
                    Text("Previous proxy: \(proxy.displayValue)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                advisory(for: device)
            }
            Spacer()
            actionMenu(for: device)
            actionButton(for: device)
        }
        .padding(.vertical, 6)
        .contextMenu {
            renameButtons(for: device)
        }
    }

    @ViewBuilder
    private func advisory(for device: DeviceTarget) -> some View {
        if device.platform == .android, device.isAttached, device.rootState == .unavailable {
            Text("Install the certificate from mitm.it. Apps with certificate pinning remain unsupported.")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if device.isSimulator, !device.isAttached {
            Text("Attaching turns on the macOS system proxy, which needs administrator approval and also routes this Mac's traffic through Lens.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if device.platform == .ios, device.attachmentMode == .guided, !device.isAttached {
            Text("Physical devices are configured by hand: Lens shows the proxy address and certificate steps.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func actionMenu(for device: DeviceTarget) -> some View {
        Menu {
            renameButtons(for: device)
            if device.supportsAndroidTooling {
                Divider()
                Button("Shared Preferences…", systemImage: "slider.horizontal.2.square") {
                    preferencesDevice = device
                }
                DeepInspectionMenu(device: device)
                    .disabled(!device.isAttached)
            }
            if device.platform == .ios, device.attachmentMode == .guided {
                Divider()
                Button("Setup Instructions…", systemImage: "list.number") {
                    guidedDevice = device
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Device actions for \(device.displayName)")
        .help("Rename this device or open its tools")
    }

    @ViewBuilder
    private func renameButtons(for device: DeviceTarget) -> some View {
        Button("Rename Device…", systemImage: "pencil") {
            renamingDevice = device
        }
        if device.customName != nil {
            Button("Reset Device Name", systemImage: "arrow.uturn.backward") {
                try? model.automation.renameDevice(serial: device.serial, name: nil)
            }
        }
    }

    @ViewBuilder
    private func actionButton(for device: DeviceTarget) -> some View {
        if device.isAttached {
            Button("Detach") { model.automation.requestDetach(device) }
        } else if model.attachingDeviceID == device.serial {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing…")
            }
            .foregroundStyle(.secondary)
        } else if device.platform == .ios, device.attachmentMode == .guided {
            Button("Set Up…") {
                model.automation.requestAttach(device)
                guidedDevice = device
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button("Attach") {
                if device.platform == .android, model.devices.activeVPNPackage != nil {
                    pendingVPNDevice = device
                } else {
                    model.automation.requestAttach(device)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.attachingDeviceID != nil)
        }
    }

    private func deviceDetails(_ device: DeviceTarget) -> String {
        let hardware = device.customName == nil ? device.serial : "\(device.model) · \(device.serial)"
        switch device.platform {
        case .android:
            return "\(hardware) · \(device.platformVersionText) · \(device.rootState.rawValue.capitalized)"
        case .ios:
            let role = device.kind == .emulator ? "Simulator" : "Device"
            return "\(hardware) · \(device.platformVersionText) · \(role)"
        }
    }
}

struct DeviceRenameView: View {
    @Environment(LensModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var name: String

    let device: DeviceTarget

    init(device: DeviceTarget) {
        self.device = device
        _name = State(initialValue: device.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename Device")
                    .font(.title2.bold())
                Text("The alias is stored by hardware identity and does not change the device itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("Device name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)

            LabeledContent("Hardware model", value: device.model)
            LabeledContent(device.platform == .ios ? "Identifier" : "ADB serial", value: device.serial)

            HStack {
                if device.customName != nil {
                    Button("Reset to \(device.model)") {
                        try? model.automation.renameDevice(serial: device.serial, name: nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    try? model.automation.renameDevice(serial: device.serial, name: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .task {
            await Task.yield()
            isNameFocused = true
        }
    }
}
