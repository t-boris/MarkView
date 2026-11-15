import Foundation

// The app side of cycle time (feature cycle-time-as-a-view-over-the-workflow): what the project's stores hold, handed to the pure
// projection in CycleTime.swift / CycleTimeReport.swift, and the corrections of DEC-001 (Measure since, Exclude, Recompute) kept in
// `.dde/lifecycle/cycle-time.json`. Reading and folding happen off the main thread; the journal is only read, never written.

/// Everything the report is built from, copied on the main actor so that the build can run anywhere.
struct CycleSnapshot: Sendable {
    let root: URL
    let items: [CycleItemInfo]
    let service: IssueTransitionService
    let workflow: ProjectWorkflow
    /// The evidence lines of this Mac for the project, with the model that took each feature.
    let evidence: [LifecycleEvent]
    let now: Date
}

enum CycleTimeBuilder {
    /// The input of a report: the journal, the settings and the models, read off the main thread.
    static func input(_ snapshot: CycleSnapshot, settings: CycleSettings) -> CycleInput {
        let records = snapshot.service.records()
        let workflow = snapshot.workflow
        let roles = CycleRoles(
            workflow: { kind, status in workflow.role(kind, status) },
            known: { kind, status in
                if let role = ProjectWorkflow.standard.role(kind, status) { return role }
                for flow in WorkflowFlow.catalogue { if let role = flow.lifecycle(kind).role(of: status) { return role } }
                return nil
            })
        func acceptance(_ kind: IssueKind) -> Bool {
            let own = workflow.lifecycle(kind).rules.contains { $0.kind == .acceptance }
            return own || workflow.variants(for: kind).contains { ($0.rules ?? []).contains { $0.kind == .acceptance } }
        }
        func accepting(_ kind: IssueKind, _ status: String) -> Bool {
            let value = IssueStatus.normalize(status)
            let rules = workflow.lifecycle(kind).rules + workflow.variants(for: kind).flatMap { $0.rules ?? [] }
            return rules.contains { $0.kind == .acceptance && $0.from.contains(value) }
        }
        // The model that took each feature: the one on its first hand-off, from the journal's own beginning.
        var begun: [String: Date] = [:]
        for record in records where record.kind == .feature { begun[record.issue] = min(begun[record.issue] ?? record.at, record.at) }
        var raw: [String: String] = [:]
        for event in snapshot.evidence.sorted(by: { $0.timestamp < $1.timestamp }) where event.stage == .workStarted {
            guard let model = event.model, !model.isEmpty, raw["feature:" + event.feature] == nil else { continue }
            if let first = begun[event.feature], event.timestamp < first { continue }
            raw["feature:" + event.feature] = model
        }
        return CycleInput(items: snapshot.items, records: records, roles: roles,
                          statusOrder: { workflow.lifecycle($0).statusIDs }, acceptanceStep: acceptance, acceptsFrom: accepting,
                          settings: settings, models: CycleModelNames.resolve(raw), now: snapshot.now)
    }

    static func report(_ snapshot: CycleSnapshot, settings: CycleSettings) -> CycleReport {
        CycleReport.make(input(snapshot, settings: settings))
    }

    @MainActor
    static func snapshot(of store: FeatureStore) -> CycleSnapshot? {
        guard let root = store.root, store.recordsLifecycle, let service = store.lifecycle.service else { return nil }
        let features = store.features.map {
            CycleItemInfo(kind: .feature, issue: $0.slug, title: $0.title, status: $0.status, created: CycleTimeBuilder.created($0.front.string("created")))
        }
        let bugs = store.bugs.map {
            CycleItemInfo(kind: .bug, issue: $0.key, title: $0.title, status: $0.status, created: CycleTimeBuilder.created($0.created))
        }
        let project = store.lifecycleProject ?? root.standardizedFileURL.path
        return CycleSnapshot(root: root, items: features + bugs, service: service, workflow: store.lifecycle.workflow,
                             evidence: LifecycleLog.shared.events.filter { $0.project == project }, now: Date())
    }

    /// One item, as text for an agent: its stays, rounds, measures and marks, from the journal.
    @MainActor
    static func describe(_ store: FeatureStore, kind: IssueKind, issue: String) -> String {
        guard let snapshot = snapshot(of: store) else { return "This project does not record a lifecycle history." }
        guard let info = snapshot.items.first(where: { $0.kind == kind && $0.issue == issue }) else { return "No such item." }
        let one = CycleSnapshot(root: snapshot.root, items: [info], service: snapshot.service, workflow: snapshot.workflow, evidence: [], now: snapshot.now)
        let report = CycleReport.make(input(one, settings: .empty)).report(kind)
        return report.items[kind.rawValue + ":" + issue]?.describe(now: snapshot.now) ?? "No lifecycle history recorded."
    }

    /// The `created` date of an item as MarkView writes it: a UTC day.
    static func created(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: String(text.prefix(10)))
    }
}

@MainActor
final class CycleTimeModel: ObservableObject {
    @Published private(set) var report: CycleReport?
    @Published private(set) var settings: CycleSettings = .empty
    /// The settings file exists but cannot be read; the report ignores it until it is fixed.
    @Published private(set) var settingsProblem: String?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?

    private weak var store: FeatureStore?
    private var generation = 0
    private var snapshotTaken: CycleSnapshot?

    init(store: FeatureStore) { self.store = store }

    var settingsURL: URL? { store?.root.map { CycleSettingsFile.url(projectRoot: $0) } }

    /// Reads the journal, the workflow and the settings again and builds the report. Nothing is written.
    func reload() {
        guard let store, let snapshot = CycleTimeBuilder.snapshot(of: store) else {
            report = nil
            failure = "This folder has no project with a lifecycle history."
            return
        }
        generation += 1
        let mine = generation
        loading = true
        failure = nil
        snapshotTaken = snapshot
        let url = CycleSettingsFile.url(projectRoot: snapshot.root)
        Task.detached(priority: .userInitiated) {
            let loaded = CycleSettingsFile.load(url)
            var used = CycleSettings.empty
            var problem: String?
            switch loaded {
            case .settings(let value): used = value
            case .unreadable(let message): problem = message
            }
            let built = CycleTimeBuilder.report(snapshot, settings: used)
            await MainActor.run {
                guard mine == self.generation else { return }
                self.settings = used
                self.settingsProblem = problem
                self.report = built
                self.loading = false
            }
        }
    }

    /// Measure since: items whose latest round began earlier are left out. `nil` = all time.
    func setSince(_ date: Date?) { change { $0.since = date } }

    func exclude(_ kind: IssueKind, _ issue: String, reason: String) {
        change { $0 = $0.excluding(kind, issue, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func include(_ kind: IssueKind, _ issue: String) { change { $0 = $0.including(kind, issue) } }

    /// Removes this project's lines from the per-Mac evidence log, after the person confirmed. The journal and the settings stay.
    func deleteMacEvidence() {
        guard let project = store?.lifecycleProject else { return }
        LifecycleLog.shared.deleteProject(project)
        reload()
    }

    private func change(_ edit: (inout CycleSettings) -> Void) {
        guard let url = settingsURL, settingsProblem == nil else { return }
        var next = settings
        edit(&next)
        guard next != settings else { return }
        do {
            try CycleSettingsFile.save(next, to: url)
            settings = next
            failure = nil
        } catch {
            failure = "Could not save the cycle-time settings: \(error.localizedDescription)"
            return
        }
        reload()
    }

    /// The delivery evidence of one feature for the item detail.
    func evidence(for item: CycleItem) -> EvidenceTimeline? {
        guard item.kind == .feature, let store, let project = store.lifecycleProject else { return nil }
        let events = LifecycleLog.shared.events(project: project, feature: item.issue)
        let workflow = store.lifecycle.workflow
        let assigned = store.lifecycle.assignedVariantID(.feature, item.issue)
        let direct = workflow.resolvedVariant(.feature, assigned: assigned)?.integration == .directToMain
        let timeline = EvidenceTimings.timeline(events, directToMain: direct, since: item.stays.first?.entered)
        return timeline.started == nil && timeline.units.isEmpty ? nil : timeline
    }
}
