import Foundation

struct LensRuntimePaths: Sendable {
    static let bundledMitmdumpRelativePath = "Contents/Helpers/mitmproxy.app/Contents/MacOS/mitmdump"
    static let bundledADBRelativePath = "Contents/Helpers/platform-tools/adb"
    static let bundledAndroidAgentDirectory = "Contents/Helpers/android-inspector"

    let applicationBundleURL: URL
    let applicationSupportDirectory: URL

    static func live(
        applicationBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> LensRuntimePaths {
        LensRuntimePaths(
            applicationBundleURL: applicationBundleURL,
            applicationSupportDirectory: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lens", isDirectory: true)
        )
    }

    var mitmproxyConfigurationDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("mitmproxy", isDirectory: true)
    }

    var certificateURL: URL {
        mitmproxyConfigurationDirectory.appendingPathComponent("mitmproxy-ca-cert.cer")
    }

    func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: mitmproxyConfigurationDirectory, withIntermediateDirectories: true)
    }

    func bundledMitmdumpURL(fileManager: FileManager = .default) -> URL? {
        executableURL(relativePath: Self.bundledMitmdumpRelativePath, fileManager: fileManager)
    }

    func bundledADBURL(fileManager: FileManager = .default) -> URL? {
        executableURL(relativePath: Self.bundledADBRelativePath, fileManager: fileManager)
    }

    func bundledAndroidAgentURL(abi: String, fileManager: FileManager = .default) -> URL? {
        let normalizedABI = abi == "x86_64" ? "x86_64" : "arm64-v8a"
        let relativePath = "\(Self.bundledAndroidAgentDirectory)/\(normalizedABI)/liblens_jvmti.so"
        let url = applicationBundleURL.appendingPathComponent(relativePath)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func executableURL(relativePath: String, fileManager: FileManager) -> URL? {
        let url = applicationBundleURL.appendingPathComponent(relativePath)
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }
}
