import Foundation

// Checks the MCP server agents use to drive MarkView's browser tab (MarkView/Models/BrowserAgentTools.swift):
// the MCP answers, and a real `--mcp-browser` process relaying a tool call over a Unix socket to a
// stand-in for the app. Compiled by tools/tests/browser-agent-tools-tests.sh.

if CommandLine.arguments.contains("--mcp-browser") { BrowserAgentTools.runServer(arguments: CommandLine.arguments) }

var failures = 0
func check(_ condition: Bool, _ message: String, _ detail: String = "", line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line)) \(detail)") }
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
var address = BrowserAgentTools.unixAddress(socketPath)!
_ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
listen(listener, 4)
nonisolated(unsafe) var received: [String: Any] = [:]
let served = DispatchSemaphore(value: 0)
Thread {
    let client = accept(listener, nil, nil)
    if let line = BrowserAgentTools.readLine(client) { received = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:] }
    let reply = try! JSONSerialization.data(withJSONObject: BrowserAgentTools.Reply(text: "Page: http://localhost:5173/ — Garden").json)
    _ = BrowserAgentTools.writeAll(client, reply + Data("\n".utf8))
    close(client)
    served.signal()
}.start()

// MARK: A real --mcp-browser process

let process = Process()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
process.arguments = ["--mcp-browser"]
let input = Pipe(), output = Pipe()
process.standardInput = input
process.standardOutput = output
try! process.run()
let messages: [[String: Any]] = [
    ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]],
    ["jsonrpc": "2.0", "method": "notifications/initialized"],
    ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "browser_navigate", "arguments": ["url": "localhost:5173"]]],
]
for message in messages { input.fileHandleForWriting.write(try! JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)) }
try! input.fileHandleForWriting.close()
let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
process.waitUntilExit()
_ = served.wait(timeout: .now() + 5)
let lines = out.split(separator: "\n").map(String.init)
check(lines.count == 2, "two answers for two requests (the notification gets none)", out)
check(received["tool"] as? String == "browser_navigate" && (received["pids"] as? [Int])?.first == Int(getpid())
      && (received["arguments"] as? [String: Any])?["url"] as? String == "localhost:5173",
      "found through its parent process, the call reached the app with its ancestors", "\(received)")
check(lines.last?.contains("Garden") == true, "the app's reply came back as the tool result", out)
let unreachable = BrowserAgentTools.request(socket: socketPath + ".missing", payload: [:], timeout: 1)
check(unreachable.isError && unreachable.text.contains("not reachable"), "a closed app is reported, not hung on")
unlink(socketPath)

print(failures == 0 ? "All browser agent tool checks passed." : "\(failures) browser agent tool check(s) failed.")
exit(failures == 0 ? 0 : 1)
