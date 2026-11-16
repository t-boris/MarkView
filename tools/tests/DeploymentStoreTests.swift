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

    // The file is a schema-versioned store (AR-36): enveloped when saved, a file written before it still loads, a file that cannot
    // be read is never replaced without a backup, a newer file is never replaced.
    let legacyFixture = """
    {
      "environments" : [
        {
          "checks" : [ { "expect" : "", "id" : "uname", "kind" : "command", "target" : "uname -s", "title" : "uname" } ],
          "cloudCommands" : [],
          "evidence" : [],
          "host" : "",
          "id" : "this-mac",
          "identityFile" : "",
          "kind" : "local",
          "logSources" : [],
          "name" : "This Mac",
          "notes" : "kept",
          "port" : 22,
          "provider" : "",
          "user" : ""
        }
      ],
      "version" : 1
    }
    """
    let legacyRoot = StoreFixture.folder("deploy-legacy")
    defer { try? FileManager.default.removeItem(at: legacyRoot) }
    let deployFile = legacyRoot.appendingPathComponent(".dde/deployments.json")
    StoreFixture.write(legacyFixture, to: deployFile)
    let upgraded = DeploymentStore()
    upgraded.setRoot(legacyRoot)
    check(upgraded.environments.map(\.id) == ["this-mac"] && upgraded.environments.first?.notes == "kept" && upgraded.lastError == nil,
          "legacy file: the environments and their notes load")
    check(StoreFixture.envelope(deployFile) == nil, "legacy file: it is left as written until a change is saved")
    upgraded.add(DeploymentEnvironment(id: "", name: "Second", kind: .local))
    check(StoreFixture.envelope(deployFile)?.schema == 1 && StoreFixture.backups(of: deployFile).isEmpty, "legacy file: the next save writes the envelope, with no backup")
    let reloaded = DeploymentStore()
    reloaded.setRoot(legacyRoot)
    check(reloaded.environments.map(\.id) == ["this-mac", "second"], "legacy file: the envelope reloads with both environments")

    let damagedRoot = StoreFixture.folder("deploy-damaged")
    defer { try? FileManager.default.removeItem(at: damagedRoot) }
    let damagedFile = damagedRoot.appendingPathComponent(".dde/deployments.json")
    StoreFixture.write("{ \"environments\": [ { \"id\": ", to: damagedFile)
    let damaged = DeploymentStore()
    damaged.setRoot(damagedRoot)
    check(damaged.environments.isEmpty && damaged.lastError?.contains("deployments.json") == true, "damaged file: nothing is listed and the problem is shown")
    check(StoreFixture.bytes(damagedFile) == Data("{ \"environments\": [ { \"id\": ".utf8) && StoreFixture.backups(of: damagedFile).isEmpty,
          "damaged file: loading leaves it as it is")
    damaged.add(DeploymentEnvironment(id: "", name: "Fresh", kind: .local))
    check(StoreFixture.backups(of: damagedFile).count == 1 && StoreFixture.bytes(StoreFixture.backups(of: damagedFile)[0]) == Data("{ \"environments\": [ { \"id\": ".utf8)
          && StoreFixture.envelope(damagedFile)?.schema == 1, "damaged file: a change keeps the old bytes in a dated backup and writes the new list")

    let newerRoot = StoreFixture.folder("deploy-newer")
    defer { try? FileManager.default.removeItem(at: newerRoot) }
    let newerFile = newerRoot.appendingPathComponent(".dde/deployments.json")
    StoreFixture.write(StoreFixture.newerFile(payload: #"{"environments":[],"future":1}"#), to: newerFile)
    let newer = DeploymentStore()
    newer.setRoot(newerRoot)
    check(newer.environments.isEmpty && newer.lastError?.contains("newer") == true, "newer file: it is not used and the person is told")
    newer.add(DeploymentEnvironment(id: "", name: "Fresh", kind: .local))
    check(StoreFixture.bytes(newerFile) == Data(StoreFixture.newerFile(payload: #"{"environments":[],"future":1}"#).utf8) && newer.lastError?.contains("Could not save") == true,
          "newer file: a change is refused and the file is untouched")

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
    // The log is read again by the next window, and a note that cannot be written is dropped without touching the lines before it.
    let logFile = root.appendingPathComponent(".dde/deployments-log.jsonl")
    let reopened = DeploymentStore()
    reopened.setRoot(root)
    check(reopened.log.map(\.id) == store.log.map(\.id), "a second window reads the same log back")
    chmod(logFile.path, 0o444)
    store.note(CommandLogEntry(time: Date(), environment: "this-mac", command: "echo dropped", origin: "test", outcome: "ran", status: 0))
    chmod(logFile.path, 0o644)
    check((try? String(contentsOf: logFile, encoding: .utf8)) == logText, "a note the file cannot take leaves the earlier lines as they were")
    store.note(CommandLogEntry(time: Date(), environment: "this-mac", command: "echo kept", origin: "test", outcome: "ran", status: 0))
    let grown = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    check(grown.hasPrefix(logText) && grown.hasSuffix("\n") && grown.contains("echo kept") && !grown.contains("echo dropped"), "the next note is added after them")

    // A line of the log that cannot be read (cut by an interrupted write, or made by another version) is skipped when the log is read
    // again, and stays in the file: reading never rewrites the log, and the next command is appended after it (AR-36).
    let logFile = root.appendingPathComponent(".dde/deployments-log.jsonl")
    let keptLines = logText.split(separator: "\n").count
    if let handle = try? FileHandle(forWritingTo: logFile) {
        handle.seekToEndOfFile(); handle.write(Data("{ cut off\n".utf8)); try? handle.close()
    }
    let damagedBefore = (try? Data(contentsOf: logFile)) ?? Data()
    let reread = DeploymentStore()
    reread.setRoot(root)
    check(reread.log.count == keptLines, "a damaged line of the command log is skipped, the \(keptLines) others load (\(reread.log.count))")
    check((try? Data(contentsOf: logFile)) == damagedBefore, "reading the log leaves the file as it was, damaged line included")
    reread.note(CommandLogEntry(time: Date(), environment: "this-mac", command: "uptime", origin: "You", outcome: "ran"))
    let afterNote = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    check(afterNote.contains("{ cut off") && afterNote.contains("uptime"), "the next command is appended after the damaged line")

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
