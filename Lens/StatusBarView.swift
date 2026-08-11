import SwiftUI

struct StatusBarView: View {
    @Environment(LensModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Text("\(model.captures.filteredFlows.count)/\(model.captures.flows.count) flows")
            Text(ByteCountFormatter.string(fromByteCount: Int64(model.captures.flows.reduce(0) { $0 + $1.size }), countStyle: .file))
            if model.captures.isGlobalSearchActive {
                Label("Global Search", systemImage: "magnifyingglass")
                    .foregroundStyle(.primary)
            }
            Spacer()
            statusChip("Map Local", active: !model.mappings.rules.isEmpty)
            statusChip("No Caching", active: model.isNoCachingEnabled)
            statusChip("Capture Paused", active: model.captures.isCapturePaused)
            statusChip(deviceStatusText, active: model.devices.devices.contains(where: \.isAttached))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    private func statusChip(_ text: String, active: Bool) -> some View {
        Text(text)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(active ? Color.primary : Color.secondary)
    }

    private var deviceStatusText: String {
        if model.attachingDeviceID != nil { return "Attaching Device" }
        if model.devices.devices.contains(where: \.isAttached) { return "Device Attached" }
        return "Device Detached"
    }
}
