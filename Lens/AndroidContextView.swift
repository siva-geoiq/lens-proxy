import AppKit
import SwiftUI

struct AndroidContextView: View {
    let flow: FlowRecord
    @State private var showsFrameworkFrames = false

    var body: some View {
        if let context = flow.androidContext {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusHeader(context)
                    if let callSite = context.primaryCallSite {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Application call site").font(.caption).foregroundStyle(.secondary)
                            Text(callSite.displayName)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                            Button {
                                copy(callSite.displayName)
                            } label: {
                                Label("Copy Call Site", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy the Android source call site")
                            .accessibilityLabel("Copy Android call site")
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let activity = context.foregroundActivity {
                        LabeledContent("Foreground at request") {
                            Text(activity).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                        metadataRow("Package", context.packageName)
                        metadataRow("Process", "\(context.processName) (PID \(context.pid))")
                        metadataRow("Thread", context.threadName)
                        metadataRow("Confidence", context.confidence.rawValue.capitalized)
                        if let delay = context.correlationDelayMilliseconds {
                            metadataRow("Correlation", String(format: "%.0f ms", delay))
                        }
                    }
                    let applicationFrames = context.stackFrames.filter { !$0.isFramework }
                    let frameworkFrames = context.stackFrames.filter(\.isFramework)
                    if !applicationFrames.isEmpty {
                        stackSection("Application frames", frames: applicationFrames)
                    }
                    if !frameworkFrames.isEmpty {
                        DisclosureGroup("Framework, Retrofit and OkHttp frames", isExpanded: $showsFrameworkFrames) {
                            stackRows(frameworkFrames)
                                .padding(.top, 6)
                        }
                    }
                    if !context.stackFrames.isEmpty {
                        Button {
                            copy(context.stackText)
                        } label: {
                            Label("Copy Complete Stack", systemImage: "doc.on.doc.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy the complete captured Android stack")
                        .accessibilityLabel("Copy complete Android stack")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "No Android call site",
                systemImage: "ladybug.slash",
                description: Text("Deep Inspection did not produce a unique OkHttp call-site match for this request.")
            )
        }
    }

    private func statusHeader(_ context: AndroidRequestContext) -> some View {
        HStack(spacing: 8) {
            Image(systemName: context.status == .captured ? "checkmark.circle.fill" : "questionmark.circle.fill")
                .foregroundStyle(context.status == .captured ? .green : .orange)
            Text(statusText(context.status)).font(.headline)
            Spacer()
            Text(context.confidence.rawValue.capitalized)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
    }

    private func statusText(_ status: AndroidContextStatus) -> String {
        switch status {
        case .captured: "Android context captured"
        case .activityOnly: "Foreground Activity observed"
        case .ambiguous: "Call-site match was ambiguous"
        case .unmatched: "No matching OkHttp event"
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func stackSection(_ title: String, frames: [AndroidStackFrame]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            stackRows(frames)
        }
    }

    private func stackRows(_ frames: [AndroidStackFrame]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                Text(frame.displayName)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
