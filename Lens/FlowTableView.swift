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

    private enum ColumnWidth {
        static let indicator: CGFloat = 28
        static let client: CGFloat = 160
        static let method: CGFloat = 78
        static let status: CGFloat = 68
        static let time: CGFloat = 96
        static let duration: CGFloat = 88
        static let size: CGFloat = 84

        static var fixed: CGFloat {
            indicator + client + method + status + time + duration + size
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let urlWidth = max(260, proxy.size.width - ColumnWidth.fixed)
            let filteredFlows = model.captures.filteredFlows

            VStack(spacing: 0) {
                flowHeader(urlWidth: urlWidth)
                Divider()
                if model.captures.isGlobalSearchActive, filteredFlows.isEmpty {
                    ContentUnavailableView(
                        "No Search Results",
                        systemImage: "magnifyingglass",
                        description: Text("No request or response content matches this query.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredFlows.enumerated()), id: \.element.id) { index, flow in
                                flowRow(flow, index: index, urlWidth: urlWidth)
                            }
                        }
                    }
                }
            }
        }
    }

    private func flowHeader(urlWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            tableCell("", width: ColumnWidth.indicator)
            tableCell("URL", width: urlWidth)
            tableCell("Client", width: ColumnWidth.client)
            tableCell("Method", width: ColumnWidth.method)
            tableCell("Status", width: ColumnWidth.status)
            tableCell("Time", width: ColumnWidth.time)
            tableCell("Duration", width: ColumnWidth.duration)
            tableCell("Size", width: ColumnWidth.size)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(height: 34)
    }

    private func flowRow(_ flow: FlowRecord, index: Int, urlWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(flowIndicatorColor(flow))
                .frame(width: 8, height: 8)
                .frame(width: ColumnWidth.indicator)
            HStack(spacing: 6) {
                if flow.mappedRuleID != nil {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.orange)
                }
                if flow.rewrittenRuleID != nil {
                    Image(systemName: "arrow.right.arrow.left")
                        .foregroundStyle(.blue)
                }
                Text(flow.displayURL)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: urlWidth, alignment: .leading)
            Text(flow.clientDisplayName)
                .lineLimit(1)
                .frame(width: ColumnWidth.client, alignment: .leading)
            Text(flow.method)
                .frame(width: ColumnWidth.method, alignment: .leading)
            Text(flow.statusText)
                .foregroundStyle(statusColor(flow.responseStatus))
                .fontWeight(.semibold)
                .frame(width: ColumnWidth.status, alignment: .leading)
            Text(Date(timeIntervalSince1970: flow.startedAt), style: .time)
                .frame(width: ColumnWidth.time, alignment: .leading)
            Text(flow.duration.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—")
                .frame(width: ColumnWidth.duration, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: Int64(flow.size), countStyle: .file))
                .frame(width: ColumnWidth.size, alignment: .leading)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(rowBackground(flow: flow, index: index))
        .onTapGesture {
            model.captures.selectedFlowID = flow.id
        }
        .contextMenu {
            Button("Rewrite Request") {
                model.captures.selectedFlowID = flow.id
                model.rewriteSelectedRequest()
            }
            Button("Map Local Response") {
                model.captures.selectedFlowID = flow.id
                model.mapSelectedFlow()
            }
            Divider()
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(flow.url, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(flow.method) \(flow.displayURL), \(flow.statusText), client \(flow.clientDisplayName)")
    }

    private func tableCell(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    private func rowBackground(flow: FlowRecord, index: Int) -> Color {
        if model.captures.selectedFlowID == flow.id {
            return Color.accentColor.opacity(0.55)
        }
        return index.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.045)
    }

    private func statusColor(_ status: Int?) -> Color {
        guard let status else { return .secondary }
        if status >= 500 { return .red }
        if status >= 400 { return .orange }
        if status >= 300 { return .blue }
        return .green
    }

    private func flowIndicatorColor(_ flow: FlowRecord) -> Color {
        if flow.error != nil { return .red }
        if flow.mappedRuleID != nil { return .orange }
        if flow.rewrittenRuleID != nil { return .blue }
        return .green
    }
}
