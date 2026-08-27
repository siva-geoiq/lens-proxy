import AppKit
import SwiftUI

struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var searchTerm: String = ""
    var activeMatchIndex: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.string = text
        textView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        return scrollView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text { textView.string = text }
        applyHighlights(in: textView, context: context)
    }

    private func applyHighlights(in textView: NSTextView, context: Context) {
        let matches = TextSearch.ranges(of: searchTerm, in: textView.string)
        let hadHighlights = context.coordinator.hasHighlights
        guard !matches.isEmpty || hadHighlights else { return }
        guard let storage = textView.textStorage else { return }

        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: fullRange)
        for (index, match) in matches.enumerated() {
            let isActive = index == activeMatchIndex
            let color = isActive
                ? NSColor.systemOrange.withAlphaComponent(0.65)
                : NSColor.systemYellow.withAlphaComponent(0.35)
            storage.addAttribute(.backgroundColor, value: color, range: match)
        }
        storage.endEditing()
        context.coordinator.hasHighlights = !matches.isEmpty

        if matches.indices.contains(activeMatchIndex) {
            textView.scrollRangeToVisible(matches[activeMatchIndex])
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        var hasHighlights = false

        init(text: Binding<String>) { _text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
