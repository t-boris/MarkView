import Darwin
import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

@MainActor private final class PersistentRemoteRecorder: TerminalConnectionObserver {
    var output = ""
    var exited = false
    var state = "not started"
    func connectionDidReceive(_ data: Data) { output += String(decoding: data, as: UTF8.self) }
    func connectionDidExit(_ code: Int32) { exited = true }
    func connectionDidChangeState(_ phase: RemoteConnectionState.Phase, detail: String) { state = "\(phase): \(detail)" }
}

/// The wrapper supplies a unique home, local echo executable and owned loopback relay.
final class PersistentRemoteHostTests: XCTestCase {
    @MainActor func testPersistentRemoteSessions() async throws {
        executionTimeAllowance = 240
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost", AgentProcesses.count == 0,
              let homePath = environment["MARKVIEW_PERSISTENT_TEST_HOME"],
              environment["CFFIXED_USER_HOME"] == homePath, environment["HOME"] == homePath,
              environment["SHELL"] == "/bin/sh", environment["ZDOTDIR"] == homePath,
              let fixturePath = environment["MARKVIEW_PERSISTENT_TEST_FIXTURE"],
              let idText = environment["MARKVIEW_PERSISTENT_TEST_ID"], let identifier = UUID(uuidString: idText),
              let relayText = environment["MARKVIEW_PERSISTENT_TEST_RELAY"], let relay = URL(string: relayText),
              relay.scheme == "http", relay.host == "127.0.0.1", let port = relay.port, (1...65535).contains(port) else {
            XCTFail("Persistent remote isolation is incomplete")
            return
        }
        let home = URL(fileURLWithPath: homePath).resolvingSymlinksInPath()
        let scratch = home.deletingLastPathComponent()
        let fixture = URL(fileURLWithPath: fixturePath).resolvingSymlinksInPath()
        let tmp = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
        guard home.lastPathComponent == "home", scratch.lastPathComponent.hasPrefix("mvpersist-test-"),
              scratch.deletingLastPathComponent().path == tmp.path,
              home.path == URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path,
              fixture.path == scratch.appendingPathComponent("fixture/echo.sh").path,
              FileManager.default.isExecutableFile(atPath: fixture.path),
              environment["MARKVIEW_SOCKET_DIR"].map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) == scratch.path,
              Int(try String(contentsOf: scratch.appendingPathComponent("relay.port"), encoding: .ascii)) == port else {
            XCTFail("Persistent remote fixture paths or relay are invalid")
            return
        }
        let support = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        guard support.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") else {
            XCTFail("Application Support must remain in the temporary home")
            return
        }
        let settings = Settings.standard
        let claude = try XCTUnwrap(CLITool(rawValue: "claude"))
        let codex = try XCTUnwrap(CLITool(rawValue: "codex"))
        let oldClaude = settings.stored(Setting.cliPath(claude.rawValue))
        let oldCodex = settings.stored(Setting.cliPath(codex.rawValue))
        let oldLinks = settings.stored(Setting.openTerminalLinksInApp)
        let oldClaudeTools = settings.stored(claude.agentToolsKey)
        let oldCodexTools = settings.stored(codex.agentToolsKey)
        let oldClaudeSel = settings.stored(Setting.mcpServiceSelections(claude.rawValue))
        let oldCodexSel = settings.stored(Setting.mcpServiceSelections(codex.rawValue))
        let oldClaudeMig = settings.stored(Setting.mcpServiceMigrated(claude.rawValue))
        let oldCodexMig = settings.stored(Setting.mcpServiceMigrated(codex.rawValue))
        defer {
            settings.set(oldClaude, for: Setting.cliPath(claude.rawValue))
            settings.set(oldCodex, for: Setting.cliPath(codex.rawValue))
            settings.set(oldLinks, for: Setting.openTerminalLinksInApp)
            settings.set(oldClaudeTools, for: claude.agentToolsKey)
            settings.set(oldCodexTools, for: codex.agentToolsKey)
            settings.set(oldClaudeSel, for: Setting.mcpServiceSelections(claude.rawValue))
            settings.set(oldCodexSel, for: Setting.mcpServiceSelections(codex.rawValue))
            settings.set(oldClaudeMig, for: Setting.mcpServiceMigrated(claude.rawValue))
            settings.set(oldCodexMig, for: Setting.mcpServiceMigrated(codex.rawValue))
        }
        CLIToolLocator.setOverride(fixturePath, for: claude)
        CLIToolLocator.setOverride(fixturePath, for: codex)
        settings.set(true, for: Setting.openTerminalLinksInApp)
        settings.set(true, for: claude.agentToolsKey)
        settings.set(true, for: codex.agentToolsKey)
        for tool in [claude, codex] {
            settings.set(true, for: Setting.mcpServiceMigrated(tool.rawValue))
            AgentMCPServices.saveSelections(AgentMCPSelectionRecord(selections: [
                AgentMCPServer.markviewName: true,
                AgentMCPServer.markviewBrowserName: true,
            ]), for: tool)
        }
        let resolvedClaude = await CLIToolLocator.resolveThorough(claude)
        let resolvedCodex = await CLIToolLocator.resolveThorough(codex)
        guard resolvedClaude == fixturePath, resolvedCodex == fixturePath else {
            XCTFail("Both providers must resolve to the isolated echo fixture")
            return
        }
        let suite = "com.markview.persistent-remote-tests." + identifier.uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); defaults.synchronize() }
        Settings(defaults).set(relayText, for: Setting.remoteRelayURL)
        let relaySettings = RemoteRelaySettings(defaults: defaults,
            keychain: RemoteRelayKeychain(service: "MarkView persistent remote tests " + identifier.uuidString))
        await relaySettings.finishPendingChanges()
        let first = try RemoteInvitation(relay: relay, persistent: true)
        let second = try RemoteInvitation(relay: relay, persistent: true)
        for _ in 0..<50 {
            let channel = RemoteChannel(invitation: first, role: .work)
            let receiver = Task { try? await channel.receive { _ in } }
            await Task.yield()
            await channel.close()
            _ = await receiver.value
        }
        let a = scratch.appendingPathComponent("a", isDirectory: true)
        let b = scratch.appendingPathComponent("b", isDirectory: true)
        for (folder, text) in [(a, "WORK A"), (b, "WORK B")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent("identity.txt"))
        }
        func wait(_ message: String, seconds: Double = 30, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            guard predicate() else { XCTFail(message); throw RemoteFailure.invalid(message) }
        }
        let workspaceA = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: scratch.appendingPathComponent("recent-a.json"))
        let workspaceB = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: scratch.appendingPathComponent("recent-b.json"))
        workspaceA.project.fileTree.rootNode = FileNode(url: a, isDirectory: true)
        workspaceB.project.fileTree.rootNode = FileNode(url: b, isDirectory: true)
        let windowA = UUID(), windowB = UUID()
        AgentToolServer.register(windowA, AgentToolWindow(workspace: { workspaceA }, root: { a }, browser: { _, _ in .init(text: "BROWSER " + windowA.uuidString) }))
        AgentToolServer.register(windowB, AgentToolWindow(workspace: { workspaceB }, root: { b }, browser: { _, _ in .init(text: "BROWSER " + windowB.uuidString) }))
        defer {
            AgentToolServer.unregister(windowA); AgentToolServer.unregister(windowB)
            workspaceA.composition.close(); workspaceB.composition.close()
            AgentToolServer.shutdown()
        }
        var readyA = false, readyB = false
        let homeA = RemoteHostController(relaySettings: relaySettings) { phase, _ in if phase == .waiting { readyA = true } }
        let homeB = RemoteHostController(relaySettings: relaySettings) { phase, _ in if phase == .waiting { readyB = true } }
        homeA.start(code: try first.code); homeB.start(code: try second.code)
        defer { homeA.suspend(); homeB.suspend() }
        try await wait("Both home endpoints register") { readyA && readyB }
        let workA = try await RemoteTerminalConnection(invitation: first, root: a, browserWindowID: windowA, provider: claude, model: nil, resume: true)
        let workB = try await RemoteTerminalConnection(invitation: second, root: b, browserWindowID: windowB, provider: codex, model: nil, resume: true)
        let recorderA = PersistentRemoteRecorder(), recorderB = PersistentRemoteRecorder()
        workA.observer = recorderA; workB.observer = recorderB
        workA.start(); workB.start()
        defer { workA.stop(); workB.stop() }
        do {
            try await wait("Both real terminal fixtures start") { recorderA.output.contains("SESSION_STARTED") && recorderB.output.contains("SESSION_STARTED") }
        } catch {
            print("Fixture state: home A=\(homeA.status); home B=\(homeB.status); work A=\(recorderA.state); work B=\(recorderB.state); output bytes=\(recorderA.output.utf8.count),\(recorderB.output.utf8.count); fixture PID file exists=\(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("children.pid").path))")
            throw error
        }
        workA.write("ECHO_A\n"); workB.write("ECHO_B\n")
        try await wait("Terminal streams stay isolated") {
            recorderA.output.contains("ECHO_A") && recorderB.output.contains("ECHO_B") && !recorderA.output.contains("ECHO_B")
        }
        let workspaces = support.appendingPathComponent("MarkView/RemoteWorkspaces", isDirectory: true)
        let folders = try FileManager.default.contentsOfDirectory(at: workspaces, includingPropertiesForKeys: nil)
        var identities: Set<String> = [], browsers: Set<String> = []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("mcp.json")),
                  let config = try? JSONDecoder().decode(RemoteJSON.self, from: data),
                  let socket = config["mcpServers"][RemoteWorkspaceTools.serverName]["args"].array?.last?.string else { continue }
            let file = await Task.detached { RemoteUnixRPC.call(socket: socket, id: UUID(), name: "read_file", arguments: .object(["path": .string("identity.txt")])) }.value
            let browser = await Task.detached { RemoteUnixRPC.call(socket: socket, id: UUID(), name: "browser_tabs", arguments: .object([:])) }.value
            identities.insert(file["content"].array?.first?["text"].string ?? "")
            browsers.insert(browser["content"].array?.first?["text"].string ?? "")
        }
        XCTAssertTrue(identities.contains { $0.contains("WORK A") } && identities.contains { $0.contains("WORK B") })
        XCTAssertEqual(browsers, Set(["BROWSER " + windowA.uuidString, "BROWSER " + windowB.uuidString]))
        let initialStarts = recorderA.output.components(separatedBy: "SESSION_STARTED").count
        homeA.suspend()
        let restarted = RemoteHostController(relaySettings: relaySettings)
        restarted.start(code: try first.code)
        defer { restarted.suspend() }
        try await wait("Restart restores the saved pairing") { recorderA.output.components(separatedBy: "SESSION_STARTED").count > initialStarts }
        var outage = URLRequest(url: relay.appendingPathComponent("test/outage")); outage.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: outage)
        let beforeA = recorderA.output.components(separatedBy: "SESSION_STARTED").count
        let beforeB = recorderB.output.components(separatedBy: "SESSION_STARTED").count
        try await wait("Both sessions recover after an outage", seconds: 45) {
            recorderA.output.components(separatedBy: "SESSION_STARTED").count > beforeA && recorderB.output.components(separatedBy: "SESSION_STARTED").count > beforeB
        }
        let revoker = RemoteChannel(invitation: first, role: .work)
        try await revoker.revokeAccess()
        try await wait("Revocation ends the first session") { recorderA.exited }
        workB.write("STILL_CONNECTED\n")
        try await wait("The other session remains connected") { recorderB.output.contains("STILL_CONNECTED") }
    }
}

/// Exercises the work-computer endpoint and its private Unix bridge in an isolated test host.
final class RemoteWorkspaceHostTests: XCTestCase {
    static func check(_ condition: Bool, _ message: String) { XCTAssertTrue(condition, message) }
    static func text(_ value: RemoteJSON) -> String { value["content"].array?.first?["text"].string ?? "" }
    static func session(_ result: RemoteJSON) -> String? {
        let text = text(result)
        return text.components(separatedBy: "session_id: ").dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// What the bridge at `path` answers to one raw request line; nil when it closes the connection without a reply.
    static func rawBridgeReply(_ path: String, line: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = PrivateSocket.address(path) else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0, RemoteUnixRPC.write(fd, line + Data([10])) else { return nil }
        return RemoteUnixRPC.readLine(fd)
    }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func expectFailure(_ message: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), message)
    }

    func testRemoteWorkspace() async throws {
        executionTimeAllowance = 180
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost", AgentProcesses.count == 0 else {
            XCTFail("The remote workspace test requires an isolated host with no registered child processes")
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
        Self.check(copy.room == invitation.room && copy.token(for: .home) == invitation.token(for: .home), "Pairing code must round-trip.")
        Self.check(copy.token(for: .work) != copy.token(for: .home), "Roles require different credentials.")
        let message = RemoteMessage("input", .string("Привет 🌍"))
        let sealed = try invitation.seal(message, sender: .work)
        Self.check(!(Data(base64Encoded: sealed).map { String(decoding: $0, as: UTF8.self).contains("Привет") } ?? true), "The relay must not see plaintext.")
        let opened = try copy.open(sealed, sender: .work)
        Self.check(opened.id == message.id && opened.payload == message.payload, "Authenticated messages must round-trip.")
        Self.expectFailure("A reflected message must fail role authentication.") { _ = try copy.open(sealed, sender: .home) }
        let other = try RemoteInvitation(relay: invitation.relay)
        Self.expectFailure("A different room cannot decrypt a message.") { _ = try other.open(sealed, sender: .work) }
        Self.expectFailure("External plaintext HTTP must be rejected.") { _ = try RemoteInvitation(relay: URL(string: "http://relay.example.com")!) }
        Self.expectFailure("Credentials in a URL must be rejected.") { _ = try RemoteInvitation(relay: URL(string: "https://user:password@relay.example.com")!) }
        Self.expectFailure("Invalid codes must be rejected.") { _ = try RemoteInvitation(code: "not a connection") }
        _ = try RemoteInvitation(relay: URL(string: "http://127.0.0.1:8787")!)
        let largeMessage = RemoteMessage("toolResult", .string(String(repeating: "large image or file data;", count: 100000)))
        let frames = try RemoteFraming.frames(for: largeMessage)
        Self.check(frames.count > 1, "Large tool results must be framed for serverless payload limits.")
        var assembler = RemoteReassembler(), assembled: RemoteMessage?
        for frame in frames {
            let box = try invitation.seal(frame, sender: .home)
            Self.check(box.utf8.count <= RemoteFraming.maxEncryptedBytes, "Every encrypted frame must fit the serverless request limit.")
            assembled = try assembler.accept(invitation.open(box, sender: .home))
        }
        Self.check(assembled?.id == largeMessage.id && assembled?.payload == largeMessage.payload, "Framing must retain the original tool ID and complete contents.")
        let retried = try assembler.accept(frames.last!)
        Self.check(retried?.id == largeMessage.id, "The final frame must remain retryable until the application acknowledges it.")
        assembler.acknowledge(largeMessage.id)
        let replayed = try assembler.accept(frames[0])
        Self.check(replayed == nil, "A completed operation must not be delivered again under new transport retries.")

        let workspace = try await RemoteWorkspace(root: workRoot, deviceID: UUID().uuidString)
        @Sendable func call(_ name: String, _ args: [String: RemoteJSON] = [:], id: UUID = UUID()) async -> RemoteJSON {
            await workspace.call(id: id, name: name, arguments: .object(args))
        }
        func commandOutputUntilExit(_ first: RemoteJSON) async -> String {
            var current = first, output = Self.text(first)
            for _ in 0..<10 {
                guard let id = Self.session(current) else { return output }
                current = await call("write_stdin", ["session_id": .string(id), "yield_time_ms": .int(1000)])
                output += "\n" + Self.text(current)
            }
            fatalError("The test command did not finish: \(output)")
        }
        let read = await call("read_file", ["path": .string("identity.txt")])
        Self.check(Self.text(read).contains("WORK ONLY") && !Self.text(read).contains("HOME ONLY"), "The workspace must read the work file, never its home namesake.")
        let absolute = await call("read_file", ["path": .string(workRoot.appendingPathComponent("identity.txt").path)])
        Self.check(Self.text(read) == Self.text(absolute), "Absolute work paths must resolve to the same file.")
        let escaped = await call("read_file", ["path": .string("escape/identity.txt")])
        Self.check(escaped["isError"].bool == true, "File reads must reject symlink escapes.")
        let traversal = await call("write_file", ["path": .string("../home/identity.txt"), "content": .string("bad")])
        Self.check(traversal["isError"].bool == true, "File writes must reject path traversal.")
        let writeID = UUID()
        _ = await call("write_file", ["path": .string("new/file.txt"), "content": .string("alpha alpha")], id: writeID)
        let ambiguous = await call("edit_file", ["path": .string("new/file.txt"), "old_text": .string("alpha"), "new_text": .string("beta")])
        Self.check(ambiguous["isError"].bool == true, "Edits must refuse ambiguous matches.")
        let edit = await call("edit_file", ["path": .string("new/file.txt"), "old_text": .string("alpha"), "new_text": .string("beta"), "replace_all": .bool(true)])
        Self.check(edit["isError"].bool == false, "Explicit replace-all must work.")
        _ = await call("write_file", ["path": .string("new/file.txt"), "content": .string("alpha alpha")], id: writeID)
        Self.check(try String(contentsOf: workRoot.appendingPathComponent("new/file.txt"), encoding: .utf8) == "beta beta", "Retrying a previous write must not overwrite subsequent edits.")

        let bounded = try await RemoteWorkspace(root: workRoot, deviceID: UUID().uuidString, resultCacheBytes: 0)
        let oldID = UUID()
        _ = await bounded.call(id: oldID, name: "write_file", arguments: .object(["path": .string("cache.txt"), "content": .string("first")]))
        _ = await bounded.call(id: UUID(), name: "write_file", arguments: .object(["path": .string("cache.txt"), "content": .string("second")]))
        let expiredRetry = await bounded.call(id: oldID, name: "write_file", arguments: .object(["path": .string("cache.txt"), "content": .string("first")]))
        let afterExpiredRetry = try String(contentsOf: workRoot.appendingPathComponent("cache.txt"), encoding: .utf8)
        Self.check(expiredRetry["isError"].bool == true && afterExpiredRetry == "second", "Evicting a cached result must never replay a completed write.")
        await bounded.close()
        try Data(repeating: 1, count: 1024 * 1024).write(to: workRoot.appendingPathComponent("control-characters.txt"))
        let oversized = await call("read_file", ["path": .string("control-characters.txt")])
        Self.check(oversized["isError"].bool == true && Self.text(oversized).contains("Read a smaller portion"), "JSON escaping must not turn a bounded file into an oversized transport message.")

        let shell = await call("exec_command", ["cmd": .string("pwd; cat identity.txt; printf built > build.txt; /usr/bin/git init -q"), "yield_time_ms": .int(1000)])
        let shellOutput = await commandOutputUntilExit(shell)
        Self.check(shellOutput.contains("WORK ONLY") && shellOutput.contains(workRoot.path), "Commands must execute in the work-computer root.")
        Self.check(shellOutput.contains("Exit code: 0") && FileManager.default.fileExists(atPath: workRoot.appendingPathComponent(".git").path), "Git must run on the work computer: \(shellOutput)")
        Self.check(!FileManager.default.fileExists(atPath: homeRoot.appendingPathComponent("build.txt").path), "Commands must leave the home fixture unchanged.")
        let dedupeID = UUID()
        let dedupeArgs: [String: RemoteJSON] = ["cmd": .string("printf x >> once.txt; sleep 0.1"), "yield_time_ms": .int(1000)]
        async let a = call("exec_command", dedupeArgs, id: dedupeID)
        async let b = call("exec_command", dedupeArgs, id: dedupeID)
        let pair = await (a, b)
        Self.check(pair.0 == pair.1, "Concurrent duplicate requests must share one command result.")
        Self.check(try String(contentsOf: workRoot.appendingPathComponent("once.txt"), encoding: .utf8) == "x", "A retried command must execute exactly once.")

        let large = await call("exec_command", ["cmd": .string("/usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' x; printf FINAL_MARKER"), "yield_time_ms": .int(2000)])
        Self.check(Self.text(large).contains("FINAL_MARKER") && Self.text(large).contains("Exit code: 0"), "Large pipe output must drain completely without deadlocking or losing the tail.")
        let running = await call("exec_command", ["cmd": .string("read reply; printf 'REPLY:%s' \"$reply\""), "yield_time_ms": .int(0)])
        Self.check(Self.session(running) != nil, "A running command must return a session ID.")
        let input = await call("write_stdin", ["session_id": .string(Self.session(running)!), "chars": .string("from work\n"), "yield_time_ms": .int(1000)])
        Self.check(Self.text(input).contains("REPLY:from work") && Self.text(input).contains("Exit code: 0"), "Command input and completion must use the same work process.")
        let counter = await call("exec_command", ["cmd": .string("/usr/bin/wc -c"), "yield_time_ms": .int(0)])
        let countResult = await call("write_stdin", ["session_id": .string(Self.session(counter)!), "chars": .string(String(repeating: "x", count: 60000)), "close_stdin": .bool(true), "yield_time_ms": .int(2000)])
        Self.check(Self.text(countResult).contains("60000") && Self.text(countResult).contains("Exit code: 0"), "Large stdin must drain under backpressure before EOF.")
        let sleeper = await call("exec_command", ["cmd": .string("sleep 30"), "yield_time_ms": .int(0)])
        let stopped = await call("write_stdin", ["session_id": .string(Self.session(sleeper)!), "terminate": .bool(true), "yield_time_ms": .int(1000)])
        Self.check(Self.text(stopped).contains("Exit code:"), "Stopping a command must terminate it.")

        // Browser calls use the work endpoint and the same retry/size/disconnect rules as writes.
        actor BrowserFixture {
            var clicks = 0
            func call(_ name: String, _ args: RemoteJSON) -> RemoteJSON {
                if name == "browser_click" { clicks += 1 }
                if name == "browser_screenshot" {
                    return .object(["content": .array([.object(["type": .string("image"),
                        "mimeType": .string("image/png"), "data": .string("work-image")])]), "isError": .bool(false)])
                }
                return .textResult("WORK tab T2: " + name + " " + (args["tab"].string ?? "active"))
            }
            func count() -> Int { clicks }
        }
        let browser = BrowserFixture()
        let browserWorkspace = try await RemoteWorkspace(root: workRoot, browserCall: { name, args in
            await browser.call(name, args)
        })
        let tabs = await browserWorkspace.call(id: UUID(), name: "browser_tabs", arguments: .object([:]))
        Self.check(Self.text(tabs).contains("WORK tab T2"), "Browser discovery must reach the work endpoint.")
        let clickID = UUID(), clickArgs = RemoteJSON.object(["tab": .string("T2"), "ref": .string("e1")])
        async let clickA = browserWorkspace.call(id: clickID, name: "browser_click", arguments: clickArgs)
        async let clickB = browserWorkspace.call(id: clickID, name: "browser_click", arguments: clickArgs)
        let clicks = await (clickA, clickB)
        let clickCount = await browser.count()
        Self.check(clicks.0 == clicks.1 && Self.text(clicks.0).contains("T2") && clickCount == 1, "Retried browser mutations must execute once and retain the target tab.")
        let screenshot = await browserWorkspace.call(id: UUID(), name: "browser_screenshot", arguments: .object([:]))
        Self.check(screenshot["content"].array?.first?["data"].string == "work-image", "Screenshot MCP image blocks must survive unchanged.")
        let noBrowser = await call("browser_tabs")
        Self.check(noBrowser["isError"].bool == true, "Missing window bindings must fail without using a home browser.")
        await browserWorkspace.close()
        let afterClose = await browserWorkspace.call(id: UUID(), name: "browser_click", arguments: clickArgs)
        let closedClicks = await browser.count()
        Self.check(afterClose["isError"].bool == true && closedClicks == 1, "Disconnected browser calls must not execute.")

        let listed = RemoteWorkspaceTools.response(to: .object(["id": .int(1), "method": .string("tools/list")])) { _, _, _ in .null }
        Self.check(listed?["result"]["tools"].array?.count == RemoteWorkspaceTools.names.count, "Both providers must discover the complete workspace interface.")
        let advertised = listed?["result"]["tools"].array ?? []
        Self.check(Set(advertised.compactMap { $0["name"].string }).isSuperset(of: BrowserAgentTools.tools.map(\.name)), "Both providers must discover every shipping browser tool.")
        Self.check(advertised.filter { $0["name"].string?.hasPrefix("browser_") == true }.allSatisfy {
            $0["inputSchema"]["properties"]["project_folder"] == .null
        }, "Remote browser tools must not route using an agent's home folder.")
        let browserRPC = RemoteWorkspaceTools.response(to: .object(["id": .int(7), "method": .string("tools/call"),
            "params": .object(["name": .string("browser_snapshot"), "arguments": .object(["tab": .string("T2")])])])) { _, name, args in
                .textResult(name + " " + (args["tab"].string ?? ""))
            }
        Self.check(Self.text(browserRPC?["result"] ?? .null) == "browser_snapshot T2", "The stdio MCP dispatcher must forward browser calls and arguments.")
        Self.check(["Bash", "Read", "Write", "Edit", "apply_patch", "exec_command", "shell_command", "mcp__work__read_file", ""].allSatisfy {
            RemoteUnixRPC.guardResponse(for: $0)["hookSpecificOutput"]["permissionDecision"].string == "deny"
        }, "Both providers must receive a supported denial for native home tools and malformed names.")
        Self.check([RemoteWorkspaceTools.toolPrefix + "read_file", "AskUserQuestion", "update_plan"].allSatisfy {
            RemoteUnixRPC.guardResponse(for: $0) == .object([:])
        }, "Allowed tools must use a neutral hook result accepted by both Claude and Codex.")
        let context = await workspace.describe()
        var hostBytes = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        XCTAssertEqual(gethostname(&hostBytes, hostBytes.count - 1), 0)
        let expectedHost = String(decoding: hostBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        XCTAssertEqual(context["hostname"].string, expectedHost)
        Self.check(context["computer"].string == "work" && context["file_tools"]["root_writable"].bool == true,
              "Workspace info must identify the work computer and report its actual writable root.")
        Self.check(context["file_tools"]["write_operations"].array == [.string("write_file"), .string("edit_file")],
              "The work endpoint must advertise its file-edit capabilities independently of the home sandbox.")
        for provider in RemoteProviderConfiguration.tools {
            let command = try RemoteProviderConfiguration.command(tool: provider, executable: "/test/agent", app: "/test/MarkView's App",
                socket: fixture.appendingPathComponent("bridge.sock").path, context: context, directory: fixture, model: "model; touch /unwanted", resume: false)
            Self.check(command.contains("--remote-workspace-guard") || provider.rawValue == "claude", "Codex must configure the native-tool guard.")
            Self.check(!command.contains("--dangerously-bypass-approvals-and-sandbox"), "Codex native execution must retain its sandbox.")
            Self.check(command.contains("'model; touch /unwanted'"), "Model values must remain one quoted argument.")
            if provider.rawValue == "codex" {
                Self.check(command.contains("'--sandbox' 'read-only'") && command.contains("'--cd' " + RemoteProviderConfiguration.quote(fixture.path)),
                      "Codex must retain native read-only access in the transport directory.")
                let server = "mcp_servers." + RemoteWorkspaceTools.serverName
                Self.check(command.contains(server + ".required=true") && command.contains(server + ".default_tools_approval_mode=\"approve\""), "Codex must require and authorize the owned work MCP server without prompting in never-approval mode.")
            }
        }
        let settings = try JSONDecoder().decode(RemoteJSON.self, from: Data(contentsOf: fixture.appendingPathComponent("claude-settings.json")))
        Self.check(settings["hooks"]["PreToolUse"].array?.count == 1, "Claude must have the same fail-closed native-tool guard.")
        let config = try JSONDecoder().decode(RemoteJSON.self, from: Data(contentsOf: fixture.appendingPathComponent("mcp.json")))
        Self.check(config["mcpServers"][RemoteWorkspaceTools.serverName]["args"].array?.first?.string == "--remote-workspace-mcp", "MCP configuration must use this app's embedded bridge.")
        let quitCommand = await call("exec_command", ["cmd": .string("sleep 30"), "yield_time_ms": .int(0)])
        guard let quitSession = Self.session(quitCommand), AgentProcesses.count == 1 else {
            await workspace.close()
            XCTFail("The isolated test must own exactly one registered child before testing shutdown")
            return
        }
        AgentProcesses.terminateAll(grace: 0.2)
        let quitResult = await call("write_stdin", ["session_id": .string(quitSession), "yield_time_ms": .int(1000)])
        Self.check(Self.text(quitResult).contains("Exit code:"), "App termination must stop work-computer commands through the shared process registry.")
        print("Remote workspace core checks passed.")
        if ProcessInfo.processInfo.environment["MARKVIEW_REMOTE_CORE_ONLY"] != "1" {
            let bridge = try RemoteToolBridge { id, name, args in await workspace.call(id: id, name: name, arguments: args) }
            defer { bridge.stop() }
            let viaBridge = await Task.detached {
                RemoteUnixRPC.call(socket: bridge.path, id: UUID(), name: "read_file", arguments: .object(["path": .string("identity.txt")]))
            }.value
            let browserBridge = try RemoteToolBridge { _, name, args in await browser.call(name, args) }
            defer { browserBridge.stop() }
            let viaBrowserBridge = await Task.detached {
                RemoteUnixRPC.call(socket: browserBridge.path, id: UUID(), name: "browser_snapshot", arguments: .object(["tab": .string("T2")]))
            }.value
            Self.check(Self.text(viaBrowserBridge).contains("browser_snapshot T2"), "The real Unix bridge must accept browser tool names.")
            Self.check(Self.text(viaBridge).contains("WORK ONLY"), "The real per-session Unix bridge must reach the selected workspace.")
            // AR-40: the bridge serves only a caller that holds its token; every other request is closed unanswered.
            let served = Counter()
            let guarded = try RemoteToolBridge { _, name, _ in served.increment(); return .textResult("served " + name) }
            defer { guarded.stop() }
            let guardedPath = guarded.path
            let call = RemoteMessage("toolCall", .object(["name": .string("read_file"), "arguments": .object(["path": .string("identity.txt")])]))
            let token = PrivateSocket.readToken(forSocket: guardedPath) ?? ""
            let tokenMode = (try? FileManager.default.attributesOfItem(atPath: PrivateSocket.tokenPath(forSocket: guardedPath))[.posixPermissions] as? NSNumber)?.intValue
            let socketMode = (try? FileManager.default.attributesOfItem(atPath: guardedPath)[.posixPermissions] as? NSNumber)?.intValue
            Self.check(token.count == 64 && tokenMode == 0o600 && socketMode == 0o600, "The bridge socket and its 256-bit token file are private to this user.")
            let withoutToken = try JSONEncoder().encode(call)
            let wrongToken = try JSONEncoder().encode(RemoteBridgeRequest(token: "wrong", message: call))
            let emptyToken = try JSONEncoder().encode(RemoteBridgeRequest(token: "", message: call))
            let rightToken = try JSONEncoder().encode(RemoteBridgeRequest(token: token, message: call))
            let replies = await Task.detached { [withoutToken, wrongToken, emptyToken, rightToken] in
                (Self.rawBridgeReply(guardedPath, line: withoutToken), Self.rawBridgeReply(guardedPath, line: wrongToken),
                 Self.rawBridgeReply(guardedPath, line: emptyToken), served.count, Self.rawBridgeReply(guardedPath, line: rightToken))
            }.value
            Self.check(replies.0 == nil && replies.1 == nil && replies.2 == nil && replies.3 == 0,
                  "A bridge request without the token, with a wrong one or an empty one is closed unanswered and never reaches the handler.")
            Self.check(replies.4.flatMap { try? JSONDecoder().decode(RemoteJSON.self, from: $0) }.map(Self.text)?.contains("served read_file") == true && served.count == 1,
                  "A bridge request with the token is served.")
            let tokenFile = PrivateSocket.tokenPath(forSocket: guardedPath)
            guarded.stop()
            Self.check(!FileManager.default.fileExists(atPath: guardedPath) && !FileManager.default.fileExists(atPath: tokenFile),
                  "Stopping the bridge removes its socket and token file.")
        } else { print("Unix bridge integration not run (--core-only).") }
        await workspace.close()
        let closed = await call("exec_command", ["cmd": .string("touch must-not-run")])
        Self.check(closed["isError"].bool == true && !FileManager.default.fileExists(atPath: workRoot.appendingPathComponent("must-not-run").path), "Disconnected workspaces must refuse commands.")
        print("Remote workspace checks passed.")
    }
}
