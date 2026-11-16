import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

func entry(_ label: String) -> AICallLog.Entry {
    AICallLog.Entry(timestamp: Date(timeIntervalSince1970: 1_800_000_000), project: "demo", label: label, tool: "claude", model: "m",
                    effort: "low", seconds: 1.5, inputTokens: 10, outputTokens: 20, costUSD: nil, outcome: "ok")
}

/// `record` writes on its own queue: wait until the log shows `count` entries (or give up after five seconds).
func entries(waitingFor count: Int) -> [AICallLog.Entry] {
    var found = AICallLog.read()
    let deadline = Date().addingTimeInterval(5)
    while found.count < count && Date() < deadline { Thread.sleep(forTimeInterval: 0.02); found = AICallLog.read() }
    return found
}

check(AICallLog.url.path.hasPrefix(NSHomeDirectory()) && NSHomeDirectory().contains("/home"), "the log lives under the scratch home, not the person's")
check(AICallLog.read().isEmpty, "a log that does not exist yet reads as empty")

// The first call creates the folder and the file; the next ones follow in order.
AICallLog.record(entry("first"))
AICallLog.record(entry("second"))
AICallLog.record(entry("third"))
check(entries(waitingFor: 3).map(\.label) == ["first", "second", "third"], "the calls are written in order")
let text = (try? String(contentsOf: AICallLog.url, encoding: .utf8)) ?? ""
check(text.hasSuffix("\n") && text.split(separator: "\n").count == 3, "one line per call")

// Many threads at once: the file is neither cut nor does a call overwrite another.
DispatchQueue.concurrentPerform(iterations: 8) { thread in
    for call in 0..<25 { AICallLog.record(entry("t\(thread)-c\(call)")) }
}
let all = entries(waitingFor: 3 + 200)
check(all.count == 203 && Set(all.map(\.label)).count == 203, "200 calls from 8 threads are all in the log, once each (\(all.count))")
check(Array(all.prefix(3).map(\.label)) == ["first", "second", "third"], "the earlier calls stay in front")

// A log that cannot be written keeps what it holds; the call is dropped, and the next one that can be written follows.
let before = (try? String(contentsOf: AICallLog.url, encoding: .utf8)) ?? ""
chmod(AICallLog.url.path, 0o444)
AICallLog.record(entry("dropped"))
Thread.sleep(forTimeInterval: 1)
chmod(AICallLog.url.path, 0o644)
check((try? String(contentsOf: AICallLog.url, encoding: .utf8)) == before, "a log the file system refuses is left as it was")
AICallLog.record(entry("after"))
let last = entries(waitingFor: 204)
check(last.count == 204 && last.last?.label == "after" && !last.contains { $0.label == "dropped" }, "the next call is added after the old lines")

if failures > 0 { exit(1) }
print("All AI call log checks passed")
