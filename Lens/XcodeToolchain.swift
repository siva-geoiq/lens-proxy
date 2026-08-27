import Foundation

/// Locates the Xcode command-line tools Lens needs for iOS support.
///
/// Lens bundles ADB, but `simctl` and `devicectl` ship inside Xcode and cannot be
/// redistributed. `xcode-select -p` frequently points at a Command Line Tools
/// instance, which contains neither utility, so resolution walks several
/// candidates instead of trusting the active developer directory alone.
struct XcodeToolchain: Sendable {
    static let simctlRelativePath = "usr/bin/simctl"
    static let devicectlRelativePath = "usr/bin/devicectl"

    let developerDirectory: URL

    var simctlURL: URL { developerDirectory.appendingPathComponent(Self.simctlRelativePath) }
    var devicectlURL: URL { developerDirectory.appendingPathComponent(Self.devicectlRelativePath) }

    /// Resolves the first developer directory that actually contains `simctl`.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        activeDeveloperDirectory: @Sendable () -> String? = Self.activeDeveloperDirectory
    ) -> XcodeToolchain? {
        for candidate in candidateDirectories(
            environment: environment,
            activeDeveloperDirectory: activeDeveloperDirectory
        ) {
            let toolchain = XcodeToolchain(developerDirectory: candidate)
            if fileManager.isExecutableFile(atPath: toolchain.simctlURL.path) {
                return toolchain
            }
        }
        return nil
    }

    /// Candidate developer directories in preference order.
    ///
    /// `DEVELOPER_DIR` wins because it is how a developer overrides the active
    /// toolchain, and a Command Line Tools path is skipped outright because it can
    /// never provide `simctl`.
    static func candidateDirectories(
        environment: [String: String],
        activeDeveloperDirectory: @Sendable () -> String? = Self.activeDeveloperDirectory
    ) -> [URL] {
        var paths: [String] = []
        if let override = environment["DEVELOPER_DIR"], !override.isEmpty {
            paths.append(override)
        }
        if let active = activeDeveloperDirectory(), !active.isEmpty, !isCommandLineTools(active) {
            paths.append(active)
        }
        paths.append("/Applications/Xcode.app/Contents/Developer")

        var seen = Set<String>()
        return paths.compactMap { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    static func isCommandLineTools(_ path: String) -> Bool {
        path.contains("/CommandLineTools")
    }

    private static func activeDeveloperDirectory() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
