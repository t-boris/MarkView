import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func start(_ script: String) throws -> SubprocessChild {
    let child = try Subprocess.start(
        SubprocessSpec(executable: "/bin/sh", arguments: ["-c", script], timeout: 0),
        onExit: { child, _ in AgentProcesses.remove(child) })
    AgentProcesses.add(child)
    return child
}

let polite = try start("sleep 60")
let stubborn = try start("trap '' TERM; while true; do sleep 1; done")
let finished = try start("exit 0")
let finishedExit = DispatchSemaphore(value: 0)
Task { await finished.waitForExit(); finishedExit.signal() }
check(finishedExit.wait(timeout: .now() + 5) == .success, "the short process ended")
Thread.sleep(forTimeInterval: 0.3)
check(AgentProcesses.count == 2, "finished process is forgotten")
check(polite.isRunning && stubborn.isRunning, "both running before quit")
DispatchQueue.concurrentPerform(iterations: 200) { _ in
    AgentProcesses.add(polite)
    AgentProcesses.add(stubborn)
}
check(AgentProcesses.count == 2, "concurrent registration retains both processes")

let began = Date()
AgentProcesses.terminateAll(grace: 0.5)
let took = Date().timeIntervalSince(began)
Thread.sleep(forTimeInterval: 0.2)
check(!polite.isRunning, "normal process stopped")
check(!stubborn.isRunning, "process ignoring SIGTERM killed")
check(took < 2, "quit is not held up (\(String(format: "%.2f", took)) s)")
print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
