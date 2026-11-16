import SwiftUI
import AppKit

struct HandoffStartList: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var flow: FeatureFlowCoordinator
    @EnvironmentObject private var layout: PanelLayout
    @ObservedObject var store: FeatureStore
    @State private var ready: [(feature: Feature, state: HandoffState)] = []
    /// Bumped by the refresh button: the read below starts again at once instead of at its next turn.
    @State private var refreshes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ready to resume").uiFont(size: 13, weight: .semibold)
                Spacer()
                Button { refreshes += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh handoffs")
                    .accessibilityLabel("Refresh handoffs")
            }
            ForEach(ready, id: \.feature.slug) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.state.hasChanged ? "exclamationmark.triangle" : "checkmark.seal")
                        .foregroundColor(item.state.hasChanged ? palette.orange : palette.green)
                    Text(item.feature.title).lineLimit(1)
                    Text(item.state.hasChanged ? "Changed" : "Ready")
                        .uiFont(size: 10, weight: .semibold)
                    Spacer()
                    Button("Files") {
                        if let revision = item.state.revision {
                            flow.resumeHandoff(slug: item.feature.slug, title: item.feature.title, linkedFiles: revision.linkedFiles)
                        }
                    }
                    Button("Specification") {
                        store.activeSlug = item.feature.slug
                        layout.workspaceArea = .work
                        layout.workSection = .features
                    }
                }
                .uiFont(size: 11)
            }
            if ready.isEmpty {
                Text("A handed-off specification appears here with links to Files and Work.")
                    .uiFont(size: 11).foregroundColor(palette.textDim)
            }
        }
        .padding(12)
        .background(palette.bgActive)
        .cornerRadius(8)
        .task(id: store.features.map(\.slug).joined(separator: ":") + "#\(refreshes)") {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    @MainActor private func load() async {
        guard let project = store.root else { ready = []; return }
        var items: [(feature: Feature, state: HandoffState)] = []
        for feature in store.features {
            if let state = try? await SpecificationHandoffStore.shared.state(project: project, slug: feature.slug),
               state.revision != nil {
                items.append((feature, state))
            }
        }
        ready = items
    }
}

struct HandoffPanelView: View {
    @EnvironmentObject private var chrome: WindowChrome
    @EnvironmentObject private var tabs: TabsController
    @EnvironmentObject private var flow: FeatureFlowCoordinator
    @Environment(\.palette) private var palette
    let feature: Feature

    @State private var state: HandoffState?
    @State private var error: String?
    @State private var busy = false
    @State private var showingVersions = false
    @State private var expanded = true

    private var project: URL? { flow.features.root }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { expanded.toggle() } label: {
                    Label("Specification handoff", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .uiFont(size: 12, weight: .semibold)
                }
                .buttonStyle(.plain)
                Spacer()
                if let revision = state?.revision {
                    Label("Ready · revision \(revision.number)", systemImage: "checkmark.seal")
                        .uiFont(size: 11)
                    if state?.hasChanged == true {
                        Label("Changed since handoff", systemImage: "exclamationmark.triangle")
                            .uiFont(size: 11, weight: .semibold)
                            .foregroundColor(palette.orange)
                    }
                } else {
                    Text("No handoff yet").uiFont(size: 11).foregroundColor(palette.textDim)
                }
            }

            if expanded {
                if let revision = state?.revision {
                    Text("Handed off by \(revision.actor) · \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .uiFont(size: 10).foregroundColor(palette.textDim)
                    if let changes = state?.changes, !changes.isEmpty {
                        Text(changes.map { "\($0.kind.rawValue.capitalized): \($0.path)" }.joined(separator: " · "))
                            .uiFont(size: 10).foregroundColor(palette.orange)
                            .lineLimit(2)
                    }
                }
                HStack(spacing: 8) {
                    Button(state?.revision == nil ? "Mark ready and hand off" : "Mark current version ready again") {
                        startMarkReady()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || project == nil)
                    Button { addFiles() } label: { Label("Link files", systemImage: "plus") }
                        .disabled(busy || project == nil)
                    if state?.revision != nil {
                        Button { resume() } label: { Label("Resume in Files", systemImage: "folder") }
                        Button { showingVersions = true } label: { Label("Versions", systemImage: "clock.arrow.circlepath") }
                    }
                }
                .controlSize(.small)
                if let links = state?.currentLinks, !links.isEmpty {
                    ForEach(links, id: \.self) { path in
                        HStack(spacing: 6) {
                            Image(systemName: linkedFileExists(path) ? "doc" : "exclamationmark.triangle")
                            Text(path).uiFont(size: 10, design: .monospaced).lineLimit(1)
                            if !linkedFileExists(path) { Text("Missing").uiFont(size: 10).foregroundColor(palette.orange) }
                            Spacer(minLength: 0)
                            Button { startSaveLinks((state?.currentLinks ?? []).filter { $0 != path }) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("Remove linked file")
                                .accessibilityLabel("Remove linked file \(path)")
                        }
                    }
                } else {
                    Text("No files linked. The developer can browse the project after handoff.")
                        .uiFont(size: 10).foregroundColor(palette.textDim)
                }
                if let error {
                    Text(error).uiFont(size: 10).foregroundColor(palette.red)
                }
            }
        }
        .padding(10)
        .background(palette.bgActive)
        .cornerRadius(8)
        .padding(.horizontal, 10).padding(.top, 8)
        .sheet(isPresented: $showingVersions) {
            if let project, let state {
                HandoffVersionsView(project: project, feature: feature, state: state)
            }
        }
        .onAppear { if chrome.compactLayout { expanded = false } }
        .onChange(of: chrome.compactLayout) { compact in
            if compact { expanded = false }
        }
        .task(id: feature.slug) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    @MainActor private func refresh() async {
        guard let project else { return }
        do {
            state = try await SpecificationHandoffStore.shared.state(project: project, slug: feature.slug)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The hand-off is a job of the feature store (AR-19): one per feature at a time, ended by closing the folder.
    private func startMarkReady() {
        flow.features.jobs.start("handoff:ready:" + feature.slug) { await markReady() }
    }

    /// Writing the linked files is a job of the feature store like `startMarkReady`.
    private func startSaveLinks(_ links: [String]) {
        flow.features.jobs.start("handoff:links:" + feature.slug) { await saveLinks(links) }
    }

    @MainActor private func markReady() async {
        guard let project else { return }
        guard tabs.saveBeforeHandoff(under: feature.folder) else { return }
        busy = true
        defer { busy = false }
        do {
            let store = flow.features
            let slug = feature.slug, person = store.lifecycleActor
            let service = store.lifecycle.service
            // The step is judged under the project's workflow and the item's rule variant, like every other status change.
            let workflow = store.lifecycle.workflow
            let variant = store.lifecycle.assignedVariantID(.feature, slug)
            _ = try await SpecificationHandoffStore.shared.markReady(
                project: project, slug: slug, actor: person, commitStatus: { from in
                    // The live status goes through the lifecycle service like every other status change.
                    guard let service else { return false }
                    let seen = from.isEmpty ? "idea" : from
                    service.recordBaseline(.feature, slug, status: seen)
                    let result = service.apply(TransitionRequest(kind: .feature, issue: slug, from: seen, to: "ready", actor: .human(person),
                                                                 workflow: workflow, variantID: variant))
                    return result.reachedStatus
                })
            flow.features.reloadSync(feature.slug)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func linkedFileExists(_ path: String) -> Bool {
        guard let project else { return false }
        return FileManager.default.fileExists(atPath: project.appendingPathComponent(path).path)
    }

    private func addFiles() {
        guard let project else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = project
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let root = project.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let links = panel.urls.compactMap { url -> String? in
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(root) else { return nil }
            return String(path.dropFirst(root.count))
        }
        if links.count != panel.urls.count {
            error = "Only files inside the open project can be linked."
            return
        }
        startSaveLinks(Array(Set((state?.currentLinks ?? []) + links)).sorted())
    }

    @MainActor private func saveLinks(_ links: [String]) async {
        guard let project else { return }
        guard tabs.saveBeforeReading(feature.overviewURL,
            action: "updating the handoff links") else { return }
        busy = true
        defer { busy = false }
        do {
            try await SpecificationHandoffStore.shared.setLinkedFiles(links, project: project, slug: feature.slug)
            flow.features.reloadSync(feature.slug)
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func resume() {
        guard let revision = state?.revision else { return }
        flow.resumeHandoff(slug: feature.slug, title: feature.title, linkedFiles: revision.linkedFiles)
    }
}

struct HandoffResumeBar: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var flow: FeatureFlowCoordinator
    @EnvironmentObject private var layout: PanelLayout
    @EnvironmentObject private var chrome: WindowChrome
    @EnvironmentObject private var requests: WindowRequests
    let resume: HandoffResume

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Resume: \(resume.title)", systemImage: "checkmark.seal")
                    .uiFont(size: 12, weight: .semibold)
                Spacer()
                Button("Browse files") { chrome.toggleNavigation() }
                Button("Open specification") {
                    flow.features.activeSlug = resume.slug
                    layout.workspaceArea = .work
                    layout.workSection = .features
                }
                Button { requests.handoffResume = nil } label: { Image(systemName: "xmark") }
                    .help("Dismiss handoff")
                    .accessibilityLabel("Dismiss handoff")
            }
            if resume.linkedFiles.isEmpty {
                Text("No files were linked. Browse project files or return to the specification in Work.")
                    .uiFont(size: 11).foregroundColor(palette.textDim)
            }
            ForEach(resume.missingFiles, id: \.self) { path in
                Text("Missing linked file: \(path)").uiFont(size: 11).foregroundColor(palette.orange)
            }
        }
        .padding(10).background(palette.bgActive)
    }
}

private struct HandoffVersionsView: View {
    @EnvironmentObject private var flow: FeatureFlowCoordinator
    @Environment(\.dismiss) private var dismiss
    let project: URL
    let feature: Feature
    let state: HandoffState

    @State private var revisionNumber = 0
    @State private var selectedPath = "overview.md"
    @State private var handedOffText = ""
    @State private var currentText = ""

    private var selectedRevision: HandoffRevision? {
        state.history.first { $0.number == revisionNumber } ?? state.history.last
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Specification versions").uiFont(.title3, weight: .semibold)
                Picker("Revision", selection: $revisionNumber) {
                    ForEach(state.history) { revision in
                        Text("Revision \(revision.number) · \(revision.actor)").tag(revision.number)
                    }
                }
                .frame(width: 220)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                List(Array(Set((selectedRevision?.hashes.keys.map { $0 } ?? []) +
                               state.currentHashes.keys.map { $0 })).sorted(), id: \.self,
                     selection: $selectedPath) { path in
                    Text(path).uiFont(size: 10, design: .monospaced)
                }
                .frame(width: 240)
                Divider()
                versionColumn("Handed off", text: handedOffText)
                Divider()
                versionColumn("Current", text: currentText)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { revisionNumber = state.revision?.number ?? 0 }
        .task(id: "\(revisionNumber):\(selectedPath)") { await loadText() }
    }

    private func versionColumn(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).uiFont(size: 12, weight: .semibold)
                Spacer()
                if title == "Current" {
                    Button("Open in Files") {
                        flow.open(feature.folder.appendingPathComponent(selectedPath))
                        dismiss()
                    }
                    .disabled(state.currentHashes[selectedPath] == nil)
                }
            }.padding(8)
            Divider()
            ScrollView {
                Text(text).uiFont(size: 11, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func loadText() async {
        guard let selectedRevision else { return }
        do {
            handedOffText = try await SpecificationHandoffStore.shared.snapshotText(
                project: project, slug: feature.slug, revision: selectedRevision.number, path: selectedPath)
                ?? "File absent or not readable as text in this revision."
            currentText = try await SpecificationHandoffStore.shared.currentText(
                project: project, slug: feature.slug, path: selectedPath)
                ?? "File absent or not readable as text in the current specification."
        } catch {
            handedOffText = error.localizedDescription
            currentText = error.localizedDescription
        }
    }
}
