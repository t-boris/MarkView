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
    func testBrowserAgentProtocolAndSocket() throws {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + detail, line: line)
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-browser-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        let previous = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        setenv("MARKVIEW_SOCKET_DIR", socketDirectory.path, 1)
        defer {
            if let previous { setenv("MARKVIEW_SOCKET_DIR", previous, 1) } else { unsetenv("MARKVIEW_SOCKET_DIR") }
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        guard BrowserAgentTools.socketFolder == socketDirectory.path else {
            XCTFail("The browser socket fixture is not isolated")
            return
        }
        // MARK: MCP answers

        let initialize = BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                   "params": ["protocolVersion": "2025-03-26"]]) { _, _ in .error("") }
        let initResult = initialize?["result"] as? [String: Any]
        check(initResult?["protocolVersion"] as? String == "2025-03-26", "initialize echoes the client's protocol version")
        check((initResult?["instructions"] as? String)?.contains("instead of Chrome") == true, "instructions steer away from Chrome")
        check(BrowserAgentTools.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) { _, _ in .error("") } == nil,
              "notifications get no answer")
        let list = BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]) { _, _ in .error("") }
        let names = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        check(names.contains("browser_navigate") && names.contains("browser_tabs") && names.contains("browser_open_tab") && names.count == 13,
              "thirteen tools listed", "\(names)")
        let schemas = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
        let clickProps = (schemas.first { $0["name"] as? String == "browser_click" }?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        check(clickProps?["tab"] != nil && clickProps?["ref"] != nil, "tools take a tab")
        let hidden = BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 9, "method": "tools/list"], available: false) { _, _ in .error("") }
        check(((hidden?["result"] as? [String: Any])?["tools"] as? [Any])?.isEmpty == true, "outside MarkView no tools are offered")

        // MARK: Tabs

        let tabs = [(name: "T1", title: "Plant list", url: "http://localhost:5173/"), (name: "Jira", title: "Board - Jira", url: "https://acme.atlassian.net/"),
                    (name: "T3", title: "Stripe Dashboard", url: "https://dashboard.stripe.com/")]
        check(BrowserAgentTools.tabIndex("jira", in: tabs) == 1, "a tab by its name, any case")
        check(BrowserAgentTools.tabIndex("3", in: tabs) == 2, "a tab by its number")
        check(BrowserAgentTools.tabIndex("stripe", in: tabs) == 2, "a tab by part of its title")
        check(BrowserAgentTools.tabIndex("https", in: tabs) == nil, "an ambiguous part matches nothing")
        check(BrowserAgentTools.nextTabName(taken: ["T1", "Jira", "T3"]) == "T2", "the next free default name")
        check(BrowserAgentTools.windowIndex(forFolder: "/w/garden/src", roots: ["/w/other", "/w/garden", "/w"]) == 1,
              "an agent outside the terminals: the window whose project holds its folder, the deepest")
        check(BrowserAgentTools.windowIndex(forFolder: "/tmp/x", roots: ["/w/garden"]) == 0, "else the only window")
        check(BrowserAgentTools.windowIndex(forFolder: "/tmp/x", roots: ["/w/a", "/w/b"]) == nil, "several windows and none matches: none")
        check(BrowserAgentTools.windowIndex(forFolder: "/tmp/x", roots: ["/w/garden"], strict: true) == nil
              && BrowserAgentTools.windowIndex(forFolder: "/w/garden/src", roots: ["/w/other", "/w/garden"], strict: true) == 1, "strict: the only window is not enough, a project holding the folder is")
        check(BrowserAgentTools.windowIndex(forFolder: "/w/gardening", roots: ["/w/garden", "/w/b"]) == nil, "a name prefix is not a parent folder")

        // The server derives the caller’s working folder from kernel process information.
        let ownFolder = BrowserAgentTools.workingDirectory(forPIDs: [getpid()])
        check(ownFolder == FileManager.default.currentDirectoryPath, "the kernel reports this process’s working directory")
        check(BrowserAgentTools.workingDirectory(forPIDs: [-1, 0]) == nil, "invalid process identifiers do not produce a folder")
        let routingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mv-route-" + UUID().uuidString)
        let routingAlias = routingRoot.appendingPathExtension("alias")
        try! FileManager.default.createDirectory(at: routingRoot, withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(at: routingAlias, withDestinationURL: routingRoot)
        check(BrowserAgentTools.windowIndex(forFolder: routingAlias.path, roots: [routingRoot.path], strict: true) == 0,
              "a symlinked peer folder selects the same project")
        check(BrowserAgentTools.folder(routingAlias.path, isInProject: routingRoot.path), "a legacy folder matches through a symlink")
        check(!BrowserAgentTools.folder(routingRoot.path + "-other", isInProject: routingRoot.path), "a legacy path prefix outside the project is refused")
        try? FileManager.default.removeItem(at: routingAlias)
        try? FileManager.default.removeItem(at: routingRoot)
        let schema = BrowserAgentTools.tools[0].json["inputSchema"] as? [String: Any]
        check((schema?["properties"] as? [String: Any])?["project_folder"] == nil, "the tool schema does not advertise client-selected project folders")
        check(BrowserAgentTools.reportsPolicyBlock("\u{1b}[31m✗ MCP server was blocked by policy: \"markview-browser\"\u{1b}[0m"),
              "Copilot's policy block is recognised")
        check(!BrowserAgentTools.reportsPolicyBlock("MCP server was blocked by policy: \"github\"") && !BrowserAgentTools.reportsPolicyBlock("markview-browser ready"),
              "other servers' blocks and normal output are not")
        let merged = BrowserAgentTools.withServer(["command": "x"], in: ["mcpServers": ["other": ["command": "y"]], "theme": "dark"])
        check(((merged["mcpServers"] as? [String: Any])?.count == 2) && merged["theme"] as? String == "dark", "registration keeps other servers and settings")
        var called: (String, [String: Any])?
        let callAnswer = BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                                   "params": ["name": "browser_click", "arguments": ["ref": "e3"]]]) { tool, args in
            called = (tool, args)
            return BrowserAgentTools.Reply(text: "Clicked.", pngBase64: "AAAA")
        }
        let content = ((callAnswer?["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        check(called?.0 == "browser_click" && called?.1["ref"] as? String == "e3", "tools/call passes the tool and its arguments")
        check(content.count == 2 && content[1]["type"] as? String == "image" && content[1]["mimeType"] as? String == "image/png",
              "a reply with a screenshot becomes text + image content")
        let unknown = BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "rm_rf"]]) { _, _ in
            BrowserAgentTools.Reply(text: "should not run")
        }
        check(((unknown?["result"] as? [String: Any])?["isError"] as? Bool) == true, "an unknown tool is an error, not a call")
        check((BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 5, "method": "resources/list"]) { _, _ in .error("") }?["error"]) != nil,
              "unknown methods answer with an error")

        // MARK: Stand-in for the app: a socket that records the request and answers

        // The server is started without --socket: it must find this process (its parent) by the app's socket name.
        let socketPath = BrowserAgentTools.socketPath(forApp: getpid())
        unlink(socketPath)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = PrivateSocket.address(socketPath)!
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(listener, 4)
        let receivedBox = OSAllocatedUnfairLock(initialState: [String: Any]())
        let served = DispatchSemaphore(value: 0)
        Thread {
            let client = accept(listener, nil, nil)
            if let line = BrowserAgentTools.readLine(client) {
                let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                receivedBox.withLock { $0 = request }
            }
            let reply = try! JSONSerialization.data(withJSONObject: BrowserAgentTools.Reply(text: "Page: http://localhost:5173/ — Garden").json)
            _ = BrowserAgentTools.writeAll(client, reply + Data("\n".utf8))
            close(client)
            served.signal()
        }.start()

        // MARK: A real --mcp-browser process

        let process = Process()
        process.executableURL = Bundle.main.executableURL!
        process.arguments = ["--mcp-browser"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try! process.run()
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "browser_navigate", "arguments": ["url": "localhost:5173", "project_folder": "/legacy"]]],
        ]
        for message in messages { input.fileHandleForWriting.write(try! JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)) }
        try! input.fileHandleForWriting.close()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        _ = served.wait(timeout: .now() + 5)
        let received = receivedBox.withLock { $0 }
        let lines = out.split(separator: "\n").map(String.init)
        check(lines.count == 2, "two answers for two requests (the notification gets none)", out)
        check(received["tool"] as? String == "browser_navigate"
              && (received["arguments"] as? [String: Any])?["url"] as? String == "localhost:5173",
              "found through its parent process, the call reached the app", "\(received)")
        check(lines.last?.contains("Garden") == true, "the app's reply came back as the tool result", out)
        check(received["cwd"] == nil && received["pids"] == nil, "the request carries no client-supplied folder or ancestry")
        check((received["arguments"] as? [String: Any])?["project_folder"] as? String == "/legacy", "a legacy folder is forwarded only as an argument for mismatch validation")
        let unreachable = BrowserAgentTools.request(socket: socketPath + ".missing", payload: [:], timeout: 1)
        check(unreachable.isError && unreachable.text.contains("not reachable"), "a closed app is reported, not hung on")
        unlink(socketPath)

    }

    func testProjectAgentToolsAndSockets() throws {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + detail, line: line)
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("mv-project-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        let previous = getenv("MARKVIEW_SOCKET_DIR").map { String(cString: $0) }
        setenv("MARKVIEW_SOCKET_DIR", socketDirectory.path, 1)
        defer {
            if let previous { setenv("MARKVIEW_SOCKET_DIR", previous, 1) } else { unsetenv("MARKVIEW_SOCKET_DIR") }
            try? FileManager.default.removeItem(at: socketDirectory)
        }
        guard BrowserAgentTools.socketFolder == socketDirectory.path else {
            XCTFail("The project socket fixture is not isolated")
            return
        }
        // MARK: Tools

        let tools = ProjectAgentTools.tools
        let names = tools.map(\.name)
        check(names.count == 42 && Set(names).count == 42, "forty-two distinct tools", "\(names)")
        check(names.allSatisfy { $0.hasPrefix("markview_") }, "every tool is prefixed")
        check(tools.allSatisfy { !$0.description.isEmpty && $0.required.allSatisfy { $0.isEmpty == false && tools.isEmpty == false } }, "every tool is described")
        check(tools.allSatisfy { tool in tool.required.allSatisfy { tool.properties[$0] != nil } }, "required arguments are declared")
        let readOnly: Set<String> = ["markview_guide", "markview_project", "markview_get_workflow", "markview_list_features", "markview_get_feature", "markview_list_bugs", "markview_get_bug", "markview_list_prototypes", "markview_get_prototype", "markview_issue_context", "markview_open_questions", "markview_discussions", "markview_get_discussion"]
        check(readOnly.isSubset(of: Set(names)) && names.count - readOnly.count == 29, "thirteen readers, twenty writers, six deployments tools and three cockpit tools")
        check(DiscussionAgentTools.names.count == 4 && DiscussionAgentTools.names.isSubset(of: Set(names)), "the discussions tools are among them")
        for name in ["markview_update_feature", "markview_update_object", "markview_answer_question", "markview_add_source", "markview_add_discussion_note", "markview_update_bug", "markview_answer_bug_question", "markview_link_issue"] {
            check(names.contains(name), "\(name) exists")
        }
        for name in ["markview_answer_question", "markview_answer_bug_question"] {
            check(tools.first { $0.name == name }!.required.contains("by_user"), "\(name) needs the person's word")
        }
        check(ProjectAgentTools.personsStatuses.isSuperset(of: ["approved", "accepted", "answered"]), "settling statuses need the person")
        let setBug = tools.first { $0.name == "markview_set_bug_status" }!
        check(setBug.required == ["id"] && setBug.properties["status"]?["enum"] == nil && setBug.properties["status"]?["type"] as? String == "string", "a bug status is a status of the project's workflow, not a fixed list")
        var tinyWorkflow = ProjectWorkflow.standard
        tinyWorkflow.name = "Renamed"
        tinyWorkflow.bug.statuses = tinyWorkflow.bug.statuses.map { WorkflowStatus(id: $0.id == "fixing" ? "doing" : $0.id, role: $0.role) }
        check(ProjectAgentTools.guide("lifecycle", workflow: tinyWorkflow).contains("doing"), "the lifecycle guide names the statuses of a project whose workflow differs")
        check(ProjectAgentTools.guide("lifecycle") == IssueLifecycleContext.guidance, "the lifecycle guide is the standard text for the standard workflow")
        check(ProjectAgentTools.guide("bug").contains("markview_set_bug_status"), "the bug guide names the status tool")
        let setStatus = tools.first { $0.name == "markview_set_status" }!
        check(setStatus.properties["reason"] != nil && setStatus.properties["evidence"] != nil && setStatus.properties["session"] != nil && setStatus.properties["tool"] != nil, "set_status carries a reason, evidence and the caller's session")
        check(setBug.properties["reason"] != nil && setBug.properties["evidence"] != nil && setBug.properties["duplicate_of"] != nil, "set_bug_status carries a reason, evidence and the original of a duplicate")
        check(tools.first { $0.name == "markview_attach_issue" }!.required == ["issue"], "attaching a session names the issue")
        check(tools.first { $0.name == "markview_confirm_delivery" }!.required == ["issue", "evidence"], "confirming a delivery names the issue and the evidence")
        check(tools.first { $0.name == "markview_get_workflow" }!.required.isEmpty, "reading the workflow needs nothing")
        check(tools.first { $0.name == "markview_propose_workflow" }!.required == ["workflow", "summary"] && tools.first { $0.name == "markview_propose_workflow" }!.properties["workflow"]?["type"] as? String == "object",
              "proposing a workflow needs the whole workflow as an object and a summary")
        check(!names.contains { $0.contains("save_workflow") || $0.contains("write_workflow") || $0.contains("set_workflow") || $0.contains("update_workflow") },
              "there is no tool that writes the workflow")
        check(tools.first { $0.name == "markview_propose_workflow" }!.description.contains("You cannot save it"), "the proposal tool says that the assistant cannot save")
        check(ProjectAgentTools.guideTopics.contains("workflow-format") && ProjectAgentTools.guide("workflow-format") == WorkflowFormatGuide.text, "the workflow format has a guide topic")
        check(ProjectAgentTools.guide("workflow").contains("workflow-format") && ProjectAgentTools.guide("workflow").contains("markview_get_workflow"), "the feature workflow guide points to the workflow file")

        // Every assistant that MarkView can start gets the project tools registered (Connect Agents): its provider says how.
        check(CLITool.allCases.count >= 5, "the assistants that MarkView knows come from the provider list")
        for tool in CLITool.allCases {
            check(tool.provider.mcp != nil, "Connect Agents registers the MarkView tools for \(tool.rawValue)")
        }
        check(tools.first { $0.name == "markview_create_bug" }!.properties["regression_of"] != nil && tools.first { $0.name == "markview_update_bug" }!.properties["regression_of"] != nil,
              "a bug report can name the work it is a regression of")
        check(tools.first { $0.name == "markview_create_bug" }!.properties["related"] != nil && tools.first { $0.name == "markview_create_feature" }!.properties["related"] != nil,
              "independent new work is created as a new issue linked with related")
        check(ProjectAgentTools.guide("lifecycle").contains("`related`"), "the lifecycle guide says independent new work is a linked new issue")
        let known = (features: ["export-pdf", "dark-mode"], bugs: ["BUG-007", "BUG-012"])
        func name(_ raw: String, own: String? = nil) -> ProjectAgentTools.IssueName { ProjectAgentTools.issueName(raw, features: known.features, bugs: known.bugs, own: own) }
        check(name("export-pdf") == .feature("export-pdf") && name("  dark-mode ") == .feature("dark-mode"), "a feature slug names the feature")
        check(name("BUG-007") == .bug("BUG-007") && name("bug-012") == .bug("BUG-012"), "a bug key names the bug, whatever its case")
        check(name("") == .empty && name("   ") == .empty, "an empty name clears the field")
        check(name("BUG-099") == .unknown("BUG-099") && name("nothing") == .unknown("nothing"), "an unknown name is refused")
        check(name("../export-pdf") == .unknown("../export-pdf") && name("a/b") == .unknown("a/b"), "a path is no feature name")
        check(name("BUG-007", own: "bug-007") == .itself && name("BUG-012", own: "BUG-007") == .bug("BUG-012"), "a bug cannot name itself")
        check(tools.first { $0.name == "markview_issue_context" }!.required.isEmpty, "the issue context also lists the issues in progress")
        check(ProjectAgentTools.guideTopics.contains("lifecycle") && ProjectAgentTools.guide("lifecycle") == IssueLifecycleContext.guidance, "there is a lifecycle guide")
        check(ProjectAgentTools.guide("lifecycle").contains("markview_issue_context") && ProjectAgentTools.guide("lifecycle").contains("by_user"), "the lifecycle guide names the context tool and what by_user does not grant")
        check(DeploymentAgentTools.names.count == 6 && DeploymentAgentTools.names.isSubset(of: Set(names)), "the deployments tools are among them")
        check(ProjectAgentTools.guide("deployments").contains("never run") && ProjectAgentTools.guideTopics.contains("deployments"), "there is a deployments guide")
        let requirement = tools.first { $0.name == "markview_add_requirement" }!
        check((requirement.properties["req_type"]?["enum"] as? [String]) == FeatureVocabulary.requirementTypes, "requirement types come from the app's vocabulary")
        check(requirement.required == ["feature", "title", "statement", "acceptance_criteria"], "a requirement needs criteria")
        let createFeature = tools.first { $0.name == "markview_create_feature" }!
        check((createFeature.properties["status"]?["enum"] as? [String])?.contains("implementing") == false, "an agent cannot create a feature as implementing")
        check(ProjectAgentTools.agentFeatureStatuses == ["idea", "exploring", "draft", "review", "ready"], "feature statuses an agent may set")

        // MARK: Guide

        for topic in ProjectAgentTools.guideTopics { check(ProjectAgentTools.guide(topic).count > 200, "guide \(topic) has text") }
        check(ProjectAgentTools.guideTopics.contains("process") && ProjectAgentTools.guide("process").contains("pull request"), "there is a process guide")
        check(Set(ProjectAgentTools.guideTopics.map { ProjectAgentTools.guide($0) }).count == ProjectAgentTools.guideTopics.count, "guide topics differ")
        check(ProjectAgentTools.guide(nil) == ProjectAgentTools.guide("overview") && ProjectAgentTools.guide("zzz") == ProjectAgentTools.guide("overview"), "the overview is the default")
        check(ProjectAgentTools.guide("overview").contains("docs/features/<slug>/") && ProjectAgentTools.guide("overview").contains("never write these files by hand"), "the overview names the folder and forbids hand-written files")
        check(ProjectAgentTools.guide("prototype").contains("markview_get_prototype") && ProjectAgentTools.guide("prototype").contains("markview_add_requirement"), "the prototype guide shows the way to features")
        let prototypeGuide = ProjectAgentTools.guide("prototype")
        check(prototypeGuide.contains("markview://prototype/<slug>") && prototypeGuide.contains("latest saved version") && prototypeGuide.contains("same project"),
              "the prototype guide explains the reference, that it means the latest version and that it is local to the project")
        let getPrototype = tools.first { $0.name == "markview_get_prototype" }!
        check(getPrototype.description.contains("markview://prototype/<slug>") && getPrototype.description.contains("latest saved version") && getPrototype.description.contains("checkout"),
              "markview_get_prototype describes the reference and where it resolves")
        check((getPrototype.properties["prototype"]?["description"] as? String)?.contains("markview://prototype/<slug>") == true
              && (getPrototype.properties["prototype"]?["description"] as? String)?.contains("docs/prototypes/<slug>") == true, "the prototype argument takes the reference in its forms")
        check(tools.first { $0.name == "markview_list_prototypes" }!.description.contains("markview://prototype/<slug>"), "markview_list_prototypes shows each reference")

        // MARK: Bodies

        let decision = ProjectAgentTools.decisionBody(context: "c", alternatives: ["a", "b"], decision: "d", reason: "r", consequences: "q")
        check(decision.contains("## Alternatives\n\n1. a\n2. b") && decision.contains("## Decision\n\nd") && decision.contains("## Consequences\n\nq"), "decision body")
        let question = ProjectAgentTools.questionBody(question: "Who approves?", why: "Permissions", options: [("A", "Manager"), ("B", "Anyone")], recommended: "A")
        check(question.contains("## Question\n\nWho approves?") && question.contains("- **A**: Manager") && question.contains("## Recommended\n\nA"), "question body")
        let bug = ProjectAgentTools.bugBody(title: "Crash", summary: "It crashes", steps: ["Open", "Click"], expected: "", actual: "Crash", environment: "")
        check(bug.hasPrefix("# Crash\n\n## Summary\n\nIt crashes") && bug.contains("1. Open\n2. Click") && !bug.contains("## Expected") && bug.contains("## Environment\n\nUnknown"), "bug body drops empty sections", bug)

        // MARK: Arguments

        func throwsInvalid(_ work: () throws -> Any) -> String? {
            do { _ = try work(); return nil } catch let e as ProjectAgentTools.Invalid { return e.message } catch { return "other" }
        }
        check(throwsInvalid { try ProjectAgentTools.text([:], "title", required: true) }?.contains("required") == true, "a required text must be given")
        check((try? ProjectAgentTools.text(["title": "  Hi \n"], "title")) == "Hi", "text is trimmed")
        check(throwsInvalid { try ProjectAgentTools.text(["t": String(repeating: "x", count: 20_001)], "t") }?.contains("too long") == true, "text has a limit")
        check(throwsInvalid { try ProjectAgentTools.list(["l": "not a list"], "l") }?.contains("array") == true, "a list must be an array of strings")
        check((try? ProjectAgentTools.list(["l": ["a", " ", "b "]], "l")) == ["a", "b"], "empty list items are dropped")
        check(throwsInvalid { try ProjectAgentTools.list(["l": Array(repeating: "x", count: 41)], "l") }?.contains("limit") == true, "a list has a limit")
        check(throwsInvalid { try ProjectAgentTools.choice(["s": "weird"], "s", in: ["a", "b"], default: "a") }?.contains("a, b") == true, "a choice outside the vocabulary is refused")
        check((try? ProjectAgentTools.choice([:], "s", in: ["a", "b"], default: "b")) == "b" && (try? ProjectAgentTools.choice(["s": "A"], "s", in: ["a", "b"], default: "b")) == "a", "default and case-insensitive choice")
        check(["a-b", "feature_1", "x"].allSatisfy(ProjectAgentTools.isPlainName) && !["", "../x", "a/b", ".hidden", "a\\b", "a..b"].contains(where: ProjectAgentTools.isPlainName), "a slug is a plain name, never a path")
        check(ProjectAgentTools.statuses(forObjectID: "REQ-003") == FeatureVocabulary.requirementStatuses && ProjectAgentTools.statuses(forObjectID: "DEC-001") == FeatureVocabulary.decisionStatuses
              && ProjectAgentTools.statuses(forObjectID: "Q-002") == FeatureVocabulary.questionStatuses && ProjectAgentTools.statuses(forObjectID: "X-1") == nil, "statuses by object kind")

        // MARK: MCP answers

        let profile = ProjectAgentTools.profile
        let initialize = BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]], profile: profile) { _, _ in .error("") }
        let initResult = initialize?["result"] as? [String: Any]
        check((initResult?["serverInfo"] as? [String: Any])?["name"] as? String == "markview", "the server is named markview")
        check((initResult?["instructions"] as? String)?.contains("markview_guide") == true, "instructions point to the guide")
        let list = BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], profile: profile) { _, _ in .error("") }
        check((((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count ?? 0) == 42, "tools/list offers the project tools")
        let offline = BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/list"], available: false, profile: profile) { _, _ in .error("") }
        check(((offline?["result"] as? [String: Any])?["tools"] as? [Any])?.isEmpty == true, "without the app: no tools")
        var reached = false
        let browserCall = BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "browser_click"]], profile: profile) { _, _ in reached = true; return .error("") }
        check(!reached && ((browserCall?["result"] as? [String: Any])?["isError"] as? Bool) == true, "a browser tool is not a project tool")
        let blocked = BrowserAgentTools.handle(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "markview_guide"]], available: false, profile: profile) { _, _ in reached = true; return .error("") }
        check(!reached && (((blocked?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("not running") == true, "without the app a call says so and goes nowhere")

        // MARK: Skill

        let skill = ProjectAgentTools.skillText(executable: "/Applications/MarkView.app/Contents/MacOS/MarkView")
        check(skill.hasPrefix("---\nname: markview\ndescription: ") && skill.contains("--project-call"), "the skill has front matter and the command")
        check(names.allSatisfy { skill.contains($0) }, "the skill lists every tool")
        check(skill.contains("## How work is done") && skill.contains("CLAUDE.md"), "the skill carries the process and defers to the project's own rules")
        check(skill.contains("\"/Applications/MarkView.app/Contents/MacOS/MarkView\" --project-call"), "the command carries the app's path, quoted")
        check(skill.contains("## A prototype handed to you as a reference") && skill.contains("`markview://prototype/<slug>`") && skill.contains("latest saved version") && skill.contains("same project open"),
              "the skill explains the prototype reference: its form, latest version, local to the project")

        // MARK: Stand-in for the app

        func spawnApp(serving tool: @escaping (String) -> String) -> (path: String, requests: () -> [[String: Any]], stop: () -> Void) {
            let path = BrowserAgentTools.socketPath(forApp: getpid())
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
                        let reply = try! JSONSerialization.data(withJSONObject: BrowserAgentTools.Reply(text: tool(request["tool"] as? String ?? "")).json)
                        _ = BrowserAgentTools.writeAll(client, reply + Data("\n".utf8))
                    }
                    close(client)
                }
            }.start()
            return (path, { seen.withLock { $0 } }, { close(listener); unlink(path) })
        }

        func run(_ arguments: [String], input: String = "", timeout: TimeInterval = 15) -> (out: String, status: Int32) {
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

        let noApp = run(["--mcp-project"], input: rpc(1, "tools/list") + rpc(2, "tools/call", ["name": "markview_guide", "arguments": [:]]))
        let noAppLines = noApp.out.split(separator: "\n")
        check(noAppLines.count == 2 && toolCount(noAppLines[0]) == 0, "a --mcp-project process with no app offers no tools", noApp.out)
        check(noAppLines.last?.contains("not running") == true, "and a call says MarkView is not running", noApp.out)
        let callNoApp = run(["--project-call", "markview_project"])
        check(callNoApp.status == 1 && callNoApp.out.contains("not running"), "--project-call with no app fails and touches nothing", callNoApp.out)
        check(run(["--project-call", "markview_nope"]).status == 2, "--project-call refuses an unknown tool")
        check(run(["--project-call", "markview_guide", "[1]"]).status == 2, "--project-call refuses arguments that are not a JSON object")

        // MARK: Real processes: with the app

        let app = spawnApp { tool in "reply to \(tool)" }
        let withApp = run(["--mcp-project"], input: rpc(1, "tools/list") + rpc(2, "tools/call", ["name": "markview_add_requirement", "arguments": ["feature": "f", "title": "T"]]))
        let withLines = withApp.out.split(separator: "\n")
        check(withLines.count == 2 && toolCount(withLines[0]) == 42, "with the app running the project tools are offered", withApp.out)
        check(withLines.last?.contains("reply to markview_add_requirement") == true, "a tool call reaches the app and its reply comes back", withApp.out)
        let callWithApp = run(["--project-call", "markview_get_feature", "{\"feature\":\"orders\"}"])
        check(callWithApp.status == 0 && callWithApp.out.contains("reply to markview_get_feature"), "--project-call reaches the app", callWithApp.out)
        let seen = app.requests()
        check(seen.count == 2 && seen.last?["tool"] as? String == "markview_get_feature" && (seen.last?["arguments"] as? [String: Any])?["feature"] as? String == "orders"
              && seen.last?["pids"] == nil && seen.last?["cwd"] == nil,
              "the request carries the tool and its arguments without client-supplied process identity", "\(seen)")

        // MARK: Real process: the app quits while the server runs

        app.stop()  // the stand-in is the server's parent app by pid; here the app is the fake process below

        let fakeApp = Process()
        fakeApp.executableURL = URL(fileURLWithPath: "/bin/sleep")
        fakeApp.arguments = ["60"]
        try! fakeApp.run()
        defer { if fakeApp.isRunning { fakeApp.terminate() }; fakeApp.waitUntilExit() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mv-proj-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeSocket = dir.appendingPathComponent("mv-browser-\(fakeApp.processIdentifier).sock").path
        FileManager.default.createFile(atPath: fakeSocket, contents: nil)
        let server = Process()
        server.executableURL = Bundle.main.executableURL!
        server.arguments = ["--mcp-project", "--socket", fakeSocket]
        let sIn = Pipe(), sOut = Pipe()
        server.standardInput = sIn
        server.standardOutput = sOut
        try! server.run()
        func ask(_ id: Int) -> Int {
            sIn.fileHandleForWriting.write(Data(rpc(id, "tools/list").utf8))
            guard let line = BrowserAgentTools.readLine(sOut.fileHandleForReading.fileDescriptor) else { return -2 }
            return toolCount(Substring(String(decoding: line, as: UTF8.self)))
        }
        check(ask(1) == 42, "while MarkView runs the tools are there")
        fakeApp.terminate()
        fakeApp.waitUntilExit()
        check(ask(2) == 0, "when MarkView quits the tools disappear, without restarting the server")
        try? sIn.fileHandleForWriting.close()
        server.waitUntilExit()
        try? FileManager.default.removeItem(at: dir)

    }

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
