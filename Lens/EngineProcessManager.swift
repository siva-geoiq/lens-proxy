import Darwin
import Foundation

final class EngineProcessManager: @unchecked Sendable {
    static let bundledRuntimeRelativePath = LensRuntimePaths.bundledMitmdumpRelativePath

    private let runtimePaths: LensRuntimePaths
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private let outputQueue = DispatchQueue(label: "com.lenskart.lens.engine-output")
    private var outputBuffer = ""

    var isRunning: Bool { process?.isRunning == true }

    init(runtimePaths: LensRuntimePaths = .live()) {
        self.runtimePaths = runtimePaths
    }

    func start(
        proxyPort: Int,
        onControlPort: @escaping @Sendable (UInt16, String) -> Void,
        onLog: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> String {
        guard process?.isRunning != true else { throw EngineProcessError.alreadyRunning }
        guard isPortAvailable(proxyPort) else { throw EngineProcessError.portInUse(proxyPort) }
        guard let executable = runtimePaths.bundledMitmdumpURL() else {
            throw EngineProcessError.bundledRuntimeMissing
        }
        guard let addonURL = Bundle.main.url(forResource: "lens_addon", withExtension: "py") else {
            throw EngineProcessError.addonNotFound
        }

        do {
            try runtimePaths.prepare()
        } catch {
            throw EngineProcessError.runtimeStorageUnavailable(error.localizedDescription)
        }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = [
            "--listen-host", "0.0.0.0",
            "--listen-port", String(proxyPort),
            "--set", "confdir=\(runtimePaths.mitmproxyConfigurationDirectory.path)",
            "--set", "block_global=false",
            "--set", "websocket=true",
            "--scripts", addonURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["LENS_CONTROL_TOKEN"] = token
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self, self.process === terminatedProcess else { return }
            self.process = nil
            self.outputPipe = nil
            self.errorPipe = nil
            onExit(terminatedProcess.terminationStatus)
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.processOutput(text, token: token, onControlPort: onControlPort, onLog: onLog)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onLog(text)
        }

        try process.run()
        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        return token
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        let runningProcess = process
        process = nil
        outputPipe = nil
        errorPipe = nil
        guard let runningProcess, runningProcess.isRunning else { return }
        runningProcess.terminate()
        let deadline = Date().addingTimeInterval(1)
        while runningProcess.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if runningProcess.isRunning {
            kill(runningProcess.processIdentifier, SIGKILL)
            runningProcess.waitUntilExit()
        }
    }

    private func processOutput(
        _ text: String,
        token: String,
        onControlPort: @escaping @Sendable (UInt16, String) -> Void,
        onLog: @escaping @Sendable (String) -> Void
    ) {
        outputQueue.async { [weak self] in
            guard let self else { return }
            outputBuffer += text
            let parts = outputBuffer.components(separatedBy: .newlines)
            outputBuffer = parts.last ?? ""
            for line in parts.dropLast() {
                if line.hasPrefix("LENS_CONTROL_PORT="),
                   let port = UInt16(line.replacingOccurrences(of: "LENS_CONTROL_PORT=", with: "")) {
                    onControlPort(port, token)
                } else if !line.isEmpty {
                    onLog(line)
                }
            }
        }
    }

    static func bundledMitmdumpURL(
        in applicationBundleURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        LensRuntimePaths(
            applicationBundleURL: applicationBundleURL,
            applicationSupportDirectory: fileManager.temporaryDirectory
        ).bundledMitmdumpURL(fileManager: fileManager)
    }

    private func isPortAvailable(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var reuseAddress: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { return false }
        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: in_port_t(port).bigEndian,
            sin_addr: in_addr(s_addr: INADDR_ANY),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

enum EngineProcessError: LocalizedError {
    case alreadyRunning
    case bundledRuntimeMissing
    case runtimeStorageUnavailable(String)
    case addonNotFound
    case portInUse(Int)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "mitmdump is already running."
        case .bundledRuntimeMissing: "The bundled mitmproxy runtime is missing or cannot be executed. Reinstall Lens."
        case let .runtimeStorageUnavailable(message): "Lens could not prepare its proxy storage: \(message)"
        case .addonNotFound: "The Lens mitmproxy addon is missing from the application bundle."
        case let .portInUse(port): "Port \(port) is already in use. Stop the conflicting proxy or select another port in Settings."
        }
    }
}
