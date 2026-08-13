import SwiftUI

struct GlobalSearchOverlay: View {
    private struct DisplayResult: Identifiable {
        let match: FlowSearchMatch
        let flow: FlowRecord

        var id: String { match.flowID }
    }

    @Environment(LensModel.self) private var model
    @State private var highlightedFlowID: String?
    @FocusState private var isSearchFieldFocused: Bool

    private var query: String {
        model.captures.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [DisplayResult] {
        guard !query.isEmpty else { return [] }
        return model.captures.searchMatches.compactMap { match in
            model.captures.flow(id: match.flowID).map { DisplayResult(match: match, flow: $0) }
        }
    }

    private var visibleResults: [DisplayResult] {
        Array(results.prefix(8))
    }

    var body: some View {
        @Bindable var captures = model.captures
        ZStack(alignment: .top) {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { captures.dismissGlobalSearch() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    TextField(
                        "Search requests, responses, headers, bodies, cURL, and metadata",
                        text: $captures.searchText
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($isSearchFieldFocused)
                    .task(id: captures.globalSearchFocusRequest) {
                        try? await Task.sleep(for: .milliseconds(180))
                        guard !Task.isCancelled, captures.isGlobalSearchPresented else { return }
                        isSearchFieldFocused = true
                    }
                    .onSubmit(openHighlightedResult)
                    .onMoveCommand(perform: moveHighlight)
                    .onExitCommand(perform: captures.dismissGlobalSearch)
                    .accessibilityIdentifier("lens-global-search-field")
                    .frame(height: 30)

                    if !captures.searchText.isEmpty {
                        Button {
                            captures.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear global search")
                        .help("Clear global search")
                    }

                    if captures.searchPhase == .searching {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Searching captured flows")
                    }

                    Text("esc")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 20)
                .frame(height: 64)

                Divider()

                searchContent
            }
            .frame(width: 720)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
            .padding(.top, 44)
        }
        .onAppear {
            highlightedFlowID = visibleResults.first?.id
        }
        .onChange(of: captures.searchText) {
            highlightedFlowID = nil
        }
        .onChange(of: captures.searchMatches) {
            highlightedFlowID = visibleResults.first?.id
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if query.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Search every captured flow")
                        .font(.headline)
                    Text("URLs, request and response content, headers, cURL, metadata, WebSockets, and Android call sites")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
        } else if model.captures.searchPhase == .searching, results.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Searching captured flows…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .accessibilityElement(children: .combine)
        } else if results.isEmpty {
            ContentUnavailableView(
                "No matching flows",
                systemImage: "magnifyingglass",
                description: Text("No captured request or response contains “\(query)”.")
            )
            .frame(height: 150)
        } else {
            VStack(spacing: 0) {
                ForEach(visibleResults) { result in
                    resultRow(result)
                    if result.id != visibleResults.last?.id {
                        Divider().padding(.leading, 82)
                    }
                }

                if results.count > visibleResults.count {
                    Divider()
                    Text("Showing \(visibleResults.count) of \(results.count) matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                } else if model.captures.searchPhase == .searching {
                    Divider()
                    Label("Updating results", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                }
            }
        }
    }

    private func resultRow(_ result: DisplayResult) -> some View {
        let flow = result.flow
        return Button {
            open(result)
        } label: {
            HStack(spacing: 12) {
                highlightedText(flow.method)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 50, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    highlightedText(flow.displayURL)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        highlightedText(flow.clientDisplayName)
                        Text("·")
                        highlightedText(flow.statusText)
                        if let mimeType = flow.responseBody?.mimeType ?? flow.requestBody?.mimeType {
                            Text("·")
                            highlightedText(mimeType)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    if let preview = result.match.preview {
                        HStack(spacing: 5) {
                            highlightedText(result.match.field.label)
                                .fontWeight(.semibold)
                            highlightedText(preview)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
                if highlightedFlowID == flow.id {
                    Image(systemName: "return")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                highlightedFlowID == flow.id ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(flow.method) \(flow.displayURL), status \(flow.statusText)")
        .accessibilityHint("Open this flow")
        .onHover { isHovering in
            if isHovering { highlightedFlowID = flow.id }
        }
    }

    private func moveHighlight(_ direction: MoveCommandDirection) {
        guard !visibleResults.isEmpty else { return }
        let currentIndex = highlightedFlowID.flatMap { id in
            visibleResults.firstIndex { $0.id == id }
        } ?? 0
        switch direction {
        case .down:
            highlightedFlowID = visibleResults[min(currentIndex + 1, visibleResults.count - 1)].id
        case .up:
            highlightedFlowID = visibleResults[max(currentIndex - 1, 0)].id
        default:
            break
        }
    }

    private func openHighlightedResult() {
        guard let result = visibleResults.first(where: { $0.id == highlightedFlowID }) ?? visibleResults.first else { return }
        open(result)
    }

    private func open(_ result: DisplayResult) {
        model.captures.selectedFlowID = result.flow.id
        model.captures.dismissGlobalSearch()
    }

    private func highlightedText(_ value: String) -> Text {
        guard !query.isEmpty else { return Text(value) }

        var output = Text("")
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let match = value.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchStart..<value.endIndex
              ) {
            output = Text("\(output)\(Text(String(value[searchStart..<match.lowerBound])))")
            let highlightedMatch = Text(String(value[match]))
                .bold()
                .foregroundColor(.accentColor)
            output = Text("\(output)\(highlightedMatch)")
            searchStart = match.upperBound
        }
        return Text("\(output)\(Text(String(value[searchStart...])))")
    }

}
