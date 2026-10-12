import AppKit
import SwiftUI

/// What a cloud place runs, one row per function, site, machine or deployment: its state, its log, a link to open it.
struct CloudServicesCard: View {
    let env: DeploymentEnvironment
    @ObservedObject var store: DeploymentStore
    /// Hand a log to the assistant: (question, log text, log title).
    let askAI: (String, String, String) -> Void

    @State private var filter = ""
    @State private var collapsed: Set<String> = []
    @State private var logRequest: ServiceLogRequest?

    private var state: DeploymentStore.ServicesState { store.servicesStates[env.id] ?? DeploymentStore.ServicesState() }

    private var shown: [CloudService] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? state.items : state.items.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.details.joined(separator: " ").localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SERVICES").uiFont(size: 9, weight: .semibold).foregroundColor(VSDark.textDim)
                ForEach(CloudServices.totals(state.items), id: \.group) { total in
                    HStack(spacing: 4) {
                        Text("\(total.count) \(total.group.lowercased())").uiFont(size: 10).foregroundColor(VSDark.textDim)
                        if total.bad > 0 { badge("\(total.bad) failing", VSDark.red) }
                        if total.warn > 0 { badge("\(total.warn) warning", VSDark.orange) }
                    }
                }
                Spacer()
                if state.loading { ProgressView().controlSize(.small) }
                Button { Task { await store.loadServices(env.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(state.loading).help("Look again")
            }
            ForEach(state.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").uiFont(size: 10).foregroundColor(VSDark.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if state.items.isEmpty {
                Text(state.loading ? "Looking…" : state.updated == nil ? "Not looked at yet." : "The provider lists nothing for this project.")
                    .uiFont(size: 10).foregroundColor(VSDark.textDim)
            } else {
                if state.items.count > 8 {
                    TextField("Filter by name", text: $filter).textFieldStyle(.roundedBorder).uiFont(size: 11)
                }
                ForEach(groups, id: \.self) { group in
                    let rows = shown.filter { $0.group == group }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Button { toggle(group) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: collapsed.contains(group) ? "chevron.right" : "chevron.down").uiFont(size: 8)
                                    Text(group).uiFont(size: 11, weight: .semibold)
                                    Text("\(rows.count)").uiFont(size: 10).foregroundColor(VSDark.textDim)
                                }
                            }.buttonStyle(.plain).foregroundColor(VSDark.text)
                            if !collapsed.contains(group) { ForEach(rows) { row($0) } }
                        }
                    }
                }
                if let updated = state.updated {
                    Text("Looked at \(updated.formatted(date: .omitted, time: .standard)). A badge on a site is its answer to a request from this Mac; a function has no state here, read its log.")
                        .uiFont(size: 9).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(VSDark.bgSidebar).cornerRadius(6)
        .onAppear { if state.updated == nil && !state.loading { Task { await store.loadServices(env.id) } } }
        .sheet(item: $logRequest) { request in
            ServiceLogSheet(env: env, store: store, request: request, askAI: askAI)
        }
    }

    private var groups: [String] {
        var seen: [String] = []
        for item in state.items where !seen.contains(item.group) { seen.append(item.group) }
        return seen
    }

    private func toggle(_ group: String) {
        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
    }

    private func row(_ service: CloudService) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(service.level)).frame(width: 7, height: 7).opacity(service.level == .unknown && service.state == nil ? 0.25 : 1)
            Text(service.name).uiFont(size: 11, weight: .medium).foregroundColor(VSDark.text).lineLimit(1).truncationMode(.middle)
            Text(service.details.joined(separator: " · ")).uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(1)
            Spacer(minLength: 4)
            if let word = service.state { badge(word, color(service.level)) }
            if service.logCommand != nil {
                Button { logRequest = ServiceLogRequest(service: service) } label: { Image(systemName: "text.alignleft") }
                    .buttonStyle(.plain).help("Read its log")
            }
            if let open = service.openURL, let url = URL(string: open) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }.buttonStyle(.plain).help("Open \(open)")
                Button { copy(open) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy the address")
            }
            if let console = service.consoleURL, let url = URL(string: console) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain).help("Open its page in the provider's console")
            }
        }
        .padding(.vertical, 2).padding(.leading, 12)
        .contextMenu {
            if service.logCommand != nil { Button("Read its log") { logRequest = ServiceLogRequest(service: service) } }
            if let open = service.openURL { Button("Copy address") { copy(open) } }
            Button("Copy name") { copy(service.name) }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).uiFont(size: 9, weight: .medium).foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 1).background(color.opacity(0.15)).cornerRadius(3)
    }

    private func color(_ level: CloudService.Level) -> Color {
        switch level {
        case .ok: return VSDark.green
        case .warn: return VSDark.orange
        case .bad: return VSDark.red
        case .unknown: return VSDark.textDim
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct ServiceLogRequest: Identifiable {
    let service: CloudService
    var id: String { service.id }
}

/// The log of one service: fetched when the sheet opens (a read-only command), filterable, and the assistant can read it.
struct ServiceLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let env: DeploymentEnvironment
    @ObservedObject var store: DeploymentStore
    let request: ServiceLogRequest
    let askAI: (String, String, String) -> Void

    @State private var text = ""
    @State private var filter = ""
    @State private var loading = false

    private var shown: String {
        guard !filter.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.localizedCaseInsensitiveContains(filter) }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Log: \(request.service.name)").uiFont(size: 14, weight: .semibold)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            Text(request.service.logCommand ?? "").uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim).textSelection(.enabled)
            HStack {
                TextField("Filter lines (error, 500, …)", text: $filter).textFieldStyle(.roundedBorder)
                Button("Fetch again") { fetch() }.disabled(loading)
                Button { askAI("Read this log: what stands out, and what should I do?", text, "Log: " + request.service.name) } label: { Label("Ask AI", systemImage: "sparkles") }
                    .disabled(text.isEmpty).help("Send what is on screen to the assistant")
            }
            ScrollView {
                Text(shown.isEmpty ? (loading ? "Fetching…" : "Nothing.") : shown).uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 360).padding(6).background(VSDark.bgInput).cornerRadius(4)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 720)
        .onAppear(perform: fetch)
    }

    private func fetch() {
        guard let command = request.service.logCommand, !loading else { return }
        loading = true
        Task {
            text = await store.run(command, on: env.id, origin: "You", timeout: 90).summary
            loading = false
        }
    }
}
