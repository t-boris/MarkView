import SwiftUI

/// The "Databases" card of an environment in the Deployments tab: connect a PostgreSQL database (Neon, a managed
/// one, or one on a server), see how big it is, what tables it has and a few rows, and run read-only queries.
struct DatabaseCard: View {
    @ObservedObject var store: DeploymentStore
    let env: DeploymentEnvironment
    let installPsql: () -> Void

    @State private var adding = false
    @State private var pasted = ""
    @State private var title = ""
    @State private var addError: String?
    @State private var candidates: [DatabaseCandidate] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DATABASES").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                Spacer()
                Button(adding ? "Cancel" : "Connect a database…") { adding.toggle(); if adding { candidates = store.databaseCandidates() } }
                    .controlSize(.small)
            }
            if adding { connect }
            if env.databases.isEmpty && !adding {
                Text("Connect a PostgreSQL database to see its size, tables and rows, and to run read-only queries. MarkView reads the connection string from a .env file or the Keychain only when it looks, and never shows or saves it.")
                    .uiFont(size: 11).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(env.databases) { target in
                DatabaseView(store: store, env: env, target: target, installPsql: installPsql)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name (optional), e.g. Production database", text: $title).textFieldStyle(.roundedBorder).uiFont(size: 11)
            if candidates.isEmpty {
                Text("No PostgreSQL URL found in the project's .env files.").uiFont(size: 11).foregroundColor(VSDark.textDim)
            } else {
                Text("Found in the project's .env files (the password stays in the file):").uiFont(size: 11).foregroundColor(VSDark.textDim)
            }
            ForEach(candidates) { c in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.redacted).uiFont(size: 11, design: .monospaced).foregroundColor(VSDark.text).lineLimit(1)
                        Text("\(c.file) · \(c.key)\(c.looksLikeExample ? " · looks like an example" : "")").uiFont(size: 10).foregroundColor(c.looksLikeExample ? VSDark.orange : VSDark.textDim)
                    }
                    Spacer()
                    Button("Connect") { store.connectDatabase(env: env.id, title: title, candidate: c); adding = false; title = "" }.controlSize(.small)
                }
            }
            Divider()
            Text("Or paste a connection string. It goes to your Keychain, not to the project.").uiFont(size: 11).foregroundColor(VSDark.textDim)
            HStack {
                SecureField("postgresql://user:password@host/database", text: $pasted).textFieldStyle(.roundedBorder).uiFont(size: 11)
                Button("Save and connect") {
                    if let problem = store.connectDatabase(env: env.id, title: title, pastedURL: pasted) { addError = problem }
                    else { pasted = ""; title = ""; addError = nil; adding = false }
                }.controlSize(.small).disabled(pasted.isEmpty)
            }
            if let addError { Text(addError).uiFont(size: 10).foregroundColor(VSDark.red) }
        }
        .padding(8).background(VSDark.bgInput).cornerRadius(5)
    }
}

private struct DatabaseView: View {
    @ObservedObject var store: DeploymentStore
    let env: DeploymentEnvironment
    let target: DatabaseTarget
    let installPsql: () -> Void

    @State private var picked: String?
    @State private var sql = "select 1"
    @State private var running = false
    @State private var message: String?
    @State private var showAll = false

    private var state: DatabaseState { store.databaseState(env.id, target.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let error = state.error { problem(error) }
            if let o = state.overview {
                summary(o)
                tables(o)
                if let table = o.tables.first(where: { $0.id == picked }) { detail(table) }
                queryBox
            } else if state.loading {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking… a Neon database that was idle needs a few seconds to wake up.").uiFont(size: 11).foregroundColor(VSDark.textDim) }
            }
        }
        .padding(8).background(VSDark.bgInput.opacity(0.5)).cornerRadius(5)
        .task { if state.overview == nil && !state.loading && state.error == nil { await store.loadOverview(env: env.id, target: target.id) } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder.split.1x2").foregroundColor(VSDark.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.title).uiFont(size: 12, weight: .semibold).foregroundColor(VSDark.text)
                Text(target.source == .keychain ? "connection string in the Keychain" : "\(target.file) · \(target.key)").uiFont(size: 10).foregroundColor(VSDark.textDim)
            }
            Spacer()
            if state.loading { ProgressView().controlSize(.small) }
            Button { Task { await store.loadOverview(env: env.id, target: target.id) } } label: { Image(systemName: "arrow.clockwise") }
                .controlSize(.small).disabled(state.loading).help("Look again")
            Button { store.disconnectDatabase(env: env.id, target: target.id) } label: { Image(systemName: "xmark") }
                .controlSize(.small).help("Disconnect (forgets the Keychain item, if there is one)")
        }
    }

    @ViewBuilder private func problem(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(text, systemImage: "exclamationmark.triangle").uiFont(size: 11).foregroundColor(VSDark.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if text.contains("psql is not installed") {
                Button("Install psql") { installPsql() }.controlSize(.small).help("Runs brew install libpq on this Mac after you approve it")
            }
        }
    }

    private func summary(_ o: DatabaseOverview) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), alignment: .topLeading)], alignment: .leading, spacing: 8) {
            fact("Size", databaseBytes(o.bytes))
            fact("Tables", "\(o.tables.filter { $0.kind != "v" }.count)" + (o.tables.contains { $0.kind == "v" } ? " + \(o.tables.filter { $0.kind == "v" }.count) views" : ""))
            fact("Connections", "\(o.connections) of \(o.maxConnections)")
            fact("Server", o.version)
            fact("User", o.user)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            Text(value).uiFont(size: 13, weight: .semibold).foregroundColor(VSDark.text).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func tables(_ o: DatabaseOverview) -> some View {
        let biggest = max(o.tables.map(\.bytes).max() ?? 1, 1)
        let shown = showAll ? o.tables : Array(o.tables.prefix(12))
        return VStack(alignment: .leading, spacing: 2) {
            Text("TABLES — click one to explore (rows are estimates)").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            ForEach(shown) { t in
                Button {
                    picked = t.id
                    Task { await store.loadTable(env: env.id, target: target.id, table: t) }
                } label: {
                    HStack(spacing: 8) {
                        Text(t.schema == "public" ? t.name : t.id).uiFont(size: 11, design: .monospaced).foregroundColor(VSDark.text).lineLimit(1).truncationMode(.middle)
                            .layoutPriority(1)
                        if t.kind != "r" { Text(t.kindTitle).uiFont(size: 9).foregroundColor(VSDark.textDim).lineLimit(1) }
                        Spacer(minLength: 4)
                        Text("~\(t.rows.formatted())").uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1).fixedSize()
                        Text(databaseBytes(t.bytes)).uiFont(size: 10, weight: .medium).foregroundColor(VSDark.text).lineLimit(1).fixedSize()
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6).contentShape(Rectangle())
                    .background(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle().fill(VSDark.blue.opacity(0.22)).frame(width: max(3, geo.size.width * CGFloat(t.bytes) / CGFloat(biggest)))
                        }
                    }
                    .background(picked == t.id ? VSDark.bgActive : Color.clear).cornerRadius(4)
                }.buttonStyle(.plain)
            }
            if o.tables.count > 12 {
                Button(showAll ? "Show fewer" : "Show all \(o.tables.count)") { showAll.toggle() }.controlSize(.small).buttonStyle(.link)
            }
            if o.tables.isEmpty { Text("No tables yet.").uiFont(size: 11).foregroundColor(VSDark.textDim) }
        }
    }

    private func detail(_ table: DatabaseTable) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(table.id).uiFont(size: 12, weight: .semibold, design: .monospaced).foregroundColor(VSDark.text)
                Spacer()
                Button("Query it") { sql = PostgresClient.sampleSQL(schema: table.schema, table: table.name, limit: 100) }.controlSize(.small)
            }
            if let d = state.details[table.id] {
                ForEach(Array(d.columns.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text(c.name).uiFont(size: 11, weight: .medium, design: .monospaced).foregroundColor(VSDark.text).lineLimit(1).layoutPriority(1)
                            Text(c.type).uiFont(size: 11, design: .monospaced).foregroundColor(VSDark.blue).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        let flags = [c.notNull ? "not null" : "", c.defaultValue.isEmpty ? "" : "default \(c.defaultValue)"].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !flags.isEmpty { Text(flags).uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1) }
                    }
                }
                ForEach(d.constraints + d.indexes, id: \.self) { Text($0).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim).lineLimit(2).textSelection(.enabled) }
            }
            if let rows = state.samples[table.id] { ResultGrid(rows) }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(5)
    }

    private var queryBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SQL").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            TextEditor(text: $sql).uiFont(size: 12, design: .monospaced).frame(height: 80).scrollContentBackground(.hidden)
                .padding(4).background(VSDark.bgSidebar).cornerRadius(4)
            HStack(spacing: 10) {
                Button { run() } label: { Label("Run", systemImage: "play.fill") }.controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command).disabled(running || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if running { ProgressView().controlSize(.small) }
                risk
                Spacer()
            }
            if let message { Text(message).uiFont(size: 11).foregroundColor(VSDark.red).textSelection(.enabled) }
            if let error = state.lastError { Text(error).uiFont(size: 11).foregroundColor(VSDark.red).textSelection(.enabled) }
            if let last = state.last { ResultGrid(last.result) }
        }
    }

    @ViewBuilder private var risk: some View {
        switch SQLPolicy.classify(sql) {
        case .readOnly: Label("Read-only: runs at once, the server refuses writes", systemImage: "eye").uiFont(size: 10).foregroundColor(VSDark.green)
        case .needsConfirmation(let why): Label("Asks you first: \(why)", systemImage: "hand.raised").uiFont(size: 10).foregroundColor(VSDark.orange)
        case .blocked(let why): Label(why, systemImage: "nosign").uiFont(size: 10).foregroundColor(VSDark.red)
        }
    }

    private func run() {
        running = true; message = nil
        let text = sql
        Task {
            let outcome = await store.runQuery(text, env: env.id, target: target.id, origin: "You")
            switch outcome {
            case .ran(let result, let wrote): if result.empty { message = wrote ? "Done: the statement ran." : "The statement ran and returned no rows." }
            case .denied: message = "Not run: you said no."
            case .blocked(let why): message = why
            case .failed: break
            }
            running = false
            if case .ran(_, true) = outcome { await store.loadOverview(env: env.id, target: target.id) }
        }
    }
}

/// A result as a table that scrolls sideways.
private struct ResultGrid: View {
    let result: QueryResult
    init(_ result: QueryResult) { self.result = result }

    private func width(_ column: Int) -> CGFloat {
        let longest = ([result.columns[column]] + result.rows.prefix(60).compactMap { $0.indices.contains(column) ? $0[column] : nil }).map { $0.split(separator: "\n").first?.count ?? 0 }.max() ?? 4
        return CGFloat(min(max(longest, 4), 36)) * 7 + 14
    }

    var body: some View {
        if result.empty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 3) {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        row(result.columns, header: true)
                        ForEach(Array(result.rows.enumerated()), id: \.offset) { _, r in row(r, header: false) }
                    }
                }.frame(maxHeight: 260)
                Text("\(result.rows.count)\(result.truncated ? "+" : "") row\(result.rows.count == 1 ? "" : "s")\(result.truncated ? " (more exist: narrow the query)" : "") · \(String(format: "%.1f", result.seconds)) s")
                    .uiFont(size: 10).foregroundColor(VSDark.textDim)
            }
            .padding(6).background(VSDark.bgSidebar).cornerRadius(4)
        }
    }

    private func row(_ cells: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(result.columns.indices), id: \.self) { i in
                Text(cells.indices.contains(i) ? cells[i].replacingOccurrences(of: "\n", with: "⏎") : "")
                    .uiFont(size: 11, weight: header ? .semibold : .regular, design: .monospaced).foregroundColor(header ? VSDark.blue : VSDark.text)
                    .lineLimit(1).textSelection(.enabled).frame(width: width(i), alignment: .leading).padding(.horizontal, 3).padding(.vertical, 2)
            }
        }
        .background(header ? VSDark.bgInput : Color.clear)
    }
}
