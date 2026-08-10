import SwiftUI

struct FlowInspectorView: View {
    let flow: FlowRecord?

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
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    if let mappedRuleName = flow.mappedRuleName {
                        Label(mappedRuleName, systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                Divider()
                HSplitView {
                    MessageInspector(title: "Request", headers: flow.requestHeaders, messageBody: flow.requestBody, raw: requestRaw(flow), query: queryText(flow), frames: [])
                        .frame(minWidth: 240, maxWidth: .infinity)
                    MessageInspector(title: "Response", headers: flow.responseHeaders, messageBody: flow.responseBody, raw: responseRaw(flow), query: "", frames: flow.websocketMessages)
                        .frame(minWidth: 240, maxWidth: .infinity)
                }
            }
        } else {
            ContentUnavailableView("Select a request", systemImage: "network", description: Text("Request and response details will appear here."))
        }
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
    let title: String
    let headers: [HeaderField]
    let messageBody: BodyPayload?
    let raw: String
    let query: String
    let frames: [WebSocketFrame]
    @State private var selectedTab = "Body"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.horizontal, 10).padding(.top, 8)
            Picker("", selection: $selectedTab) {
                Text("Header").tag("Header")
                if !query.isEmpty { Text("Query").tag("Query") }
                Text("Body").tag("Body")
                if messageBody?.isJSON == true { Text("JSON").tag("JSON") }
                Text("Raw").tag("Raw")
                if !frames.isEmpty { Text("WebSocket").tag("WebSocket") }
            }
            .pickerStyle(.segmented)
            .padding(8)
            Group {
                switch selectedTab {
                case "Header": CodeTextView(text: .constant(headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")), isEditable: false)
                case "Query": CodeTextView(text: .constant(query), isEditable: false)
                case "Raw": CodeTextView(text: .constant(raw), isEditable: false)
                case "WebSocket": WebSocketFramesView(frames: frames)
                case "JSON": bodyContent(formatted: true)
                default: bodyContent(formatted: false)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
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
            CodeTextView(
                text: .constant(formatted ? messageBody?.formattedText ?? "" : messageBody?.text ?? messageBody?.hexPreview ?? ""),
                isEditable: false
            )
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
