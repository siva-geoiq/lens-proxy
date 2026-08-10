import SwiftUI

struct DeviceManagerView: View {
    @Environment(LensModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingVPNDevice: DeviceTarget?

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
            if model.devices.devices.isEmpty {
                ContentUnavailableView(
                    "No ADB devices",
                    systemImage: "iphone.slash",
                    description: Text(model.devices.adbPath == nil ? "ADB was not found." : "Start an emulator or authorize a connected device, then refresh.")
                )
            } else {
                List(model.devices.devices) { device in
                    HStack(spacing: 14) {
                        Image(systemName: device.kind == .emulator ? "apps.iphone" : "iphone")
                            .font(.title2)
                            .foregroundStyle(device.isAttached ? .green : .blue)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.model).font(.headline)
                            Text("\(device.serial) · Android API \(device.apiLevel) · \(device.rootState.rawValue.capitalized)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                        if device.isAttached {
                            Button("Detach") { model.detach(device) }
                        } else {
                            Button("Attach") {
                                if model.devices.activeVPNPackage != nil { pendingVPNDevice = device }
                                else { model.attach(device) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
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
    }
}
