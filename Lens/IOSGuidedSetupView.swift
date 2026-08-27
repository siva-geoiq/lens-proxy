import SwiftUI

/// Walks the user through proxying a physical iPhone or iPad.
///
/// Apple provides no way to set a device's Wi-Fi proxy or install a certificate from the
/// Mac, so Lens shows the exact values to enter and confirms once traffic arrives.
struct IOSGuidedSetupView: View {
    @Environment(LensModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let device: DeviceTarget

    @State private var hostAddress: String?
    @State private var addressError: String?

    private var currentDevice: DeviceTarget {
        model.devices.devices.first { $0.serial == device.serial } ?? device
    }

    private var proxyValue: String {
        guard let hostAddress else { return "…" }
        return "\(hostAddress):\(model.proxyPort)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up \(currentDevice.displayName)")
                    .font(.title2.bold())
                Text("iOS does not let a Mac change a device's Wi-Fi proxy, so these three steps happen on the device itself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let addressError {
                Label(addressError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    step(
                        number: 1,
                        title: "Join the same Wi-Fi network as this Mac",
                        detail: "The device reaches Lens over the local network, not over USB."
                    )
                    Divider()
                    step(
                        number: 2,
                        title: "Settings → Wi-Fi → (i) → Configure Proxy → Manual",
                        detail: "Enter the server and port below, then save."
                    ) {
                        HStack(spacing: 8) {
                            Text(proxyValue)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Button {
                                copyProxyValue()
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy the proxy address")
                            .disabled(hostAddress == nil)
                        }
                    }
                    Divider()
                    step(
                        number: 3,
                        title: "Open http://mitm.it in Safari and install the profile",
                        detail: "Then trust it in Settings → General → About → Certificate Trust Settings. Apps that pin certificates stay unreadable."
                    )
                }
                .padding(4)
            }

            HStack(spacing: 8) {
                if currentDevice.networkAddresses.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the first request from this device…")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Receiving traffic from \(currentDevice.networkAddresses.joined(separator: ", "))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            HStack {
                Text("Detaching only stops Lens from tracking the device. Remove the proxy on the device itself to restore direct networking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            do { hostAddress = try model.devices.hostAddressForGuidedSetup() }
            catch { addressError = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func step(
        number: Int,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
    }

    private func copyProxyValue() {
        guard let hostAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(hostAddress):\(model.proxyPort)", forType: .string)
    }
}
