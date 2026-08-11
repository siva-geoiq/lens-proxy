import AppKit
import SwiftUI

@MainActor
struct ResizableFlowTable: NSViewRepresentable {
    let flows: [FlowRecord]
    let selectedFlowID: String?
    let onSelect: (String?) -> Void
    let onRewrite: (FlowRecord) -> Void
    let onMapLocal: (FlowRecord) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tableView = ContextualFlowTableView()
        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 31
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.autosaveName = "LensFlowTableColumnsV2"
        tableView.autosaveTableColumns = true

        for specification in FlowTableColumn.allCases {
            let column = NSTableColumn(identifier: specification.identifier)
            column.title = specification.title
            column.width = specification.defaultWidth
            column.minWidth = specification.minimumWidth
            column.maxWidth = specification.maximumWidth
            column.resizingMask = [.userResizingMask]
            column.headerCell.alignment = specification.alignment
            tableView.addTableColumn(column)
        }

        tableView.contextualMenuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(for: row)
        }
        context.coordinator.tableView = tableView
        context.coordinator.flows = flows
        tableView.reloadData()
        context.coordinator.synchronizeSelection(selectedFlowID)
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(flows: flows, selectedFlowID: selectedFlowID)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ResizableFlowTable
        var flows: [FlowRecord] = []
        weak var tableView: NSTableView?

        private var rowSignatures: [FlowTableRowSignature] = []
        private var isSynchronizingSelection = false
        private var contextualFlow: FlowRecord?

        init(parent: ResizableFlowTable) {
            self.parent = parent
        }

        func update(flows: [FlowRecord], selectedFlowID: String?) {
            let newSignatures = flows.map(FlowTableRowSignature.init)
            if newSignatures != rowSignatures {
                self.flows = flows
                rowSignatures = newSignatures
                tableView?.reloadData()
            } else {
                self.flows = flows
            }
            synchronizeSelection(selectedFlowID)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            flows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard flows.indices.contains(row),
                  let tableColumn,
                  let column = FlowTableColumn(identifier: tableColumn.identifier) else { return nil }
            let flow = flows[row]

            switch column {
            case .url:
                let cell = reusableURLCell(in: tableView, identifier: column.identifier)
                cell.configure(flow: flow)
                return cell
            default:
                let cell = reusableTextCell(in: tableView, identifier: column.identifier)
                cell.configure(
                    text: text(for: column, flow: flow),
                    color: column == .status ? statusColor(for: flow.responseStatus) : .labelColor,
                    font: column == .status
                        ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                        : .systemFont(ofSize: NSFont.systemFontSize),
                    alignment: column.alignment
                )
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection, let tableView else { return }
            let row = tableView.selectedRow
            parent.onSelect(flows.indices.contains(row) ? flows[row].id : nil)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            flows.indices.contains(row)
        }

        func synchronizeSelection(_ selectedFlowID: String?) {
            guard let tableView else { return }
            let selectedRow = selectedFlowID.flatMap { id in flows.firstIndex(where: { $0.id == id }) }
            let desiredIndexes = selectedRow.map { IndexSet(integer: $0) } ?? IndexSet()
            guard tableView.selectedRowIndexes != desiredIndexes else { return }
            isSynchronizingSelection = true
            tableView.selectRowIndexes(desiredIndexes, byExtendingSelection: false)
            isSynchronizingSelection = false
        }

        func contextMenu(for row: Int) -> NSMenu? {
            guard flows.indices.contains(row) else { return nil }
            contextualFlow = flows[row]
            parent.onSelect(flows[row].id)

            let menu = NSMenu()
            menu.addItem(withTitle: "Rewrite Request", action: #selector(rewriteRequest), keyEquivalent: "")
            menu.addItem(withTitle: "Map Local Response", action: #selector(mapLocalResponse), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Copy URL", action: #selector(copyURL), keyEquivalent: "")
            for item in menu.items { item.target = self }
            return menu
        }

        @objc private func rewriteRequest() {
            guard let contextualFlow else { return }
            parent.onRewrite(contextualFlow)
        }

        @objc private func mapLocalResponse() {
            guard let contextualFlow else { return }
            parent.onMapLocal(contextualFlow)
        }

        @objc private func copyURL() {
            guard let contextualFlow else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(contextualFlow.url, forType: .string)
        }

        private func reusableTextCell(in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier) -> FlowTextCellView {
            if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FlowTextCellView {
                return cell
            }
            let cell = FlowTextCellView()
            cell.identifier = identifier
            return cell
        }

        private func reusableURLCell(in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier) -> FlowURLCellView {
            if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FlowURLCellView {
                return cell
            }
            let cell = FlowURLCellView()
            cell.identifier = identifier
            return cell
        }

        private func text(for column: FlowTableColumn, flow: FlowRecord) -> String {
            switch column {
            case .client: flow.clientDisplayName
            case .method: flow.method
            case .status: flow.statusText
            case .time:
                DateFormatter.flowTableTime.string(from: Date(timeIntervalSince1970: flow.startedAt))
            case .duration:
                flow.duration.map { String(format: "%.0f ms", $0 * 1_000) } ?? "—"
            case .size:
                ByteCountFormatter.string(fromByteCount: Int64(flow.size), countStyle: .file)
            case .url: ""
            }
        }

        private func statusColor(for status: Int?) -> NSColor {
            guard let status else { return .secondaryLabelColor }
            if status >= 500 { return .systemRed }
            if status >= 400 { return .systemOrange }
            if status >= 300 { return .systemBlue }
            return .systemGreen
        }
    }
}

enum FlowTableColumn: String, CaseIterable {
    case url
    case client
    case method
    case status
    case time
    case duration
    case size

    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }

    init?(identifier: NSUserInterfaceItemIdentifier) {
        self.init(rawValue: identifier.rawValue)
    }

    var title: String {
        switch self {
        case .url: "URL"
        case .client: "Client"
        case .method: "Method"
        case .status: "Status"
        case .time: "Time"
        case .duration: "Duration"
        case .size: "Size"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .url: 480
        case .client: 160
        case .method: 78
        case .status: 68
        case .time: 96
        case .duration: 88
        case .size: 84
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .url: 220
        case .client: 90
        case .method: 60
        case .status: 56
        case .time: 72
        case .duration: 72
        case .size: 64
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .url: 2_000
        default: 600
        }
    }

    var alignment: NSTextAlignment {
        .left
    }
}

private struct FlowTableRowSignature: Equatable {
    let id: String
    let url: String
    let client: String
    let method: String
    let status: String
    let startedAt: Double
    let duration: Double?
    let size: Int
    let mappedRuleID: UUID?
    let rewrittenRuleID: UUID?
    let error: String?

    init(_ flow: FlowRecord) {
        id = flow.id
        url = flow.displayURL
        client = flow.clientDisplayName
        method = flow.method
        status = flow.statusText
        startedAt = flow.startedAt
        duration = flow.duration
        size = flow.size
        mappedRuleID = flow.mappedRuleID
        rewrittenRuleID = flow.rewrittenRuleID
        error = flow.error
    }
}

private final class ContextualFlowTableView: NSTableView {
    var contextualMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return contextualMenuProvider?(row)
    }
}

private final class FlowTextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(text: String, color: NSColor, font: NSFont, alignment: NSTextAlignment) {
        label.stringValue = text
        label.textColor = color
        label.font = font
        label.alignment = alignment
        toolTip = text
    }
}

private final class FlowURLCellView: NSTableCellView {
    private let indicator = NSView()
    private let mappedIcon = NSImageView()
    private let rewrittenIcon = NSImageView()
    private let androidIcon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 4
        mappedIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Mapped response")
        mappedIcon.contentTintColor = .systemOrange
        rewrittenIcon.image = NSImage(systemSymbolName: "arrow.right.arrow.left", accessibilityDescription: "Rewritten request")
        rewrittenIcon.contentTintColor = .systemBlue
        androidIcon.image = NSImage(systemSymbolName: "ladybug.fill", accessibilityDescription: "Android call site captured")
        androidIcon.contentTintColor = .systemPurple
        label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        let stack = NSStackView(views: [indicator, mappedIcon, rewrittenIcon, androidIcon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = label
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 8),
            indicator.heightAnchor.constraint(equalToConstant: 8),
            mappedIcon.widthAnchor.constraint(equalToConstant: 14),
            rewrittenIcon.widthAnchor.constraint(equalToConstant: 14),
            androidIcon.widthAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(flow: FlowRecord) {
        let state: String
        if flow.error != nil {
            indicator.layer?.backgroundColor = NSColor.systemRed.cgColor
            state = "Failed"
        } else if flow.mappedRuleID != nil {
            indicator.layer?.backgroundColor = NSColor.systemOrange.cgColor
            state = "Mapped"
        } else if flow.rewrittenRuleID != nil {
            indicator.layer?.backgroundColor = NSColor.systemBlue.cgColor
            state = "Rewritten"
        } else {
            indicator.layer?.backgroundColor = NSColor.systemGreen.cgColor
            state = "Completed"
        }
        mappedIcon.isHidden = flow.mappedRuleID == nil
        rewrittenIcon.isHidden = flow.rewrittenRuleID == nil
        androidIcon.isHidden = flow.androidContext?.status != .captured
        label.stringValue = flow.displayURL
        let contextDescription = flow.androidContext?.primaryCallSite?.displayName
        toolTip = contextDescription.map { "\(flow.displayURL)\nAndroid: \($0)" } ?? flow.displayURL
        setAccessibilityLabel("\(state), \(flow.method) \(flow.displayURL)\(contextDescription.map { ", Android call site \($0)" } ?? "")")
    }
}

private extension DateFormatter {
    static let flowTableTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
