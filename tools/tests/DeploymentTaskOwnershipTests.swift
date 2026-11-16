import Foundation

// The owner of the work the Deployments tab starts (AR-19): the shipping DeploymentStore with the real local executor. A tap starts
// work the store keeps in its task bag; a restart replaces it, a close ends it (the process too), and nothing is written after the
// close. Commands that run are real `sh` commands in a temporary folder; a slow one is `cat` on a named pipe or `sleep`.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

/// Polls until `condition` holds or `seconds` pass; the main actor keeps running meanwhile.
@MainActor func waitFor(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return condition()
}

/// How many processes have `needle` in their command line.
func processes(matching needle: String) async -> Int {
    let result = await Subprocess.run(SubprocessSpec(executable: "/usr/bin/pgrep", arguments: ["-f", needle], timeout: 10, maxOutputBytes: 1 << 16))
    return result.stdout.split(separator: "\n").count
}

/// A new project folder with a `.env` that names a database nobody listens at. The store keeps its environments in the folder, so
/// every store of the checks below has a folder of its own.
func newProject() -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-owner-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? "DATABASE_URL=postgresql://u:p@127.0.0.1:1/db\n".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    return folder
}

let database = DatabaseTarget(id: "main", title: "Main", source: .envFile, file: ".env", key: "DATABASE_URL")

@MainActor func run() async {
    let root = newProject()
    var projects = [root]
    defer { for folder in projects { try? FileManager.default.removeItem(at: folder) } }
    func project() -> URL { let folder = newProject(); projects.append(folder); return folder }
    let fifo = root.appendingPathComponent("wait.fifo")
    _ = await Subprocess.run(SubprocessSpec(executable: "/usr/bin/mkfifo", arguments: [fifo.path], timeout: 10, maxOutputBytes: 1 << 10))
    DeploymentStore.approvalTimeout = 30

    let store = DeploymentStore()
    store.setRoot(root)
    var cloud = DeploymentEnvironment(id: "", name: "Cloud", kind: .cloud, provider: "demo")
    cloud.cloudCommands = [CloudCommand(id: "a", title: "Wait", command: "cat '\(fifo.path)'")]
    store.add(cloud)

    // A look is started, and a second one asked for while it runs replaces it: the first ends, with its process.
    store.startRefresh("cloud")
    check(store.tasks.contains(key: "refresh:cloud"), "a look is kept by the store under the environment's key")
    check(await waitFor { runningCount(fifo.path) >= 1 }, "the look's command is running")
    let before = await processes(matching: fifo.path)
    store.startRefresh("cloud")
    check(store.tasks.activeCount == 1, "a second look replaces the first in the store")
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    let afterRestart = await processes(matching: fifo.path)
    check(before >= 1 && afterRestart == before, "the replaced look's command ended; one command is left (\(before) then \(afterRestart))")
    check(store.log.filter { $0.origin == "Refresh" }.isEmpty, "a replaced look noted nothing")
    // Release the pipe: the look that is left finishes and is the only one that writes.
    Task { _ = await Subprocess.run(SubprocessSpec(executable: "/bin/sh", arguments: ["-c", "echo released > '\(fifo.path)'"], timeout: 20, maxOutputBytes: 1 << 10)) }
    check(await waitFor { store.states["cloud"]?.phase == .loaded }, "the look that is left finishes")
    check(store.states["cloud"]?.cloud["a"]?.result.stdout == "released\n" && store.log.filter { $0.origin == "Refresh" }.count == 1,
          "and wrote its answer once")

    // Close: a look under way ends with its command, and the store keeps nothing of it.
    store.startRefresh("cloud")
    check(await waitFor { runningCount(fifo.path) >= 1 }, "a new look waits at the pipe")
    store.close()
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    let afterClose = await processes(matching: fifo.path)
    check(afterClose == 0, "closing the window ended the look's command (\(afterClose) left)")
    check(store.tasks.activeCount == 0 && store.states["cloud"]?.phase == .loading && store.log.filter { $0.origin == "Refresh" }.count == 1,
          "and nothing was written after the close")

    // The command box: one waits for the person's yes, a second start is dropped, the yes runs it, a close ends it.
    let store2 = DeploymentStore()
    store2.setRoot(project())
    store2.add(DeploymentEnvironment(id: "", name: "Local", kind: .local))
    let marker = root.appendingPathComponent("marker.txt")
    store2.startCommand("sleep 28.7391", on: "local")
    check(store2.consoles["local"]?.running == true, "a started command shows that it runs")
    store2.startCommand("touch '\(marker.path)'", on: "local")
    check(await waitFor { store2.approval != nil }, "a command that is not read-only waits for the person")
    check(store2.approval?.command == "sleep 28.7391", "the second start while one runs was dropped")
    store2.answer(true)
    check(await waitFor { runningCount("sleep 28.7391") >= 1 }, "after the yes it runs")
    store2.close()
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    check(await processes(matching: "sleep 28.7391") == 0, "closing the window ended the command")
    check(store2.consoles["local"]?.output == nil, "and it printed nothing after the close")
    check(!FileManager.default.fileExists(atPath: marker.path), "the dropped command never ran")

    // A command waiting for the yes when the window closes counts as no and is never run.
    let store3 = DeploymentStore()
    store3.setRoot(project())
    store3.add(DeploymentEnvironment(id: "", name: "Local", kind: .local))
    store3.startCommand("touch '\(marker.path)'", on: "local")
    check(await waitFor { store3.approval != nil }, "a command waits for the yes")
    store3.close()
    try? await Task.sleep(nanoseconds: 500_000_000)
    check(!FileManager.default.fileExists(atPath: marker.path) && store3.approval == nil && store3.consoles["local"]?.output == nil,
          "a close answers no: it did not run and printed nothing")

    // The commands that run at once fill the log reader and the output, and end.
    let store4 = DeploymentStore()
    store4.setRoot(project())
    store4.add(DeploymentEnvironment(id: "", name: "Local", kind: .local))
    store4.startLogFetch("printf 'one\\ntwo'", on: "local")
    check(await waitFor { store4.consoles["local"]?.running == false && store4.consoles["local"]?.log.contains("one\ntwo") == true },
          "a log fetch fills the log reader and ends")
    store4.startCommand("printf 'ab%sef' cd", on: "local")
    check(await waitFor { store4.consoles["local"]?.running == false && store4.consoles["local"]?.output?.contains("abcdef") == true },
          "a command fills the output and ends")
    check(store4.states["local"] == nil, "a read-only command is not followed by a look")
    // A new folder drops what the old one had: nothing of it is shown, and nothing stays running.
    store4.startCommand("touch '\(marker.path)'", on: "local")
    check(await waitFor { store4.approval != nil }, "another command waits for the yes")
    store4.setRoot(project())
    check(store4.consoles.isEmpty && store4.tasks.activeCount == 0, "opening another folder ends the command and forgets the consoles")
    store4.close()

    // Databases: a statement the policy blocks is answered at once; one that is let through ends with an answer or a problem; a started
    // look is the store's, ends with a close, and a disconnect ends what asked the database.
    let store5 = DeploymentStore()
    store5.setRoot(project())
    var withDb = DeploymentEnvironment(id: "", name: "Local", kind: .local)
    withDb.databaseList = [database]
    store5.add(withDb)
    // A psql meta-command never runs: the policy blocks it before anything is asked of the database.
    store5.startQuery("\\! echo hi", env: "local", target: "main")
    check(await waitFor { store5.databaseState("local", "main").running == false && store5.databaseState("local", "main").message != nil },
          "a blocked statement ends with what the SQL box says")
    store5.startQuery("select 1", env: "local", target: "main")
    check(store5.databaseState("local", "main").running, "a statement that is let through shows that it runs")
    check(await waitFor(30) {
        let state = store5.databaseState("local", "main")
        return !state.running && (state.lastError != nil || state.last != nil)
    }, "and ends with an answer or a problem")
    // The statement's own task leaves the bag a moment after the state it wrote shows an answer; wait for that, or a slow machine counts it.
    check(await waitFor { store5.tasks.activeCount == 0 }, "the statement's own task has left the bag")
    store5.startOverview(env: "local", target: "main")
    store5.startOverview(env: "local", target: "main")
    check(store5.tasks.activeCount == 1 && store5.tasks.contains(key: "overview:local|main"), "a second look at a database replaces the first")
    store5.disconnectDatabase(env: "local", target: "main")
    check(!store5.tasks.contains(key: "overview:local|main"), "a disconnect ends the look at the database")
    try? await Task.sleep(nanoseconds: 800_000_000)
    check(store5.databaseStates["local|main"] == nil, "and nothing of the database comes back after it")
    store5.startServices("local")
    check(store5.tasks.contains(key: "services:local"), "the list of services is started under its own key")
    store5.close()
    check(store5.tasks.activeCount == 0, "a close ends everything the store started")

    print(failures == 0 ? "All deployment ownership checks passed." : "\(failures) deployment ownership check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

/// How many processes have `needle` in their command line, asked without awaiting (the poll of `waitFor` is synchronous).
@MainActor func runningCount(_ needle: String) -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", needle]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").count
}

Task { await run() }
RunLoop.main.run()
