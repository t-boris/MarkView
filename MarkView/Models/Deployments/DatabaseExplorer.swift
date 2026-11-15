import Foundation

// Looking into a PostgreSQL database from the Deployments tab: how big it is, what tables it has, a few rows, and
// read-only queries. Foundation only, checked in `tools/tests/database-explorer-tests.sh`.
//
// The connection URL holds a password. It is read when the person asks to look (from a project `.env` file or from
// the Keychain), lives in memory for the call, is handed to `psql` through standard input (never in an argument,
// so `ps` does not show it) and is removed from everything that is shown or logged.

// MARK: - Connection URL

/// A parsed `postgres://user:password@host:port/db?sslmode=require`. Printing it never shows the password.
struct DatabaseURL: CustomStringConvertible {
    var host: String
    var port: Int?
    var user: String
    var password: String
    var database: String
    var sslmode: String
    var channelBinding: String
    var options: String

    static func looksLikePostgres(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("postgres://") || lower.hasPrefix("postgresql://")
    }

    init?(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikePostgres(rest), let schemeEnd = rest.range(of: "://") else { return nil }
        rest = String(rest[schemeEnd.upperBound...])
        var query = ""
        if let q = rest.firstIndex(of: "?") { query = String(rest[rest.index(after: q)...]); rest = String(rest[..<q]) }
        var path = ""
        // The password may hold a "/" only when it is percent-encoded, so the first "/" after the last "@" starts the path.
        let at = rest.lastIndex(of: "@")
        let searchFrom = at.map { rest.index(after: $0) } ?? rest.startIndex
        if let slash = rest[searchFrom...].firstIndex(of: "/") { path = String(rest[rest.index(after: slash)...]); rest = String(rest[..<slash]) }
        var userInfo = ""
        var hostPart = rest
        if let at = rest.lastIndex(of: "@") { userInfo = String(rest[..<at]); hostPart = String(rest[rest.index(after: at)...]) }
        var user = userInfo, password = ""
        if let colon = userInfo.firstIndex(of: ":") { user = String(userInfo[..<colon]); password = String(userInfo[userInfo.index(after: colon)...]) }
        var host = hostPart
        var port: Int?
        if hostPart.hasPrefix("[") , let close = hostPart.firstIndex(of: "]") {
            host = String(hostPart[hostPart.index(after: hostPart.startIndex)..<close])
            let after = hostPart[hostPart.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
        } else if let colon = hostPart.lastIndex(of: ":") {
            host = String(hostPart[..<colon]); port = Int(hostPart[hostPart.index(after: colon)...])
        }
        self.user = user.removingPercentEncoding ?? user
        self.password = password.removingPercentEncoding ?? password
        self.database = path.removingPercentEncoding ?? path
        self.host = host
        self.port = port
        var sslmode = "", binding = "", options = ""
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "sslmode": sslmode = parts[1]
            case "channel_binding": binding = parts[1]
            case "options": options = parts[1]
            case "host": if self.host.isEmpty { self.host = parts[1] }
            case "port": if self.port == nil { self.port = Int(parts[1]) }
            default: break
            }
        }
        self.sslmode = sslmode; self.channelBinding = binding; self.options = options
        guard !self.host.isEmpty else { return nil }
        guard [self.host, self.user, self.database, sslmode, binding, options, self.password].allSatisfy({ !$0.contains("\n") && !$0.contains("\0") }) else { return nil }
    }

    /// `postgresql://user@host:5432/db`: what is safe to show.
    var redacted: String {
        "postgresql://" + (user.isEmpty ? "" : user + "@") + (host.contains(":") ? "[\(host)]" : host) + (port.map { ":\($0)" } ?? "") + (database.isEmpty ? "" : "/" + database)
    }

    var description: String { redacted }

    /// The settings, one per line, in the order the `psql` script reads them.
    var stdinHeader: String {
        [host, port.map(String.init) ?? "", user, password, database, sslmode, channelBinding, options].joined(separator: "\n") + "\n"
    }

    /// Text with this connection's password (and any form of the URL) taken out.
    func scrub(_ text: String) -> String {
        var out = text
        if password.count >= 3 {
            let encoded = password.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? password
            for secret in Set([password, encoded]) { out = out.replacingOccurrences(of: secret, with: "••••") }
        }
        return out
    }
}

// MARK: - .env files

enum EnvFile {
    /// `KEY=value` lines (also `export KEY=value`, quoted values, trailing comments on unquoted ones).
    static func parse(_ text: String) -> [(key: String, value: String)] {
        var found: [(String, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if let first = value.first, first == "\"" || first == "'", let close = value.dropFirst().lastIndex(of: first) {
                value = String(value[value.index(after: value.startIndex)..<close])
            } else if let hash = value.range(of: " #") {
                value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            found.append((key, value))
        }
        return found
    }
}

/// A PostgreSQL URL found in a project file. Only the redacted form is kept.
struct DatabaseCandidate: Identifiable, Equatable {
    var id: String { file + "#" + key }
    let file: String
    let key: String
    let redacted: String
    /// A placeholder (`user:password@localhost`, an `.env.example` file): probably not a real database.
    let looksLikeExample: Bool
}

enum DatabaseCandidates {
    /// `.env*` files in the project folder and one folder below it, and the PostgreSQL URLs they hold.
    static func scan(root: URL) -> [DatabaseCandidate] {
        let fm = FileManager.default
        var folders: [(url: URL, prefix: String)] = [(root, "")]
        if let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for child in children.sorted(by: { $0.path < $1.path }) where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if ["node_modules", "build", "dist", "vendor", "Pods", "venv", ".venv"].contains(child.lastPathComponent) { continue }
                folders.append((child, child.lastPathComponent + "/"))
            }
        }
        var out: [DatabaseCandidate] = []
        for (folder, prefix) in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") {
                let url = folder.appendingPathComponent(name)
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let text = try? String(contentsOf: url, encoding: .utf8), text.utf8.count < 256 * 1024 else { continue }
                let relative = prefix + name
                for (key, value) in EnvFile.parse(text) {
                    guard let parsed = DatabaseURL(value) else { continue }
                    let example = name.contains("example") || name.contains("sample") || name.contains("template")
                        || ["password", "pass", "changeme", "your-password", "xxxx"].contains(parsed.password.lowercased())
                        || parsed.host.contains("<") || parsed.host.contains("{")
                    out.append(DatabaseCandidate(file: relative, key: key, redacted: parsed.redacted, looksLikeExample: example))
                }
            }
        }
        return out
    }

    /// The URL a target points at, read now.
    static func resolve(_ target: DatabaseTarget, root: URL?, keychain: (String) -> String?) -> Result<DatabaseURL, DatabaseProblem> {
        switch target.source {
        case .keychain:
            guard let text = keychain(target.id), let url = DatabaseURL(text) else { return .failure(.noURL("The connection string is not in the Keychain. Connect the database again.")) }
            return .success(url)
        case .envFile:
            guard let root else { return .failure(.noURL("No project folder is open.")) }
            let path = (target.file as NSString).standardizingPath
            guard !path.hasPrefix("/"), !path.hasPrefix("..") else { return .failure(.noURL("The file \(target.file) is outside the project.")) }
            let url = root.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .failure(.noURL("\(target.file) cannot be read.")) }
            guard let value = EnvFile.parse(text).last(where: { $0.key == target.key })?.value else { return .failure(.noURL("\(target.key) is not in \(target.file).")) }
            guard let parsed = DatabaseURL(value) else { return .failure(.noURL("\(target.key) in \(target.file) is not a PostgreSQL connection URL.")) }
            return .success(parsed)
        }
    }
}

enum DatabaseProblem: Error, Equatable {
    case noURL(String)
    case noPsql
    case failed(String)
    case timedOut
    case blocked(String)

    var message: String {
        switch self {
        case .noURL(let text), .failed(let text), .blocked(let text): return text
        case .noPsql: return "psql is not installed where the query runs. On this Mac: brew install libpq"
        case .timedOut: return "The database did not answer in time. A Neon database that was idle needs a few seconds to wake up: try again."
        }
    }
}

// MARK: - SQL policy

enum SQLPolicy {
    enum Risk: Equatable {
        case readOnly
        case needsConfirmation(String)
        case blocked(String)
    }

    /// The statements of `sql` with comments removed. nil when the text holds a psql meta-command (a backslash outside
    /// a string), which could run a shell command.
    static func statements(_ sql: String) -> [String]? {
        var out: [String] = []
        var current = ""
        let chars = Array(sql)
        var i = 0
        func flush() { let t = current.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(t) }; current = "" }
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "-", next == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                current.append(" ")
            } else if c == "/", next == "*" {
                var depth = 1; i += 2
                while i < chars.count, depth > 0 {
                    if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" { depth += 1; i += 2 }
                    else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                current.append(" ")
            } else if c == "'" || c == "\"" {
                current.append(c); i += 1
                var closed = false
                while i < chars.count {
                    current.append(chars[i])
                    if chars[i] == c {
                        if i + 1 < chars.count, chars[i + 1] == c { current.append(c); i += 2; continue }
                        closed = true
                        break
                    }
                    i += 1
                }
                if !closed { return nil }
                i += 1
            } else if c == "$" {
                // $tag$ ... $tag$
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                if j < chars.count, chars[j] == "$", !(chars[i + 1..<j].first?.isNumber ?? false) {
                    let tag = String(chars[i...j])
                    current.append(tag); i = j + 1
                    var closed = false
                    while i < chars.count {
                        if chars[i] == "$", i + tag.count <= chars.count, String(chars[i..<(i + tag.count)]) == tag {
                            current.append(tag); i += tag.count; closed = true; break
                        }
                        current.append(chars[i]); i += 1
                    }
                    if !closed { return nil }
                } else { current.append(c); i += 1 }
            } else if c == "\\" {
                return nil
            } else if c == ";" {
                flush(); i += 1
            } else {
                current.append(c); i += 1
            }
        }
        flush()
        return out
    }

    private static let readWords: Set<String> = ["select", "with", "show", "explain", "values", "table"]
    private static let heavyFunctions = ["pg_read_file", "pg_read_binary_file", "pg_ls_dir", "lo_import", "lo_export", "pg_terminate_backend", "pg_cancel_backend",
                                         "pg_reload_conf", "pg_rotate_logfile", "dblink", "set_config"]

    static func classify(_ sql: String) -> Risk {
        guard let parts = statements(sql) else {
            return .blocked("The query holds a psql meta-command (a backslash outside a string) or an unfinished quote. MarkView runs SQL only.")
        }
        if parts.isEmpty { return .blocked("There is no SQL to run.") }
        if parts.count > 1 { return .blocked("Run one statement at a time.") }
        let statement = parts[0]
        let lower = statement.lowercased()
        if lower.range(of: #"\bcopy\b[\s\S]*\b(program)\b"#, options: .regularExpression) != nil {
            return .blocked("COPY … PROGRAM runs a shell command on the database server.")
        }
        let word = lower.drop(while: { $0 == "(" || $0.isWhitespace }).prefix(while: { $0.isLetter })
        guard readWords.contains(String(word)) else {
            return .needsConfirmation("\(word.uppercased().isEmpty ? "This statement" : word.uppercased()) can change the data or the structure of the database")
        }
        if word == "explain", lower.range(of: #"\banalyze\b|\banalyse\b"#, options: .regularExpression) != nil {
            return .needsConfirmation("EXPLAIN ANALYZE runs the statement")
        }
        for name in heavyFunctions where lower.range(of: #"\b"# + name + #"\b"#, options: .regularExpression) != nil {
            return .needsConfirmation("\(name)() reaches beyond reading data")
        }
        if lower.range(of: #"\bfor\s+(update|share|no\s+key\s+update|key\s+share)\b"#, options: .regularExpression) != nil {
            return .needsConfirmation("FOR UPDATE locks rows")
        }
        if lower.range(of: #"\binto\b\s+(?!strict)"#, options: .regularExpression) != nil, word == "select" {
            return .needsConfirmation("SELECT … INTO creates a table")
        }
        return .readOnly
    }

    static func quoteIdent(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func literal(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
}

// MARK: - CSV

enum CSV {
    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var pending = false
        let chars = Array(text.unicodeScalars)
        var i = 0
        func endField() { row.append(field); field = ""; pending = false }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append(c); i += 1 } else { quoted = false }
                } else { field.unicodeScalars.append(c) }
            } else if c == "\"" { quoted = true; pending = true }
            else if c == "," { endField(); pending = true }
            else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                endField(); rows.append(row); row = []; pending = false
            } else { field.unicodeScalars.append(c); pending = true }
            i += 1
        }
        if pending || !field.isEmpty || !row.isEmpty { endField(); rows.append(row) }
        return rows
    }
}

// MARK: - Results

struct DatabaseTable: Identifiable, Equatable {
    var id: String { schema + "." + name }
    let schema: String
    let name: String
    /// r table, p partitioned table, m materialized view, v view, f foreign table
    let kind: String
    /// An estimate from the statistics, not a count.
    let rows: Int64
    let bytes: Int64
    let indexBytes: Int64

    var kindTitle: String {
        switch kind {
        case "v": return "view"
        case "m": return "materialized view"
        case "f": return "foreign table"
        case "p": return "partitioned table"
        default: return "table"
        }
    }
}

struct DatabaseOverview: Equatable {
    var database = ""
    var user = ""
    var version = ""
    var bytes: Int64 = 0
    var connections = 0
    var maxConnections = 0
    var tables: [DatabaseTable] = []
    var extensions: [String] = []
    var at = Date()

    static func == (a: Self, b: Self) -> Bool { a.database == b.database && a.bytes == b.bytes && a.tables == b.tables && a.at == b.at }
}

struct TableDetail: Equatable {
    struct Column: Equatable { let name: String; let type: String; let notNull: Bool; let defaultValue: String }
    var columns: [Column] = []
    var indexes: [String] = []
    var constraints: [String] = []
}

struct QueryResult: Equatable {
    var columns: [String] = []
    var rows: [[String]] = []
    /// More rows came back than are kept.
    var truncated = false
    var seconds: Double = 0
    /// Statements that return no rows (INSERT, UPDATE…): psql's `--csv` prints nothing for them.
    var empty: Bool { columns.isEmpty }

    static let rowLimit = 500
    static let cellLimit = 2_000

    /// For an assistant: an aligned text table.
    func text(maxRows: Int = 200) -> String {
        if columns.isEmpty { return "(the statement ran and returned no rows)" }
        var lines = [columns.joined(separator: " | ")]
        for row in rows.prefix(maxRows) { lines.append(row.map { $0.replacingOccurrences(of: "\n", with: "⏎") }.joined(separator: " | ")) }
        if rows.count > maxRows || truncated { lines.append("… more rows exist (showing \(min(rows.count, maxRows)))") }
        return lines.joined(separator: "\n") + "\n(\(rows.count) row\(rows.count == 1 ? "" : "s")\(truncated ? "+" : ""))"
    }
}

// MARK: - The client

enum PostgresClient {
    /// The script both the Mac and a server run. The settings come on the first lines of standard input, the SQL after them.
    static func script(readOnly: Bool, timeoutSeconds: Int) -> String {
        let options = (readOnly ? "-c default_transaction_read_only=on " : "") + "-c statement_timeout=\(timeoutSeconds * 1000) -c lock_timeout=3000 -c idle_in_transaction_session_timeout=20000"
        return """
        IFS= read -r h; IFS= read -r p; IFS= read -r u; IFS= read -r w; IFS= read -r d; IFS= read -r s; IFS= read -r b; IFS= read -r o
        P=$(command -v psql 2>/dev/null)
        if [ -z "$P" ]; then for c in /opt/homebrew/opt/libpq/bin/psql /opt/homebrew/bin/psql /usr/local/opt/libpq/bin/psql /usr/local/bin/psql /Applications/Postgres.app/Contents/Versions/latest/bin/psql /usr/lib/postgresql/*/bin/psql; do [ -x "$c" ] && P=$c && break; done; fi
        [ -z "$P" ] && { echo "markview: psql is not installed" >&2; exit 127; }
        [ -n "$h" ] && export PGHOST="$h"; [ -n "$p" ] && export PGPORT="$p"; [ -n "$u" ] && export PGUSER="$u"; [ -n "$w" ] && export PGPASSWORD="$w"
        [ -n "$d" ] && export PGDATABASE="$d"; [ -n "$s" ] && export PGSSLMODE="$s"; [ -n "$b" ] && export PGCHANNELBINDING="$b"
        export PGCONNECT_TIMEOUT=15 PGAPPNAME=MarkView
        export PGOPTIONS="\(options) $o"
        exec "$P" -X -q --csv -v ON_ERROR_STOP=1 -f -
        """
    }

    /// Run one statement. `readOnly` makes the server itself refuse any write.
    static func run(_ sql: String, url: DatabaseURL, executor: DeploymentExecutor, readOnly: Bool, timeoutSeconds: Int = 20) async -> Result<QueryResult, DatabaseProblem> {
        let started = Date()
        let command = "sh -c " + shellQuote(script(readOnly: readOnly, timeoutSeconds: timeoutSeconds))
        let result = await executor.run(command, stdin: url.stdinHeader + sql + "\n", timeout: TimeInterval(timeoutSeconds + 25))
        if result.timedOut { return .failure(.timedOut) }
        if result.status == 127 && result.stderr.contains("psql is not installed") { return .failure(.noPsql) }
        guard result.status == 0 else {
            let raw = url.scrub(result.stderr.isEmpty ? result.stdout : result.stderr)
            let line = raw.split(separator: "\n").map(String.init).first { $0.contains("ERROR") || $0.contains("error") || $0.contains("FATAL") } ?? raw
            let text = line.replacingOccurrences(of: "psql: error: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.failed(text.isEmpty ? "The query failed (exit \(result.status))." : String(text.prefix(600))))
        }
        var parsed = parse(result.stdout)
        parsed.seconds = Date().timeIntervalSince(started)
        if result.truncated { parsed.truncated = true }
        return .success(parsed)
    }

    static func parse(_ output: String) -> QueryResult {
        var rows = CSV.parse(output)
        guard !rows.isEmpty else { return QueryResult() }
        let header = rows.removeFirst()
        var result = QueryResult(columns: header)
        if rows.count > QueryResult.rowLimit { result.truncated = true; rows = Array(rows.prefix(QueryResult.rowLimit)) }
        result.rows = rows.map { row in row.map { $0.count > QueryResult.cellLimit ? String($0.prefix(QueryResult.cellLimit)) + "…" : $0 } }
        return result
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Looking around

    static let overviewSQL = """
    select json_build_object(
      'database', current_database(), 'user', current_user, 'version', version(),
      'size', pg_database_size(current_database()),
      'connections', (select count(*) from pg_stat_activity where datname = current_database()),
      'maxConnections', current_setting('max_connections')::int,
      'extensions', (select coalesce(json_agg(extname), '[]'::json) from pg_extension),
      'tables', coalesce((select json_agg(t) from (
         select n.nspname as schema, c.relname as name, c.relkind::text as kind, greatest(c.reltuples, 0)::bigint as rows,
                case when c.relkind in ('r','p','m') then pg_total_relation_size(c.oid) else 0 end as bytes,
                case when c.relkind in ('r','p','m') then pg_indexes_size(c.oid) else 0 end as index_bytes
         from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where c.relkind in ('r','p','m','v','f') and n.nspname not in ('pg_catalog','information_schema') and n.nspname not like 'pg_toast%' and n.nspname not like 'pg_temp%'
         order by 5 desc, 1, 2 limit 300) t), '[]'::json)
    )::text as overview
    """

    static func overview(url: DatabaseURL, executor: DeploymentExecutor) async -> Result<DatabaseOverview, DatabaseProblem> {
        switch await run(overviewSQL, url: url, executor: executor, readOnly: true) {
        case .failure(let problem): return .failure(problem)
        case .success(let result):
            guard let json = result.rows.first?.first, let overview = parseOverview(json) else { return .failure(.failed("The database answered in a form MarkView does not understand.")) }
            return .success(overview)
        }
    }

    static func parseOverview(_ json: String) -> DatabaseOverview? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        func int(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? Int64(v as? String ?? "") ?? 0 }
        var overview = DatabaseOverview()
        overview.database = object["database"] as? String ?? ""
        overview.user = object["user"] as? String ?? ""
        let version = object["version"] as? String ?? ""
        overview.version = version.split(separator: " ").prefix(2).joined(separator: " ")
        overview.bytes = int(object["size"])
        overview.connections = Int(int(object["connections"]))
        overview.maxConnections = Int(int(object["maxConnections"]))
        overview.extensions = object["extensions"] as? [String] ?? []
        overview.tables = (object["tables"] as? [[String: Any]] ?? []).map {
            DatabaseTable(schema: $0["schema"] as? String ?? "", name: $0["name"] as? String ?? "", kind: $0["kind"] as? String ?? "r",
                          rows: int($0["rows"]), bytes: int($0["bytes"]), indexBytes: int($0["index_bytes"]))
        }
        return overview
    }

    static func detailSQL(schema: String, table: String) -> String {
        let regclass = SQLPolicy.literal(SQLPolicy.quoteIdent(schema) + "." + SQLPolicy.quoteIdent(table)) + "::regclass"
        return """
        select json_build_object(
          'columns', coalesce((select json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'notNull', a.attnotnull, 'default', pg_get_expr(d.adbin, d.adrelid)) order by a.attnum)
              from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
              where a.attrelid = \(regclass) and a.attnum > 0 and not a.attisdropped), '[]'::json),
          'indexes', coalesce((select json_agg(indexdef) from pg_indexes where schemaname = \(SQLPolicy.literal(schema)) and tablename = \(SQLPolicy.literal(table))), '[]'::json),
          'constraints', coalesce((select json_agg(conname || ': ' || pg_get_constraintdef(oid)) from pg_constraint where conrelid = \(regclass)), '[]'::json)
        )::text as detail
        """
    }

    static func detail(schema: String, table: String, url: DatabaseURL, executor: DeploymentExecutor) async -> Result<TableDetail, DatabaseProblem> {
        switch await run(detailSQL(schema: schema, table: table), url: url, executor: executor, readOnly: true) {
        case .failure(let problem): return .failure(problem)
        case .success(let result):
            guard let json = result.rows.first?.first, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                return .failure(.failed("The database answered in a form MarkView does not understand."))
            }
            var detail = TableDetail()
            detail.columns = (object["columns"] as? [[String: Any]] ?? []).map {
                TableDetail.Column(name: $0["name"] as? String ?? "", type: $0["type"] as? String ?? "", notNull: $0["notNull"] as? Bool ?? false, defaultValue: $0["default"] as? String ?? "")
            }
            detail.indexes = object["indexes"] as? [String] ?? []
            detail.constraints = object["constraints"] as? [String] ?? []
            return .success(detail)
        }
    }

    static func sampleSQL(schema: String, table: String, limit: Int = 50) -> String {
        "select * from \(SQLPolicy.quoteIdent(schema)).\(SQLPolicy.quoteIdent(table)) limit \(limit)"
    }
}

/// "12.4 MB", "3 GB".
func databaseBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary) }
