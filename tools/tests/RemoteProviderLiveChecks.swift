import Foundation

private actor ToolAudit {
    private var calls: [String] = []
    func record(_ name: String) { calls.append(name) }
    func names() -> Set<String> { Set(calls) }
}

@main
enum RemoteProviderLiveChecks {
    static func main() async {
        do { try await check() }
        catch {
            FileHandle.standardError.write(Data(("Remote provider live check failed: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func check() async throws {
        guard (6...7).contains(CommandLine.arguments.count),
              let provider = RemoteProviderConfiguration.Provider(rawValue: CommandLine.arguments[1]),
              let relay = URL(string: CommandLine.arguments[4]) else {
            throw RemoteFailure.invalid("Usage: remote-provider-live <claude|codex> <executable> <MarkView executable> <relay URL> <access-key file>")
        }
        let naturalEdit = CommandLine.arguments.last == "--natural-edit"
        let executable = CommandLine.arguments[2]
        let app = CommandLine.arguments[3]
        let resumeFixture = ProcessInfo.processInfo.environment["MARKVIEW_LIVE_RESUME_FIXTURE"].map { URL(fileURLWithPath: $0) }
        let fixture = resumeFixture ?? FileManager.default.temporaryDirectory.appendingPathComponent("mv-provider-live-" + UUID().uuidString)
        let workRoot = fixture.appendingPathComponent("work"), homeRoot = fixture.appendingPathComponent("home")
        if resumeFixture != nil {
            guard naturalEdit, fixture.lastPathComponent.hasPrefix("mv-provider-live-"),
                  fixture.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
                  try String(contentsOf: homeRoot.appendingPathComponent("identity.txt"), encoding: .utf8) == "HOME-UNTOUCHED\n",
                  try String(contentsOf: workRoot.appendingPathComponent("identity.txt"), encoding: .utf8).hasPrefix("WORK-") else {
                throw RemoteFailure.invalid("Resume only an existing temporary live-check fixture.")
            }
        }
        for root in [workRoot, homeRoot] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let marker = "WORK-" + UUID().uuidString
        let memory = "remember-" + UUID().uuidString
        try Data((marker + "\n").utf8).write(to: workRoot.appendingPathComponent("identity.txt"))
        try Data("HOME-UNTOUCHED\n".utf8).write(to: homeRoot.appendingPathComponent("identity.txt"))
        let invitation = try RemoteInvitation(relay: relay)
        let home = RemoteChannel(invitation: invitation, role: .home)
        let work = RemoteChannel(invitation: invitation, role: .work)
        let workspace = try await RemoteWorkspace(root: workRoot, deviceID: UUID().uuidString)
        let requests = RemoteToolRequests(channel: home)
        let audit = ToolAudit()
        let key = try String(contentsOfFile: CommandLine.arguments[5], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try await home.register(accessKey: key)
        let bridge = try RemoteToolBridge { id, name, arguments in await requests.call(id: id, name: name, arguments: arguments) }
        defer { bridge.stop() }
        let homeReceiver = Task {
            try await home.receive { message in
                if message.kind == "toolResult" { await requests.finish(message.id, result: message.payload) }
            }
        }
        let workReceiver = Task {
            try await work.receive { message in
                guard message.kind == "toolCall", let name = message.payload["name"].string else { throw RemoteFailure.invalid("Unexpected live-test request.") }
                await audit.record(name)
                let result = await workspace.call(id: message.id, name: name, arguments: message.payload["arguments"])
                try await work.send(RemoteMessage("toolResult", result, id: message.id))
            }
        }
        do {
            let context = await workspace.describe()
            func batchCommand(_ prompt: String, resume: Bool) async throws -> String {
                let threadID = provider == .codex && resume
                    ? try await RemoteCodexContext.prepare(executable: executable, directory: homeRoot, context: context) : nil
                var command = try RemoteProviderConfiguration.command(provider: provider, executable: executable, app: app,
                    socket: bridge.path, context: context, directory: homeRoot, model: ProcessInfo.processInfo.environment["MARKVIEW_LIVE_MODEL"], resume: resume,
                    resumeThreadID: threadID)
                // Exercise the production MCP and hook settings with the providers' batch interfaces.
                if provider == .claude {
                    command += " --print --output-format json --max-turns 16 " + RemoteProviderConfiguration.quote(prompt)
                } else {
                    if resume {
                        let selector = RemoteProviderConfiguration.quote(threadID ?? "--last")
                        command = command.replacingOccurrences(of: "'resume' " + selector, with: "'exec' 'resume' " + selector + " '--skip-git-repo-check' '--json'")
                    }
                    else { command += " exec --skip-git-repo-check --json" }
                    command += " " + RemoteProviderConfiguration.quote(prompt)
                }
                return command
            }
            if naturalEdit {
                let target = workRoot.appendingPathComponent("notes.md")
                if resumeFixture == nil {
                    try Data("# Architecture notes\n\nInitial draft.\n".utf8).write(to: target)
                    try await run(try await batchCommand("Read my local file at " + target.path + " and tell me its heading.", resume: false), directory: homeRoot)
                }
                try await run(try await batchCommand("Update that same local file: replace Initial draft. with Revised draft. and save the file. Please make the change directly.", resume: true), directory: homeRoot)
                let contents = try String(contentsOf: target, encoding: .utf8)
                print("Observed work tools: \(await audit.names().sorted())")
                guard contents.contains("Revised draft."), !contents.contains("Initial draft.") else {
                    throw RemoteFailure.invalid("The provider did not edit the user's work-computer file from a natural request.")
                }
                guard try String(contentsOf: homeRoot.appendingPathComponent("identity.txt"), encoding: .utf8) == "HOME-UNTOUCHED\n",
                      !FileManager.default.fileExists(atPath: homeRoot.appendingPathComponent("notes.md").path),
                      !(await audit.names()).isDisjoint(with: ["edit_file", "write_file", "exec_command"]) else {
                    throw RemoteFailure.invalid("A natural file-edit request must use WORK tools and leave HOME untouched.")
                }
                print("\(provider.title): natural absolute-path request and resumed file edit passed.")
                await requests.close(); await workspace.close(); await home.revoke(); await work.close()
                homeReceiver.cancel(); workReceiver.cancel()
                print("Fixture: \(fixture.path)")
                return
            }
            let prompt = """
            This is an end-to-end work-computer test. Use ONLY the markview_remote_workspace MCP tools.
            First call workspace_info, then read identity.txt. Use write_file to create result.txt
            containing the exact contents of that work-computer file. Use write_file to create
            edit.txt containing alpha, then use edit_file to replace alpha with beta.
            Run `git init -q && git status --short` on the WORK
            computer using exec_command, polling if needed until it exits. Do not inspect or modify
            the CLI transport directory or any native home file. Remember this phrase for our next
            conversation turn, without writing it into any file: \(memory). Finish with LIVE_CHECK_DONE.
            """
            try await run(try await batchCommand(prompt, resume: false), directory: homeRoot)
            FileHandle.standardOutput.write(Data(("Observed work tools: \(await audit.names().sorted())\n").utf8))
            let result = try String(contentsOf: workRoot.appendingPathComponent("result.txt"), encoding: .utf8)
            guard result.trimmingCharacters(in: .whitespacesAndNewlines) == marker,
                  FileManager.default.fileExists(atPath: workRoot.appendingPathComponent(".git").path),
                  try String(contentsOf: homeRoot.appendingPathComponent("identity.txt"), encoding: .utf8) == "HOME-UNTOUCHED\n",
                  !FileManager.default.fileExists(atPath: homeRoot.appendingPathComponent("result.txt").path),
                  !FileManager.default.fileExists(atPath: homeRoot.appendingPathComponent(".git").path) else { throw RemoteFailure.invalid("Work/home isolation did not hold.") }
            let names = await audit.names()
            guard names.isSuperset(of: ["workspace_info", "read_file", "write_file", "edit_file", "exec_command"]),
                  try String(contentsOf: workRoot.appendingPathComponent("edit.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "beta" else { throw RemoteFailure.invalid("The provider did not exercise all required work-computer tools.") }
            print("\(provider.title): real login, HTTPS MCP, work-file read/write, Git and home-file isolation passed.")
            let resumePrompt = "Use the work-computer write_file tool to create resumed.txt containing only the phrase I asked you to remember in our previous turn. Do not read any files or logs to recover it. Then finish."
            try await run(try await batchCommand(resumePrompt, resume: true), directory: homeRoot)
            let recalled = try String(contentsOf: workRoot.appendingPathComponent("resumed.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard recalled == memory else { throw RemoteFailure.invalid("The provider did not continue its previous conversation.") }
            print("\(provider.title): conversation continuation passed.")
            await requests.close(); await workspace.close(); await home.revoke(); await work.close()
            homeReceiver.cancel(); workReceiver.cancel()
            print("Fixture: \(fixture.path)")
        } catch {
            await requests.close(); await workspace.close(); await home.revoke(); await work.close()
            homeReceiver.cancel(); workReceiver.cancel()
            print("Failed fixture preserved: \(fixture.path)")
            throw error
        }
    }

    private static func run(_ command: String, directory: URL) async throws {
        let process = try RemoteCommand(command: command, directory: directory)
        process.closeInput()
        var output = ""
        for _ in 0..<180 {
            await process.wait(milliseconds: 1000)
            let snapshot = process.takeOutput()
            output += snapshot.output
            if output.utf8.count > 1_048_576 { output = String(output.suffix(524288)) }
            if let exit = snapshot.exitCode {
                let log = directory.deletingLastPathComponent().appendingPathComponent("provider-output-" + UUID().uuidString + ".log")
                try Data(output.utf8).write(to: log)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
                FileHandle.standardOutput.write(Data(("Provider output: \(log.path)\n").utf8))
                guard !output.contains("unsupported permissionDecision") else {
                    throw RemoteFailure.invalid("The provider rejected the tool guard's hook response.")
                }
                guard exit == 0 else {
                    print(String(output.suffix(6000)))
                    throw RemoteFailure.invalid("Provider CLI exited with code \(exit).")
                }
                return
            }
        }
        process.stop()
        print(String(output.suffix(6000)))
        throw RemoteFailure.invalid("Provider live test timed out.")
    }
}
