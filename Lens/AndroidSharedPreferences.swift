import CryptoKit
import Foundation

enum AndroidPreferenceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case string
    case stringSet
    case boolean
    case int
    case long
    case float

    var id: String { rawValue }

    var title: String {
        switch self {
        case .string: "String"
        case .stringSet: "String Set"
        case .boolean: "Boolean"
        case .int: "Int"
        case .long: "Long"
        case .float: "Float"
        }
    }
}

enum AndroidPreferenceValue: Hashable, Sendable {
    case string(String)
    case stringSet([String])
    case boolean(Bool)
    case int(Int)
    case long(String)
    case float(Double)
}

struct AndroidPreferenceEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String { key }
    var key: String
    var type: AndroidPreferenceType
    var value: AndroidPreferenceValue

    private enum CodingKeys: String, CodingKey {
        case key
        case type
        case value
    }

    init(key: String, type: AndroidPreferenceType, value: AndroidPreferenceValue) {
        self.key = key
        self.type = type
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        type = try container.decode(AndroidPreferenceType.self, forKey: .type)
        switch type {
        case .string:
            value = .string(try container.decode(String.self, forKey: .value))
        case .stringSet:
            value = .stringSet(try container.decode([String].self, forKey: .value))
        case .boolean:
            value = .boolean(try container.decode(Bool.self, forKey: .value))
        case .int:
            value = .int(try container.decode(Int.self, forKey: .value))
        case .long:
            value = .long(try container.decode(String.self, forKey: .value))
        case .float:
            value = .float(try container.decode(Double.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(type, forKey: .type)
        switch value {
        case let .string(value): try container.encode(value, forKey: .value)
        case let .stringSet(value): try container.encode(value, forKey: .value)
        case let .boolean(value): try container.encode(value, forKey: .value)
        case let .int(value): try container.encode(value, forKey: .value)
        case let .long(value): try container.encode(value, forKey: .value)
        case let .float(value): try container.encode(value, forKey: .value)
        }
    }

    var displayValue: String {
        switch value {
        case let .string(value): value
        case let .stringSet(value): value.joined(separator: ", ")
        case let .boolean(value): value ? "true" : "false"
        case let .int(value): String(value)
        case let .long(value): value
        case let .float(value): String(Float(value))
        }
    }
}

struct AndroidPreferenceFile: Codable, Hashable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var entries: [AndroidPreferenceEntry]
    var parseError: String?

    var isEditable: Bool { parseError == nil }
}

struct AndroidPreferencePackageSnapshot: Codable, Hashable, Sendable {
    var packageName: String
    var revision: String
    var files: [AndroidPreferenceFile]
}

struct AndroidPreferenceFileReplacement: Codable, Hashable, Sendable {
    var fileName: String
    var entries: [AndroidPreferenceEntry]
}

struct AndroidPreferenceApplyRequest: Codable, Hashable, Sendable {
    var files: [AndroidPreferenceFileReplacement]
}

struct AndroidPreferenceApplyResult: Codable, Hashable, Sendable {
    var packageName: String
    var revision: String
    var changedFileCount: Int
    var relaunched: Bool
    var message: String
}

enum AndroidSharedPreferencesCodec {
    static func parse(_ data: Data) throws -> [AndroidPreferenceEntry] {
        let delegate = AndroidPreferencesXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw delegate.failure ?? parser.parserError ?? AndroidSharedPreferencesError.malformedXML("The XML could not be parsed.")
        }
        if let failure = delegate.failure { throw failure }
        guard delegate.didSeeMap else {
            throw AndroidSharedPreferencesError.malformedXML("The document root must be <map>.")
        }
        return delegate.entries.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    static func serialize(_ entries: [AndroidPreferenceEntry]) throws -> Data {
        var seen = Set<String>()
        let sorted = try entries.sorted { $0.key < $1.key }.map { entry -> AndroidPreferenceEntry in
            try validateKey(entry.key)
            guard seen.insert(entry.key).inserted else {
                throw AndroidSharedPreferencesError.duplicateKey(entry.key)
            }
            try validate(entry)
            return entry
        }
        var lines = [#"<?xml version='1.0' encoding='utf-8' standalone='yes' ?>"#, "<map>"]
        for entry in sorted {
            let name = escapeAttribute(entry.key)
            switch entry.value {
            case let .string(value):
                lines.append("    <string name=\"\(name)\">\(escapeText(value))</string>")
            case let .stringSet(values):
                lines.append("    <set name=\"\(name)\">")
                for value in values.sorted() {
                    lines.append("        <string>\(escapeText(value))</string>")
                }
                lines.append("    </set>")
            case let .boolean(value):
                lines.append("    <boolean name=\"\(name)\" value=\"\(value ? "true" : "false")\" />")
            case let .int(value):
                lines.append("    <int name=\"\(name)\" value=\"\(value)\" />")
            case let .long(value):
                lines.append("    <long name=\"\(name)\" value=\"\(value)\" />")
            case let .float(value):
                lines.append("    <float name=\"\(name)\" value=\"\(String(Float(value)))\" />")
            }
        }
        lines.append("</map>")
        lines.append("")
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func validate(_ entry: AndroidPreferenceEntry) throws {
        let matches: Bool = switch (entry.type, entry.value) {
        case (.string, .string), (.stringSet, .stringSet), (.boolean, .boolean),
             (.int, .int), (.long, .long), (.float, .float): true
        default: false
        }
        guard matches else { throw AndroidSharedPreferencesError.typeMismatch(entry.key) }
        switch entry.value {
        case let .int(value):
            guard Int32(exactly: value) != nil else { throw AndroidSharedPreferencesError.invalidValue(entry.key) }
        case let .long(value):
            guard Int64(value) != nil else { throw AndroidSharedPreferencesError.invalidValue(entry.key) }
        case let .float(value):
            guard value.isFinite, Float(value).isFinite else { throw AndroidSharedPreferencesError.invalidValue(entry.key) }
        default:
            break
        }
    }

    static func validateKey(_ key: String) throws {
        guard !key.isEmpty,
              key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw AndroidSharedPreferencesError.invalidKey(key)
        }
    }

    private static func escapeText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class AndroidPreferencesXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [AndroidPreferenceEntry] = []
    var failure: Error?
    var didSeeMap = false

    private var keys = Set<String>()
    private var scalarKey: String?
    private var scalarText = ""
    private var setKey: String?
    private var setValues: [String] = []
    private var readingSetString = false
    private var depth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        depth += 1
        if depth == 1 {
            guard elementName == "map" else { return fail(parser, "The document root must be <map>.") }
            didSeeMap = true
            return
        }
        if let setKey {
            guard depth == 3, elementName == "string", attributeDict.isEmpty else {
                return fail(parser, "Only <string> values are supported inside set \(setKey).")
            }
            readingSetString = true
            scalarText = ""
            return
        }
        guard depth == 2, let key = attributeDict["name"] else {
            return fail(parser, "Preference elements must be direct children of <map> and include a name.")
        }
        do { try AndroidSharedPreferencesCodec.validateKey(key) }
        catch { return fail(parser, error.localizedDescription) }
        guard keys.insert(key).inserted else { return fail(parser, "Duplicate preference key: \(key)") }

        switch elementName {
        case "string":
            scalarKey = key
            scalarText = ""
        case "set":
            self.setKey = key
            setValues = []
        case "boolean":
            guard let raw = attributeDict["value"], let value = Bool(raw) else { return fail(parser, "Invalid boolean for \(key).") }
            entries.append(AndroidPreferenceEntry(key: key, type: .boolean, value: .boolean(value)))
        case "int":
            guard let raw = attributeDict["value"], let value = Int32(raw) else { return fail(parser, "Invalid int for \(key).") }
            entries.append(AndroidPreferenceEntry(key: key, type: .int, value: .int(Int(value))))
        case "long":
            guard let raw = attributeDict["value"], Int64(raw) != nil else { return fail(parser, "Invalid long for \(key).") }
            entries.append(AndroidPreferenceEntry(key: key, type: .long, value: .long(raw)))
        case "float":
            guard let raw = attributeDict["value"], let value = Float(raw), value.isFinite else { return fail(parser, "Invalid float for \(key).") }
            entries.append(AndroidPreferenceEntry(key: key, type: .float, value: .float(Double(value))))
        default:
            fail(parser, "Unsupported preference element <\(elementName)>.")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if scalarKey != nil || readingSetString { scalarText += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8), scalarKey != nil || readingSetString {
            scalarText += value
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard failure == nil else { return }
        if depth == 3, readingSetString, elementName == "string" {
            setValues.append(scalarText)
            scalarText = ""
            readingSetString = false
        } else if depth == 2, elementName == "string", let key = scalarKey {
            entries.append(AndroidPreferenceEntry(key: key, type: .string, value: .string(scalarText)))
            scalarKey = nil
            scalarText = ""
        } else if depth == 2, elementName == "set", let key = setKey {
            entries.append(AndroidPreferenceEntry(key: key, type: .stringSet, value: .stringSet(setValues)))
            self.setKey = nil
            setValues = []
        }
        depth -= 1
    }

    private func fail(_ parser: XMLParser, _ message: String) {
        failure = AndroidSharedPreferencesError.malformedXML(message)
        parser.abortParsing()
    }
}

@MainActor
final class AndroidSharedPreferencesService {
    private let runner: any AndroidCommandRunning
    private let runtimePaths: LensRuntimePaths

    init(
        runner: any AndroidCommandRunning = CommandRunner(),
        runtimePaths: LensRuntimePaths = .live()
    ) {
        self.runner = runner
        self.runtimePaths = runtimePaths
    }

    func discoverApps(deviceSerial: String) async throws -> [String] {
        let script = #"for package in $(cmd package list packages -3 | cut -d: -f2); do if run-as "$package" true >/dev/null 2>&1; then echo "$package"; fi; done"#
        let result = try await adb(deviceSerial, ["shell", script], timeout: 30)
        return result.output.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter(Self.isValidPackage)
            .sorted()
    }

    func loadPackage(deviceSerial: String, packageName: String) async throws -> AndroidPreferencePackageSnapshot {
        try await requirePackageAccess(deviceSerial: deviceSerial, packageName: packageName)
        let script = #"if [ -d shared_prefs ]; then for file in shared_prefs/*.xml; do [ -f "$file" ] && printf '%s\0' "${file#shared_prefs/}"; done; fi"#
        let result = try await adb(
            deviceSerial,
            ["shell", Self.runAsShellCommand(packageName: packageName, script: script)],
            timeout: 8
        )
        let names = result.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            .filter(Self.isValidFileName)
            .sorted()
        var contents: [(String, Data)] = []
        var files: [AndroidPreferenceFile] = []
        for name in names {
            let data = try await readFile(deviceSerial: deviceSerial, packageName: packageName, fileName: name)
            contents.append((name, data))
            do {
                files.append(AndroidPreferenceFile(name: name, entries: try AndroidSharedPreferencesCodec.parse(data), parseError: nil))
            } catch {
                files.append(AndroidPreferenceFile(name: name, entries: [], parseError: error.localizedDescription))
            }
        }
        return AndroidPreferencePackageSnapshot(
            packageName: packageName,
            revision: Self.revision(contents),
            files: files
        )
    }

    func loadFile(
        deviceSerial: String,
        packageName: String,
        fileName: String
    ) async throws -> (AndroidPreferenceFile, String) {
        try Self.requireValidFileName(fileName)
        let snapshot = try await loadPackage(deviceSerial: deviceSerial, packageName: packageName)
        guard let file = snapshot.files.first(where: { $0.name == fileName }) else {
            throw AndroidSharedPreferencesError.fileNotFound(fileName)
        }
        return (file, snapshot.revision)
    }

    func apply(
        deviceSerial: String,
        packageName: String,
        expectedRevision: String,
        replacements: [AndroidPreferenceFileReplacement]
    ) async throws -> AndroidPreferenceApplyResult {
        guard !replacements.isEmpty else { throw AndroidSharedPreferencesError.noChanges }
        guard Self.isValidPackage(packageName) else { throw AndroidSharedPreferencesError.invalidPackage(packageName) }
        try await requirePackageAccess(deviceSerial: deviceSerial, packageName: packageName)
        var seen = Set<String>()
        var serialized: [(name: String, data: Data)] = []
        for replacement in replacements {
            try Self.requireValidFileName(replacement.fileName)
            guard seen.insert(replacement.fileName).inserted else {
                throw AndroidSharedPreferencesError.duplicateFile(replacement.fileName)
            }
            serialized.append((replacement.fileName, try AndroidSharedPreferencesCodec.serialize(replacement.entries)))
        }

        let launchComponent = try? await resolveLaunchComponent(deviceSerial: deviceSerial, packageName: packageName)
        _ = try await adb(deviceSerial, ["shell", "am", "force-stop", packageName], timeout: 8)
        let stopped: AndroidPreferencePackageSnapshot
        do {
            stopped = try await loadPackage(deviceSerial: deviceSerial, packageName: packageName)
            guard stopped.revision == expectedRevision else { throw AndroidSharedPreferencesError.staleRevision }
            for replacement in replacements where !stopped.files.contains(where: { $0.name == replacement.fileName }) {
                throw AndroidSharedPreferencesError.fileNotFound(replacement.fileName)
            }
        } catch {
            _ = await attemptRelaunch(
                deviceSerial: deviceSerial,
                launchComponent: launchComponent
            )
            throw error
        }
        let transaction = UUID().uuidString.lowercased()
        var backedUp: [String] = []
        do {
            for item in serialized {
                let original = "shared_prefs/\(item.name)"
                let temporary = "\(original).lens-tmp-\(transaction)"
                let backup = "\(original).lens-backup-\(transaction)"
                let backupScript = "cp \(original) \(backup) && chmod 600 \(backup)"
                _ = try await adb(
                    deviceSerial,
                    ["shell", Self.runAsShellCommand(packageName: packageName, script: backupScript)],
                    timeout: 8
                )
                backedUp.append(item.name)
                let writeScript = "umask 077; cat > \(temporary) && chmod 600 \(temporary) && mv \(temporary) \(original)"
                _ = try await adb(
                    deviceSerial,
                    ["exec-in", Self.runAsShellCommand(packageName: packageName, script: writeScript)],
                    input: item.data,
                    timeout: 12
                )
            }
        } catch {
            let rollbackSucceeded = await rollback(
                deviceSerial: deviceSerial,
                packageName: packageName,
                fileNames: backedUp,
                transaction: transaction
            )
            _ = await attemptRelaunch(deviceSerial: deviceSerial, launchComponent: launchComponent)
            throw AndroidSharedPreferencesError.applyFailed(error.localizedDescription, rollbackSucceeded: rollbackSucceeded)
        }

        for name in backedUp {
            let original = "shared_prefs/\(name)"
            let cleanup = "rm -f \(original).lens-backup-\(transaction) \(original).lens-tmp-\(transaction)"
            _ = try? await adb(
                deviceSerial,
                ["shell", Self.runAsShellCommand(packageName: packageName, script: cleanup)],
                timeout: 5
            )
        }
        let updated: AndroidPreferencePackageSnapshot
        do {
            updated = try await loadPackage(deviceSerial: deviceSerial, packageName: packageName)
        } catch {
            _ = await attemptRelaunch(deviceSerial: deviceSerial, launchComponent: launchComponent)
            throw error
        }
        let relaunched: Bool
        let message: String
        if let launchComponent {
            relaunched = await attemptRelaunch(deviceSerial: deviceSerial, launchComponent: launchComponent)
            message = relaunched
                ? "Updated \(serialized.count) preference file(s) and relaunched \(packageName)."
                : "Updated \(serialized.count) preference file(s), but Android could not relaunch \(packageName). The package remains stopped."
        } else {
            relaunched = false
            message = "Updated \(serialized.count) preference file(s). The package remains stopped because no launchable activity was available."
        }
        return AndroidPreferenceApplyResult(
            packageName: packageName,
            revision: updated.revision,
            changedFileCount: serialized.count,
            relaunched: relaunched,
            message: message
        )
    }

    static func isValidPackage(_ value: String) -> Bool {
        guard value.contains("."), !value.contains(".."), value.first != ".", value.last != "." else { return false }
        return value.utf8.allSatisfy { isASCIIAlphaNumeric($0) || $0 == 95 || $0 == 46 }
    }

    static func isValidFileName(_ value: String) -> Bool {
        guard value.hasSuffix(".xml"), value != ".", value != "..", !value.contains("/") else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func requirePackageAccess(deviceSerial: String, packageName: String) async throws {
        guard Self.isValidPackage(packageName) else { throw AndroidSharedPreferencesError.invalidPackage(packageName) }
        do {
            _ = try await adb(deviceSerial, ["shell", "run-as", packageName, "true"], timeout: 5)
        } catch {
            throw AndroidSharedPreferencesError.packageNotDebuggable(packageName)
        }
    }

    private func readFile(deviceSerial: String, packageName: String, fileName: String) async throws -> Data {
        try Self.requireValidFileName(fileName)
        let command = "run-as \(Self.shellQuote(packageName)) cat \(Self.shellQuote("shared_prefs/\(fileName)"))"
        let result = try await adb(deviceSerial, ["exec-out", command], timeout: 8)
        guard let data = result.output.data(using: .utf8) else {
            throw AndroidSharedPreferencesError.malformedXML("\(fileName) is not UTF-8 XML.")
        }
        return data
    }

    private func resolveLaunchComponent(deviceSerial: String, packageName: String) async throws -> String? {
        let result = try await adb(
            deviceSerial,
            ["shell", "cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", packageName],
            timeout: 8
        )
        return result.output.split(whereSeparator: \.isWhitespace).map(String.init).last(where: Self.isValidComponent)
    }

    private func attemptRelaunch(deviceSerial: String, launchComponent: String?) async -> Bool {
        guard let launchComponent else { return false }
        return (try? await adb(
            deviceSerial,
            ["shell", "am", "start", "-n", launchComponent],
            timeout: 10
        )) != nil
    }

    private func rollback(
        deviceSerial: String,
        packageName: String,
        fileNames: [String],
        transaction: String
    ) async -> Bool {
        var succeeded = true
        for name in fileNames.reversed() {
            let original = "shared_prefs/\(name)"
            let script = "rm -f \(original).lens-tmp-\(transaction); mv \(original).lens-backup-\(transaction) \(original); chmod 600 \(original)"
            if (try? await adb(
                deviceSerial,
                ["shell", Self.runAsShellCommand(packageName: packageName, script: script)],
                timeout: 8
            )) == nil {
                succeeded = false
            }
        }
        return succeeded
    }

    private func adb(
        _ serial: String,
        _ arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        guard let executable = runtimePaths.bundledADBURL() else { throw AndroidSharedPreferencesError.adbMissing }
        let result = try await runner.run(executable, arguments: ["-s", serial] + arguments, input: input, timeout: timeout)
        guard result.status == 0 else {
            let message = result.errorOutput.isEmpty ? result.output : result.errorOutput
            throw AndroidSharedPreferencesError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private static func requireValidFileName(_ value: String) throws {
        guard isValidFileName(value) else { throw AndroidSharedPreferencesError.invalidFileName(value) }
    }

    private static func isValidComponent(_ value: String) -> Bool {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        return pieces.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy {
                isASCIIAlphaNumeric($0) || $0 == 95 || $0 == 46 || $0 == 36 || $0 == 45
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }

    private static func runAsShellCommand(packageName: String, script: String) -> String {
        "run-as \(shellQuote(packageName)) sh -c \(shellQuote(script))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func revision(_ contents: [(String, Data)]) -> String {
        var data = Data()
        for (name, content) in contents.sorted(by: { $0.0 < $1.0 }) {
            data.append(contentsOf: name.utf8)
            data.append(0)
            data.append(content)
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum AndroidSharedPreferencesError: LocalizedError {
    case adbMissing
    case commandFailed(String)
    case invalidPackage(String)
    case packageNotDebuggable(String)
    case invalidFileName(String)
    case fileNotFound(String)
    case duplicateFile(String)
    case malformedXML(String)
    case duplicateKey(String)
    case invalidKey(String)
    case invalidValue(String)
    case typeMismatch(String)
    case staleRevision
    case noChanges
    case applyFailed(String, rollbackSucceeded: Bool)

    var errorDescription: String? {
        switch self {
        case .adbMissing: "The bundled ADB runtime is missing or cannot be executed. Reinstall Lens."
        case let .commandFailed(message): message.isEmpty ? "The Android command failed." : message
        case let .invalidPackage(package): "Invalid Android package name: \(package)"
        case let .packageNotDebuggable(package): "\(package) is not installed as a debuggable app."
        case let .invalidFileName(name): "Invalid Shared Preferences file name: \(name)"
        case let .fileNotFound(name): "Shared Preferences file \(name) was not found."
        case let .duplicateFile(name): "Shared Preferences file \(name) was supplied more than once."
        case let .malformedXML(message): message
        case let .duplicateKey(key): "Duplicate preference key: \(key)"
        case let .invalidKey(key): "Invalid preference key: \(key.isEmpty ? "<empty>" : key)"
        case let .invalidValue(key): "The value for \(key) is outside the supported Android range."
        case let .typeMismatch(key): "The declared type and value for \(key) do not match."
        case .staleRevision: "Shared Preferences changed on Android. Refresh and rebuild the staged edits."
        case .noChanges: "No Shared Preferences changes were supplied."
        case let .applyFailed(message, rollbackSucceeded):
            rollbackSucceeded
                ? "Could not apply Shared Preferences. All changed files were restored. \(message)"
                : "Could not apply Shared Preferences, and rollback was incomplete. \(message)"
        }
    }
}
