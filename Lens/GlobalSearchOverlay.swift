import SwiftUI

struct GlobalSearchOverlay: View {
    private struct MatchPreview {
        let label: String
        let value: String
    }

    @Environment(LensModel.self) private var model
    @State private var highlightedFlowID: String?
    @FocusState private var isSearchFieldFocused: Bool

    private var query: String {
        model.captures.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [FlowRecord] {
        query.isEmpty ? [] : model.captures.filteredFlows
    }

    private var visibleResults: [FlowRecord] {
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
        } else if results.isEmpty {
            ContentUnavailableView(
                "No matching flows",
                systemImage: "magnifyingglass",
                description: Text("No captured request or response contains “\(query)”.")
            )
            .frame(height: 150)
        } else {
            VStack(spacing: 0) {
                ForEach(visibleResults) { flow in
                    resultRow(flow)
                    if flow.id != visibleResults.last?.id {
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
                }
            }
        }
    }

    private func resultRow(_ flow: FlowRecord) -> some View {
        Button {
            open(flow)
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

                    if let preview = matchPreview(for: flow) {
                        HStack(spacing: 5) {
                            highlightedText(preview.label)
                                .fontWeight(.semibold)
                            highlightedText(contextualSnippet(preview.value))
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
        guard let flow = visibleResults.first(where: { $0.id == highlightedFlowID }) ?? visibleResults.first else { return }
        open(flow)
    }

    private func open(_ flow: FlowRecord) {
        model.captures.selectedFlowID = flow.id
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
            output = output + Text(String(value[searchStart..<match.lowerBound]))
            output = output + Text(String(value[match]))
                .bold()
                .foregroundColor(.accentColor)
            searchStart = match.upperBound
        }
        return output + Text(String(value[searchStart...]))
    }

    private func matchPreview(for flow: FlowRecord) -> MatchPreview? {
        let visibleValues = [
            flow.method,
            flow.displayURL,
            flow.clientDisplayName,
            flow.statusText,
            flow.responseBody?.mimeType ?? flow.requestBody?.mimeType ?? ""
        ]
        if visibleValues.contains(where: containsQuery) {
            return nil
        }

        var candidates: [MatchPreview] = [
            MatchPreview(label: "Flow ID", value: flow.id),
            MatchPreview(label: "Client address", value: flow.clientAddress),
            MatchPreview(label: "Scheme", value: flow.scheme),
            MatchPreview(label: "Host", value: flow.host),
            MatchPreview(label: "Port", value: String(flow.port)),
            MatchPreview(label: "Path", value: flow.path),
            MatchPreview(label: "Raw URL", value: flow.url),
            MatchPreview(label: "Size", value: String(flow.size)),
            MatchPreview(label: "Started", value: String(flow.startedAt)),
            MatchPreview(label: "Request line", value: "\(flow.method) \(flow.path) HTTP"),
            MatchPreview(label: "cURL", value: flow.curlCommand),
            MatchPreview(label: "cURL", value: "curl -X \(flow.method)")
        ]

        if let deviceID = flow.deviceID {
            candidates.append(MatchPreview(label: "Device ID", value: deviceID))
        }
        if let deviceName = flow.deviceName {
            candidates.append(MatchPreview(label: "Device", value: deviceName))
        }
        if let endedAt = flow.endedAt {
            candidates.append(MatchPreview(label: "Ended", value: String(endedAt)))
        }
        if let duration = flow.duration {
            candidates.append(MatchPreview(label: "Duration", value: String(duration)))
        }
        if let mappedRuleID = flow.mappedRuleID {
            candidates.append(MatchPreview(label: "Local Mapping ID", value: mappedRuleID.uuidString))
        }

        candidates.append(contentsOf: flow.requestHeaders.map {
            MatchPreview(label: "Request header", value: "\($0.name): \($0.value)")
        })
        candidates.append(contentsOf: flow.responseHeaders.map {
            MatchPreview(label: "Response header", value: "\($0.name): \($0.value)")
        })
        appendBody(
            flow.requestBody,
            label: "Request body",
            curlFlag: flow.requestBody?.isText == true ? "--data-raw" : "--data-binary",
            to: &candidates
        )
        appendBody(flow.responseBody, label: "Response body", curlFlag: nil, to: &candidates)

        if let responseReason = flow.responseReason {
            candidates.append(MatchPreview(label: "Response", value: responseReason))
        }
        if let mappedRuleName = flow.mappedRuleName {
            candidates.append(MatchPreview(label: "Local Mapping", value: mappedRuleName))
        }
        if let error = flow.error {
            candidates.append(MatchPreview(label: "Error", value: error))
        }
        candidates.append(contentsOf: flow.websocketMessages.map { frame in
            let direction = frame.fromClient ? "client request outgoing" : "server response incoming"
            return MatchPreview(
                label: "WebSocket",
                value: "\(direction) \(frame.timestamp) \(frame.content)"
            )
        })

        if let context = flow.androidContext {
            candidates.append(contentsOf: [
                MatchPreview(label: "Android package", value: context.packageName),
                MatchPreview(label: "Android process", value: context.processName),
                MatchPreview(label: "Android thread", value: context.threadName),
                MatchPreview(label: "Foreground Activity", value: context.foregroundActivity ?? ""),
                MatchPreview(label: "Android call site", value: context.primaryCallSite?.displayName ?? ""),
                MatchPreview(label: "Android stack", value: context.stackText),
                MatchPreview(label: "Android match", value: context.status.rawValue),
                MatchPreview(label: "Android confidence", value: context.confidence.rawValue)
            ])
        }

        return candidates.first(where: { containsQuery($0.value) })
    }

    private func appendBody(
        _ body: BodyPayload?,
        label: String,
        curlFlag: String?,
        to candidates: inout [MatchPreview]
    ) {
        guard let body else { return }
        if let mimeType = body.mimeType {
            candidates.append(MatchPreview(label: label, value: mimeType))
        }
        if body.truncated {
            candidates.append(MatchPreview(label: label, value: "truncated evicted"))
        }
        if let curlFlag {
            candidates.append(MatchPreview(label: "cURL", value: curlFlag))
        }
        candidates.append(MatchPreview(label: label, value: body.text ?? body.hexPreview))
    }

    private func containsQuery(_ value: String) -> Bool {
        value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func contextualSnippet(_ value: String) -> String {
        guard let match = value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else { return value }

        let lowerBound = value.index(match.lowerBound, offsetBy: -70, limitedBy: value.startIndex) ?? value.startIndex
        let upperBound = value.index(match.upperBound, offsetBy: 110, limitedBy: value.endIndex) ?? value.endIndex
        let leadingEllipsis = lowerBound == value.startIndex ? "" : "…"
        let trailingEllipsis = upperBound == value.endIndex ? "" : "…"
        let excerpt = value[lowerBound..<upperBound]
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return leadingEllipsis + excerpt + trailingEllipsis
    }
}
