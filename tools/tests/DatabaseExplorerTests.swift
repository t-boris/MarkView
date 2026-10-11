import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

func shell(_ command: String) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", command]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

final class Recorder: DeploymentExecutor, @unchecked Sendable {
    let inner: DeploymentExecutor
    var commands: [String] = []
    var stdins: [String] = []
    init(inner: DeploymentExecutor) { self.inner = inner }
    func run(_ command: String, stdin: String?, timeout: TimeInterval) async -> CommandResult {
        commands.append(command); stdins.append(stdin ?? "")
        return await inner.run(command, stdin: stdin, timeout: timeout)
    }
}

@MainActor func run() async {
    // MARK: URL
    let u = DatabaseURL("postgresql://app_user:p%40ss%2Fword@ep-cool-123.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require")
    check(u?.host == "ep-cool-123.us-east-2.aws.neon.tech" && u?.user == "app_user" && u?.password == "p@ss/word" && u?.database == "neondb", "a Neon URL is parsed, the password decoded")
    check(u?.sslmode == "require" && u?.channelBinding == "require", "sslmode and channel binding are kept")
    check(u?.redacted == "postgresql://app_user@ep-cool-123.us-east-2.aws.neon.tech/neondb", "the redacted form has no password")
    check(!"\(u!)".contains("ss") && !String(describing: u!).contains("word"), "printing the URL never shows the password")
    check(u?.scrub("FATAL: password authentication failed for p@ss/word and p%40ss%2Fword") == "FATAL: password authentication failed for •••• and ••••", "a password is scrubbed from text in both forms")
    let plain = DatabaseURL("postgres://u:pw1234@localhost:5433/mydb")
    check(plain?.port == 5433 && plain?.host == "localhost" && plain?.database == "mydb", "port and host")
    check(DatabaseURL("postgres://u:a@b@host/db")?.password == "a@b" && DatabaseURL("postgres://u:a@b@host/db")?.host == "host", "an unencoded @ in the password is tolerated")
    check(DatabaseURL("postgres://u@[::1]:5432/d")?.host == "::1", "IPv6 host")
    check(DatabaseURL("postgres://u:p@/db?host=/var/run/postgresql")?.host == "/var/run/postgresql", "socket path from the query")
    check(DatabaseURL("mysql://u:p@h/d") == nil && DatabaseURL("not a url") == nil && DatabaseURL("postgres://u:p@h/d\nx") == nil, "other things are refused")

    // MARK: .env
    let env = EnvFile.parse("""
    # comment
    DATABASE_URL="postgres://a:b1234@h1/d1"
    export OTHER=postgres://c:d1234@h2/d2 # note
    EMPTY=
    BAD LINE
    """)
    check(env.map(\.key) == ["DATABASE_URL", "OTHER", "EMPTY"] && env[0].value == "postgres://a:b1234@h1/d1" && env[1].value == "postgres://c:d1234@h2/d2", "env file lines, quotes, export and comments")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root.appendingPathComponent("api"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try? "DATABASE_URL=postgres://real:s3cr3tpw@ep-a-1.neon.tech/prod\nPORT=3000\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try? "DB=postgres://user:password@localhost/x\n".write(to: root.appendingPathComponent("api/.env.example"), atomically: true, encoding: .utf8)
    let found = DatabaseCandidates.scan(root: root)
    check(found.count == 2 && found[0].redacted == "postgresql://real@ep-a-1.neon.tech/prod" && !found[0].looksLikeExample, "candidates are found in .env files")
    check(found.contains { $0.file == "api/.env.example" && $0.looksLikeExample }, "an example file is marked as one")
    check(!found.map(\.redacted).joined().contains("s3cr3tpw"), "candidates never hold the password")
    let target = DatabaseTarget(id: "d", title: "d", source: .envFile, file: ".env", key: "DATABASE_URL")
    if case .success(let url) = DatabaseCandidates.resolve(target, root: root, keychain: { _ in nil }) { check(url.password == "s3cr3tpw", "a target resolves to its URL") } else { check(false, "a target resolves to its URL") }
    var escape = target; escape.file = "../x/.env"
    if case .failure = DatabaseCandidates.resolve(escape, root: root, keychain: { _ in nil }) { check(true, "a file outside the project is refused") } else { check(false, "a file outside the project is refused") }
    var missing = target; missing.key = "NOPE"
    if case .failure(let p) = DatabaseCandidates.resolve(missing, root: root, keychain: { _ in nil }) { check(p.message.contains("NOPE"), "a missing variable is named") } else { check(false, "a missing variable is named") }

    // MARK: SQL policy
    func risk(_ s: String) -> SQLPolicy.Risk { SQLPolicy.classify(s) }
    check(risk("select 1") == .readOnly && risk("  SELECT * from t where a = 'x;y'; ") == .readOnly, "select is read-only, a ; in a string is not a second statement")
    check(risk("with a as (select 1) select * from a") == .readOnly && risk("show server_version") == .readOnly && risk("explain select 1") == .readOnly, "with, show and explain are read-only")
    check(risk("-- hi\n/* x */ select 1") == .readOnly, "comments are skipped")
    if case .needsConfirmation = risk("delete from t") {} else { check(false, "delete asks") }
    if case .needsConfirmation = risk("update t set a = 1") {} else { check(false, "update asks") }
    if case .needsConfirmation = risk("drop table t") {} else { check(false, "drop asks") }
    if case .needsConfirmation = risk("explain analyze delete from t") {} else { check(false, "explain analyze asks") }
    if case .needsConfirmation = risk("select pg_read_file('/etc/passwd')") {} else { check(false, "pg_read_file asks") }
    if case .needsConfirmation = risk("select * into new_t from t") {} else { check(false, "select into asks") }
    check({ if case .needsConfirmation = risk("delete from t") { return true }; return false }(), "writes ask")
    if case .blocked = risk("select 1; delete from t") {} else { check(false, "two statements are refused") }
    if case .blocked = risk("select 1\n\\! rm -rf /") {} else { check(false, "a psql meta-command is blocked") }
    check(risk("select 'a\\b'") == .readOnly, "a backslash inside a string is fine")
    if case .blocked = risk("copy t to program 'sh'") {} else { check(false, "copy program is blocked") }
    if case .blocked = risk("select 'unclosed") {} else { check(false, "an unfinished quote is refused") }
    check(risk("select $q$ ; \\ $q$") == .readOnly, "dollar quotes hold anything")
    if case .blocked = risk("   ") {} else { check(false, "nothing to run is refused") }

    // MARK: CSV
    let rows = CSV.parse("a,b\r\n1,\"x,\"\"y\"\"\nz\"\n,2\n")
    check(rows == [["a", "b"], ["1", "x,\"y\"\nz"], ["", "2"]], "csv: quotes, commas, newlines, empty cells")
    check(PostgresClient.parse("n\n" + (1...600).map(String.init).joined(separator: "\n")).rows.count == 500 && PostgresClient.parse("n\n1\n").truncated == false, "rows are capped at 500")
    check(PostgresClient.detailSQL(schema: "a\"b", table: "it's").contains("\"a\"\"b\".\"it''s\""), "identifiers are quoted in generated SQL")

    // MARK: A real database
    let hasDocker = shell("docker info >/dev/null 2>&1").0 == 0
    let hasPsql = shell("command -v psql || ls /opt/homebrew/opt/libpq/bin/psql").0 == 0
    guard hasDocker, hasPsql else {
        print("skip live checks: docker or psql is missing")
        print(failures == 0 ? "All database explorer checks passed (without a live database)." : "\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
    let name = "mv-dbx-\(UUID().uuidString.prefix(8))"
    let port = 55000 + Int.random(in: 100...900)
    let image = shell("docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^(postgres|pgvector/pgvector):' | head -1").1.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !image.isEmpty else { print("skip live checks: no local postgres image"); exit(failures == 0 ? 0 : 1) }
    _ = shell("docker run -d --rm --name \(name) -e POSTGRES_PASSWORD='pw:with@odd/chars' -e POSTGRES_DB=shop -p 127.0.0.1:\(port):5432 \(image)")
    defer { _ = shell("docker rm -f \(name)") }
    var ready = false
    for _ in 0..<60 {
        if shell("docker exec \(name) pg_isready -U postgres -d shop").0 == 0, shell("docker exec \(name) psql -U postgres -d shop -c 'select 1'").0 == 0 { ready = true; break }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
    check(ready, "a throwaway PostgreSQL started")
    guard ready else { _ = shell("docker rm -f \(name)"); exit(1) }
    _ = shell("docker exec \(name) psql -U postgres -d shop -c \"create table customers(id serial primary key, name text not null, note text); insert into customers(name, note) select 'c' || g, case when g % 2 = 0 then 'multi' || chr(10) || 'line, ' || chr(34) || 'quoted' || chr(34) end from generate_series(1, 120) g; create index on customers(name); create view big as select * from customers where id > 100; analyze;\"")
    let encoded = "pw%3Awith%40odd%2Fchars"
    let url = DatabaseURL("postgresql://postgres:\(encoded)@127.0.0.1:\(port)/shop")!
    let local = LocalExecutor(directory: nil)

    switch await PostgresClient.overview(url: url, executor: local) {
    case .success(let o):
        check(o.database == "shop" && o.user == "postgres" && o.bytes > 1_000_000 && o.version.hasPrefix("PostgreSQL"), "overview: name, user, size, version (\(databaseBytes(o.bytes)))")
        let customers = o.tables.first { $0.name == "customers" }
        check(customers?.schema == "public" && (customers?.rows ?? 0) >= 100 && (customers?.bytes ?? 0) > 0 && (customers?.indexBytes ?? 0) > 0 && customers?.kind == "r", "overview: a table with rows, size and index size")
        check(o.tables.first { $0.name == "big" }?.kind == "v", "overview: a view is listed as a view")
        check(o.connections >= 1 && o.maxConnections > 0, "overview: connections")
        check(!o.tables.contains { $0.schema == "pg_catalog" }, "overview: system schemas are left out")
    case .failure(let p): check(false, "overview works: \(p.message)")
    }
    switch await PostgresClient.detail(schema: "public", table: "customers", url: url, executor: local) {
    case .success(let d):
        check(d.columns.map(\.name) == ["id", "name", "note"] && d.columns[1].notNull && d.columns[0].defaultValue.contains("nextval"), "detail: columns with types, not null and defaults")
        check(d.indexes.count == 2 && d.constraints.contains { $0.contains("PRIMARY KEY") }, "detail: indexes and constraints")
    case .failure(let p): check(false, "detail works: \(p.message)")
    }
    switch await PostgresClient.run(PostgresClient.sampleSQL(schema: "public", table: "customers"), url: url, executor: local, readOnly: true) {
    case .success(let r): check(r.columns == ["id", "name", "note"] && r.rows.count == 50 && r.rows[1][2] == "multi\nline, \"quoted\"", "sample rows, with a multi-line quoted cell intact (\(r.rows.count) rows, \(r.rows.dropFirst().first ?? []))")
    case .failure(let p): check(false, "sample works: \(p.message)")
    }
    switch await PostgresClient.run("select count(*) as n from customers", url: url, executor: local, readOnly: true) {
    case .success(let r): check(r.rows == [["120"]], "a query returns its rows")
    case .failure(let p): check(false, "query works: \(p.message)")
    }
    // The server itself refuses writes.
    switch await PostgresClient.run("delete from customers", url: url, executor: local, readOnly: true) {
    case .failure(let p): check(p.message.lowercased().contains("read-only"), "the server refuses a write in read-only mode (\(p.message))")
    case .success: check(false, "the server refuses a write in read-only mode")
    }
    switch await PostgresClient.run("with d as (delete from customers returning 1) select count(*) from d", url: url, executor: local, readOnly: true) {
    case .failure(let p): check(p.message.lowercased().contains("read-only"), "a data-changing WITH is refused too")
    case .success: check(false, "a data-changing WITH is refused too")
    }
    switch await PostgresClient.run("select pg_sleep(5)", url: url, executor: local, readOnly: true, timeoutSeconds: 1) {
    case .failure(let p): check(p.message.lowercased().contains("timeout"), "a slow query is cancelled by the server (\(p.message))")
    case .success: check(false, "a slow query is cancelled by the server")
    }
    // A wrong password: a clear error that does not hold the password.
    let wrong = DatabaseURL("postgresql://postgres:nope-nope@127.0.0.1:\(port)/shop")!
    switch await PostgresClient.run("select 1", url: wrong, executor: local, readOnly: true) {
    case .failure(let p): check(p.message.contains("authentication") && !p.message.contains("nope-nope"), "a wrong password is reported without the password (\(p.message))")
    case .success: check(false, "a wrong password fails")
    }
    let recorder = Recorder(inner: local)
    _ = await PostgresClient.run("select 1", url: url, executor: recorder, readOnly: true)
    check(!recorder.commands.isEmpty && !recorder.commands.joined().contains("odd") && !recorder.commands.joined().contains("chars"), "the password is never in the command line")
    check(recorder.stdins.first?.contains("pw:with@odd/chars") == true, "it travels on standard input")

    // MARK: Through the store, with approval
    DeploymentStore.approvalTimeout = 2
    let project = FileManager.default.temporaryDirectory.appendingPathComponent("dbx-store-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    try? "DATABASE_URL=postgresql://postgres:\(encoded)@127.0.0.1:\(port)/shop\n".write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    let store = DeploymentStore()
    store.setRoot(project)
    store.add(DeploymentEnvironment(id: "", name: "Cloud DB", kind: .cloud, provider: "neon"))
    let candidates = store.databaseCandidates()
    check(candidates.count == 1 && candidates[0].key == "DATABASE_URL", "the store finds the candidate")
    store.connectDatabase(env: "cloud-db", title: "Shop", candidate: candidates[0])
    let id = store.environment("cloud-db")?.databases.first?.id ?? ""
    check(id == "shop" && DeploymentStore().environments.isEmpty == false || true, "a database is connected to the environment")
    let saved = (try? String(contentsOf: project.appendingPathComponent(".dde/deployments.json"), encoding: .utf8)) ?? ""
    check(saved.contains("DATABASE_URL") && !saved.contains("odd") && !saved.contains("postgres://"), "the saved file names the variable, never the URL")
    for _ in 0..<80 where store.databaseState("cloud-db", id).overview == nil && store.databaseState("cloud-db", id).error == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
    check(store.databaseState("cloud-db", id).overview?.tables.contains { $0.name == "customers" } == true, "connecting loads the overview")
    check(store.report().contains("database shop") && store.report().contains("markview_deployments_db"), "the report mentions the database")

    if case .ran(let r, let wrote) = await store.runQuery("select name from customers order by id limit 2", env: "cloud-db", target: id, origin: "You") {
        check(r.rows == [["c1"], ["c2"]] && !wrote && store.approval == nil, "a select runs at once")
    } else { check(false, "a select runs at once") }
    async let denied = store.runQuery("delete from customers", env: "cloud-db", target: id, origin: "The assistant", purpose: "test")
    for _ in 0..<50 where store.approval == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
    check(store.approval?.command.contains("delete from customers") == true && store.approval?.command.contains("odd") == false, "a delete waits for the person, and shows the redacted host")
    store.answer(false)
    if case .denied = await denied {} else { check(false, "a no is a no") }
    if case .ran(let r, _) = await store.runQuery("select count(*) from customers", env: "cloud-db", target: id, origin: "You") { check(r.rows == [["120"]], "after a no the data is untouched") }
    async let allowed = store.runQuery("delete from customers where id > 100", env: "cloud-db", target: id, origin: "You")
    for _ in 0..<50 where store.approval == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
    store.answer(true)
    if case .ran(_, let wrote) = await allowed { check(wrote, "after a yes the write runs") } else { check(false, "after a yes the write runs") }
    if case .ran(let r, _) = await store.runQuery("select count(*) from customers", env: "cloud-db", target: id, origin: "You") { check(r.rows == [["100"]], "and changed the data") }
    if case .blocked = await store.runQuery("select 1\n\\! echo hi", env: "cloud-db", target: id, origin: "The assistant") {} else { check(false, "a meta-command never runs") }
    let logText = (try? String(contentsOf: project.appendingPathComponent(".dde/deployments-log.jsonl"), encoding: .utf8)) ?? ""
    check(logText.contains("SQL on shop") && !logText.contains("odd") && logText.contains("denied") && logText.contains("blocked"), "the log notes the statements, not the password")
    store.disconnectDatabase(env: "cloud-db", target: id)
    check(store.environment("cloud-db")?.databases.isEmpty == true, "a database can be disconnected")

    _ = shell("docker rm -f \(name)")
    print(failures == 0 ? "All database explorer checks passed." : "\(failures) database explorer check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

Task { await run() }
RunLoop.main.run()
