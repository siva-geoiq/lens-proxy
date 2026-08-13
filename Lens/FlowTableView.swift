import SwiftUI

struct FlowFilterBar: View {
    @Environment(LensModel.self) private var model

    var body: some View {
        @Bindable var captures = model.captures
        HStack(spacing: 16) {
            ForEach(FlowKind.allCases) { kind in
                Button(kind.rawValue) { captures.selectedKind = kind }
                    .buttonStyle(.plain)
                    .font(.caption.weight(captures.selectedKind == kind ? .semibold : .regular))
                    .foregroundStyle(captures.selectedKind == kind ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(captures.selectedKind == kind ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
        }
        .padding(10)
    }
}

struct FlowTableView: View {
    @Environment(LensModel.self) private var model

    var body: some View {
        let filteredFlows = model.captures.filteredFlows
        ResizableFlowTable(
            flows: filteredFlows,
            selectedFlowID: model.captures.selectedFlowID,
            onSelect: { model.captures.selectedFlowID = $0 },
            onRewrite: { flow in
                model.captures.selectedFlowID = flow.id
                model.rewriteSelectedRequest()
            },
            onMapLocal: { flow in
                model.captures.selectedFlowID = flow.id
                model.mapSelectedFlow()
            }
        )
        .accessibilityLabel("Captured network requests")
    }
}
