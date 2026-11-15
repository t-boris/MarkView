import Foundation

/// What is known about one connected database.
struct DatabaseState: Equatable {
    var loading = false
    var overview: DatabaseOverview?
    var error: String?
    var details: [String: TableDetail] = [:]
    var samples: [String: QueryResult] = [:]
    var last: (sql: String, result: QueryResult)?
    var lastError: String?

    static func == (a: Self, b: Self) -> Bool {
        a.loading == b.loading && a.overview == b.overview && a.error == b.error && a.details == b.details && a.samples == b.samples
            && a.last?.sql == b.last?.sql && a.last?.result == b.last?.result && a.lastError == b.lastError
    }
}

enum DatabaseOutcome {
    case ran(QueryResult, wrote: Bool)
    case denied
    case blocked(String)
    case failed(String)

    /// For an assistant to read.
    var summary: String {
        switch self {
        case .ran(let result, let wrote): return (wrote ? "Ran with the person's approval.\n" : "") + result.text()
        case .denied: return "The person did not approve this statement. It was not run."
        case .blocked(let why): return "Blocked: " + why
        case .failed(let why): return "Failed: " + why
        }
    }
}

@MainActor
extension DeploymentStore {
    static func databaseKey(_ env: String, _ target: String) -> String { env + "|" + target }

    func databaseState(_ env: String, _ target: String) -> DatabaseState { databaseStates[Self.databaseKey(env, target)] ?? DatabaseState() }

    private func mutate(_ env: String, _ target: String, _ change: (inout DatabaseState) -> Void) {
        var state = databaseState(env, target)
        change(&state)
        databaseStates[Self.databaseKey(env, target)] = state
    }

    private func keychainAccount(_ env: String, _ target: String) -> String { (root?.path ?? "") + "|" + env + "|" + target }

    // MARK: Connecting

    /// PostgreSQL URLs in the project's `.env` files (only their redacted form is returned).
    func databaseCandidates() -> [DatabaseCandidate] {
        guard let root else { return [] }
        return DatabaseCandidates.scan(root: root)
    }

    private func addTarget(_ target: DatabaseTarget, to envID: String) {
        guard var env = environment(envID) else { return }
        var list = env.databases.filter { $0.id != target.id }
        list.append(target)
        env.databaseList = list
        update(env)
    }

    func connectDatabase(env envID: String, title: String, candidate: DatabaseCandidate) {
        let id = DeploymentEnvironment.slug(title.isEmpty ? candidate.key : title, existing: Set(environment(envID)?.databases.map(\.id) ?? []))
        let target = DatabaseTarget(id: id, title: title.isEmpty ? "Database (\(candidate.redacted))" : title, source: .envFile, file: candidate.file, key: candidate.key)
        addTarget(target, to: envID)
        Task { await loadOverview(env: envID, target: id) }
    }

    /// nil when saved, else what is wrong with the text.
    func connectDatabase(env envID: String, title: String, pastedURL: String) -> String? {
        guard let url = DatabaseURL(pastedURL) else { return "That is not a PostgreSQL connection string (postgresql://user:password@host/database)." }
        let id = DeploymentEnvironment.slug(title.isEmpty ? url.database : title, existing: Set(environment(envID)?.databases.map(\.id) ?? []))
        guard DatabaseKeychain.save(pastedURL.trimmingCharacters(in: .whitespacesAndNewlines), account: keychainAccount(envID, id)) else { return "The Keychain did not accept it." }
        addTarget(DatabaseTarget(id: id, title: title.isEmpty ? "Database (\(url.redacted))" : title, source: .keychain), to: envID)
        Task { await loadOverview(env: envID, target: id) }
        return nil
    }

    func disconnectDatabase(env envID: String, target: String) {
        guard var env = environment(envID) else { return }
        if env.databases.first(where: { $0.id == target })?.source == .keychain { DatabaseKeychain.delete(account: keychainAccount(envID, target)) }
        env.databaseList = env.databases.filter { $0.id != target }
        update(env)
        databaseStates[Self.databaseKey(envID, target)] = nil
    }

    func databaseURL(env envID: String, target id: String) -> Result<DatabaseURL, DatabaseProblem> {
        guard let target = environment(envID)?.databases.first(where: { $0.id == id }) else { return .failure(.noURL("There is no database \(id) on \(envID).")) }
        let account = keychainAccount(envID, id)
        return DatabaseCandidates.resolve(target, root: root, keychain: { _ in DatabaseKeychain.read(account: account) })
    }

    // MARK: Looking

    func loadOverview(env envID: String, target: String) async {
        guard let env = environment(envID) else { return }
        mutate(envID, target) { $0.loading = true; $0.error = nil }
        switch databaseURL(env: envID, target: target) {
        case .failure(let problem):
            mutate(envID, target) { $0.loading = false; $0.error = problem.message }
        case .success(let url):
            let result = await PostgresClient.overview(url: url, executor: executor(for: env))
            switch result {
            case .success(let overview): mutate(envID, target) { $0.loading = false; $0.overview = overview; $0.error = nil }
            case .failure(let problem): mutate(envID, target) { $0.loading = false; $0.error = problem.message }
            }
        }
    }

    func loadTable(env envID: String, target: String, table: DatabaseTable) async {
        guard let env = environment(envID), case .success(let url) = databaseURL(env: envID, target: target) else { return }
        let runner = executor(for: env)
        async let detail = PostgresClient.detail(schema: table.schema, table: table.name, url: url, executor: runner)
        async let sample = PostgresClient.run(PostgresClient.sampleSQL(schema: table.schema, table: table.name), url: url, executor: runner, readOnly: true)
        let (d, s) = await (detail, sample)
        mutate(envID, target) { state in
            if case .success(let detail) = d { state.details[table.id] = detail }
            switch s {
            case .success(let rows): state.samples[table.id] = rows
            case .failure(let problem): state.error = problem.message
            }
        }
    }

    // MARK: Querying

    /// Run one statement. A read runs at once, in a transaction the server itself keeps read-only; anything else waits for
    /// the person's yes to that exact statement; psql meta-commands and COPY … PROGRAM never run.
    func runQuery(_ sql: String, env envID: String, target: String, origin: String, purpose: String = "") async -> DatabaseOutcome {
        guard let env = environment(envID) else { return .failed("There is no environment \(envID).") }
        let url: DatabaseURL
        switch databaseURL(env: envID, target: target) {
        case .failure(let problem): return .failed(problem.message)
        case .success(let found): url = found
        }
        let clipped = "SQL on \(target): " + String(sql.replacingOccurrences(of: "\n", with: " ").prefix(240))
        var readOnly = true
        switch SQLPolicy.classify(sql) {
        case .blocked(let why):
            note(CommandLogEntry(time: Date(), environment: envID, command: clipped, origin: origin, outcome: "blocked", status: nil))
            return .blocked(why)
        case .needsConfirmation(let why):
            let shown = "On \(url.redacted):\n" + sql.trimmingCharacters(in: .whitespacesAndNewlines)
            guard await ask(env: env, command: shown, reason: why, origin: origin, purpose: purpose) else {
                note(CommandLogEntry(time: Date(), environment: envID, command: clipped, origin: origin, outcome: "denied", status: nil))
                return .denied
            }
            readOnly = false
        case .readOnly: break
        }
        let result = await PostgresClient.run(sql, url: url, executor: executor(for: env), readOnly: readOnly)
        switch result {
        case .success(let rows):
            note(CommandLogEntry(time: Date(), environment: envID, command: clipped, origin: origin, outcome: "ran", status: 0))
            mutate(envID, target) { $0.last = (sql, rows); $0.lastError = nil }
            return .ran(rows, wrote: !readOnly)
        case .failure(let problem):
            note(CommandLogEntry(time: Date(), environment: envID, command: clipped, origin: origin, outcome: "ran", status: 1))
            mutate(envID, target) { $0.lastError = problem.message }
            return .failed(problem.message)
        }
    }

    /// A line per connected database for the report an assistant reads.
    func databaseReport(for env: DeploymentEnvironment) -> [String] {
        env.databases.map { target in
            let state = databaseState(env.id, target.id)
            if let o = state.overview {
                return "  database \(target.id) (\(target.title)): \(o.database), \(databaseBytes(o.bytes)), \(o.tables.count) tables, \(o.connections)/\(o.maxConnections) connections — use markview_deployments_db"
            }
            return "  database \(target.id) (\(target.title)) — not looked at yet; use markview_deployments_db"
        }
    }
}
