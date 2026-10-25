import Foundation

// Checks the control tools an outside agent uses to run MarkView (MarkView/Models/ControlAgentTools.swift): the tool
// list, window and terminal choice, keys, waits, the advice on what to do next, the MCP answers, and real
// `--mcp-control` processes against stand-ins for the app — including "no app" and two running MarkViews.
// Compiled by tools/tests/control-agent-tools-tests.sh.

if CommandLine.arguments.contains("--mcp-control") { BrowserAgentTools.runServer(arguments: CommandLine.arguments, profile: ControlAgentTools.profile) }

var failures = 0
func check(_ condition: Bool, _ message: String, _ detail: String = "", line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line)) \(detail)") }
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
check(ProjectAgentTools.tools.first!.json["inputSchema"].flatMap { ($0 as? [String: Any])?["properties"] as? [String: Any] }?["project_folder"] != nil,
      "project tools still take project_folder")
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
check(advice { $0.status = "implementing"; $0.pastExplore = true }.contains("markview_agent_wait"), "implementing: follow the agent")
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
    var address = BrowserAgentTools.unixAddress(path)!
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    listen(listener, 8)
    let lock = NSLock()
    nonisolated(unsafe) var seen: [[String: Any]] = []
    Thread {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            if let line = BrowserAgentTools.readLine(client), let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                lock.lock(); seen.append(request); lock.unlock()
                let text = tool(request["tool"] as? String ?? "")
                let isError = text.hasPrefix("No MarkView window")
                let reply = try! JSONSerialization.data(withJSONObject: BrowserAgentTools.Reply(text: text, isError: isError).json)
                _ = BrowserAgentTools.writeAll(client, reply + Data("\n".utf8))
            }
            close(client)
        }
    }.start()
    return (path, { lock.lock(); defer { lock.unlock() }; return seen }, { close(listener); unlink(path) })
}

func run(_ arguments: [String], input: String = "") -> (out: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
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
      && (seen[0]["pids"] as? [Int])?.first == Int(getpid()) && (seen[0]["cwd"] as? String)?.isEmpty == false,
      "the request carries the tool, its arguments, the agent's processes and folder", "\(seen)")
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

print(failures == 0 ? "All control agent tool checks passed." : "\(failures) control agent tool check(s) failed.")
exit(failures == 0 ? 0 : 1)
