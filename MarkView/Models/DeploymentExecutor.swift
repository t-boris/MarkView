import Foundation

struct CommandResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut = false
    /// The output was cut at the cap.
    var truncated = false

    var succeeded: Bool { status == 0 && !timedOut }
}

/// Why a connection failed, from what ssh printed.
enum ConnectionProblem: Equatable {
    case hostKeyUnknown
    case hostKeyChanged
    case authFailed
    case unreachable(String)
    case timedOut
    case other(String)

    static func from(_ result: CommandResult) -> ConnectionProblem? {
        guard !result.succeeded else { return nil }
        let text = result.stderr
        if result.timedOut { return .timedOut }
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || text.contains("Offending") && text.contains("key in") { return .hostKeyChanged }
        if text.contains("Host key verification failed") || text.contains("No ED25519 host key is known") || text.contains("No RSA host key is known") || text.contains("No ECDSA host key is known") { return .hostKeyUnknown }
        if text.contains("Permission denied") { return .authFailed }
        for needle in ["Connection refused", "Connection timed out", "No route to host", "Could not resolve hostname", "Network is unreachable", "Operation timed out", "Connection closed by", "Connection reset"] where text.contains(needle) {
            return .unreachable(text.split(separator: "\n").first(where: { $0.contains(needle) }).map(String.init) ?? needle)
        }
        // A remote command that failed is not a connection problem.
        if result.status == 255 { return .other(String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))) }
        return nil
    }

    var message: String {
        switch self {
        case .hostKeyUnknown: return "This server's host key is not known yet."
        case .hostKeyChanged: return "The server's host key changed since you last connected. This can mean the server was rebuilt, or someone is in the middle. MarkView will not continue; check it with whoever runs the server, then remove the old key from ~/.ssh/known_hosts."
        case .authFailed: return "The server refused your key. Check the user, and that your key is loaded (ssh-add -l) or set as the key file. MarkView does not use passwords."
        case .unreachable(let line): return "Cannot reach the server: \(line)"
        case .timedOut: return "The server did not answer in time."
        case .other(let text): return text.isEmpty ? "The connection failed." : text
        }
    }
}

/// Runs processes off the main thread with a timeout and a cap on the output; both pipes are drained while
/// the process runs, so neither can fill up and stall it.
enum ProcessRunner {
    static let outputCap = 2 * 1024 * 1024

    static func run(executable: String, arguments: [String], stdin: String? = nil, timeout: TimeInterval = 30,
                    directory: URL? = nil, environment: [String: String]? = nil) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            runBlocking(executable: executable, arguments: arguments, stdin: stdin, timeout: timeout, directory: directory, environment: environment)
        }.value
    }

    static func runBlocking(executable: String, arguments: [String], stdin: String?, timeout: TimeInterval,
                            directory: URL?, environment: [String: String]?) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        do { try process.run() } catch { return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription) }

        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        var truncated = false
        let lock = NSLock()
        func drain(_ pipe: Pipe, into store: @escaping (Data) -> Void) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    store(chunk)
                }
                group.leave()
            }
        }
        drain(out) { chunk in lock.lock(); if outData.count < outputCap { outData.append(chunk.prefix(outputCap - outData.count)); if outData.count >= outputCap { truncated = true } } else { truncated = true }; lock.unlock() }
        drain(err) { chunk in lock.lock(); if errData.count < 64 * 1024 { errData.append(chunk.prefix(64 * 1024 - errData.count)) }; lock.unlock() }
        if let stdin {
            DispatchQueue.global(qos: .userInitiated).async {
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
        }
        var timedOut = false
        let killer = DispatchWorkItem { timedOut = true; if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        // A killed process may leave a grandchild holding the pipes: do not wait for them for ever.
        _ = group.wait(timeout: .now() + 3)
        lock.lock(); defer { lock.unlock() }
        return CommandResult(status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self), timedOut: timedOut, truncated: truncated)
    }
}

/// Where a command runs.
protocol DeploymentExecutor {
    func run(_ command: String, stdin: String?, timeout: TimeInterval) async -> CommandResult
}

/// This Mac: for the "local" environment, and for the cloud CLIs.
struct LocalExecutor: DeploymentExecutor {
    var directory: URL?

    func run(_ command: String, stdin: String?, timeout: TimeInterval) async -> CommandResult {
        // A login-like PATH: a GUI app does not inherit the shell's, so the CLIs (vercel, fly, aws) would not be found.
        let path = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.fly/bin"].joined(separator: ":")
        return await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", command], stdin: stdin, timeout: timeout, directory: directory, environment: ["PATH": path])
    }
}

/// A server over SSH: key or agent only (BatchMode), the person's own ~/.ssh/config, one connection reused.
struct SSHExecutor: DeploymentExecutor {
    let environment: DeploymentEnvironment
    /// Extra ssh options. Empty in the app; a test points ssh at its own known_hosts and a private server.
    nonisolated(unsafe) static var extraOptions: [String] = []

    /// nil when the definition is not safe to use.
    static func arguments(for env: DeploymentEnvironment) -> [String]? {
        guard env.kind == .ssh, env.problems.isEmpty else { return nil }
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
                    "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/mvssh-\(controlTag(env))-%C", "-o", "ControlPersist=60", "-o", "LogLevel=ERROR", "-p", String(env.port)]
        if !env.identityFile.isEmpty {
            let path = (env.identityFile as NSString).expandingTildeInPath
            args += ["-i", path, "-o", "IdentitiesOnly=yes"]
        }
        args += extraOptions
        args.append(env.destination)
        return args
    }

    /// One shared connection per host, port, user and key file: a changed key file must not ride on the old connection.
    private static func controlTag(_ env: DeploymentEnvironment) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (env.identityFile + "|" + env.destination).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16).prefix(8).description
    }

    func run(_ command: String, stdin: String?, timeout: TimeInterval) async -> CommandResult {
        guard let args = Self.arguments(for: environment) else {
            return CommandResult(status: 255, stdout: "", stderr: "The environment definition is not valid: " + environment.problems.joined(separator: " "))
        }
        return await ProcessRunner.run(executable: "/usr/bin/ssh", arguments: args + [command], stdin: stdin, timeout: timeout)
    }
}

enum DeploymentExecutors {
    static func make(for env: DeploymentEnvironment, projectRoot: URL?) -> DeploymentExecutor {
        switch env.kind {
        case .ssh: return SSHExecutor(environment: env)
        case .local, .cloud: return LocalExecutor(directory: projectRoot)
        }
    }
}

/// Host keys: look at a server's key before trusting it.
enum HostKeys {
    /// `ssh-keyscan` lines and their fingerprints, for the person to compare with what the server's owner says.
    static func scan(host: String, port: Int) async -> (lines: [String], fingerprints: [String])? {
        guard DeploymentEnvironment.isSafeToken(host), (1...65535).contains(port) else { return nil }
        let scan = await ProcessRunner.run(executable: "/usr/bin/ssh-keyscan", arguments: ["-T", "8", "-p", String(port), host], timeout: 20)
        let lines = scan.stdout.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let printed = await ProcessRunner.run(executable: "/usr/bin/ssh-keygen", arguments: ["-lf", "-"], stdin: lines.joined(separator: "\n") + "\n", timeout: 10)
        let fingerprints = printed.stdout.split(separator: "\n").map(String.init)
        return (lines, fingerprints)
    }

    /// Append the keys to the person's known_hosts (after they compared the fingerprints).
    static func trust(lines: [String]) -> Bool {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = (dir as NSString).appendingPathComponent("known_hosts")
        var existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
        let new = lines.filter { !existing.contains($0) }
        guard !new.isEmpty else { return true }
        do { try (existing + new.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8) } catch { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return true
    }
}
