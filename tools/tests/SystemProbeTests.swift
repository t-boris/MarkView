import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

// Parsing a Linux answer.
let linux = """
@@MV|os|Linux
@@MV|host|web-1
@@MV|kernel|6.1.0
@@MV|uptime|307234
@@MV|cpus|4
@@MV|load|0.52 0.40 0.35
@@MV|memtotal|8000000
@@MV|memavail|6000000
@@MV|disk|/|50000000|42000000|84
@@MV|disk|/data|100000000|20000000|20
@@MV|proc|812|35.2|4.1|node
@@MV|proc|7|0.3|0.1|sshd
@@MV|container|web|Up 3 days|nginx:1.25
@@MV|container|db|Up 3 days (healthy)|postgres:16
@@MV|failed|backup.service
@@MV|check|nginx|ok|active
@@MV|check|api|fail|503
noise that is not ours
"""
let snap = SystemProbe.parse(linux)
check(snap.os == "Linux" && snap.host == "web-1" && snap.cpus == 4 && snap.uptimeSeconds == 307234, "basic fields")
check(snap.load == [0.52, 0.40, 0.35] && abs(snap.loadPerCPU - 0.13) < 0.001, "load")
check(snap.memUsedKB == 2_000_000 && abs(snap.memUsedFraction - 0.25) < 0.001, "memory")
check(snap.disks.count == 2 && snap.disks[0].percent == 84 && snap.disks[0].mount == "/", "disks")
check(snap.processes.first?.name == "node" && snap.processes.first?.cpu == 35.2, "processes")
check(snap.containers.map(\.name) == ["web", "db"] && snap.containers[1].status == "Up 3 days (healthy)", "containers")
check(snap.failedUnits == ["backup.service"], "failed units")
check(snap.checks.count == 2 && snap.checks[1].status == .fail && snap.checks[1].detail == "503", "checks")
check(snap.health == .critical, "a failed check makes it critical")
check(snap.reasons.contains("Disk / is 84 % full") && snap.reasons.contains { $0.contains("Failed units") } && snap.reasons.contains { $0.hasPrefix("Check api failed") }, "reasons: \(snap.reasons)")

var healthy = SystemSnapshot(); healthy.cpus = 2; healthy.load = [0.2, 0.2, 0.2]; healthy.memTotalKB = 100; healthy.memAvailableKB = 60
healthy.disks = [.init(mount: "/", sizeKB: 100, usedKB: 40, percent: 40)]
check(healthy.health == .ok && healthy.reasons.isEmpty, "a quiet machine is ok")
healthy.disks = [.init(mount: "/", sizeKB: 100, usedKB: 85, percent: 85)]
check(healthy.health == .warning, "a disk at 85 % warns")
healthy.disks = [.init(mount: "/", sizeKB: 100, usedKB: 95, percent: 95)]
check(healthy.health == .critical, "a disk at 95 % is critical")
healthy.disks = []; healthy.load = [7.0, 1, 1]
check(healthy.health == .critical, "load above 3 per CPU is critical")
check(SystemProbe.parse("").health == .ok && SystemProbe.parse("garbage").os == "", "empty and malformed output is harmless")
check(SystemProbe.uptimeText(307234) == "3 d 13 h" && SystemProbe.uptimeText(3720) == "1 h 2 min" && SystemProbe.uptimeText(120) == "2 min", "uptime text: \(SystemProbe.uptimeText(307234))")

// Quoting is safe.
check(SystemProbe.quoted("it's") == "'it'\\''s'", "single quotes are escaped")
let evil = DeploymentCheck(id: "x", title: "x", kind: .systemd, target: "a'; touch /tmp/pwned; echo '")
check(SystemProbe.script(checks: [evil]).contains("'a'\\''; touch /tmp/pwned; echo '\\'''"), "a hostile target stays inside quotes")
let held = SystemProbe.runnable([DeploymentCheck(id: "a", title: "a", kind: .command, target: "df -h"), DeploymentCheck(id: "b", title: "b", kind: .command, target: "rm -rf /tmp/x"), DeploymentCheck(id: "c", title: "c", kind: .systemd, target: "nginx")])
check(held.run.map(\.id) == ["a", "c"] && held.held.map(\.id) == ["b"], "a command check that is not read-only is held")

// The real script, on this machine.
func shell(_ script: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-s"]
    let input = Pipe(), output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    p.standardError = FileHandle.nullDevice
    try? p.run()
    input.fileHandleForWriting.write(Data(script.utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
let checks = [DeploymentCheck(id: "uname", title: "uname", kind: .command, target: "uname -s", expect: ""),
              DeploymentCheck(id: "bad", title: "bad", kind: .command, target: "ls /definitely/not/here", expect: ""),
              DeploymentCheck(id: "want", title: "want", kind: .command, target: "echo hello world", expect: "world"),
              DeploymentCheck(id: "port", title: "closed port", kind: .port, target: "127.0.0.1:1"),
              DeploymentCheck(id: "http", title: "no server", kind: .http, target: "http://127.0.0.1:1/")]
let live = SystemProbe.parse(shell(SystemProbe.script(checks: checks)))
check(!live.os.isEmpty && !live.host.isEmpty, "live: os and host (\(live.os) \(live.host))")
check(live.cpus > 0, "live: cpus \(live.cpus)")
check(live.memTotalKB > 0 && live.memAvailableKB > 0 && live.memAvailableKB <= live.memTotalKB, "live: memory \(live.memAvailableKB)/\(live.memTotalKB) KB")
check(live.uptimeSeconds > 60 && live.uptimeSeconds < 86_400 * 365 * 2, "live: uptime \(live.uptimeSeconds) s")
check(live.load.count == 3, "live: load \(live.load)")
check(!live.disks.isEmpty && !live.disks.contains { $0.mount.hasPrefix("/Library/Developer") } && live.disks.allSatisfy { (0...100).contains($0.percent) }, "live: disks \(live.disks.map { "\($0.mount) \($0.percent)%" })")
check(!live.processes.isEmpty, "live: processes")
check(live.checks.first { $0.id == "uname" }?.status == .ok && live.checks.first { $0.id == "uname" }?.detail == "exit 0", "live: a command check passes")
check(live.checks.first { $0.id == "bad" }?.status == .fail && live.checks.first { $0.id == "bad" }?.detail.hasPrefix("exit ") == true, "live: a failing command check reports its exit status: \(live.checks.first { $0.id == "bad" }?.detail ?? "-")")
check(live.checks.first { $0.id == "want" }?.status == .ok, "live: a command check that expects text")
check(live.checks.first { $0.id == "port" }?.status == .fail, "live: a closed port fails")
check(live.checks.first { $0.id == "http" }?.status == .fail, "live: a missing server fails")
check(live.health >= .critical, "live: a failed check makes it critical")

print(failures == 0 ? "All system probe checks passed." : "\(failures) system probe check(s) failed.")
exit(failures == 0 ? 0 : 1)
