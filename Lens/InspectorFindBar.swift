import AppKit
import SwiftUI

enum TextSearch {
    /// Case-insensitive, non-overlapping ranges of `term` inside `text`.
    static func ranges(of term: String, in text: String) -> [NSRange] {
        guard !term.isEmpty, !text.isEmpty else { return [] }
        let haystack = text as NSString
        var result: [NSRange] = []
        var searchStart = 0
        while searchStart < haystack.length {
            let remaining = NSRange(location: searchStart, length: haystack.length - searchStart)
            let match = haystack.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
            guard match.location != NSNotFound, match.length > 0 else { break }
            result.append(match)
            searchStart = match.location + match.length
        }
        return result
    }
}

struct InspectorFindBar: View {
    @Binding var term: String
    @Binding var activeMatch: Int
    let matchCount: Int
    let onClose: () -> Void
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Find in body", text: $term)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .onSubmit { step(by: 1) }
            if !term.isEmpty {
                Text(matchCount == 0 ? "No results" : "\(activeMatch + 1)/\(matchCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { step(by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
                .help("Previous match")
                .accessibilityLabel("Previous match")
            Button { step(by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)
                .help("Next match")
                .accessibilityLabel("Next match")
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Close find bar")
                .accessibilityLabel("Close find bar")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35))
        .onExitCommand(perform: onClose)
    }

    private func step(by delta: Int) {
        guard matchCount > 0 else { return }
        activeMatch = ((activeMatch + delta) % matchCount + matchCount) % matchCount
    }
}
