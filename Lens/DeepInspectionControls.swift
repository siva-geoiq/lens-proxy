import SwiftUI

struct DeepInspectionMenu: View {
    @Environment(LensModel.self) private var model
    let device: DeviceTarget

    var body: some View {
        Menu {
            selectionButton(.automatic, title: "Automatic", systemImage: "sparkles")
            selectionButton(.off, title: "Off", systemImage: "pause.circle")
            let packages = Array(Set(model.inspector.processes(for: device).map(\.packageName))).sorted()
            if !packages.isEmpty {
                Divider()
                ForEach(packages, id: \.self) { package in
                    selectionButton(.package(package), title: package, systemImage: "shippingbox")
                }
            }
        } label: {
            Label("Deep Inspection", systemImage: "ladybug")
        }
    }

    private func selectionButton(_ selection: DeepInspectionSelection, title: String, systemImage: String) -> some View {
        Button {
            model.automation.setInspection(selection, for: device)
        } label: {
            Label(title, systemImage: model.inspector.selection(for: device) == selection ? "checkmark" : systemImage)
        }
    }
}

struct DeepInspectionStatusView: View {
    @Environment(LensModel.self) private var model
    let device: DeviceTarget
    var compact = false

    var body: some View {
        let state = model.inspector.state(for: device)
        Group {
            if compact {
                Image(systemName: icon(for: state))
                    .foregroundStyle(color(for: state))
                    .accessibilityLabel(state.label)
            } else {
                Label(state.label, systemImage: icon(for: state))
                    .foregroundStyle(color(for: state))
                    .font(.caption)
            }
        }
        .help(state.label)
    }

    private func icon(for state: InspectionState) -> String {
        switch state {
        case .active: "ladybug.fill"
        case .discovering, .attaching: "hourglass"
        case .unsupported, .conflict, .failed: "exclamationmark.triangle.fill"
        case .idle: "ladybug.slash"
        }
    }

    private func color(for state: InspectionState) -> Color {
        switch state {
        case .active: .purple
        case .discovering, .attaching: .orange
        case .unsupported, .conflict, .failed: .red
        case .idle: .secondary
        }
    }
}
