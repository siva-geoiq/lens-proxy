import SwiftUI

struct DeviceManagerView: View {
    @Environment(LensModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingVPNDevice: DeviceTarget?
    @State private var renamingDevice: DeviceTarget?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Android Devices").font(.title2.bold())
                    Text("Attach a device to route its HTTP(S) traffic through Lens.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh connected Android devices")
                .disabled(model.devices.isRefreshing)
            }
            .padding()
            Divider()
            Group {
                if model.devices.devices.isEmpty {
                    ContentUnavailableView(
                        "No ADB devices",
                        systemImage: "iphone.slash",
                        description: Text(model.devices.adbPath == nil ? "Bundled ADB is unavailable. Reinstall Lens." : "Start an emulator or authorize a connected device, then refresh.")
                    )
                } else {
                    List(model.devices.devices) { device in
                        HStack(spacing: 14) {
                            Image(systemName: device.kind == .emulator ? "apps.iphone" : "iphone")
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
                                if let proxy = device.previousProxy {
                                    Text("Previous proxy: \(proxy.displayValue)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if device.isAttached && device.rootState == .unavailable {
                                    Text("Install the certificate from mitm.it. Apps with certificate pinning remain unsupported.")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Menu {
                                Button("Rename Device…", systemImage: "pencil") {
                                    renamingDevice = device
                                }
                                if device.customName != nil {
                                    Button("Reset Device Name", systemImage: "arrow.uturn.backward") {
                                        model.devices.resetName(for: device)
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("Device actions for \(device.displayName)")
                            .help("Rename or reset this device name")
                            if device.isAttached {
                                Button("Detach") { model.detach(device) }
                            } else if model.attachingDeviceID == device.serial {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Syncing…")
                                }
                                .foregroundStyle(.secondary)
                            } else {
                                Button("Attach") {
                                    if model.devices.activeVPNPackage != nil { pendingVPNDevice = device }
                                    else { model.attach(device) }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.attachingDeviceID != nil)
                            }
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            Button("Rename Device…", systemImage: "pencil") {
                                renamingDevice = device
                            }
                            if device.customName != nil {
                                Button("Reset Device Name", systemImage: "arrow.uturn.backward") {
                                    model.devices.resetName(for: device)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if let vpn = model.devices.activeVPNPackage {
                    Label("Active VPN: \(vpn)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("Proxy port \(model.proxyPort)", systemImage: "network")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
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
                if let device = pendingVPNDevice { model.attach(device, stopConflictingVPN: true) }
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
    }

    private func deviceDetails(_ device: DeviceTarget) -> String {
        let hardware = device.customName == nil ? device.serial : "\(device.model) · \(device.serial)"
        return "\(hardware) · Android API \(device.apiLevel) · \(device.rootState.rawValue.capitalized)"
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
                Text("The alias is stored by hardware identity and does not change the Android device itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("Device name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)

            LabeledContent("Hardware model", value: device.model)
            LabeledContent("ADB serial", value: device.serial)

            HStack {
                if device.customName != nil {
                    Button("Reset to \(device.model)") {
                        model.devices.resetName(for: device)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.devices.rename(device, to: name)
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
