import SwiftUI

/// Deployments: the places the project runs, and how each one is doing.
struct DeploymentsView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @ObservedObject var store: DeploymentStore
    @State private var editing: DeploymentEnvironment?
    @State private var adding = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 214)
            Divider().background(VSDark.border)
            Group {
                if let id = store.selected, let env = store.environment(id) {
                    EnvironmentDetail(store: store, env: env, edit: { editing = env })
                        .id(id)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VSDark.bg)
        .sheet(item: $editing) { env in EnvironmentEditor(store: store, original: env, isNew: false) { editing = nil } }
        .sheet(isPresented: $adding) {
            EnvironmentEditor(store: store, original: DeploymentEnvironment(id: "", name: "", kind: .ssh), isNew: true) { adding = false }
        }
        .sheet(item: $store.approval) { request in ApprovalSheet(store: store, request: request) }
        .onAppear { if !store.hasScanned { store.scan() } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("ENVIRONMENTS").uiFont(size: 10, weight: .semibold).foregroundColor(VSDark.textDim)
                Spacer()
                Button { adding = true } label: { Image(systemName: "plus") }.help("Add an environment by hand")
                Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }.help("Look at every environment again")
                    .disabled(store.environments.isEmpty)
            }
            .buttonStyle(.plain).foregroundColor(VSDark.textDim).padding(.horizontal, 10).padding(.vertical, 8)
            Divider().background(VSDark.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.environments) { env in row(env) }
                    suggestionsSection
                }
            }
            Divider().background(VSDark.border)
            HStack(spacing: 6) {
                Toggle("Refresh every 30 s", isOn: $store.autoRefresh).toggleStyle(.checkbox).uiFont(size: 10)
                Spacer()
            }.padding(.horizontal, 10).padding(.vertical, 6)
            Button { workspaceManager.analyzeDeploymentsWithAI() } label: {
                Label("Ask AI to find where it runs", systemImage: "sparkles").uiFont(size: 10, weight: .medium)
            }
            .buttonStyle(.bordered).controlSize(.small).padding(.horizontal, 10).padding(.bottom, 10)
            .help("The assistant reads the code, docs and GitHub setup, asks what it cannot find out, and proposes environments")
        }
        .background(VSDark.bgSidebar)
    }

    private func row(_ env: DeploymentEnvironment) -> some View {
        let state = store.states[env.id]
        return Button { store.selected = env.id } label: {
            HStack(spacing: 8) {
                Circle().fill(color(state)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(env.name).uiFont(size: 12, weight: .medium).foregroundColor(VSDark.text).lineLimit(1)
                    Text(subtitle(env)).uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1)
                }
                Spacer(minLength: 0)
                if state?.phase == .loading { ProgressView().controlSize(.small).scaleEffect(0.6) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(store.selected == env.id ? VSDark.bgActive : Color.clear)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func subtitle(_ env: DeploymentEnvironment) -> String {
        switch env.kind {
        case .ssh: return env.destination
        case .local: return "This Mac"
        case .cloud: return env.provider
        }
    }

    private func color(_ state: DeploymentStore.State?) -> Color {
        guard let state else { return VSDark.textDim.opacity(0.5) }
        if state.phase == .failed { return VSDark.red }
        guard let snap = state.snapshot else { return state.phase == .loaded ? VSDark.green : VSDark.textDim.opacity(0.5) }
        switch snap.health { case .ok: return VSDark.green; case .warning: return VSDark.orange; case .critical: return VSDark.red }
    }

    @ViewBuilder private var suggestionsSection: some View {
        HStack {
            Text("FOUND IN THE PROJECT").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            Spacer()
            if store.scanning { ProgressView().controlSize(.small).scaleEffect(0.6) }
            else { Button("Scan again") { store.scan() }.buttonStyle(.plain).uiFont(size: 9).foregroundColor(VSDark.blue) }
        }.padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
        if store.suggestions.isEmpty && !store.scanning {
            Text("Nothing found in the workflows, platform files, docs and ~/.ssh/config. Add one by hand, or ask the assistant.")
                .uiFont(size: 10).foregroundColor(VSDark.textDim).padding(.horizontal, 10)
        }
        ForEach(store.suggestions) { s in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(s.name).uiFont(size: 11, weight: .medium).foregroundColor(VSDark.text).lineLimit(1)
                    Text(s.kind == .cloud ? s.provider : s.host).uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1)
                    Spacer()
                    Button("Add") { store.accept(s) }.buttonStyle(.bordered).controlSize(.mini)
                }
                ForEach(s.evidence.prefix(2), id: \.self) { Text($0).uiFont(size: 9).foregroundColor(VSDark.textDim).lineLimit(1).truncationMode(.middle) }
                ForEach(s.missing, id: \.self) { Text($0).uiFont(size: 9).foregroundColor(VSDark.orange).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack").uiFont(size: 30).foregroundColor(VSDark.textDim)
            Text("Where does this project run?").uiFont(size: 14, weight: .semibold).foregroundColor(VSDark.text)
            Text("Add a server (over SSH), this Mac, or a cloud service. MarkView looks at CPU, memory, disks, services, containers and logs, read-only. Anything that changes something asks you first.")
                .uiFont(size: 11).foregroundColor(VSDark.textDim).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Button("Add an environment") { adding = true }.buttonStyle(.borderedProminent)
                Button("Ask AI to find where it runs") { workspaceManager.analyzeDeploymentsWithAI() }
            }
        }.padding(30)
    }
}

// MARK: - Detail

private struct EnvironmentDetail: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @ObservedObject var store: DeploymentStore
    let env: DeploymentEnvironment
    let edit: () -> Void
    @State private var command = ""
    @State private var output: String?
    @State private var running = false
    @State private var logSource: String = ""
    @State private var logText = ""
    @State private var logFilter = ""
    @State private var trusting: (lines: [String], fingerprints: [String])?
    @State private var question = ""

    private var state: DeploymentStore.State { store.states[env.id] ?? DeploymentStore.State() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let problem = state.problem { problemBanner(problem) }
                assistantCard
                if let snap = state.snapshot, snap.os != "cloud" { system(snap) }
                if let snap = state.snapshot, !snap.checks.isEmpty || !state.held.isEmpty { checks(snap) }
                if let snap = state.snapshot, snap.os != "cloud", !snap.containers.isEmpty || !snap.failedUnits.isEmpty { services(snap) }
                if env.kind == .cloud { cloud }
                if env.kind != .cloud { logs }
                commandBox
                if let snap = state.snapshot, snap.os != "cloud", !snap.processes.isEmpty { processes(snap) }
                activity
            }
            .padding(18)
        }
        .task { if state.phase == .idle { await store.refresh(env.id) } }
        .sheet(isPresented: Binding(get: { trusting != nil }, set: { if !$0 { trusting = nil } })) { trustSheet }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(env.name).uiFont(size: 18, weight: .semibold).foregroundColor(VSDark.text).lineLimit(1)
                if let snap = state.snapshot, snap.os != "cloud" { healthBadge(snap) }
                Spacer(minLength: 0)
            }
            Text(env.kind == .ssh ? "\(env.destination):\(env.port)" : env.kind == .local ? "This Mac" : env.provider)
                .uiFont(size: 11, design: .monospaced).foregroundColor(VSDark.textDim).lineLimit(1)
            HStack(spacing: 8) {
                Button { Task { await store.refresh(env.id) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(state.phase == .loading)
                Button("Edit", action: edit)
                if state.phase == .loading { ProgressView().controlSize(.small) }
                if let updated = state.updated { Text("looked at \(updated.formatted(date: .omitted, time: .standard))").uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1) }
                Spacer(minLength: 0)
            }.controlSize(.small)
        }
    }

    private func healthBadge(_ snap: SystemSnapshot) -> some View {
        let (text, color): (String, Color) = snap.health == .ok ? ("Healthy", VSDark.green) : snap.health == .warning ? ("Needs a look", VSDark.orange) : ("Problem", VSDark.red)
        return Text(text).uiFont(size: 10, weight: .semibold).foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 2).background(color.opacity(0.15)).cornerRadius(8)
            .help(snap.reasons.isEmpty ? "Nothing stands out" : snap.reasons.joined(separator: "\n"))
    }

    private func problemBanner(_ problem: ConnectionProblem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(VSDark.red)
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.message).uiFont(size: 11).foregroundColor(VSDark.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if problem == .hostKeyUnknown {
                    Button("Check the host key…") { Task { trusting = await HostKeys.scan(host: env.host, port: env.port) ?? ([], ["The server did not give a key. Is it reachable?"]) } }
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10).background(VSDark.red.opacity(0.12)).cornerRadius(6)
    }

    private var trustSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trust this server?").uiFont(size: 14, weight: .semibold)
            Text("Compare these fingerprints with what the server's owner gives you (or `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub` on the server). If they match, trust the host: its key is added to ~/.ssh/known_hosts.")
                .uiFont(size: 11).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView { Text((trusting?.fingerprints ?? []).joined(separator: "\n")).uiFont(size: 11, design: .monospaced).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 90).padding(6).background(VSDark.bgInput).cornerRadius(5)
            HStack {
                Spacer()
                Button("Cancel") { trusting = nil }
                Button("Trust and connect") {
                    if let lines = trusting?.lines, !lines.isEmpty, HostKeys.trust(lines: lines) { Task { await store.refresh(env.id) } }
                    trusting = nil
                }.buttonStyle(.borderedProminent).disabled((trusting?.lines ?? []).isEmpty)
            }
        }.padding(18).frame(width: 520)
    }

    private func system(_ snap: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10, alignment: .top)], spacing: 10) {
                gauge("CPU load", value: min(snap.loadPerCPU, 2) / 2, text: String(format: "%.2f per CPU", snap.loadPerCPU),
                      detail: snap.load.map { String(format: "%.2f", $0) }.joined(separator: "  ") + " · \(snap.cpus) CPUs", warn: snap.loadPerCPU > 1.5, bad: snap.loadPerCPU > 3,
                      series: state.history.map { min($0.load, 2) / 2 })
                gauge("Memory", value: snap.memUsedFraction, text: "\(Int(snap.memUsedFraction * 100)) %",
                      detail: "\(bytes(snap.memUsedKB)) of \(bytes(snap.memTotalKB))", warn: snap.memUsedFraction > 0.8, bad: snap.memUsedFraction > 0.9,
                      series: state.history.map(\.memory))
                gauge("Uptime", value: nil, text: SystemProbe.uptimeText(snap.uptimeSeconds), detail: "\(snap.os) \(snap.kernel)\n\(snap.host)", warn: false, bad: false, series: [])
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("DISKS").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                ForEach(snap.disks, id: \.mount) { disk in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(disk.mount).uiFont(size: 11, design: .monospaced).foregroundColor(VSDark.text).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
                            bar(Double(disk.percent) / 100, warn: disk.percent >= 80, bad: disk.percent >= 90)
                            Text("\(disk.percent) %").uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim).frame(width: 40, alignment: .trailing)
                        }
                        Text("\(bytes(disk.usedKB)) used of \(bytes(disk.sizeKB))").uiFont(size: 9).foregroundColor(VSDark.textDim)
                    }
                }
            }
            .padding(10).background(VSDark.bgSidebar).cornerRadius(6)
        }
    }

    private func gauge(_ title: String, value: Double?, text: String, detail: String, warn: Bool, bad: Bool, series: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            Text(text).uiFont(size: 20, weight: .semibold).foregroundColor(bad ? VSDark.red : warn ? VSDark.orange : VSDark.text)
            if let value { bar(value, warn: warn, bad: bad) }
            if series.count > 1 { Sparkline(values: series, color: bad ? VSDark.red : warn ? VSDark.orange : VSDark.blue).frame(height: 22) }
            Text(detail).uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(3)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
    }

    private func bar(_ fraction: Double, warn: Bool, bad: Bool) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(VSDark.bgInput)
                RoundedRectangle(cornerRadius: 3).fill(bad ? VSDark.red : warn ? VSDark.orange : VSDark.green)
                    .frame(width: max(2, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }.frame(height: 8)
    }

    private func checks(_ snap: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CHECKS").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            ForEach(env.checks) { check in
                let result = snap.checks.first { $0.id == check.id }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: result?.status == .ok ? "checkmark.circle.fill" : result?.status == .fail ? "xmark.octagon.fill" : "questionmark.circle")
                        .foregroundColor(result?.status == .ok ? VSDark.green : result?.status == .fail ? VSDark.red : VSDark.textDim)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.title.isEmpty ? check.id : check.title).uiFont(size: 11).foregroundColor(VSDark.text)
                        Text("\(check.kind.rawValue) \(check.target)").uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if let detail = result?.detail, !detail.isEmpty { Text(detail).uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(2).multilineTextAlignment(.trailing).frame(maxWidth: 140, alignment: .trailing) }
                    if state.held.contains(where: { $0.id == check.id }) { Text("needs your OK").uiFont(size: 10).foregroundColor(VSDark.orange).help("This command is not on the read-only list, so it does not run by itself. Run it from the command box.") }
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
    }

    private func services(_ snap: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !snap.containers.isEmpty {
                Text("CONTAINERS").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                ForEach(snap.containers, id: \.name) { c in
                    HStack(spacing: 8) {
                        Circle().fill(c.status.lowercased().hasPrefix("up") ? VSDark.green : VSDark.orange).frame(width: 7, height: 7)
                        Text(c.name).uiFont(size: 11, weight: .medium).foregroundColor(VSDark.text)
                        Text(c.image).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim).lineLimit(1)
                        Spacer()
                        Text(c.status).uiFont(size: 10).foregroundColor(VSDark.textDim)
                    }
                }
            }
            if !snap.failedUnits.isEmpty {
                Text("FAILED SERVICES").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.red).padding(.top, 4)
                ForEach(snap.failedUnits, id: \.self) { Text($0).uiFont(size: 11, design: .monospaced).foregroundColor(VSDark.red) }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
    }

    private func processes(_ snap: SystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BUSIEST PROCESSES").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            ForEach(snap.processes, id: \.pid) { p in
                HStack {
                    Text(p.name).uiFont(size: 11, design: .monospaced).foregroundColor(VSDark.text).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f %% CPU", p.cpu)).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim)
                    Text(String(format: "%.1f %% mem", p.memory)).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
    }

    private var cloud: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLOUD STATE (\(env.provider.uppercased()))").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            if env.cloudCommands.isEmpty { Text("No commands yet. Add read-only commands of the provider's CLI in Edit.").uiFont(size: 11).foregroundColor(VSDark.textDim) }
            ForEach(env.cloudCommands) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(c.title).uiFont(size: 11, weight: .medium).foregroundColor(VSDark.text)
                        Text(c.command).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim).lineLimit(1)
                        Spacer()
                        if !CommandPolicy.classify(c.command).isReadOnly { Text("asks first").uiFont(size: 10).foregroundColor(VSDark.orange) }
                    }
                    if let out = state.cloud[c.id] {
                        if !out.result.succeeded, let found = ProviderHints.problem(command: c.command, stderr: out.result.stderr + out.result.stdout, status: out.result.status),
                           let advice = ProviderHints.advice(command: c.command, stderr: out.result.stderr + out.result.stdout, status: out.result.status) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(advice, systemImage: "wrench.and.screwdriver").uiFont(size: 10).foregroundColor(VSDark.orange)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                HStack(spacing: 8) {
                                    if found.problem == .missing {
                                        Button("Install \(found.hint.tool)") { install(found.hint) }.controlSize(.small).disabled(running)
                                            .help("Runs \(found.hint.installCommand) on this Mac after you approve it")
                                    } else {
                                        Button("Sign in…") { signIn(found.hint) }.controlSize(.small)
                                            .help("Opens a terminal here and copies \(found.hint.login)")
                                    }
                                    if running { ProgressView().controlSize(.small) }
                                }
                            }
                        }
                        Text(out.result.succeeded ? out.result.stdout : (out.result.stderr.isEmpty ? out.result.stdout : out.result.stderr))
                            .uiFont(size: 10, design: .monospaced).foregroundColor(out.result.succeeded ? VSDark.text : VSDark.red)
                            .textSelection(.enabled).lineLimit(30).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6).background(VSDark.bgInput).cornerRadius(4)
                    } else if state.phase == .loading {
                        Text("Looking…").uiFont(size: 10).foregroundColor(VSDark.textDim)
                    }
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
    }

    /// Ask the assistant about this environment; it looks with the markview_deployments tools.
    private var assistantCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(VSDark.purple)
                Text("ASK THE AI ABOUT THIS ENVIRONMENT").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            }
            HStack {
                TextField("e.g. Why is it slow? Is the database fine? What failed in the last hour?", text: $question)
                    .textFieldStyle(.roundedBorder).onSubmit { ask(question) }
                Button("Ask") { ask(question) }.disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("MarkView looks, reads the logs and the assistant answers here")
                Button { askInAgents(question) } label: { Image(systemName: "terminal") }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Ask in the Agents tab instead: the assistant there can run more commands (changes ask you first)")
            }
            HStack(spacing: 6) {
                ForEach(quickQuestions, id: \.self) { q in
                    Button(q) { ask(q) }.buttonStyle(.bordered).controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            AdvisorAnswers(advisor: workspaceManager.deploymentAdvisor, envID: env.id) { q in askInAgents(q) }
            Text("MarkView looks at the environment, reads the logs that matter (read-only) and your project's assistant answers from that. To go further, continue in the Agents tab: there it can run more commands, and anything that changes something is shown to you here first.")
                .uiFont(size: 10).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
    }

    private var quickQuestions: [String] {
        state.problem != nil
            ? ["Help me connect", "What could be wrong?"]
            : ["Is it healthy?", "Look for errors in the logs", "Why is it slow?"]
    }

    /// The answer appears here: state and logs are read by MarkView, the project's own assistant reads them.
    private func ask(_ text: String, log: String? = nil, logTitle: String? = nil) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let workspace = workspaceManager
        workspace.deploymentAdvisor.ask(q, env: env, store: store, root: store.root, log: log.map { (logTitle ?? "Log", $0) }) { result in
            result.record(in: workspace.semanticDatabase)
        }
        question = ""
    }

    /// The same question in the Agents tab, where the assistant can run commands (with your approval for changes).
    private func askInAgents(_ text: String, log: String? = nil, logTitle: String? = nil) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        workspaceManager.askAboutDeployment(env.id, question: q, logTitle: logTitle, log: log)
        question = ""
    }

    private var logs: some View {
        let sources = store.logSources(env.id)
        return VStack(alignment: .leading, spacing: 6) {
            Text("LOGS").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            HStack {
                Picker("", selection: $logSource) {
                    ForEach(sources) { Text($0.title).tag($0.id) }
                }.labelsHidden().frame(maxWidth: 220)
                Button("Fetch") { fetchLog() }.disabled(running || logSource.isEmpty)
                TextField("Filter", text: $logFilter).textFieldStyle(.roundedBorder).frame(minWidth: 80, maxWidth: 160)
                if !logText.isEmpty {
                    Button { ask("Read this log: what stands out, and what should I do?", log: logText, logTitle: sources.first { $0.id == logSource }?.title) } label: { Label("Ask AI", systemImage: "sparkles") }
                        .help("Send what is on screen to the assistant")
                }
                Spacer(minLength: 0)
            }
            if logText.isEmpty && !running {
                Text("Pick a log and Fetch. These are read-only commands: the system's journal and one log per service and container.").uiFont(size: 10).foregroundColor(VSDark.textDim)
            }
            if !logText.isEmpty {
                ScrollView {
                    Text(filteredLog).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 240).padding(6).background(VSDark.bgInput).cornerRadius(4)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
        .onAppear { if logSource.isEmpty { logSource = sources.first?.id ?? "" } }
    }

    private var filteredLog: String {
        guard !logFilter.isEmpty else { return logText }
        return logText.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.localizedCaseInsensitiveContains(logFilter) }.joined(separator: "\n")
    }

    private func fetchLog() {
        guard let source = store.logSources(env.id).first(where: { $0.id == logSource }) else { return }
        running = true
        Task {
            let outcome = await store.run(source.command, on: env.id, origin: "You")
            logText = outcome.summary
            running = false
        }
    }

    private var commandBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RUN A COMMAND").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
            HStack {
                TextField(env.kind == .cloud ? "e.g. vercel logs my-deployment" : "e.g. journalctl -u myapp -n 100 --no-pager", text: $command)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced)).onSubmit(runCommand)
                Button("Run", action: runCommand).disabled(running || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !command.trimmingCharacters(in: .whitespaces).isEmpty { riskChip }
            if let output {
                ScrollView { Text(output).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 260).padding(6).background(VSDark.bgInput).cornerRadius(4)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
    }

    @ViewBuilder private var riskChip: some View {
        switch CommandPolicy.classify(command) {
        case .readOnly: Label("Read-only: runs at once", systemImage: "eye").uiFont(size: 10).foregroundColor(VSDark.green)
        case .needsConfirmation(let why): Label("Asks you first: \(why)", systemImage: "hand.raised").uiFont(size: 10).foregroundColor(VSDark.orange)
        case .blocked(let why): Label(why, systemImage: "nosign").uiFont(size: 10).foregroundColor(VSDark.red)
        }
    }

    /// Install a provider's CLI: the person sees the exact command and approves it, then it runs here and the state is read again.
    private func install(_ hint: ProviderHints.Hint) {
        running = true
        Task {
            output = await store.run(hint.installCommand, on: env.id, origin: "You", purpose: "Install \(hint.tool), the command-line tool of \(env.provider.isEmpty ? "this service" : env.provider)", timeout: 900).summary
            running = false
            await store.refresh(env.id)
        }
    }

    /// Signing in opens a browser and waits for it: do it in a terminal. The command is copied.
    private func signIn(_ hint: ProviderHints.Hint) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hint.login.components(separatedBy: "   (").first ?? hint.login, forType: .string)
        if let root = store.root { workspaceManager.openTerminal(in: root) }
        output = "Copied: \(hint.login). Paste it in the terminal that opened, finish signing in, then press Refresh."
    }

    private func runCommand() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        running = true
        output = nil
        Task {
            output = await store.run(text, on: env.id, origin: "You").summary
            running = false
            if CommandPolicy.classify(text).isReadOnly == false { await store.refresh(env.id) }
        }
    }

    private var activity: some View {
        let entries = store.log.filter { $0.environment == env.id && $0.origin != "Refresh" }.suffix(8).reversed()
        return Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECENT COMMANDS").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                    ForEach(Array(entries)) { e in
                        HStack(spacing: 8) {
                            Text(e.time.formatted(date: .omitted, time: .standard)).uiFont(size: 10).foregroundColor(VSDark.textDim)
                            Text(e.origin).uiFont(size: 10, weight: .medium).foregroundColor(e.origin == "You" ? VSDark.blue : VSDark.purple)
                            Text(e.command).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.text).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(e.outcome + (e.status.map { " (\($0))" } ?? "")).uiFont(size: 10).foregroundColor(e.outcome == "ran" ? VSDark.textDim : VSDark.orange)
                        }
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
            }
        }
    }

    private func bytes(_ kb: Int64) -> String { ByteCountFormatter.string(fromByteCount: kb * 1024, countStyle: .binary) }
}

/// A small line of recent values (0…1).
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let point = CGPoint(x: proxy.size.width * CGFloat(i) / CGFloat(values.count - 1), y: proxy.size.height * (1 - CGFloat(min(max(v, 0), 1))))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Approval

private struct ApprovalSheet: View {
    @ObservedObject var store: DeploymentStore
    let request: DeploymentApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundColor(VSDark.orange).font(.system(size: 18))
                Text("\(request.origin) wants to run a command").uiFont(size: 14, weight: .semibold)
            }
            Text("On \(request.environment.name) (\(request.environment.kind == .ssh ? request.environment.destination : request.environment.kind == .local ? "this Mac" : request.environment.provider))")
                .uiFont(size: 11).foregroundColor(.secondary)
            Text(request.command).uiFont(size: 12, design: .monospaced).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgInput).cornerRadius(5)
            if !request.purpose.isEmpty { Text("For: \(request.purpose)").uiFont(size: 11).fixedSize(horizontal: false, vertical: true) }
            Text("Why you are asked: \(request.reason)").uiFont(size: 10).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Don't run") { store.answer(false) }.keyboardShortcut(.cancelAction)
                Button("Run it") { store.answer(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 520)
        .interactiveDismissDisabled()
    }
}

// MARK: - Editor

private struct EnvironmentEditor: View {
    @ObservedObject var store: DeploymentStore
    @State var env: DeploymentEnvironment
    let isNew: Bool
    let close: () -> Void
    @State private var portText: String
    @State private var confirmDelete = false

    init(store: DeploymentStore, original: DeploymentEnvironment, isNew: Bool, close: @escaping () -> Void) {
        self.store = store
        _env = State(initialValue: original)
        _portText = State(initialValue: String(original.port))
        self.isNew = isNew
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "Add an environment" : "Edit \(env.name)").uiFont(size: 14, weight: .semibold).padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("Name") { TextField("Production", text: $env.name).textFieldStyle(.roundedBorder) }
                    field("Kind") {
                        Picker("", selection: $env.kind) {
                            Text("Server over SSH").tag(DeploymentEnvironment.Kind.ssh)
                            Text("This Mac").tag(DeploymentEnvironment.Kind.local)
                            Text("Cloud service (its CLI)").tag(DeploymentEnvironment.Kind.cloud)
                        }.labelsHidden().pickerStyle(.segmented)
                    }
                    if env.kind == .ssh {
                        field("Host") { TextField("web-1.example.com or a Host from ~/.ssh/config", text: $env.host).textFieldStyle(.roundedBorder) }
                        HStack {
                            field("User") { TextField("deploy", text: $env.user).textFieldStyle(.roundedBorder) }
                            field("Port") { TextField("22", text: $portText).textFieldStyle(.roundedBorder).frame(width: 70).onChange(of: portText) { env.port = Int($0) ?? 22 } }
                        }
                        field("Key file (optional)") { TextField("~/.ssh/id_ed25519: leave empty to use your agent and ~/.ssh/config", text: $env.identityFile).textFieldStyle(.roundedBorder) }
                        Text("MarkView never stores passwords or keys. It connects with your SSH agent or key file, without prompts.").uiFont(size: 10).foregroundColor(.secondary)
                    }
                    if env.kind == .cloud {
                        field("Provider") { TextField("vercel, fly, heroku, aws, gcloud, kubernetes…", text: $env.provider).textFieldStyle(.roundedBorder) }
                        listEditor("Commands that show the state", add: { env.cloudCommands.append(CloudCommand(id: UUID().uuidString.prefix(6).lowercased(), title: "", command: "")) }) {
                            ForEach($env.cloudCommands) { $c in
                                HStack {
                                    TextField("Title", text: $c.title).textFieldStyle(.roundedBorder).frame(width: 140)
                                    TextField("vercel ls", text: $c.command).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                                    Button { env.cloudCommands.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if env.kind != .cloud {
                        listEditor("Checks", add: { env.checks.append(DeploymentCheck(id: UUID().uuidString.prefix(6).lowercased(), title: "", kind: .systemd)) }) {
                            ForEach($env.checks) { $c in
                                HStack {
                                    TextField("Title", text: $c.title).textFieldStyle(.roundedBorder).frame(width: 130)
                                    Picker("", selection: $c.kind) { ForEach(DeploymentCheck.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 100)
                                    TextField(targetHint(c.kind), text: $c.target).textFieldStyle(.roundedBorder)
                                    Button { env.checks.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                }
                            }
                        }
                        listEditor("Logs", add: { env.logSources.append(LogSource(id: UUID().uuidString.prefix(6).lowercased(), title: "", command: "")) }) {
                            ForEach($env.logSources) { $l in
                                HStack {
                                    TextField("Title", text: $l.title).textFieldStyle(.roundedBorder).frame(width: 130)
                                    TextField("journalctl -u app -n 200 --no-pager", text: $l.command).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                                    Button { env.logSources.removeAll { $0.id == l.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                }
                            }
                        }
                    } else {
                        listEditor("Checks from this Mac (http, port)", add: { env.checks.append(DeploymentCheck(id: UUID().uuidString.prefix(6).lowercased(), title: "", kind: .http)) }) {
                            ForEach($env.checks) { $c in
                                HStack {
                                    TextField("Title", text: $c.title).textFieldStyle(.roundedBorder).frame(width: 130)
                                    Picker("", selection: $c.kind) { ForEach([DeploymentCheck.Kind.http, .port], id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 90)
                                    TextField(targetHint(c.kind), text: $c.target).textFieldStyle(.roundedBorder)
                                    Button { env.checks.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    field("Notes") { TextEditor(text: $env.notes).font(.system(size: 11)).frame(height: 60).border(Color.secondary.opacity(0.3)) }
                    if !env.evidence.isEmpty {
                        field("Where this came from") { Text(env.evidence.joined(separator: "\n")).uiFont(size: 10).foregroundColor(.secondary).textSelection(.enabled) }
                    }
                    ForEach(env.problems, id: \.self) { Text($0).uiFont(size: 11).foregroundColor(.red) }
                }
                .padding(16)
            }
            Divider()
            HStack {
                if !isNew { Button("Delete…", role: .destructive) { confirmDelete = true } }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    if isNew { store.add(env); if let id = store.selected { Task { await store.refresh(id) } } } else { store.update(env); Task { await store.refresh(env.id) } }
                    close()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!env.problems.isEmpty)
            }.padding(12)
        }
        .frame(width: 620, height: 640)
        .confirmationDialog("Delete \(env.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.remove(env.id); close() }
        } message: { Text("Only the entry in this project's deployments.json goes. Nothing on the server changes.") }
    }

    private func targetHint(_ kind: DeploymentCheck.Kind) -> String {
        switch kind {
        case .systemd: return "nginx"
        case .docker: return "container name"
        case .port: return "host:port"
        case .http: return "https://example.com/health"
        case .postgres, .redis, .mysql: return "optional: -h host"
        case .command: return "a read-only command"
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).uiFont(size: 10, weight: .semibold).foregroundColor(.secondary)
            content()
        }
    }

    private func listEditor<Content: View>(_ title: String, add: @escaping () -> Void, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).uiFont(size: 10, weight: .semibold).foregroundColor(.secondary)
                Spacer()
                Button { add() } label: { Image(systemName: "plus.circle") }.buttonStyle(.plain)
            }
            content()
        }
    }
}

/// The answers to the questions asked about an environment, with what the assistant is doing while it works.
private struct AdvisorAnswers: View {
    @ObservedObject var advisor: DeploymentAdvisor
    let envID: String
    let continueInAgents: (String) -> Void

    var body: some View {
        if let exchange = advisor.latest(envID) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(exchange.question).uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text).lineLimit(2)
                    Spacer(minLength: 4)
                    if case .working = exchange.state { Button("Stop") { advisor.cancel(envID) }.controlSize(.small) }
                    else { Button { advisor.clear(envID) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundColor(VSDark.textDim).help("Clear") }
                }
                switch exchange.state {
                case .working(let step):
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(step).uiFont(size: 10).foregroundColor(VSDark.textDim) }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").uiFont(size: 10).foregroundColor(VSDark.red).textSelection(.enabled)
                case .done: EmptyView()
                }
                if !exchange.answer.isEmpty {
                    Text(rendered(exchange.answer)).uiFont(size: 11).foregroundColor(VSDark.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                if !exchange.evidence.isEmpty {
                    Text("Read: " + exchange.evidence.joined(separator: " · ")).uiFont(size: 9).foregroundColor(VSDark.textDim).lineLimit(2)
                }
                if exchange.state == .done {
                    HStack(spacing: 8) {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(exchange.answer, forType: .string) }
                        Button("Continue in Agents") { continueInAgents(exchange.question) }
                            .help("Ask the same in the Agents tab, where the assistant can run more commands")
                    }.controlSize(.small)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bg).cornerRadius(6)
        }
    }

    private func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
