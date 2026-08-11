import AppKit
import Foundation
import SwiftUI

struct JSONSyntaxToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case key
        case string
        case number
        case boolean
        case null
        case punctuation
        case folded
    }

    let text: String
    let kind: Kind
}

struct JSONSyntaxLine: Identifiable, Equatable, Sendable {
    let id: String
    let indentation: Int
    let tokens: [JSONSyntaxToken]
    let expandablePath: String?

    var plainText: String {
        tokens.map(\.text).joined()
    }
}

enum JSONSyntaxLineBuilder {
    static func lines(for document: JSONValue, collapsedPaths: Set<String>) -> [JSONSyntaxLine] {
        var result: [JSONSyntaxLine] = []
        append(
            document,
            key: nil,
            path: "$",
            indentation: 0,
            trailingComma: false,
            collapsedPaths: collapsedPaths,
            to: &result
        )
        return result
    }

    private static func append(
        _ value: JSONValue,
        key: String?,
        path: String,
        indentation: Int,
        trailingComma: Bool,
        collapsedPaths: Set<String>,
        to lines: inout [JSONSyntaxLine]
    ) {
        let prefix = key.map(keyTokens) ?? []
        let comma = trailingComma ? [JSONSyntaxToken(text: ",", kind: .punctuation)] : []

        switch value {
        case let .object(object):
            guard !object.isEmpty else {
                lines.append(
                    JSONSyntaxLine(
                        id: "\(path):value",
                        indentation: indentation,
                        tokens: prefix + [JSONSyntaxToken(text: "{}", kind: .punctuation)] + comma,
                        expandablePath: nil
                    )
                )
                return
            }

            if collapsedPaths.contains(path) {
                lines.append(
                    JSONSyntaxLine(
                        id: "\(path):folded",
                        indentation: indentation,
                        tokens: prefix + [
                            JSONSyntaxToken(text: "{ ", kind: .punctuation),
                            JSONSyntaxToken(text: "… \(object.count) fields", kind: .folded),
                            JSONSyntaxToken(text: " }", kind: .punctuation)
                        ] + comma,
                        expandablePath: path
                    )
                )
                return
            }

            lines.append(
                JSONSyntaxLine(
                    id: "\(path):open",
                    indentation: indentation,
                    tokens: prefix + [JSONSyntaxToken(text: "{", kind: .punctuation)],
                    expandablePath: path
                )
            )
            let keys = object.keys.sorted()
            for (index, childKey) in keys.enumerated() {
                guard let child = object[childKey] else { continue }
                append(
                    child,
                    key: childKey,
                    path: childPath(parent: path, component: childKey),
                    indentation: indentation + 1,
                    trailingComma: index < keys.count - 1,
                    collapsedPaths: collapsedPaths,
                    to: &lines
                )
            }
            lines.append(
                JSONSyntaxLine(
                    id: "\(path):close",
                    indentation: indentation,
                    tokens: [JSONSyntaxToken(text: "}", kind: .punctuation)] + comma,
                    expandablePath: nil
                )
            )

        case let .array(array):
            guard !array.isEmpty else {
                lines.append(
                    JSONSyntaxLine(
                        id: "\(path):value",
                        indentation: indentation,
                        tokens: prefix + [JSONSyntaxToken(text: "[]", kind: .punctuation)] + comma,
                        expandablePath: nil
                    )
                )
                return
            }

            if collapsedPaths.contains(path) {
                lines.append(
                    JSONSyntaxLine(
                        id: "\(path):folded",
                        indentation: indentation,
                        tokens: prefix + [
                            JSONSyntaxToken(text: "[ ", kind: .punctuation),
                            JSONSyntaxToken(text: "… \(array.count) items", kind: .folded),
                            JSONSyntaxToken(text: " ]", kind: .punctuation)
                        ] + comma,
                        expandablePath: path
                    )
                )
                return
            }

            lines.append(
                JSONSyntaxLine(
                    id: "\(path):open",
                    indentation: indentation,
                    tokens: prefix + [JSONSyntaxToken(text: "[", kind: .punctuation)],
                    expandablePath: path
                )
            )
            for index in array.indices {
                append(
                    array[index],
                    key: nil,
                    path: "\(path)/\(index)",
                    indentation: indentation + 1,
                    trailingComma: index < array.count - 1,
                    collapsedPaths: collapsedPaths,
                    to: &lines
                )
            }
            lines.append(
                JSONSyntaxLine(
                    id: "\(path):close",
                    indentation: indentation,
                    tokens: [JSONSyntaxToken(text: "]", kind: .punctuation)] + comma,
                    expandablePath: nil
                )
            )

        case let .string(string):
            appendScalar(prefix + [JSONSyntaxToken(text: quoted(string), kind: .string)] + comma, path: path, indentation: indentation, to: &lines)
        case let .number(number):
            appendScalar(prefix + [JSONSyntaxToken(text: formatted(number), kind: .number)] + comma, path: path, indentation: indentation, to: &lines)
        case let .bool(boolean):
            appendScalar(prefix + [JSONSyntaxToken(text: boolean ? "true" : "false", kind: .boolean)] + comma, path: path, indentation: indentation, to: &lines)
        case .null:
            appendScalar(prefix + [JSONSyntaxToken(text: "null", kind: .null)] + comma, path: path, indentation: indentation, to: &lines)
        }
    }

    private static func appendScalar(
        _ tokens: [JSONSyntaxToken],
        path: String,
        indentation: Int,
        to lines: inout [JSONSyntaxLine]
    ) {
        lines.append(
            JSONSyntaxLine(
                id: "\(path):value",
                indentation: indentation,
                tokens: tokens,
                expandablePath: nil
            )
        )
    }

    private static func keyTokens(_ key: String) -> [JSONSyntaxToken] {
        [
            JSONSyntaxToken(text: quoted(key), kind: .key),
            JSONSyntaxToken(text: ": ", kind: .punctuation)
        ]
    }

    private static func childPath(parent: String, component: String) -> String {
        let escaped = component
            .replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
        return "\(parent)/\(escaped)"
    }

    private static func quoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }

    private static func formatted(_ number: Double) -> String {
        number.rounded() == number ? String(format: "%.0f", number) : String(number)
    }
}

struct JSONSyntaxViewer: View {
    @State private var collapsedPaths: Set<String> = []

    private let document: JSONValue?
    private let parseError: String?

    init(data: Data) {
        do {
            document = try JSONValue.decodeJSON(from: data)
            parseError = nil
        } catch {
            document = nil
            parseError = error.localizedDescription
        }
    }

    var body: some View {
        if let document {
            GeometryReader { viewport in
                let renderedLines = lines(for: document)
                let contentWidth = max(viewport.size.width, minimumContentWidth(for: renderedLines))
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(renderedLines.enumerated()), id: \.element.id) { index, line in
                            syntaxLine(line, number: index + 1)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(width: contentWidth, alignment: .topLeading)
                    .frame(minHeight: viewport.size.height, alignment: .topLeading)
                }
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView(
                "JSON viewer unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(parseError ?? "The body is not valid JSON.")
            )
        }
    }

    private func lines(for document: JSONValue) -> [JSONSyntaxLine] {
        JSONSyntaxLineBuilder.lines(for: document, collapsedPaths: collapsedPaths)
    }

    private func minimumContentWidth(for lines: [JSONSyntaxLine]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let widestLine = lines.map { line in
            let textWidth = (line.plainText as NSString).size(withAttributes: [.font: font]).width
            return textWidth + CGFloat(line.indentation) * 18
        }.max() ?? 0
        // Line number, gutter spacing, disclosure icon, horizontal padding and trailing breathing room.
        return ceil(widestLine + 38 + 8 + 18 + 12 + 12)
    }

    private func syntaxLine(_ line: JSONSyntaxLine, number: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 8)

            Color.clear.frame(width: CGFloat(line.indentation) * 18)

            if let path = line.expandablePath {
                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        if collapsedPaths.contains(path) {
                            collapsedPaths.remove(path)
                        } else {
                            collapsedPaths.insert(path)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsedPaths.contains(path) ? 0 : 90))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsedPaths.contains(path) ? "Expand JSON at \(path)" : "Collapse JSON at \(path)")
                .help(collapsedPaths.contains(path) ? "Expand" : "Collapse")
            } else {
                Color.clear.frame(width: 18, height: 18)
            }

            coloredText(line.tokens)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func coloredText(_ tokens: [JSONSyntaxToken]) -> Text {
        var value = AttributedString()
        for token in tokens {
            var fragment = AttributedString(token.text)
            fragment.foregroundColor = color(for: token.kind)
            value.append(fragment)
        }
        return Text(value)
    }

    private func color(for kind: JSONSyntaxToken.Kind) -> Color {
        switch kind {
        case .key: .cyan
        case .string: .green
        case .number: .blue
        case .boolean: .orange
        case .null: .pink
        case .punctuation: .primary
        case .folded: .secondary
        }
    }
}
