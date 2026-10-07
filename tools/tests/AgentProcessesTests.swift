import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func start(_ script: String) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script]
    p.terminationHandler = { AgentProcesses.remove($0) }
    try p.run()
    AgentProcesses.add(p)
    return p
}

let polite = try start("sleep 60")
let stubborn = try start("trap '' TERM; while true; do sleep 1; done")
let finished = try start("exit 0")
finished.waitUntilExit()
Thread.sleep(forTimeInterval: 0.3)
check(AgentProcesses.count == 2, "finished process is forgotten")
check(polite.isRunning && stubborn.isRunning, "both running before quit")

let began = Date()
AgentProcesses.terminateAll(grace: 0.5)
let took = Date().timeIntervalSince(began)
Thread.sleep(forTimeInterval: 0.2)
check(!polite.isRunning, "normal process stopped")
check(!stubborn.isRunning, "process ignoring SIGTERM killed")
check(took < 2, "quit is not held up (\(String(format: "%.2f", took)) s)")
print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
