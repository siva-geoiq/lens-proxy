import SwiftUI

struct DeviceAttachmentBanner: View {
    @Environment(LensModel.self) private var model
    let device: DeviceTarget

    var body: some View {
        HStack(spacing: 10) {
            Label("Device detached", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("\(device.model) traffic is not routed through Lens.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                model.attach(device)
            } label: {
                if model.attachingDeviceID == device.serial {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Attaching…")
                    }
                } else {
                    Text("Attach")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.attachingDeviceID != nil || !engineIsRunning)
            .help("Route \(device.model) through Lens")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .accessibilityElement(children: .contain)
    }

    private var engineIsRunning: Bool {
        if case .running = model.engineState { return true }
        return false
    }
}
