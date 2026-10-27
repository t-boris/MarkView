import Foundation

@main
enum RemoteWorkspaceTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }
    static func text(_ value: RemoteJSON) -> String { value["content"].array?.first?["text"].string ?? "" }
    static func session(_ result: RemoteJSON) -> String? {
        let text = text(result)
        return text.components(separatedBy: "session_id: ").dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func expectFailure(_ message: String, _ body: () throws -> Void) {
        do { try body(); check(false, message) } catch { checks += 1 }
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--remote-workspace-mcp") { RemoteUnixRPC.runMCP(arguments: CommandLine.arguments) }
        if CommandLine.arguments.contains("--remote-workspace-guard") { RemoteUnixRPC.runGuard() }
        if let index = CommandLine.arguments.firstIndex(of: "--provider-command"), CommandLine.arguments.count > index + 4 {
            let args = CommandLine.arguments
            let directory = URL(fileURLWithPath: args[index + 4])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            print(try RemoteProviderConfiguration.command(provider: .init(rawValue: args[index + 1])!, executable: args[index + 2],
                app: args[index + 3], socket: directory.appendingPathComponent("test.sock").path,
                context: .object(["cwd": .string("/test/work"), "hostname": .string("test-work")]), directory: directory, model: nil, resume: false))
            return
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("mv-remote-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let workRoot = fixture.appendingPathComponent("work"), homeRoot = fixture.appendingPathComponent("home")
        for root in [workRoot, homeRoot] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        try Data("WORK ONLY\n".utf8).write(to: workRoot.appendingPathComponent("identity.txt"))
        try Data("HOME ONLY\n".utf8).write(to: homeRoot.appendingPathComponent("identity.txt"))
        try FileManager.default.createSymbolicLink(at: workRoot.appendingPathComponent("escape"), withDestinationURL: homeRoot)

        let invitation = try RemoteInvitation(relay: URL(string: "https://relay.example.com/base")!)
        let copy = try RemoteInvitation(code: invitation.code)
        check(copy.room == invitation.room && copy.token(for: .home) == invitation.token(for: .home), "Pairing code must round-trip.")
        check(copy.token(for: .work) != copy.token(for: .home), "Roles require different credentials.")
        let message = RemoteMessage("input", .string("Привет 🌍"))
        let sealed = try invitation.seal(message, sender: .work)
        check(!(Data(base64Encoded: sealed).map { String(decoding: $0, as: UTF8.self).contains("Привет") } ?? true), "The relay must not see plaintext.")
        let opened = try copy.open(sealed, sender: .work)
        check(opened.id == message.id && opened.payload == message.payload, "Authenticated messages must round-trip.")
        expectFailure("A reflected message must fail role authentication.") { _ = try copy.open(sealed, sender: .home) }
        let other = try RemoteInvitation(relay: invitation.relay)
        expectFailure("A different room cannot decrypt a message.") { _ = try other.open(sealed, sender: .work) }
        expectFailure("External plaintext HTTP must be rejected.") { _ = try RemoteInvitation(relay: URL(string: "http://relay.example.com")!) }
        expectFailure("Credentials in a URL must be rejected.") { _ = try RemoteInvitation(relay: URL(string: "https://user:password@relay.example.com")!) }
        expectFailure("Invalid codes must be rejected.") { _ = try RemoteInvitation(code: "not a connection") }
        _ = try RemoteInvitation(relay: URL(string: "http://127.0.0.1:8787")!)
        let largeMessage = RemoteMessage("toolResult", .string(String(repeating: "large image or file data;", count: 100000)))
        let frames = try RemoteFraming.frames(for: largeMessage)
        check(frames.count > 1, "Large tool results must be framed for serverless payload limits.")
        var assembler = RemoteReassembler(), assembled: RemoteMessage?
        for frame in frames {
            let box = try invitation.seal(frame, sender: .home)
            check(box.utf8.count <= RemoteFraming.maxEncryptedBytes, "Every encrypted frame must fit the serverless request limit.")
            assembled = try assembler.accept(invitation.open(box, sender: .home))
        }
        check(assembled?.id == largeMessage.id && assembled?.payload == largeMessage.payload, "Framing must retain the original tool ID and complete contents.")
        let retried = try assembler.accept(frames.last!)
        check(retried?.id == largeMessage.id, "The final frame must remain retryable until the application acknowledges it.")
        assembler.acknowledge(largeMessage.id)
        let replayed = try assembler.accept(frames[0])
        check(replayed == nil, "A completed operation must not be delivered again under new transport retries.")

        let workspace = try await RemoteWorkspace(root: workRoot, deviceID: UUID().uuidString)
        @Sendable func call(_ name: String, _ args: [String: RemoteJSON] = [:], id: UUID = UUID()) async -> RemoteJSON {
            await workspace.call(id: id, name: name, arguments: .object(args))
        }
        func commandOutputUntilExit(_ first: RemoteJSON) async -> String {
            var current = first, output = text(first)
            for _ in 0..<10 {
                guard let id = session(current) else { return output }
                current = await call("write_stdin", ["session_id": .string(id), "yield_time_ms": .int(1000)])
                output += "\n" + text(current)
            }
            fatalError("The test command did not finish: \(output)")
        }
        let read = await call("read_file", ["path": .string("identity.txt")])
        check(text(read).contains("WORK ONLY") && !text(read).contains("HOME ONLY"), "The workspace must read the work file, never its home namesake.")
        let absolute = await call("read_file", ["path": .string(workRoot.appendingPathComponent("identity.txt").path)])
        check(text(read) == text(absolute), "Absolute work paths must resolve to the same file.")
        let escaped = await call("read_file", ["path": .string("escape/identity.txt")])
        check(escaped["isError"].bool == true, "File reads must reject symlink escapes.")
        let traversal = await call("write_file", ["path": .string("../home/identity.txt"), "content": .string("bad")])
        check(traversal["isError"].bool == true, "File writes must reject path traversal.")
        let writeID = UUID()
        _ = await call("write_file", ["path": .string("new/file.txt"), "content": .string("alpha alpha")], id: writeID)
        let ambiguous = await call("edit_file", ["path": .string("new/file.txt"), "old_text": .string("alpha"), "new_text": .string("beta")])
        check(ambiguous["isError"].bool == true, "Edits must refuse ambiguous matches.")
        let edit = await call("edit_file", ["path": .string("new/file.txt"), "old_text": .string("alpha"), "new_text": .string("beta"), "replace_all": .bool(true)])
        check(edit["isError"].bool == false, "Explicit replace-all must work.")
        _ = await call("write_file", ["path": .string("new/file.txt"), "content": .string("alpha alpha")], id: writeID)
        check(try String(contentsOf: workRoot.appendingPathComponent("new/file.txt"), encoding: .utf8) == "beta beta", "Retrying a previous write must not overwrite subsequent edits.")

        let bounded = try await RemoteWorkspace(root: workRoot, deviceID: UUID().uuidString, resultCacheBytes: 0)
        let oldID = UUID()
        _ = await bounded.call(id: oldID, name: "write_file", arguments: .object(["path": .string("cache.txt"), "content": .string("first")]))
        _ = await bounded.call(id: UUID(), name: "write_file", arguments: .object(["path": .string("cache.txt"), "content": .string("second")]))
        let expiredRetry = await bounded.call(id: oldID, name: "write_file", arguments: .object(["path": .string("cache.txt"), "content": .string("first")]))
        let afterExpiredRetry = try String(contentsOf: workRoot.appendingPathComponent("cache.txt"), encoding: .utf8)
        check(expiredRetry["isError"].bool == true && afterExpiredRetry == "second", "Evicting a cached result must never replay a completed write.")
        await bounded.close()
        try Data(repeating: 1, count: 1024 * 1024).write(to: workRoot.appendingPathComponent("control-characters.txt"))
        let oversized = await call("read_file", ["path": .string("control-characters.txt")])
        check(oversized["isError"].bool == true && text(oversized).contains("Read a smaller portion"), "JSON escaping must not turn a bounded file into an oversized transport message.")

        let shell = await call("exec_command", ["cmd": .string("pwd; cat identity.txt; printf built > build.txt; /usr/bin/git init -q"), "yield_time_ms": .int(1000)])
        let shellOutput = await commandOutputUntilExit(shell)
        check(shellOutput.contains("WORK ONLY") && shellOutput.contains(workRoot.path), "Commands must execute in the work-computer root.")
        check(shellOutput.contains("Exit code: 0") && FileManager.default.fileExists(atPath: workRoot.appendingPathComponent(".git").path), "Git must run on the work computer: \(shellOutput)")
        check(!FileManager.default.fileExists(atPath: homeRoot.appendingPathComponent("build.txt").path), "Commands must leave the home fixture unchanged.")
        let dedupeID = UUID()
        let dedupeArgs: [String: RemoteJSON] = ["cmd": .string("printf x >> once.txt; sleep 0.1"), "yield_time_ms": .int(1000)]
        async let a = call("exec_command", dedupeArgs, id: dedupeID)
        async let b = call("exec_command", dedupeArgs, id: dedupeID)
        let pair = await (a, b)
        check(pair.0 == pair.1, "Concurrent duplicate requests must share one command result.")
        check(try String(contentsOf: workRoot.appendingPathComponent("once.txt"), encoding: .utf8) == "x", "A retried command must execute exactly once.")

        let large = await call("exec_command", ["cmd": .string("/usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' x; printf FINAL_MARKER"), "yield_time_ms": .int(2000)])
        check(text(large).contains("FINAL_MARKER") && text(large).contains("Exit code: 0"), "Large pipe output must drain completely without deadlocking or losing the tail.")
        let running = await call("exec_command", ["cmd": .string("read reply; printf 'REPLY:%s' \"$reply\""), "yield_time_ms": .int(0)])
        check(session(running) != nil, "A running command must return a session ID.")
        let input = await call("write_stdin", ["session_id": .string(session(running)!), "chars": .string("from work\n"), "yield_time_ms": .int(1000)])
        check(text(input).contains("REPLY:from work") && text(input).contains("Exit code: 0"), "Command input and completion must use the same work process.")
        let counter = await call("exec_command", ["cmd": .string("/usr/bin/wc -c"), "yield_time_ms": .int(0)])
        let countResult = await call("write_stdin", ["session_id": .string(session(counter)!), "chars": .string(String(repeating: "x", count: 60000)), "close_stdin": .bool(true), "yield_time_ms": .int(2000)])
        check(text(countResult).contains("60000") && text(countResult).contains("Exit code: 0"), "Large stdin must drain under backpressure before EOF.")
        let sleeper = await call("exec_command", ["cmd": .string("sleep 30"), "yield_time_ms": .int(0)])
        let stopped = await call("write_stdin", ["session_id": .string(session(sleeper)!), "terminate": .bool(true), "yield_time_ms": .int(1000)])
        check(text(stopped).contains("Exit code:"), "Stopping a command must terminate it.")

        let listed = RemoteWorkspaceTools.response(to: .object(["id": .int(1), "method": .string("tools/list")])) { _, _, _ in .null }
        check(listed?["result"]["tools"].array?.count == RemoteWorkspaceTools.names.count, "Both providers must discover the complete workspace interface.")
        check(["Bash", "Read", "apply_patch", "mcp__work__read_file", ""].allSatisfy {
            RemoteUnixRPC.guardResponse(for: $0)["hookSpecificOutput"]["permissionDecision"].string == "deny"
        }, "Both providers must receive a supported denial for native home tools and malformed names.")
        check([RemoteWorkspaceTools.toolPrefix + "read_file", "AskUserQuestion", "update_plan"].allSatisfy {
            RemoteUnixRPC.guardResponse(for: $0) == .object([:])
        }, "Allowed tools must use a neutral hook result accepted by both Claude and Codex.")
        let context = await workspace.describe()
        for provider in RemoteProviderConfiguration.Provider.allCases {
            let command = try RemoteProviderConfiguration.command(provider: provider, executable: "/test/agent", app: "/test/MarkView's App",
                socket: fixture.appendingPathComponent("bridge.sock").path, context: context, directory: fixture, model: "model; touch /unwanted", resume: false)
            check(command.contains("--remote-workspace-guard") || provider == .claude, "Codex must configure the native-tool guard.")
            check(!command.contains("--dangerously-bypass-approvals-and-sandbox"), "Codex native execution must retain its sandbox.")
            check(command.contains("'model; touch /unwanted'"), "Model values must remain one quoted argument.")
            if provider == .codex {
                let server = "mcp_servers." + RemoteWorkspaceTools.serverName
                check(command.contains(server + ".required=true") && command.contains(server + ".default_tools_approval_mode=\"approve\""), "Codex must require and authorize the owned work MCP server without prompting in never-approval mode.")
            }
        }
        let settings = try JSONDecoder().decode(RemoteJSON.self, from: Data(contentsOf: fixture.appendingPathComponent("claude-settings.json")))
        check(settings["hooks"]["PreToolUse"].array?.count == 1, "Claude must have the same fail-closed native-tool guard.")
        let config = try JSONDecoder().decode(RemoteJSON.self, from: Data(contentsOf: fixture.appendingPathComponent("mcp.json")))
        check(config["mcpServers"][RemoteWorkspaceTools.serverName]["args"].array?.first?.string == "--remote-workspace-mcp", "MCP configuration must use this app's embedded bridge.")
        let quitCommand = await call("exec_command", ["cmd": .string("sleep 30"), "yield_time_ms": .int(0)])
        AgentProcesses.terminateAll(grace: 0.2)
        let quitResult = await call("write_stdin", ["session_id": .string(session(quitCommand)!), "yield_time_ms": .int(1000)])
        check(text(quitResult).contains("Exit code:"), "App termination must stop work-computer commands through the shared process registry.")
        print("Remote workspace core: \(checks) checks passed.")
        if !CommandLine.arguments.contains("--core-only") {
            let bridge = try RemoteToolBridge { id, name, args in await workspace.call(id: id, name: name, arguments: args) }
            defer { bridge.stop() }
            let viaBridge = await Task.detached {
                RemoteUnixRPC.call(socket: bridge.path, id: UUID(), name: "read_file", arguments: .object(["path": .string("identity.txt")]))
            }.value
            check(text(viaBridge).contains("WORK ONLY"), "The real per-session Unix bridge must reach the selected workspace.")
        } else { print("Unix bridge integration not run (--core-only).") }
        await workspace.close()
        let closed = await call("exec_command", ["cmd": .string("touch must-not-run")])
        check(closed["isError"].bool == true && !FileManager.default.fileExists(atPath: workRoot.appendingPathComponent("must-not-run").path), "Disconnected workspaces must refuse commands.")
        print("Remote workspace: \(checks) checks passed.")
    }
}
