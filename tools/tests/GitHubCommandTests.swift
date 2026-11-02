import Foundation
import Darwin

enum CLIToolLocator {
    static func subprocessPath(toolPath: String?) -> String { ProcessInfo.processInfo.environment["MARKVIEW_GITHUB_TEST_PATH"]! }
}

@main enum GitHubCommandTests {
    static func main() async throws {
        if CommandLine.arguments.contains("--fixture") { try fixture(); return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-github-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("gh"), withDestinationURL: executable)
        setenv("MARKVIEW_GITHUB_TEST_PATH", root.path, 1)

        let start = Date()
        let inherited = await GitHubClient.execute(["--fixture", "inherited-writer"], in: root, timeout: 2)
        precondition(inherited.status == 0 && inherited.stdout == "[]")
        precondition(Date().timeIntervalSince(start) < 2,
                     "A finished gh request must not wait for a descendant to close its inherited output pipe.")
        let large = await GitHubClient.execute(["--fixture", "both-pipes"], in: root, timeout: 5)
        precondition(large.status == 7 && large.stdout.utf8.count == 1024 * 1024 && large.stderr.utf8.count == 1024 * 1024,
                     "Both full pipes must drain without losing the CLI exit status or bytes.")
        let timeoutStart = Date()
        let hung = await GitHubClient.execute(["--fixture", "ignore-term"], in: root, timeout: 1)
        precondition(hung.status == -1 && hung.stderr.contains("did not answer within"))
        precondition(Date().timeIntervalSince(timeoutStart) < 3, "SIGTERM-resistant children must be killed within a bounded deadline.")
        let pidText = try String(contentsOf: root.appendingPathComponent("hung.pid"), encoding: .utf8)
        let pid = pid_t(pidText)!
        precondition(kill(pid, 0) == -1 && errno == ESRCH, "Timed-out children must not remain alive.")
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let output = await GitHubClient.execute(["--fixture", "success"], in: root, timeout: 3)
                    return output.status == 0 && output.stdout == "ready é\n"
                }
            }
            for await success in group { precondition(success, "Concurrent requests must complete independently.") }
        }
        let invalid = await GitHubClient.execute(["--fixture", "success"], in: root.appendingPathComponent("missing"), timeout: 0.1)
        precondition(invalid.status != 0 && !invalid.stderr.isEmpty)
        try await gatedOutput(root: root)
        print("GitHub commands: inherited writers, concurrent stdout/stderr, exit status, hard timeout, reaping, parallel requests and the opt-in gate passed.")
    }

    /// BUG-044: the PR X-Ray's `gh` runner (`GitHubClient.output`) must not start `gh` while the GitHub
    /// integration is off, and with it on must return stdout only on success and give up on a hung `gh`.
    private static func gatedOutput(root: URL) async throws {
        let marker = root.appendingPathComponent("started")
        let off = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: GitHubClient.output(["--fixture", "mark"], in: root, enabled: false, timeout: 2))
            }
        }
        precondition(off == nil, "Integration off: no output.")
        precondition(!FileManager.default.fileExists(atPath: marker.path), "Integration off: gh must not be started at all.")
        let on = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: GitHubClient.output(["--fixture", "mark"], in: root, enabled: true, timeout: 2))
            }
        }
        precondition(on == "marked\n", "Integration on: gh runs and its standard output comes back.")
        precondition(FileManager.default.fileExists(atPath: marker.path), "Integration on: gh was started.")
        let failed = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: GitHubClient.output(["--fixture", "both-pipes"], in: root, enabled: true, timeout: 5))
            }
        }
        precondition(failed == nil, "A non-zero exit status gives nil, not partial output.")
        let hungStart = Date()
        let hung = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: GitHubClient.output(["--fixture", "ignore-term"], in: root, enabled: true, timeout: 1))
            }
        }
        precondition(hung == nil && Date().timeIntervalSince(hungStart) < 3, "A hung gh gives nil within the timeout.")
    }

    private static func fixture() throws {
        switch CommandLine.arguments.last {
        case "inherited-writer":
            let args: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup("/bin/sleep 4 & printf '[]'"), nil]
            _ = execv(args[0]!, args)
            _exit(127)
        case "both-pipes":
            let chunk = Data(repeating: 65, count: 16384)
            for _ in 0..<64 {
                FileHandle.standardOutput.write(chunk)
                FileHandle.standardError.write(chunk)
            }
            exit(7)
        case "mark":
            // Leaves a trace that gh was started, for the opt-in gate check.
            try Data().write(to: URL(fileURLWithPath: "started"))
            FileHandle.standardOutput.write(Data("marked\n".utf8))
        case "ignore-term":
            signal(SIGTERM, SIG_IGN)
            try String(getpid()).write(toFile: "hung.pid", atomically: true, encoding: .utf8)
            while true { pause() }
        default: FileHandle.standardOutput.write(Data("ready é\n".utf8))
        }
    }
}
