import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

@MainActor func run() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-store-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("approved.txt")
    DeploymentStore.approvalTimeout = 1.5

    let store = DeploymentStore()
    store.setRoot(root)
    var mac = DeploymentEnvironment(id: "", name: "This Mac", kind: .local)
    mac.checks = [DeploymentCheck(id: "uname", title: "uname", kind: .command, target: "uname -s"),
                  DeploymentCheck(id: "held", title: "held", kind: .command, target: "touch \(marker.path)")]
    mac.logSources = [LogSource(id: "l1", title: "ls", command: "ls /")]
    store.add(mac)
    check(store.environments.count == 1 && store.environments[0].id == "this-mac" && store.selected == "this-mac", "an environment is added with an id")

    // Saved and loaded.
    let again = DeploymentStore()
    again.setRoot(root)
    check(again.environments == store.environments, "environments are saved in .dde/deployments.json and loaded again")
    let text = (try? String(contentsOf: root.appendingPathComponent(".dde/deployments.json"), encoding: .utf8)) ?? ""
    check(!text.lowercased().contains("password"), "the file holds no secrets")

    // Looking.
    await store.refresh("this-mac")
    let state = store.states["this-mac"]
    check(state?.phase == .loaded && state?.snapshot?.os == "Darwin" && (state?.snapshot?.cpus ?? 0) > 0, "refresh reads this machine")
    check(state?.snapshot?.checks.first { $0.id == "uname" }?.status == .ok, "a read-only command check ran")
    check(state?.held.map(\.id) == ["held"] && !FileManager.default.fileExists(atPath: marker.path), "a check that is not read-only is held and did not run")
    check(state?.history.count == 1, "history keeps a sample")
    check(store.report().contains("This Mac") && store.report().contains("check uname: ok") && store.report(for: "this-mac").contains("health:"), "the report says what was seen")

    // Running commands.
    if case .ran(let r) = await store.run("printf 'ab%sef' cd", on: "this-mac", origin: "You") { check(r.stdout == "abcdef", "a read-only command runs at once") } else { check(false, "a read-only command runs at once") }
    check(store.approval == nil, "and asked nobody")
    if case .blocked(let why) = await store.run("shutdown -h now", on: "this-mac", origin: "The assistant") { check(why.contains("never runs"), "a blocked command never runs") } else { check(false, "a blocked command never runs") }
    if case .unavailable = await store.run("echo x", on: "nope", origin: "You") { check(true, "an unknown environment is refused") } else { check(false, "an unknown environment is refused") }

    // Approval: yes.
    async let approved = store.run("touch \(marker.path)", on: "this-mac", origin: "The assistant", purpose: "a test")
    for _ in 0..<50 where store.approval == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
    check(store.approval?.command == "touch \(marker.path)" && store.approval?.origin == "The assistant" && store.approval?.purpose == "a test", "a command that is not read-only waits for the person")
    check(!FileManager.default.fileExists(atPath: marker.path), "and has not run while it waits")
    store.answer(true)
    if case .ran = await approved { check(FileManager.default.fileExists(atPath: marker.path), "after a yes it runs") } else { check(false, "after a yes it runs") }
    try? FileManager.default.removeItem(at: marker)

    // Approval: no.
    async let refused = store.run("touch \(marker.path)", on: "this-mac", origin: "The assistant")
    for _ in 0..<50 where store.approval == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
    store.answer(false)
    if case .denied = await refused { check(!FileManager.default.fileExists(atPath: marker.path), "after a no it does not run, and says so") } else { check(false, "after a no it does not run, and says so") }

    // Approval: nobody answers.
    let started = Date()
    if case .denied = await store.run("touch \(marker.path)", on: "this-mac", origin: "The assistant") {
        check(!FileManager.default.fileExists(atPath: marker.path) && Date().timeIntervalSince(started) < 6, "a request nobody answers counts as no (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
    } else { check(false, "a request nobody answers counts as no") }
    check(store.approval == nil, "and leaves nothing on screen")

    // The log of commands.
    let kinds = store.log.map(\.outcome)
    check(kinds.contains("ran") && kinds.contains("blocked") && kinds.filter { $0 == "denied" }.count == 2, "every command is noted: \(kinds)")
    let logText = (try? String(contentsOf: root.appendingPathComponent(".dde/deployments-log.jsonl"), encoding: .utf8)) ?? ""
    check(logText.split(separator: "\n").count == store.log.count && logText.contains("shutdown"), "the log file has a line per command")
    check(!logText.contains("abcdef"), "the log holds commands, not their output")

    // Proposals.
    var s = DeploymentSuggestion(id: "prod", name: "Production", kind: .ssh, host: "web-1.example.com", user: "deploy")
    s.missing = ["Which key?"]
    store.propose(s)
    check(store.suggestions.map(\.id) == ["prod"], "a proposal waits under suggestions")
    store.accept(s)
    check(store.suggestions.isEmpty && store.environment("production")?.host == "web-1.example.com" && store.environment("production")?.notes == "Which key?", "accepting it adds the environment with its notes")
    var bad = DeploymentEnvironment(id: "x", name: "Bad", kind: .ssh, host: "-oProxyCommand=evil")
    bad.id = "bad"
    store.add(bad)
    if case .unavailable(let why) = await store.run("uptime", on: "bad", origin: "You") { check(why.contains("not set up properly"), "an invalid ssh environment never reaches ssh") } else { check(false, "an invalid ssh environment never reaches ssh") }

    // A cloud environment: commands of its CLI run here, read-only ones by themselves.
    var cloud = DeploymentEnvironment(id: "", name: "Cloud app", kind: .cloud, provider: "demo")
    cloud.cloudCommands = [CloudCommand(id: "a", title: "Echo", command: "echo cloud-ok"), CloudCommand(id: "b", title: "Change", command: "touch \(marker.path)")]
    cloud.checks = [DeploymentCheck(id: "h", title: "no server", kind: .http, target: "http://127.0.0.1:1/")]
    store.add(cloud)
    try? FileManager.default.removeItem(at: marker)
    await store.refresh("cloud-app")
    let cloudState = store.states["cloud-app"]
    check(cloudState?.cloud["a"]?.result.stdout == "cloud-ok\n", "a read-only cloud command runs on refresh")
    check(cloudState?.cloud["b"] == nil && !FileManager.default.fileExists(atPath: marker.path), "a cloud command that is not read-only does not run by itself")
    check(cloudState?.snapshot?.checks.first?.status == .fail && cloudState?.snapshot?.os == "cloud", "checks of a cloud environment run from this Mac")

    // Removing.
    store.remove("this-mac")
    check(store.environment("this-mac") == nil && DeploymentStore().environments.isEmpty, "removing is saved")

    print(failures == 0 ? "All deployment store checks passed." : "\(failures) deployment store check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

Task { await run() }
RunLoop.main.run()
