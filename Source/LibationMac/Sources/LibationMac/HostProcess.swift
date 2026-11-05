import Foundation

/// Finds, launches and owns the LibationHost child process.
///
/// Resolution order:
///  1. `LIBATION_HOST_URL` (+ `LIBATION_HOST_TOKEN`) in the environment: attach to a host you started yourself.
///  2. `Contents/Resources/host/LibationHost` inside the app bundle (what build.sh produces).
///  3. The repo's debug build, `Source/bin/Host/Debug/LibationHost`, for `swift run` during development.
@MainActor
final class HostProcess {
    static let shared = HostProcess()

    private(set) var process: Process?
    private(set) var client: HostClient?
    let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs/Libation")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "LibationHost.log")
    }()

    private init() {}

    func start() async throws -> HostClient {
        if let client { return client }
        let env = ProcessInfo.processInfo.environment
        if let urlString = env["LIBATION_HOST_URL"], let url = URL(string: urlString) {
            let c = HostClient(baseURL: url, token: env["LIBATION_HOST_TOKEN"])
            client = c
            return c
        }

        let exe = try locateExecutable()
        let token = UUID().uuidString
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = ["--port", "0", "--token", token, "--parent", String(ProcessInfo.processInfo.processIdentifier)]
        var childEnv = env
        // The bundled host is self-contained; the repo's debug build is framework-dependent and
        // needs to find the SDK's runtime when launched from Finder/Xcode without a shell profile.
        if childEnv["DOTNET_ROOT"] == nil {
            let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".dotnet")
            if FileManager.default.isExecutableFile(atPath: home.appending(path: "dotnet").path) { childEnv["DOTNET_ROOT"] = home.path }
        }
        proc.environment = childEnv
        let stdout = Pipe()
        proc.standardOutput = stdout
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        proc.standardError = try FileHandle(forWritingTo: logURL)
        try proc.run()
        process = proc

        let urlString = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    if line.hasPrefix("LIBATION_HOST_URL=") { return String(line.dropFirst("LIBATION_HOST_URL=".count)) }
                }
                // stdout closed: the host died before announcing its URL. Wait so the exit code is readable.
                proc.waitUntilExit()
                let tail = (try? String(contentsOf: self.logURL, encoding: .utf8)).map { String($0.suffix(2000)) } ?? ""
                throw HostError.exited(proc.terminationStatus, tail)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(40))
                throw HostError.startupTimeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        // Keep draining stdout so the child never blocks on a full pipe.
        _ = Task.detached { try? await stdout.fileHandleForReading.bytes.lines.reduce(0) { n, _ in n + 1 } }

        // Kestrel reports "localhost"; pin to IPv4 so URLSession does not try ::1 first.
        var comps = URLComponents(string: urlString)!
        comps.host = "127.0.0.1"
        let c = HostClient(baseURL: comps.url!, token: token)
        client = c
        return c
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        let c = client
        let sem = DispatchSemaphore(value: 0)
        Task.detached { await c?.shutdown(); sem.signal() }
        _ = sem.wait(timeout: .now() + 3)
        if proc.isRunning { proc.terminate() }
        process = nil
        client = nil
    }

    private func locateExecutable() throws -> URL {
        var tried: [String] = []
        if let bundled = Bundle.main.resourceURL?.appending(path: "host/LibationHost") {
            tried.append(bundled.path)
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        // #filePath = .../Source/LibationMac/Sources/LibationMac/HostProcess.swift
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for cfg in ["Debug", "Release"] {
            let dev = source.appending(path: "bin/Host/\(cfg)/LibationHost")
            tried.append(dev.path)
            if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        }
        throw HostError.hostNotFound(tried)
    }
}
