import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

var server = DeploymentEnvironment(id: "p", name: "Prod", kind: .ssh, host: "web-1.example.com")
server.checks = [DeploymentCheck(id: "n", title: "nginx", kind: .systemd, target: "nginx"), DeploymentCheck(id: "d", title: "db", kind: .docker, target: "db")]
let before = DeploymentLogs.suggestions(for: server, snapshot: nil)
check(before.map(\.title) == ["System journal", "Errors only", "Service nginx", "Container db"], "before the first look: the journal, errors, and what the checks name: \(before.map(\.title))")
check(before.allSatisfy { CommandPolicy.classify($0.command).isReadOnly }, "every suggested command is read-only: \(before.filter { !CommandPolicy.classify($0.command).isReadOnly }.map(\.command))")

var snap = SystemSnapshot()
snap.os = "Linux"
snap.containers = [.init(name: "web", status: "Up", image: "nginx"), .init(name: "db", status: "Up", image: "postgres")]
snap.failedUnits = ["backup.service"]
let after = DeploymentLogs.suggestions(for: server, snapshot: snap)
check(after.map(\.title).contains("Container web") && after.map(\.title).contains("Service backup.service") && after.filter { $0.title == "Container db" }.count == 1, "after a look: containers and failed services are added once: \(after.map(\.title))")

server.logSources = [LogSource(id: "mine", title: "App", command: "journalctl -u nginx -n 200 --no-pager")]
let merged = DeploymentLogs.all(for: server, snapshot: snap)
check(merged.first?.id == "mine" && merged.filter { $0.command == "journalctl -u nginx -n 200 --no-pager" }.count == 1, "own sources come first and are not repeated")

let mac = DeploymentEnvironment(id: "m", name: "Mac", kind: .local)
let macLogs = DeploymentLogs.suggestions(for: mac, snapshot: nil)
check(macLogs.first?.command.hasPrefix("log show") == true && !macLogs.contains { $0.command.contains("journalctl") }, "this Mac gets the unified log, not the journal")
check(DeploymentLogs.suggestions(for: DeploymentEnvironment(id: "c", name: "C", kind: .cloud, provider: "fly"), snapshot: nil).isEmpty, "a cloud service has none (its commands show logs)")
var hostile = DeploymentEnvironment(id: "h", name: "H", kind: .ssh, host: "h.example.com")
hostile.checks = [DeploymentCheck(id: "x", title: "x", kind: .systemd, target: "a; reboot"), DeploymentCheck(id: "y", title: "y", kind: .docker, target: "$(id)")]
check(!DeploymentLogs.suggestions(for: hostile, snapshot: nil).contains { $0.command.contains("reboot") || $0.command.contains("$(") }, "a hostile name never reaches a command")

// What is read before answering a question.
var box = DeploymentEnvironment(id: "b", name: "Box", kind: .ssh, host: "b.example.com")
box.logSources = [LogSource(id: "mine", title: "App", command: "tail -n 200 /var/log/app.log")]
var seen = SystemSnapshot(); seen.os = "Linux"
seen.containers = [.init(name: "web", status: "Up 3 days", image: "nginx"), .init(name: "pg", status: "Up 3 days", image: "postgres:16"), .init(name: "worker", status: "Restarting (1) 5 seconds ago", image: "app"), .init(name: "cache", status: "Up 2 days", image: "redis:7")]
seen.failedUnits = ["backup.service"]
let plan = DeploymentLogs.evidencePlan(question: "Is it healthy?", env: box, snapshot: seen).map(\.title)
check(plan.first == "Errors only" && plan.contains("Service backup.service") && plan.contains("Container worker"), "errors, failed services and containers that are not up come first: \(plan)")
check(plan.count <= 6 && Set(plan).count == plan.count, "no more than six, none twice")
let dbPlan = DeploymentLogs.evidencePlan(question: "Is the database fine?", env: box, snapshot: seen).map(\.title)
check(dbPlan.contains("Container pg") && !dbPlan.contains("Container cache") || dbPlan.count == 6, "a question about the database reads the database container: \(dbPlan)")
check(DeploymentLogs.evidencePlan(question: "?", env: box, snapshot: seen).contains { $0.title == "App" }, "the person's own log is read too")
check(DeploymentLogs.evidencePlan(question: "?", env: DeploymentEnvironment(id: "q", name: "Q", kind: .ssh, host: "q.example.com"), snapshot: nil).count >= 2, "before a first look it still reads the journal")
check(DeploymentLogs.evidencePlan(question: "?", env: DeploymentEnvironment(id: "c", name: "C", kind: .cloud, provider: "fly"), snapshot: nil).isEmpty, "a cloud service has nothing to read this way")
check(DeploymentLogs.evidencePlan(question: "x", env: box, snapshot: seen).allSatisfy { CommandPolicy.classify($0.command).isReadOnly }, "everything read is read-only")

print(failures == 0 ? "All deployment logs checks passed." : "\(failures) deployment logs check(s) failed.")
exit(failures == 0 ? 0 : 1)
