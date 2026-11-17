import Combine
import Foundation
import Darwin
import MarkViewCore
import os
import XCTest
@testable import MarkView

/// Checks that a Git remote is recognized as GitHub through an SSH host alias, and that a
/// folder's `gh` configuration directory is resolved from its `.ghprofile`.
private enum GitHubRemoteProfileChecks {
    static func run() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mv-github-remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try remotesWithoutAliases(home: home)
        try aliasedRemotes(home: home)
        let suite = "github-profile-host-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try profiles(home: home, settings: Settings(defaults))
    }

    // MARK: Remotes

    static func remotesWithoutAliases(home: URL) throws {
        let expected: [String: String?] = [
            "git@github.com:owner/name.git": "owner/name",
            "https://github.com/owner/name.git": "owner/name",
            "https://github.com/owner/name": "owner/name",
            "ssh://git@github.com/owner/name.git": "owner/name",
            "git@gitlab.com:owner/name.git": nil,
            "https://example.com/owner/name.git": nil
        ]
        for (url, slug) in expected {
            let actual = GitHubClient.slug(fromRemoteURL: url, home: home)
            XCTAssertTrue(actual == slug, "\(url) resolved to \(actual ?? "nil"), expected \(slug ?? "nil")")
        }
    }

    static func aliasedRemotes(home: URL) throws {
        let config = """
            # A personal identity reached through an alias.
            Host github-personal
              HostName github.com
              User git

            Host gl-*
              HostName gitlab.com

            Include config.d/*.conf
            """
        try config.write(to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh/config.d"), withIntermediateDirectories: true)
        try "Host gh-work\n  HostName github.com\n"
            .write(to: home.appendingPathComponent(".ssh/config.d/work.conf"), atomically: true, encoding: .utf8)

        XCTAssertTrue(SSHHostAliases.resolve("github-personal", home: home) == "github.com")
        XCTAssertTrue(SSHHostAliases.resolve("gh-work", home: home) == "github.com", "An Include'd file must be read.")
        XCTAssertTrue(SSHHostAliases.resolve("gl-main", home: home) == "gitlab.com", "A wildcard Host pattern must match.")
        XCTAssertTrue(SSHHostAliases.resolve("unknown-host", home: home) == "unknown-host")
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            XCTAssertTrue(SSHHostAliases.resolve("gh-work", home: home) == "github.com", "Concurrent cache reads must agree.")
        }

        XCTAssertTrue(GitHubClient.slug(fromRemoteURL: "git@github-personal:owner/name.git", home: home) == "owner/name")
        XCTAssertTrue(GitHubClient.slug(fromRemoteURL: "ssh://git@gh-work/owner/name.git", home: home) == "owner/name")
        XCTAssertTrue(GitHubClient.slug(fromRemoteURL: "git@gl-main:owner/name.git", home: home) == nil,
                     "An alias that is not GitHub must stay unrecognized.")

        // An edited configuration is picked up rather than served from the cache.
        try (config + "\nHost later\n  HostName github.com\n")
            .write(to: home.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SSHHostAliases.resolve("later", home: home) == "github.com", "A changed ~/.ssh/config must be re-read.")
    }

    // MARK: Profiles

    static func profiles(home: URL, settings: Settings) throws {
        let project = home.appendingPathComponent("Projects/app")
        let nested = project.appendingPathComponent("docs/features")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertTrue(GitHubProfile.resolve(root: project, home: home, settings: settings).directory == nil,
                     "Without a marker file gh keeps its own configuration.")

        try "personal\n".write(to: project.appendingPathComponent(".ghprofile"), atomically: true, encoding: .utf8)
        XCTAssertTrue(GitHubProfile.resolve(root: project, home: home, settings: settings).directory == nil,
                     "A marker naming a profile that does not exist must not invent a directory.")

        let profile = home.appendingPathComponent(".config/gh-profiles/personal")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let resolved = GitHubProfile.resolve(root: project, home: home, settings: settings)
        XCTAssertTrue(resolved.directory?.path == profile.path, "The profile directory must come from .ghprofile.")
        XCTAssertTrue(resolved.name == "personal")
        XCTAssertTrue(GitHubProfile.resolve(root: nested, home: home, settings: settings).directory?.path == profile.path,
                     "A subfolder follows the marker of the folder above it.")

        try "GHP_SSH_KEY=\"~/.ssh/id_personal\"\nGHP_TOKEN='secret-token' # inline\n"
            .write(to: profile.appendingPathComponent("profile.env"), atomically: true, encoding: .utf8)
        let withEnvironment = GitHubProfile.resolve(root: project, home: home, settings: settings)
        XCTAssertTrue(withEnvironment.token == "secret-token", "Quotes and trailing comments must be stripped.")
        XCTAssertTrue(withEnvironment.sshCommand == "ssh -i \(home.path)/.ssh/id_personal -o IdentitiesOnly=yes")

        var environment = ["GITHUB_TOKEN": "inherited", "PATH": "/usr/bin"]
        GitHubProfile.apply(to: &environment, root: project, home: home, settings: settings)
        XCTAssertTrue(environment["GH_CONFIG_DIR"] == profile.path)
        XCTAssertTrue(environment["GITHUB_TOKEN"] == "secret-token")
        XCTAssertTrue(environment["PATH"] == "/usr/bin")

        // A profile without a token must drop an inherited one: it belongs to another account.
        try "".write(to: profile.appendingPathComponent("profile.env"), atomically: true, encoding: .utf8)
        var inherited = ["GITHUB_TOKEN": "inherited"]
        GitHubProfile.apply(to: &inherited, root: project, home: home, settings: settings)
        XCTAssertTrue(inherited["GITHUB_TOKEN"] == nil, "An inherited token would override the profile's own credentials.")

        // An explicit setting wins over the folder's marker.
        let chosen = home.appendingPathComponent("chosen-config")
        settings.set(chosen.path, for: Setting.gitHubConfigDirectory)
        XCTAssertTrue(GitHubProfile.resolve(root: project, home: home, settings: settings).directory?.path == chosen.path)
        settings.remove(Setting.gitHubConfigDirectory)
    }
}

extension EditorHostTests {
    func testControlAgentToolsAndSockets() throws {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + detail, line: line)
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-control-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        let previous = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        setenv("MARKVIEW_SOCKET_DIR", socketDirectory.path, 1)
        defer {
            if let previous { setenv("MARKVIEW_SOCKET_DIR", previous, 1) } else { unsetenv("MARKVIEW_SOCKET_DIR") }
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        guard BrowserAgentTools.socketFolder == socketDirectory.path else {
            XCTFail("The control socket fixture is not isolated")
            return
        }
        // MARK: Tools

        let tools = ControlAgentTools.tools
        let names = tools.map(\.name)
        check(names.count == 18 && Set(names).count == 18, "eighteen distinct tools", "\(names)")
        check(names.allSatisfy { $0.hasPrefix("markview_") }, "every tool is prefixed")
        check(tools.allSatisfy { !$0.description.isEmpty }, "every tool is described")
        check(tools.allSatisfy { tool in tool.required.allSatisfy { tool.properties[$0] != nil } }, "required arguments are declared")
        let projectNames = Set(ProjectAgentTools.tools.map(\.name)), browserNames = Set(BrowserAgentTools.tools.map(\.name))
        check(ControlAgentTools.names.isDisjoint(with: projectNames) && ControlAgentTools.names.isDisjoint(with: browserNames),
              "no control tool shares a name with a project or browser tool (the app tells them apart by name)")
        let schemas = tools.map(\.json)
        check(schemas.allSatisfy { (($0["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["project_folder"] == nil },
              "control tools are addressed by window, not by project_folder")
        check(ProjectAgentTools.tools.first!.json["inputSchema"].flatMap { ($0 as? [String: Any])?["properties"] as? [String: Any] }?["project_folder"] == nil,
              "project tools do not accept a client-selected folder")
        for name in ["markview_flow_implement", "markview_flow_fix_bug"] {
            check(tools.first { $0.name == name }!.required.contains("by_user"), "\(name) needs the person's word")
        }
        check(tools.first { $0.name == "markview_flow_answer" }!.required == ["feature"], "an answer names its feature; by_user is checked against what is answered")
        check(ControlAgentTools.FlowStep.allCases.map(\.rawValue) == ["explore", "decide_rest", "finish_explore", "review", "resolve", "ready", "plan", "issues"],
              "the steps of the flow, in order")
        check(ControlAgentTools.FlowStep.finishExplore.needsPerson && ControlAgentTools.FlowStep.issues.needsPerson
              && !ControlAgentTools.FlowStep.explore.needsPerson && !ControlAgentTools.FlowStep.resolve.needsPerson,
              "approving requirements and filing issues are the person's; the AI's own steps are not")
        let step = tools.first { $0.name == "markview_flow_run" }!
        check((step.properties["step"]?["enum"] as? [String]) == ControlAgentTools.FlowStep.allCases.map(\.rawValue), "the step argument lists every step")
        let start = tools.first { $0.name == "markview_agent_start" }!
        check((start.properties["tool"]?["enum"] as? [String]) == ["claude", "codex", "cline", "copilot", "antigravity"], "an agent is one of the five assistants")
        check(ControlAgentTools.profile.alwaysListsTools && ControlAgentTools.profile.probeTool == "markview_windows" && ControlAgentTools.profile.rechecksApp,
              "the control profile always lists its tools and looks for the app with every message")
        check(!ProjectAgentTools.profile.alwaysListsTools && !BrowserAgentTools.browserProfile.alwaysListsTools, "the other profiles hide their tools without the app")
        check(BrowserAgentTools.fanOutTools == ["markview_windows"], "only the window list is asked of every running MarkView")

        // MARK: Guide

        for topic in ControlAgentTools.guideTopics { check(ControlAgentTools.guide(topic).count > 200, "guide \(topic) has text") }
        check(Set(ControlAgentTools.guideTopics.map(ControlAgentTools.guide)).count == ControlAgentTools.guideTopics.count, "guide topics differ")
        check(ControlAgentTools.guide(nil) == ControlAgentTools.guide("overview") && ControlAgentTools.guide("zzz") == ControlAgentTools.guide("overview"), "the overview is the default")
        check(names.allSatisfy { name in ControlAgentTools.guideTopics.contains { ControlAgentTools.guide($0).contains(name) } || name == "markview_control_guide" || name == "markview_focus_window" || name == "markview_recent_projects" || name == "markview_flow_fix_bug" || name == "markview_flow_stop" },
              "the guide names the tools it teaches")
        check(ControlAgentTools.guide("safety").contains("by_user: true") && ControlAgentTools.guide("safety").contains("full access"), "the safety guide says what is the person's and what agents can do")
        check(ControlAgentTools.instructions.contains("markview_control_guide"), "the server's instructions point to the guide")

        // MARK: Choosing a window

        let a = "3F2A9C41-0000-4000-8000-000000000001", b = "B07E55D2-0000-4000-8000-000000000002", c = "B07E1111-0000-4000-8000-000000000003"
        let windows: [(id: String, title: String, project: String?)] = [
            (a, "MarkView 4.55 — shop", "/Users/me/work/shop"),
            (b, "MarkView 4.55 — blog", "/Users/me/work/blog"),
            (c, "MarkView 4.55", nil),
        ]
        check(ControlAgentTools.pickWindow("3f2a", among: windows, callerFolder: nil) == .one(0), "a window by the start of its id")
        check(ControlAgentTools.pickWindow("3F2A9C41-0000", among: windows, callerFolder: nil) == .one(0), "a window by its full id, upper case")
        check(ControlAgentTools.pickWindow("b07e", among: windows, callerFolder: nil) == .many([1, 2]), "an id start shared by two windows is ambiguous")
        check(ControlAgentTools.pickWindow("/Users/me/work/blog", among: windows, callerFolder: nil) == .one(1), "a window by its project folder")
        check(ControlAgentTools.pickWindow("/Users/me/work/blog/", among: windows, callerFolder: nil) == .one(1), "…with a trailing slash")
        check(ControlAgentTools.pickWindow("shop", among: windows, callerFolder: nil) == .one(0), "a window by its project's name")
        check(ControlAgentTools.pickWindow("blog", among: windows, callerFolder: nil) == .one(1), "…or a part of its title")
        check(ControlAgentTools.pickWindow("work", among: windows, callerFolder: nil) == .many([0, 1]), "a part of a folder shared by two projects is ambiguous")
        check(ControlAgentTools.pickWindow("zzz", among: windows, callerFolder: nil) == .none, "no match")
        check(ControlAgentTools.pickWindow("", among: windows, callerFolder: nil) == .many([0, 1, 2]), "several windows and no query: ambiguous")
        check(ControlAgentTools.pickWindow("", among: [windows[1]], callerFolder: nil) == .one(0), "one window needs no query")
        check(ControlAgentTools.pickWindow("", among: [], callerFolder: nil) == .none, "no window at all")
        check(ControlAgentTools.pickWindow("", among: windows, callerFolder: "/Users/me/work/shop/src") == .one(0), "no query: the window whose project holds the caller's folder")
        check(ControlAgentTools.pickWindow("", among: windows, callerFolder: "/Users/me/work/shopping") == .many([0, 1, 2]), "…a sibling folder with the same prefix is not inside it")
        check(ControlAgentTools.pickWindow("", among: [(a, "x", "/Users/me/work"), (b, "y", "/Users/me/work/shop")], callerFolder: "/Users/me/work/shop/app") == .one(1),
              "…the deepest project wins")
        check(ControlAgentTools.shortID(a) == "3f2a9c41" && ControlAgentTools.shortID("ABC") == "abc", "the short id is eight characters, lower case")

        // MARK: Choosing a terminal

        let terminals: [(id: String, tool: String, title: String)] = [
            ("11111111-0000-4000-8000-000000000001", "claude", "Claude Code · opus"),
            ("22222222-0000-4000-8000-000000000002", "codex", "Codex · gpt-5"),
            ("33333333-0000-4000-8000-000000000003", "claude", "Claude Code 2 · sonnet"),
        ]
        check(ControlAgentTools.pickTerminal("2222", among: terminals, shown: nil) == .one(1), "a terminal by the start of its id")
        check(ControlAgentTools.pickTerminal("codex", among: terminals, shown: nil) == .one(1), "a terminal by its tool")
        check(ControlAgentTools.pickTerminal("claude", among: terminals, shown: nil) == .many([0, 2]), "a tool run twice is ambiguous")
        check(ControlAgentTools.pickTerminal("code 2", among: terminals, shown: nil) == .one(2), "a terminal by a part of its title")
        check(ControlAgentTools.pickTerminal("", among: terminals, shown: "33333333-0000-4000-8000-000000000003") == .one(2), "no query: the shown terminal")
        check(ControlAgentTools.pickTerminal("", among: terminals, shown: nil) == .many([0, 1, 2]), "…none shown and several: ambiguous")
        check(ControlAgentTools.pickTerminal("", among: [terminals[1]], shown: nil) == .one(0), "one terminal needs no query")
        check(ControlAgentTools.pickTerminal("", among: [], shown: nil) == .none, "no terminal")

        // MARK: Keys, waits, output

        check(ControlAgentTools.keyNames.allSatisfy { ControlAgentTools.keyBytes[$0] != nil } && ControlAgentTools.keyBytes.count == ControlAgentTools.keyNames.count, "every key has its bytes")
        check(ControlAgentTools.keyBytes["enter"] == "\r" && ControlAgentTools.keyBytes["escape"] == "\u{1b}" && ControlAgentTools.keyBytes["ctrl-c"] == "\u{03}" && ControlAgentTools.keyBytes["down"] == "\u{1b}[B",
              "enter, escape, ctrl-c and the arrows are the terminal's own bytes")
        check(ControlAgentTools.keyBytes["ctrl-d"] == nil && ControlAgentTools.keyBytes["a"] == nil, "no key outside the list (no EOF, no letters)")
        check(ControlAgentTools.seconds(nil) == 30 && ControlAgentTools.seconds(5) == 5 && ControlAgentTools.seconds(-3) == 0 && ControlAgentTools.seconds(9999) == 90 && ControlAgentTools.seconds(12.7) == 12,
              "a wait is clamped to 0…90 seconds")
        check(ControlAgentTools.seconds(nil, default: 4) == 4, "…with a default")
        check(ControlAgentTools.tail("a\nb\nc\nd\n\n   \n", lines: 2) == "c\nd", "the tail is the last lines without blank ones at the end")
        check(ControlAgentTools.tail("a\n\n\n\nb\n\n\nc\n", lines: 10) == "a\n\nb\n\nc", "a run of blank lines shows as one")
        check(ControlAgentTools.tail("\n\na\n\n\nb", lines: 2) == "\nb", "the tail counts the collapsed lines")
        check(ControlAgentTools.tail("one  \ntwo", lines: 10) == "one\ntwo", "…trailing spaces cut")
        check(ControlAgentTools.tail(String(repeating: "x", count: 50), lines: 5, maxCharacters: 10) == "…" + String(repeating: "x", count: 10), "…and the characters limited")
        check(ControlAgentTools.tail("", lines: 5) == "", "…of nothing is nothing")

        // MARK: What to do next

        func advice(_ configure: (inout ControlAgentTools.FlowSnapshot) -> Void) -> String {
            var snapshot = ControlAgentTools.FlowSnapshot(slug: "orders", status: "exploring")
            configure(&snapshot)
            return ControlAgentTools.advice(snapshot)
        }
        check(advice { $0.running = ["answer"]; $0.openQuestions = 3 }.contains("wait_s"), "a running step is waited for before anything else")
        check(advice { $0.openQuestions = 2 }.contains("markview_flow_answer") && advice { $0.openQuestions = 2 }.contains("2 open question"), "open questions: answer them")
        check(advice { _ in }.contains("step: \"explore\""), "nothing open and not understood: ask the next round")
        check(advice { $0.understood = true; $0.draftRequirements = 4 }.contains("\"review\"") && advice { $0.understood = true }.contains("by_user: true"), "understood: review, with the person's word")
        check(advice { $0.pastExplore = true; $0.openFindings = 5; $0.requirements = 4 }.contains("5 open finding"), "past Explore with findings: resolve")
        check(advice { $0.pastExplore = true; $0.requirements = 4 }.contains("\"plan\""), "reviewed: plan")
        check(advice { $0.pastExplore = true; $0.requirements = 4; $0.planIssues = 3; $0.issuesFiled = 1; $0.gitHubReady = true }.contains("\"issues\""), "a plan not yet filed: file it")
        check(advice { $0.pastExplore = true; $0.requirements = 4; $0.planIssues = 3; $0.issuesFiled = 1; $0.gitHubReady = false }.contains("markview_flow_implement"), "without GitHub: implement")
        check(advice { $0.pastExplore = true; $0.requirements = 4; $0.planIssues = 3; $0.issuesFiled = 3; $0.gitHubReady = true }.contains("markview_flow_implement"), "filed: implement")
        check(advice { $0.status = "building"; $0.implementationStarted = true; $0.pastExplore = true }.contains("markview_agent_wait"), "implementation started (any status with that role): follow the agent")
        check(advice { $0.pastExplore = true }.contains("no requirements"), "reviewed but empty: say so")

        // MARK: MCP answers

        func message(_ method: String, _ params: [String: Any] = [:]) -> [String: Any] { ["jsonrpc": "2.0", "id": 1, "method": method, "params": params] }
        let profile = ControlAgentTools.profile
        let listed = BrowserAgentTools.handle(message("tools/list"), available: false, profile: profile) { _, _ in .error("no") }
        check(((listed?["result"] as? [String: Any])?["tools"] as? [Any])?.count == 18, "the tools are listed even when MarkView is not running")
        let listedProject = BrowserAgentTools.handle(message("tools/list"), available: false, profile: ProjectAgentTools.profile) { _, _ in .error("no") }
        check(((listedProject?["result"] as? [String: Any])?["tools"] as? [Any])?.count == 0, "…while the project tools are hidden")
        let called = BrowserAgentTools.handle(message("tools/call", ["name": "markview_windows"]), available: false, profile: profile) { _, _ in .init(text: "ran") }
        check(String(describing: called?["result"] ?? "").contains("not running"), "a call without the app says MarkView is not running")
        let calledUp = BrowserAgentTools.handle(message("tools/call", ["name": "markview_windows", "arguments": ["x": 1]]), available: true, profile: profile) { tool, args in .init(text: "ran \(tool) \(args.count)") }
        check(String(describing: calledUp?["result"] ?? "").contains("ran markview_windows 1"), "a call with the app reaches it")
        let init0 = BrowserAgentTools.handle(message("initialize", ["protocolVersion": "2025-06-18"]), available: false, profile: profile) { _, _ in .error("no") }
        check(((init0?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String == "markview-control"
              && ((init0?["result"] as? [String: Any])?["instructions"] as? String)?.contains("markview_windows") == true, "the server introduces itself with its instructions")
        check(BrowserAgentTools.isNoWindow("No MarkView window matches “x”.") && BrowserAgentTools.isNoWindow("No MarkView window has the folder /x") && !BrowserAgentTools.isNoWindow("Several windows"),
              "a reply that says this MarkView has no such window lets the next MarkView be asked")

        // MARK: Stand-in for the app

        func spawnApp(pid: Int32 = getpid(), serving tool: @escaping (String) -> String) -> (path: String, requests: () -> [[String: Any]], stop: () -> Void) {
            let path = BrowserAgentTools.socketPath(forApp: pid)
            unlink(path)
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = PrivateSocket.address(path)!
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            listen(listener, 8)
            let seen = OSAllocatedUnfairLock(initialState: [[String: Any]]())
            Thread {
                while true {
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { return }
                    if let line = BrowserAgentTools.readLine(client), let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        seen.withLock { $0.append(request) }
                        let text = tool(request["tool"] as? String ?? "")
                        let isError = text.hasPrefix("No MarkView window")
                        let reply = try! JSONSerialization.data(withJSONObject: BrowserAgentTools.Reply(text: text, isError: isError).json)
                        _ = BrowserAgentTools.writeAll(client, reply + Data("\n".utf8))
                    }
                    close(client)
                }
            }.start()
            return (path, { seen.withLock { $0 } }, { close(listener); unlink(path) })
        }

        func run(_ arguments: [String], input: String = "") -> (out: String, status: Int32) {
            let process = Process()
            process.executableURL = Bundle.main.executableURL!
            process.arguments = arguments
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            try! process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: data, as: UTF8.self), process.terminationStatus)
        }

        func rpc(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params]), as: UTF8.self) + "\n"
        }
        func toolCount(_ line: Substring) -> Int {
            guard let data = line.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return -1 }
            return ((object["result"] as? [String: Any])?["tools"] as? [Any])?.count ?? -1
        }

        // MARK: Real processes: no app

        let noApp = run(["--mcp-control"], input: rpc(1, "tools/list") + rpc(2, "tools/call", ["name": "markview_windows", "arguments": [:]]))
        let noAppLines = noApp.out.split(separator: "\n")
        check(noAppLines.count == 2 && toolCount(noAppLines[0]) == 18, "a --mcp-control process with no app still offers its tools", noApp.out)
        check(noAppLines.last?.contains("not running") == true, "and a call says MarkView is not running", noApp.out)

        // MARK: Real processes: with the app

        let app = spawnApp { tool in "reply to \(tool)" }
        let withApp = run(["--mcp-control"], input: rpc(1, "tools/list") + rpc(2, "tools/call", ["name": "markview_open_project", "arguments": ["path": "/tmp/p", "new_window": true]]))
        let withLines = withApp.out.split(separator: "\n")
        check(withLines.count == 2 && toolCount(withLines[0]) == 18, "with the app running the control tools are offered", withApp.out)
        check(withLines.last?.contains("reply to markview_open_project") == true, "a tool call reaches the app and its reply comes back", withApp.out)
        let seen = app.requests()
        check(seen.count == 1 && seen[0]["tool"] as? String == "markview_open_project" && (seen[0]["arguments"] as? [String: Any])?["path"] as? String == "/tmp/p"
              && seen[0]["pids"] == nil && seen[0]["cwd"] == nil,
              "the request carries the tool and arguments without client-supplied process identity", "\(seen)")
        app.stop()

        // MARK: Real processes: two running MarkViews

        func sleeper() -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            try! process.run()
            return process
        }
        let first = sleeper(), second = sleeper()
        defer {
            if first.isRunning { first.terminate() }; first.waitUntilExit()
            if second.isRunning { second.terminate() }; second.waitUntilExit()
        }
        let high = max(first.processIdentifier, second.processIdentifier), low = min(first.processIdentifier, second.processIdentifier)
        let appHigh = spawnApp(pid: high) { tool in tool == "markview_windows" ? "windows of the newer MarkView" : "No MarkView window matches “blog”." }
        let appLow = spawnApp(pid: low) { tool in tool == "markview_windows" ? "windows of the older MarkView" : "blog is here (\(tool))" }
        // Neither stand-in is an ancestor of the server, so it finds both by their sockets, the newer process first.
        let both = run(["--mcp-control"], input: rpc(1, "tools/call", ["name": "markview_windows", "arguments": [:]])
                       + rpc(2, "tools/call", ["name": "markview_agents", "arguments": ["window": "blog"]]))
        check(both.out.contains("windows of the newer MarkView") && both.out.contains("windows of the older MarkView"), "the window list is the sum of every running MarkView", both.out)
        check(both.out.contains("blog is here (markview_agents)"), "a window the newer MarkView does not have is looked for in the older one", both.out)
        check(appHigh.requests().count == 2 && appLow.requests().count == 2, "…each was asked", "\(appHigh.requests().count) \(appLow.requests().count)")
        appHigh.stop(); appLow.stop()
        first.terminate(); second.terminate()

    }

    @MainActor func testGitTaskOwnership() async {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        /// Runs real git in `dir`; the standard output, trimmed.
        @discardableResult
        func git(_ args: [String], in dir: URL) -> String {
            let result = Subprocess.runBlocking(SubprocessSpec(executable: "/usr/bin/env", arguments: ["git"] + args, cwd: dir, timeout: 30,
                                                               maxOutputBytes: 1 << 20))
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Polls until `condition` holds or `seconds` pass; the main actor keeps running meanwhile.
        @MainActor func waitFor(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return condition()
        }

        /// A repository with one commit on `main` and a bare "origin" it tracks.
        func makeRepository(_ name: String) -> (repo: URL, origin: URL, base: URL) {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("git-ownership-\(name)-\(UUID().uuidString)", isDirectory: true)
            let repo = base.appendingPathComponent("repo", isDirectory: true), origin = base.appendingPathComponent("origin.git", isDirectory: true)
            try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
            git(["init", "--bare", "-b", "main"], in: origin)
            git(["init", "-b", "main"], in: repo)
            git(["config", "user.name", "Check"], in: repo)
            git(["config", "user.email", "check@example.invalid"], in: repo)
            git(["config", "commit.gpgsign", "false"], in: repo)
            git(["remote", "add", "origin", origin.path], in: repo)
            try? "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            git(["add", "a.txt"], in: repo)
            git(["commit", "-m", "first"], in: repo)
            git(["push", "-u", "origin", "main"], in: repo)
            return (repo, origin, base)
        }

        @MainActor func gitClientChecks() async {
            let oldGlobal = getenv("GIT_CONFIG_GLOBAL").map { String(cString: $0) }
            let oldSystem = getenv("GIT_CONFIG_SYSTEM").map { String(cString: $0) }
            defer {
                if let oldGlobal { setenv("GIT_CONFIG_GLOBAL", oldGlobal, 1) } else { unsetenv("GIT_CONFIG_GLOBAL") }
                if let oldSystem { setenv("GIT_CONFIG_SYSTEM", oldSystem, 1) } else { unsetenv("GIT_CONFIG_SYSTEM") }
            }
            setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
            setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
            let (repo, origin, base) = makeRepository("client")
            defer { try? FileManager.default.removeItem(at: base) }

            // Start: opening the folder starts a look, and the client keeps it.
            let client = GitClient()
            var reports = 0
            let subscription = client.branchReports.sink { _ in reports += 1 }
            client.setup(at: repo)
            check(await waitFor { client.isGitRepo && client.branch == "main" }, "setup starts a look at the repository: the branch is read")

            // Restart: a look asked for while another is waiting replaces it, so the repository is read once.
            reports = 0
            client.startRefresh(); client.startRefresh()
            check(await waitFor { reports >= 1 }, "a look reports the branch")
            try? await Task.sleep(nanoseconds: 700_000_000)
            check(reports == 1, "a second look asked for at once replaces the first: one report, not two (\(reports))")

            // Operations never replace one another: two `.gitignore` entries asked for one after the other both land.
            client.startIgnore("one.txt", isDirectory: false)
            client.startIgnore("two.txt", isDirectory: false)
            let ignore = repo.appendingPathComponent(".gitignore")
            check(await waitFor { ((try? String(contentsOf: ignore, encoding: .utf8)) ?? "").contains("/two.txt") }, "the second operation runs")
            let ignored = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
            check(ignored.contains("/one.txt") && ignored.contains("/two.txt"), "an operation asked for later does not end the one before it")

            // The commit bar: the client commits what is staged, tells the bar through a receipt, and pushes when asked. The looks the operations
            // above ended with are over first: a look and a commit both want git's index lock.
            check(await waitFor { !client.isOperating && client.activity == nil }, "the operations are over")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try? "two\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            git(["add", "b.txt"], in: repo)
            client.startCommit(message: "second", thenPush: true)
            check(await waitFor { client.lastCommit?.message == "second" }, "a commit leaves a receipt with its message")
            check(await waitFor { git(["--git-dir", origin.path, "log", "--format=%s", "-1"], in: repo) == "second" }, "the commit is pushed when asked")

            // A transfer asked for while one runs is dropped, not started twice (a slow pre-push hook counts its runs).
            let hookLog = base.appendingPathComponent("hook.log")
            let hook = repo.appendingPathComponent(".git/hooks/pre-push")
            try? "#!/bin/sh\necho run >> '\(hookLog.path)'\nsleep 1\n".write(to: hook, atomically: true, encoding: .utf8)
            git(["update-index", "--chmod=+x", "--add", "--", ".git/hooks/pre-push"], in: repo)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            try? "three\n".write(to: repo.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
            git(["add", "c.txt"], in: repo)
            git(["commit", "-m", "third"], in: repo)
            client.startPush(); client.startPush()
            check(await waitFor(15) { git(["--git-dir", origin.path, "log", "--format=%s", "-1"], in: repo) == "third" }, "the push goes through")
            let runs = ((try? String(contentsOf: hookLog, encoding: .utf8)) ?? "").split(separator: "\n").count
            check(runs == 1, "a second push asked for while one runs is dropped: the hook ran once (\(runs))")
            try? FileManager.default.removeItem(at: hook)

            // Close: what is waiting never starts, and a look that is under way writes nothing more.
            client.startIgnore("never.txt", isDirectory: false)
            client.close()
            try? await Task.sleep(nanoseconds: 800_000_000)
            check(!((try? String(contentsOf: ignore, encoding: .utf8)) ?? "").contains("/never.txt"), "close cancels an operation that has not started")

            let closing = GitClient()
            var closingReports = 0
            let closingSubscription = closing.branchReports.sink { _ in closingReports += 1 }
            closing.workingDirectory = repo
            closing.startRefresh()
            var spins = 0
            while !closing.isGitRepo && spins < 200 { await Task.yield(); spins += 1 }
            check(closing.isGitRepo, "the look had started when the window closed")
            closing.close()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            check(closing.branch.isEmpty && closingReports == 0 && closing.localBranches.isEmpty, "a look cancelled by the close writes nothing after it")
            subscription.cancel(); closingSubscription.cancel()
        }

        @MainActor func gitHubStoreChecks() async {
            let store = GitHubStore()

            // Start: the job runs under its key with the words its row shows, and ends with how it went.
            var release: CheckedContinuation<Void, Never>?
            store.start("pr-1", label: "Merging…", title: "Merge") {
                await withCheckedContinuation { release = $0 }
                return nil
            }
            check(store.jobs["pr-1"]?.isRunning == true && store.jobs["pr-1"]?.label == "Merging…", "a started job shows its label while it runs")
            check(await waitFor { release != nil }, "the job's work is under way")
            release?.resume()
            check(await waitFor { store.jobs["pr-1"]?.end == .done }, "a job whose work returns no error ends done")
            store.clearJob("pr-1")
            check(store.jobs["pr-1"] == nil, "the view that started a job forgets it once it has the outcome")

            store.start("pr-2", label: "Closing…", title: "Close") { "boom" }
            check(await waitFor { store.jobs["pr-2"]?.failure == "boom" }, "a job whose work returns an error ends failed with it")
            check(store.jobs["pr-2"]?.title == "Close", "the failure carries the title of its alert")

            // Restart: the same key replaces the job that runs, which is cancelled and writes nothing.
            var firstCancelled = false
            store.start("pr-3", label: "First…") {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { firstCancelled = true }
                return "stale"
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            store.start("pr-3", label: "Second…") { nil }
            check(await waitFor { store.jobs["pr-3"]?.end == .done }, "the second job of a key ends done")
            check(await waitFor { firstCancelled }, "the first job of the key is cancelled")
            try? await Task.sleep(nanoseconds: 200_000_000)
            check(store.jobs["pr-3"]?.end == .done && store.jobs["pr-3"]?.label == "Second…", "the cancelled job writes nothing after its replacement")

            // Close: a reset (the folder or the window closing) cancels what runs, forgets the jobs and nothing is written after it.
            var closeCancelled = false
            store.start("pr-4", label: "Running…") {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { closeCancelled = true }
                return "late"
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            store.reset()
            check(await waitFor { closeCancelled }, "a reset cancels the job that runs")
            try? await Task.sleep(nanoseconds: 200_000_000)
            check(store.jobs.isEmpty, "a reset forgets the jobs and a cancelled job writes nothing after it")
        }

        await gitClientChecks()
        await gitHubStoreChecks()
    }

    func testGitHubRemoteProfiles() throws { try GitHubRemoteProfileChecks.run() }
}

extension EditorHostTests {
    func testGitHubCommandLocalFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("github-command-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("gh-fixture")
        let script = #"""
        #!/usr/bin/python3
        import os, signal, sys
        case = sys.argv[-1]
        if case == "inherited-writer":
            os.execv("/bin/sh", ["/bin/sh", "-c", "/bin/sleep 4 & printf '[]'"])
        elif case == "both-pipes":
            for _ in range(64):
                os.write(1, b"A" * 16384)
                os.write(2, b"A" * 16384)
            sys.exit(7)
        elif case == "mark":
            open("started", "wb").close()
            os.write(1, b"marked\n")
        elif case == "ignore-term":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with open("hung.pid", "w") as f:
                f.write(str(os.getpid()))
            while True:
                signal.pause()
        else:
            os.write(1, "ready é\n".encode())
        """#
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        let dateErrors = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let stamp = index.isMultiple(of: 2) ? "2023-11-14T22:13:20Z" : "2023-11-14T22:13:20.000Z"
            if GHDate.parse(stamp) != expected { dateErrors.withLock { $0 += 1 } }
        }
        XCTAssertEqual(dateErrors.withLock { $0 }, 0)
        let started = Date()
        let inherited = await GitHubClient.execute(["--fixture", "inherited-writer"], in: root, timeout: 2, ghExecutable: fixture)
        XCTAssertEqual(inherited.status, 0); XCTAssertEqual(inherited.stdout, "[]")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let large = await GitHubClient.execute(["--fixture", "both-pipes"], in: root, timeout: 5, ghExecutable: fixture)
        XCTAssertEqual(large.status, 7); XCTAssertEqual(large.stdout.utf8.count, 1_048_576); XCTAssertEqual(large.stderr.utf8.count, 1_048_576)
        let timeoutStart = Date()
        let hung = await GitHubClient.execute(["--fixture", "ignore-term"], in: root, timeout: 1, ghExecutable: fixture)
        XCTAssertEqual(hung.status, -1); XCTAssertTrue(hung.stderr.contains("did not answer within"))
        XCTAssertLessThan(Date().timeIntervalSince(timeoutStart), 3)
        let pid = try XCTUnwrap(pid_t(String(contentsOf: root.appendingPathComponent("hung.pid"), encoding: .utf8)))
        XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let output = await GitHubClient.execute(["--fixture", "success"], in: root, timeout: 3, ghExecutable: fixture)
                    return output.status == 0 && output.stdout == "ready é\n"
                }
            }
            for await success in group { XCTAssertTrue(success) }
        }
        let invalid = await GitHubClient.execute(["--fixture", "success"], in: root.appendingPathComponent("missing"), timeout: 0.1, ghExecutable: fixture)
        XCTAssertTrue(invalid.status != 0 && !invalid.stderr.isEmpty)
        let marker = root.appendingPathComponent("started")
        func output(_ mode: String, enabled: Bool, timeout: TimeInterval) async -> String? {
            await Task.detached { GitHubClient.output(["--fixture", mode], in: root, enabled: enabled, timeout: timeout, ghExecutable: fixture) }.value
        }
        let off = await output("mark", enabled: false, timeout: 2)
        XCTAssertNil(off); XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let on = await output("mark", enabled: true, timeout: 2)
        XCTAssertEqual(on, "marked\n"); XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let failed = await output("both-pipes", enabled: true, timeout: 5)
        XCTAssertNil(failed)
        let hungStart = Date()
        let blocked = await output("ignore-term", enabled: true, timeout: 1)
        XCTAssertNil(blocked); XCTAssertLessThan(Date().timeIntervalSince(hungStart), 3)
    }
}
