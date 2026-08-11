import SwiftUI

struct FlowFilterBar: View {
    @Environment(LensModel.self) private var model
    @FocusState private var isGlobalSearchFocused: Bool

    var body: some View {
        @Bindable var captures = model.captures
        VStack(spacing: 8) {
            if captures.isGlobalSearchPresented {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(
                        "Search URLs, metadata, headers, bodies, cURL, and WebSockets",
                        text: $captures.searchText
                    )
                    .textFieldStyle(.plain)
                    .focused($isGlobalSearchFocused)
                    .task(id: captures.globalSearchFocusRequest) {
                        await Task.yield()
                        guard !Task.isCancelled, captures.isGlobalSearchPresented else { return }
                        isGlobalSearchFocused = true
                    }
                    .onExitCommand { captures.dismissGlobalSearch() }
                    if captures.isGlobalSearchActive {
                        Text("\(captures.filteredFlows.count) matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    if !captures.searchText.isEmpty {
                        Button { captures.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear global search")
                        .help("Clear global search")
                    }
                    Button { captures.dismissGlobalSearch() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close global search")
                    .help("Close global search (Escape)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .contain)
            }
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
        }
        .padding(10)
    }
}

struct FlowTableView: View {
    @Environment(LensModel.self) private var model

    var body: some View {
        let filteredFlows = model.captures.filteredFlows
        if model.captures.isGlobalSearchActive, filteredFlows.isEmpty {
            ContentUnavailableView(
                "No Search Results",
                systemImage: "magnifyingglass",
                description: Text("No request or response content matches this query.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
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
}
