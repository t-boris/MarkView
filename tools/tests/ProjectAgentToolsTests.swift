import Foundation

// Checks the project tools agents use to read and extend a MarkView project (MarkView/Models/ProjectAgentTools.swift):
// the tool list and guide, argument validation, the file bodies, the MCP answers, and real `--mcp-project` and
// `--project-call` processes against a stand-in for the app — including "no app, no tools".
// Compiled by tools/tests/project-agent-tools-tests.sh.

if CommandLine.arguments.contains("--mcp-project") { BrowserAgentTools.runServer(arguments: CommandLine.arguments, profile: ProjectAgentTools.profile) }
if CommandLine.arguments.contains("--project-call") { ProjectAgentTools.runCall(arguments: CommandLine.arguments) }

var failures = 0
func check(_ condition: Bool, _ message: String, _ detail: String = "", line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line)) \(detail)") }
}

// MARK: Tools

let tools = ProjectAgentTools.tools
let names = tools.map(\.name)
check(names.count == 19 && Set(names).count == 19, "nineteen distinct tools", "\(names)")
check(names.allSatisfy { $0.hasPrefix("markview_") }, "every tool is prefixed")
check(tools.allSatisfy { !$0.description.isEmpty && $0.required.allSatisfy { $0.isEmpty == false && tools.isEmpty == false } }, "every tool is described")
check(tools.allSatisfy { tool in tool.required.allSatisfy { tool.properties[$0] != nil } }, "required arguments are declared")
let readOnly: Set<String> = ["markview_guide", "markview_project", "markview_list_features", "markview_get_feature", "markview_list_bugs", "markview_get_bug", "markview_list_prototypes", "markview_get_prototype"]
check(readOnly.isSubset(of: Set(names)) && names.count - readOnly.count == 11, "eight readers, six writers, five deployments tools")
check(DeploymentAgentTools.names.count == 5 && DeploymentAgentTools.names.isSubset(of: Set(names)), "the deployments tools are among them")
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
check(Set(ProjectAgentTools.guideTopics.map(ProjectAgentTools.guide)).count == ProjectAgentTools.guideTopics.count, "guide topics differ")
check(ProjectAgentTools.guide(nil) == ProjectAgentTools.guide("overview") && ProjectAgentTools.guide("zzz") == ProjectAgentTools.guide("overview"), "the overview is the default")
check(ProjectAgentTools.guide("overview").contains("docs/features/<slug>/") && ProjectAgentTools.guide("overview").contains("never write these files by hand"), "the overview names the folder and forbids hand-written files")
check(ProjectAgentTools.guide("prototype").contains("markview_get_prototype") && ProjectAgentTools.guide("prototype").contains("markview_add_requirement"), "the prototype guide shows the way to features")

// MARK: Bodies

let body = ProjectAgentTools.requirementBody(statement: "The system shall list tickets.", criteria: ["Shows 20 per page", "Sorted by SLA"])
check(body == "## Statement\n\nThe system shall list tickets.\n\n## Acceptance Criteria\n\n- [ ] Shows 20 per page\n- [ ] Sorted by SLA\n", "requirement body", body)
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
check((((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count ?? 0) == 19, "tools/list offers the project tools")
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

// MARK: Stand-in for the app

func spawnApp(serving tool: @escaping (String) -> String) -> (path: String, requests: () -> [[String: Any]], stop: () -> Void) {
    let path = BrowserAgentTools.socketPath(forApp: getpid())
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
                let reply = try! JSONSerialization.data(withJSONObject: BrowserAgentTools.Reply(text: tool(request["tool"] as? String ?? "")).json)
                _ = BrowserAgentTools.writeAll(client, reply + Data("\n".utf8))
            }
            close(client)
        }
    }.start()
    return (path, { lock.lock(); defer { lock.unlock() }; return seen }, { close(listener); unlink(path) })
}

func run(_ arguments: [String], input: String = "", timeout: TimeInterval = 15) -> (out: String, status: Int32) {
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
check(withLines.count == 2 && toolCount(withLines[0]) == 19, "with the app running the project tools are offered", withApp.out)
check(withLines.last?.contains("reply to markview_add_requirement") == true, "a tool call reaches the app and its reply comes back", withApp.out)
let callWithApp = run(["--project-call", "markview_get_feature", "{\"feature\":\"orders\"}"])
check(callWithApp.status == 0 && callWithApp.out.contains("reply to markview_get_feature"), "--project-call reaches the app", callWithApp.out)
let seen = app.requests()
check(seen.count == 2 && seen.last?["tool"] as? String == "markview_get_feature" && (seen.last?["arguments"] as? [String: Any])?["feature"] as? String == "orders"
      && (seen.last?["pids"] as? [Int])?.first == Int(getpid()) && (seen.last?["cwd"] as? String)?.isEmpty == false,
      "the request carries the tool, its arguments, the agent's processes and folder", "\(seen)")

// MARK: Real process: the app quits while the server runs

app.stop()  // the stand-in is the server's parent app by pid; here the app is the fake process below

let fakeApp = Process()
fakeApp.executableURL = URL(fileURLWithPath: "/bin/sleep")
fakeApp.arguments = ["60"]
try! fakeApp.run()
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mv-proj-\(getpid())")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let fakeSocket = dir.appendingPathComponent("mv-browser-\(fakeApp.processIdentifier).sock").path
FileManager.default.createFile(atPath: fakeSocket, contents: nil)
let server = Process()
server.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
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
check(ask(1) == 19, "while MarkView runs the tools are there")
fakeApp.terminate()
fakeApp.waitUntilExit()
check(ask(2) == 0, "when MarkView quits the tools disappear, without restarting the server")
try? sIn.fileHandleForWriting.close()
server.waitUntilExit()
try? FileManager.default.removeItem(at: dir)

print(failures == 0 ? "All project agent tool checks passed." : "\(failures) project agent tool check(s) failed.")
exit(failures == 0 ? 0 : 1)
