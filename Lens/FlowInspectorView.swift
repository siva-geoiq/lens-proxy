import AppKit
import SwiftUI

enum InspectorPane: Hashable {
    case request
    case response
}

struct FlowInspectorView: View {
    let flow: FlowRecord?
    @Binding var fullscreenPane: InspectorPane?
    @Binding var requestSelectedTab: String
    @Binding var responseSelectedTab: String

    var body: some View {
        if let flow {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(flow.method)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.15), in: Capsule())
                        .fixedSize()
                    Text(flow.statusText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .fixedSize()
                    Text(flow.displayURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    if let mappedRuleName = flow.mappedRuleName {
                        Label(mappedRuleName, systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                    if let rewrittenRuleName = flow.rewrittenRuleName {
                        Label(rewrittenRuleName, systemImage: "arrow.right.arrow.left")
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                Divider()
                switch fullscreenPane {
                case .request:
                    requestInspector(flow)
                case .response:
                    responseInspector(flow)
                case nil:
                    HSplitView {
                        requestInspector(flow)
                        responseInspector(flow)
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a request", systemImage: "network", description: Text("Request and response details will appear here."))
        }
    }

    private func requestInspector(_ flow: FlowRecord) -> some View {
        MessageInspector(
            flow: flow,
            title: "Request",
            headers: flow.requestHeaders,
            messageBody: flow.requestBody,
            raw: requestRaw(flow),
            query: queryText(flow),
            frames: [],
            mappingBehavior: .rewriteRequest,
            selectedTab: $requestSelectedTab,
            isFullscreen: fullscreenPane == .request,
            toggleFullscreen: { toggleFullscreen(.request) }
        )
        .id("\(flow.id)-request")
        .frame(minWidth: 240, maxWidth: .infinity)
    }

    private func responseInspector(_ flow: FlowRecord) -> some View {
        MessageInspector(
            flow: flow,
            title: "Response",
            headers: flow.responseHeaders,
            messageBody: flow.responseBody,
            raw: responseRaw(flow),
            query: "",
            frames: flow.websocketMessages,
            mappingBehavior: .localResponse,
            selectedTab: $responseSelectedTab,
            isFullscreen: fullscreenPane == .response,
            toggleFullscreen: { toggleFullscreen(.response) }
        )
        .id("\(flow.id)-response")
        .frame(minWidth: 240, maxWidth: .infinity)
    }

    private func toggleFullscreen(_ pane: InspectorPane) {
        fullscreenPane = fullscreenPane == pane ? nil : pane
    }

    private func requestRaw(_ flow: FlowRecord) -> String {
        let headers = flow.requestHeaders.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        return "\(flow.method) \(flow.path) HTTP\n\(headers)\n\n\(flow.requestBody?.text ?? "")"
    }

    private func responseRaw(_ flow: FlowRecord) -> String {
        let headers = flow.responseHeaders.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        return "HTTP \(flow.responseStatus ?? 0) \(flow.responseReason ?? "")\n\(headers)\n\n\(flow.responseBody?.text ?? "")"
    }

    private func queryText(_ flow: FlowRecord) -> String {
        URLComponents(string: flow.url)?.queryItems?.map { "\($0.name) = \($0.value ?? "")" }.joined(separator: "\n") ?? ""
    }
}

private struct MessageInspector: View {
    @Environment(LensModel.self) private var model

    let flow: FlowRecord
    let title: String
    let headers: [HeaderField]
    let messageBody: BodyPayload?
    let raw: String
    let query: String
    let frames: [WebSocketFrame]
    let mappingBehavior: MappingBehavior
    @Binding var selectedTab: String
    let isFullscreen: Bool
    let toggleFullscreen: () -> Void
    @State private var editedRuleID: UUID?
    @State private var isSearchVisible = false
    @State private var searchTerm = ""
    @State private var activeMatch = 0
    @State private var jsonMatchCount = 0
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer()
                if selectedTab == "JSON", let jsonPayload = copyableJSONPayload {
                    Button {
                        copyToPasteboard(jsonPayload)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy \(title) JSON payload")
                    .help("Copy \(title.lowercased()) JSON payload")
                }
                if isSearchable {
                    Button {
                        isSearchVisible.toggle()
                        if isSearchVisible {
                            searchFieldFocused = true
                        } else {
                            searchTerm = ""
                        }
                    } label: {
                        Image(systemName: "text.magnifyingglass")
                            .foregroundStyle(isSearchVisible ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Find in \(title.lowercased())")
                    .help("Find in \(title.lowercased())")
                }
                Button(action: toggleFullscreen) {
                    Image(systemName: isFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFullscreen ? "Restore \(title) inspector" : "Maximize \(title) inspector")
                .help(isFullscreen ? "Restore \(title) inspector" : "Maximize \(title) inspector")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            Picker("", selection: $selectedTab) {
                Text("Header").tag("Header")
                if !query.isEmpty { Text("Query").tag("Query") }
                Text("Body").tag("Body")
                if messageBody?.isJSON == true { Text("JSON").tag("JSON") }
                if messageBody?.isJSON == true { Text("Tree").tag("Tree") }
                Text("Raw").tag("Raw")
                if !frames.isEmpty { Text("WebSocket").tag("WebSocket") }
                if mappingBehavior == .rewriteRequest && flow.deviceID != nil { Text("Android").tag("Android") }
            }
            .pickerStyle(.segmented)
            .padding(8)
            if isSearchVisible && isSearchable {
                InspectorFindBar(
                    term: $searchTerm,
                    activeMatch: $activeMatch,
                    matchCount: matchCount,
                    onClose: {
                        isSearchVisible = false
                        searchTerm = ""
                        searchFieldFocused = false
                    },
                    isFocused: $searchFieldFocused
                )
                Divider()
            }
            Group {
                switch selectedTab {
                case "Header": headerContent
                case "Query": searchableText(query)
                case "Raw": searchableText(raw)
                case "WebSocket": WebSocketFramesView(frames: frames)
                case "JSON": jsonContent
                case "Tree": treeContent
                case "Android": AndroidContextView(flow: flow)
                default: bodyContent(formatted: false)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onChange(of: selectedTab) { activeMatch = 0 }
        .onChange(of: searchTerm) { activeMatch = 0 }
        .onChange(of: matchCount) {
            if activeMatch >= matchCount { activeMatch = 0 }
        }
    }

    /// Tabs whose content is plain or JSON text can be searched in place.
    private var isSearchable: Bool {
        !["WebSocket", "Tree", "Android"].contains(selectedTab)
    }

    private var searchedText: String {
        switch selectedTab {
        case "Header": headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        case "Query": query
        case "Raw": raw
        case "JSON": ""
        default: bodyText
        }
    }

    private var matchCount: Int {
        guard !searchTerm.isEmpty else { return 0 }
        if selectedTab == "JSON" { return jsonMatchCount }
        return TextSearch.ranges(of: searchTerm, in: searchedText).count
    }

    private var bodyText: String {
        messageBody?.text ?? messageBody?.hexPreview ?? ""
    }

    private func searchableText(_ value: String) -> some View {
        CodeTextView(
            text: .constant(value),
            isEditable: false,
            searchTerm: searchTerm,
            activeMatchIndex: activeMatch
        )
    }

    @ViewBuilder
    private var jsonContent: some View {
        if messageBody?.truncated == true {
            ContentUnavailableView(
                "JSON viewer unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This body was truncated or evicted.")
            )
        } else if let messageBody, messageBody.isJSON {
            JSONSyntaxViewer(
                data: treeBodyData,
                searchTerm: searchTerm,
                activeMatchIndex: activeMatch,
                onMatchCountChange: { jsonMatchCount = $0 }
            )
        } else {
            ContentUnavailableView(
                "JSON viewer unavailable",
                systemImage: "curlybraces",
                description: Text("The selected body is not valid JSON.")
            )
        }
    }

    @ViewBuilder
    private var treeContent: some View {
        if messageBody?.truncated == true {
            ContentUnavailableView(
                "JSON tree unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This body was truncated or evicted.")
            )
        } else if let messageBody, messageBody.isJSON {
            VStack(spacing: 0) {
                if let ruleID = activeRuleID {
                    HStack(spacing: 6) {
                        Label(
                            mappingBehavior == .rewriteRequest ? "Request rewrite active" : "Local response active",
                            systemImage: mappingBehavior.systemImage
                        )
                            .foregroundStyle(mappingBehavior == .rewriteRequest ? .blue : .orange)
                        Spacer()
                        Button(mappingBehavior == .rewriteRequest ? "Open Rewrite" : "Open Mock") {
                            model.mappings.selectedRuleID = ruleID
                            model.showingMappings = true
                        }
                        .buttonStyle(.borderless)
                        .help("Open this rule in Local Mappings")
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((mappingBehavior == .rewriteRequest ? Color.blue : Color.orange).opacity(0.08))
                }

                JSONTreeEditorView(
                    data: treeBodyData,
                    isEditable: true,
                    editingDescription: mappingBehavior == .rewriteRequest
                        ? "Edit any value to create or update a Request Rewrite. Future matches are modified before reaching the server."
                        : "Edit any value to create or update this response's Local Mapping."
                ) { json in
                    switch mappingBehavior {
                    case .rewriteRequest:
                        editedRuleID = model.updateRequestRewrite(for: flow, json: json)
                    case .localResponse:
                        editedRuleID = model.updateMockResponse(for: flow, json: json)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "JSON tree unavailable",
                systemImage: "curlybraces",
                description: Text("The selected body is not valid JSON.")
            )
        }
    }

    private var activeRuleID: UUID? {
        if let editedRuleID { return editedRuleID }
        let capturedRuleID = mappingBehavior == .rewriteRequest ? flow.rewrittenRuleID : flow.mappedRuleID
        return capturedRuleID ?? model.mappings.rules.first(where: {
            $0.sourceFlowID == flow.id && $0.behavior == mappingBehavior
        })?.id
    }

    private var treeBodyData: Data {
        guard let activeRuleID,
              let rule = model.mappings.rules.first(where: { $0.id == activeRuleID }) else {
            return messageBody?.data ?? Data()
        }
        return mappingBehavior == .rewriteRequest ? rule.requestBody.data : rule.responseBody.data
    }

    private var copyableJSONPayload: String? {
        guard messageBody?.truncated != true,
              let document = try? JSONValue.decodeJSON(from: treeBodyData),
              let data = try? document.encodedJSON() else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @ViewBuilder
    private var headerContent: some View {
        VStack(spacing: 0) {
            if mappingBehavior == .rewriteRequest {
                HStack(spacing: 6) {
                    Label(
                        activeRuleID == nil ? "Request headers are captured as sent." : "A Request Rewrite exists for this request.",
                        systemImage: activeRuleID == nil ? "info.circle" : MappingBehavior.rewriteRequest.systemImage
                    )
                    Spacer()
                    Button(activeRuleID == nil ? "Rewrite Headers…" : "Open Rewrite…") {
                        let ruleID = activeRuleID ?? model.createRequestHeaderRewrite(for: flow)
                        model.mappings.selectedRuleID = ruleID
                        model.showingMappings = true
                    }
                    .buttonStyle(.borderless)
                    .help("Edit the headers sent to the upstream server")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.35))
            }
            searchableText(headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func bodyContent(formatted: Bool) -> some View {
        VStack(spacing: 0) {
            if messageBody?.truncated == true {
                Label("Body was truncated or evicted; metadata is retained.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1))
            } else if let messageBody, !messageBody.isText {
                Text("Binary body · \(ByteCountFormatter.string(fromByteCount: Int64(messageBody.data.count), countStyle: .file)) · read-only hex preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            searchableText(formatted ? messageBody?.formattedText ?? "" : bodyText)
        }
    }
}

private struct WebSocketFramesView: View {
    let frames: [WebSocketFrame]

    var body: some View {
        List(frames) { frame in
            HStack(alignment: .top) {
                Image(systemName: frame.fromClient ? "arrow.up" : "arrow.down")
                    .foregroundStyle(frame.fromClient ? .blue : .green)
                Text(frame.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Text(Date(timeIntervalSince1970: frame.timestamp), style: .time).foregroundStyle(.secondary)
            }
        }
    }
}
