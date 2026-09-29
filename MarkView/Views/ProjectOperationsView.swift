import SwiftUI

/// The same operation registry powers both toolbar entry points and the details panel.
struct ProjectDeployButton: View {
    @ObservedObject var store: ProjectOperationsStore

    var body: some View {
        let deploys = store.deployOperations
        if deploys.count == 1, let operation = deploys.first {
            Button { action(operation) } label: { label }
                .buttonStyle(.bordered)
                .disabled(store.unavailability(for: operation) != nil && store.runs[operation.id]?.isActive != true)
                .help(store.unavailability(for: operation) ?? operation.label
                    + (operation.environment.map { " · \($0)" } ?? "")
                    + (store.state(id: operation.id) == "dispatched" ? " · Remote run is not tracked" : ""))
        } else if !deploys.isEmpty {
            Menu { pickerItems(deploys) } label: { label }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
    }

    private var label: some View {
        let states = store.deployOperations.compactMap { store.state(id: $0.id) }
        let suffix = states.contains("running") || states.contains("cancelling") ? "Running"
            : store.deployOperations.count == 1 ? (states.first?.capitalized ?? "") : ""
        return Label(suffix.isEmpty ? "Deploy" : "Deploy · " + suffix,
              systemImage: "arrow.up.circle")
            .uiFont(size: 11, weight: .semibold)
    }

    @ViewBuilder
    private func pickerItems(_ operations: [ProjectOperation]) -> some View {
        let unnamed = operations.filter { ($0.environment ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        ForEach(unnamed.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }) { operation in item(operation) }
        let names = operations.compactMap { $0.environment?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let groups = names.enumerated().filter { index, name in
            !names[..<index].contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }.map(\.element)
        ForEach(groups, id: \.self) { name in
            let members = operations.filter {
                ($0.environment ?? "").trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
            }
            Section(name + (members.contains { store.runs[$0.id]?.isActive == true } ? " · Running" : "")) {
                ForEach(members.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }) { operation in
                    item(operation)
                }
            }
        }
    }

    private func item(_ operation: ProjectOperation) -> some View {
        let running = store.runs[operation.id]?.isActive == true
        return Button {
            action(operation)
        } label: {
            Text(title(for: operation))
        }
        .disabled(store.unavailability(for: operation) != nil && !running)
        .help(store.unavailability(for: operation) ?? operation.command)
    }

    /// "State · Label · notes", built in steps so older compilers type-check it quickly.
    private func title(for operation: ProjectOperation) -> String {
        let state: String? = store.state(id: operation.id)
        var parts: [String] = []
        if let state { parts.append(state.capitalized) }
        parts.append(operation.label)
        if operation.confidence == "low" && !operation.isEdited { parts.append("Low confidence") }
        if state == "dispatched" { parts.append("Remote run is not tracked") }
        return parts.joined(separator: " · ")
    }

    private func action(_ operation: ProjectOperation) {
        if store.runs[operation.id]?.isActive == true { store.openPanel(id: operation.id) }
        else { store.run(id: operation.id) }
    }
}

struct ProjectOperationConsole: View {
    @ObservedObject var store: ProjectOperationsStore

    private static func runTitle(label: String, environment: String?, state: String) -> String {
        let suffix: String = environment.map { " (\($0))" } ?? ""
        return "\(label)\(suffix) · \(state)"
    }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Project operations").font(.headline)
                Spacer()
                Button("Close") { store.panelVisible = false; dismiss() }
            }
            .padding(12)
            Divider()
            if !store.runs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(store.runs.keys.sorted(), id: \.self) { id in
                            if let run = store.runs[id] {
                                Button {
                                    store.selectedRunID = id
                                } label: {
                                    Text(Self.runTitle(label: run.snapshot.label,
                                                       environment: run.snapshot.environment, state: run.state))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(8)
                }
                Divider()
            }
            if let id = store.selectedRunID, let run = store.runs[id] {
                OperationRunPanel(store: store, run: run)
                    .id(run.id)
            } else if let id = store.selectedRunID, let last = store.lastRuns[id] {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(last.label)\(last.environment.map { " (\($0))" } ?? "")").font(.headline)
                    Text("Last run: " + last.state.capitalized)
                    if let code = last.exitCode { Text("Exit code: \(code)") }
                    if let ended = last.ended { Text("Ended: \(ended.formatted())") }
                    Text("Output is not kept across application restarts.").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("Select an operation to see its output.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 430)
    }
}

private struct OperationRunPanel: View {
    @ObservedObject var store: ProjectOperationsStore
    @ObservedObject var run: ProjectOperationRun

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(run.snapshot.label).font(.headline)
                if let environment = run.snapshot.environment { Text(environment).foregroundStyle(.secondary) }
                Text(run.state.capitalized)
                    .foregroundStyle(run.state == "failed" ? .red : .secondary)
                if let code = run.exitCode { Text("Exit \(code)").foregroundStyle(.secondary) }
                if run.state == "dispatched" { Text("Remote run is not tracked").foregroundStyle(.secondary) }
                if let seconds = run.graceSeconds { Text("\(seconds) s before escalation").foregroundStyle(.secondary) }
                Spacer()
                if run.state == "running" { Button("Cancel") { store.cancel(id: run.id) } }
                if run.state == "cancelling" { Button("Force stop") { store.forceStop(id: run.id) } }
                if !run.isActive { Button("Dismiss") { store.dismiss(id: run.id) } }
            }
            .padding(10)
            if let notice = run.definitionNotice {
                Text(notice).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
            }
            TerminalHostView(session: run.session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProjectOperationEditRequest: Identifiable {
    let id = UUID()
    let operation: ProjectOperation?
    var kind = "other"
    var environment: String?
    var label: String?
}

struct ProjectOperationEditor: View {
    @ObservedObject var store: ProjectOperationsStore
    let request: ProjectOperationEditRequest
    let deploymentNodes: [ProjectOperation.Node]
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var kind: String
    @State private var environment: String
    @State private var target: String
    @State private var command: String
    @State private var cwd: String
    @State private var prerequisites: String
    @State private var nodeID: String
    @State private var remoteTrigger: Bool

    init(store: ProjectOperationsStore, request: ProjectOperationEditRequest,
         deploymentNodes: [ProjectOperation.Node]) {
        self.store = store; self.request = request; self.deploymentNodes = deploymentNodes
        let operation = request.operation
        _label = State(initialValue: operation?.label ?? request.label ?? "")
        _kind = State(initialValue: operation?.kind ?? request.kind)
        _environment = State(initialValue: operation?.environment ?? request.environment ?? "")
        _target = State(initialValue: operation?.target ?? "")
        _command = State(initialValue: operation?.command ?? "")
        _cwd = State(initialValue: operation?.cwd ?? ".")
        _prerequisites = State(initialValue: operation?.prerequisites.joined(separator: "\n") ?? "")
        _nodeID = State(initialValue: operation?.nodes.first?.id ?? "")
        _remoteTrigger = State(initialValue: operation?.remoteTrigger ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.operation == nil ? "Add operation" : "Edit operation").font(.headline)
            Form {
                TextField("Label", text: $label)
                Picker("Kind", selection: $kind) {
                    ForEach(["deploy", "install", "build", "clean", "restart", "other"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                TextField("Environment (optional)", text: $environment)
                TextField("Target (optional)", text: $target)
                TextField("Working directory", text: $cwd)
                TextField("Command", text: $command, axis: .vertical).lineLimit(2...6)
                TextField("Prerequisites (one per line)", text: $prerequisites, axis: .vertical).lineLimit(2...4)
                Picker("Deployment node", selection: $nodeID) {
                    Text("None").tag("")
                    ForEach(deploymentNodes, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle("Remote trigger (dispatch only)", isOn: $remoteTrigger)
            }
            HStack {
                if let operation = request.operation {
                    Button("Delete", role: .destructive) { store.delete(id: operation.id); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(); dismiss() }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty
                        || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cwd.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 610, height: 490)
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = request.operation?.id ?? store.newID(kind: kind, environment: environment, target: target, label: trimmedLabel)
        var operation = request.operation ?? ProjectOperation(id: id, label: trimmedLabel, kind: kind,
            command: command)
        operation.label = trimmedLabel
        operation.kind = kind
        operation.environment = environment.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        operation.target = target.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        operation.command = command
        operation.cwd = ProjectOperationsStore.storedPath(ProjectOperationsStore.resolve(cwd, root: store.root), root: store.root)
        operation.prerequisites = prerequisites.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        operation.nodes = deploymentNodes.filter { $0.id == nodeID }
        if request.operation?.nodes.first?.id != nodeID { operation.extra["nodesEdited"] = .bool(true) }
        operation.remoteTrigger = remoteTrigger
        store.save(operation)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
