import AppKit
import Foundation

@MainActor
final class AgentSkillExporter {
    enum ExportError: LocalizedError {
        case bundledSkillMissing
        case openAPIMissing

        var errorDescription: String? {
            switch self {
            case .bundledSkillMissing: "The bundled lens-operator skill is missing from this Lens build."
            case .openAPIMissing: "The bundled OpenAPI document is missing from this Lens build."
            }
        }
    }

    func exportSkill() throws {
        guard let source = Bundle.main.resourceURL?
            .appendingPathComponent("AgentSkills", isDirectory: true)
            .appendingPathComponent("lens-operator", isDirectory: true),
              FileManager.default.fileExists(atPath: source.path) else {
            throw ExportError.bundledSkillMissing
        }
        let panel = NSOpenPanel()
        panel.title = "Export Lens Operator Skill"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = parent.appendingPathComponent("lens-operator", isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.messageText = "Replace existing lens-operator skill?"
            alert.informativeText = destination.path
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let temporary = parent.appendingPathComponent(".lens-operator-\(UUID().uuidString)", isDirectory: true)
        try manager.copyItem(at: source, to: temporary)
        do {
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    func exportOpenAPI() throws {
        guard let source = Bundle.main.url(forResource: "openapi", withExtension: "json") else {
            throw ExportError.openAPIMissing
        }
        let panel = NSSavePanel()
        panel.title = "Export Lens OpenAPI"
        panel.nameFieldStringValue = "lens-openapi.json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
    }
}
