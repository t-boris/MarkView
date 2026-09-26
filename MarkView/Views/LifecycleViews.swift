import SwiftUI

// Lifecycle events of a feature (docs/features/lifecycle-event-log-cycle-time-analytics): the
// timeline in the Feature panel header, the confirmation for manual marks, and the project's
// cycle-time table.

extension LifecycleStage: Identifiable {
    var id: String { rawValue }
}

private func durationText(_ duration: LifecycleDuration) -> String {
    switch duration {
    case .missing: return "—"
    case .inconsistent: return "inconsistent"
    case .valid(let seconds): return LifecycleAnalytics.format(seconds)
    }
}

/// "Lifecycle · 5 events · total 3d 4h 2m ▸  Mark stage ▾" — expands into the events and the
/// step durations.
struct LifecycleSection: View {
    @ObservedObject var store: FeatureStore
    @ObservedObject private var log = LifecycleLog.shared
    let feature: Feature
    @AppStorage("feature.lifecycle.expanded") private var expanded = false
    @State private var marking: LifecycleStage?

    var body: some View {
        let events = store.lifecycleEvents(feature.slug)
        let total = LifecycleAnalytics.total(events)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: { expanded.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8)).foregroundColor(VSDark.textDim)
                        Text("Lifecycle").font(.system(size: 10)).foregroundColor(VSDark.textDim)
                        Text("· \(events.count) \(events.count == 1 ? "event" : "events")" + (total.seconds.map { " · total \(LifecycleAnalytics.format($0))" } ?? ""))
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(VSDark.text).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).help("Timestamped lifecycle events of this feature and the time between stages")
                Spacer()
                Menu {
                    ForEach(LifecycleStage.manual) { stage in Button(stage.title + "…") { marking = stage } }
                } label: {
                    Text("Mark stage").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Record that a stage happened now (idea created, questions resolved and spec ready are recorded automatically)")
            }
            if let error = log.lastError {
                Text(error).font(.system(size: 9)).foregroundColor(VSDark.red).onTapGesture { log.clearError() }
            }
            if expanded { details(events, total: total) }
        }
        .sheet(item: $marking) { stage in
            MarkStageSheet(store: store, feature: feature, stage: stage) { marking = nil }
        }
    }

    @ViewBuilder
    private func details(_ events: [LifecycleEvent], total: LifecycleDuration) -> some View {
        if events.isEmpty {
            Text("No events yet. Idea created, questions resolved and spec ready are recorded automatically from now on; mark the other stages when they happen.")
                .font(.system(size: 9)).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(VSDark.textDim)
                        Text(event.stage.title).font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.textBright)
                        Spacer(minLength: 0)
                    }
                    Text([event.actor, event.model, event.source == .automatic ? "auto" : "manual"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9)).foregroundColor(VSDark.textDim).lineLimit(1)
                    if let note = event.note {
                        Text(note).font(.system(size: 9)).foregroundColor(VSDark.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 12)
            }
            Text("STEPS").font(.system(size: 8, weight: .bold)).foregroundColor(VSDark.textDim).padding(.top, 2)
            ForEach(LifecycleAnalytics.steps(events), id: \.step) { item in
                durationRow(item.step.title, item.duration)
            }
            durationRow("Idea created → verified (total)", total)
        }
    }

    private func durationRow(_ title: String, _ duration: LifecycleDuration) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundColor(duration == .missing ? VSDark.textDim : VSDark.text).lineLimit(1)
            Spacer(minLength: 4)
            Text(durationText(duration)).font(.system(size: 9, design: .monospaced))
                .foregroundColor(duration == .inconsistent ? VSDark.orange : duration == .missing ? VSDark.textDim : VSDark.textBright)
        }
        .padding(.leading, 12)
        .help(duration == .inconsistent ? "The end stage was recorded before the start stage — left out of the project averages" : "")
    }
}

/// Confirmation of a manual mark (DEC-010): stamped now, cannot be changed afterwards.
struct MarkStageSheet: View {
    @ObservedObject var store: FeatureStore
    let feature: Feature
    let stage: LifecycleStage
    let close: () -> Void
    @State private var model: String
    @State private var note = ""
    private let events: [LifecycleEvent]

    init(store: FeatureStore, feature: Feature, stage: LifecycleStage, close: @escaping () -> Void) {
        self.store = store
        self.feature = feature
        self.stage = stage
        self.close = close
        events = store.lifecycleEvents(feature.slug)
        // Implementation finished: the model that started it (DEC-011).
        let started = stage == .implementationFinished
            ? events.last { $0.stage == .implementationStarted }?.model : nil
        _model = State(initialValue: started ?? "")
    }

    private var modelRequired: Bool { stage == .implementationStarted }
    private var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let repeats = events.filter { $0.stage == stage }.count
        let recorded = Set(events.map(\.stage))
        let later = LifecycleStage.allCases.filter { $0.order > stage.order && recorded.contains($0) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Mark “\(stage.title)”").font(.system(size: 13, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                row("Feature", feature.title)
                row("Stage", stage.title)
                row("Time", "Now (when you confirm)")
                row("Actor", store.lifecycleActor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(modelRequired ? "AI model / agent (required)" : "AI model / agent (if an AI did this step)")
                    .font(.system(size: 11, weight: .medium))
                HStack(spacing: 4) {
                    TextField("e.g. Claude Opus 5.5", text: $model).textFieldStyle(.roundedBorder)
                    let known = LifecycleModels.all
                    Menu {
                        ForEach(known, id: \.self) { name in Button(name) { model = name } }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton).fixedSize().disabled(known.isEmpty)
                    .help("Models used before")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Note (optional)").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(note.count)/\(LifecycleEvent.noteLimit)").font(.system(size: 10, design: .monospaced))
                        .foregroundColor(note.count > LifecycleEvent.noteLimit ? .red : .secondary)
                }
                TextField("Why it took long, what was special…", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5)
            }
            if repeats > 0 {
                warning("This stage already has \(repeats == 1 ? "an event" : "\(repeats) events"). Another one is added; durations use the earliest start and the latest end.")
            }
            if !later.isEmpty {
                warning("Later stages are already recorded: \(later.map(\.title).joined(separator: ", ")).")
            }
            Text("Recorded events cannot be edited or deleted.").font(.system(size: 10)).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Record") {
                    let name = trimmedModel.isEmpty ? nil : LifecycleModels.use(trimmedModel)
                    store.recordLifecycle(stage, feature: feature.slug, source: .manual, model: name, note: note)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((modelRequired && trimmedModel.isEmpty) || note.count > LifecycleEvent.noteLimit)
            }
        }
        .padding(16).frame(width: 440)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Text(value).font(.system(size: 11)).lineLimit(2)
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(.orange)
            Text(text).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Median, mean and feature count per step over the current project's features (DEC-004,
/// DEC-014); the implementation step also per AI model.
struct CycleTimeSummarySheet: View {
    @ObservedObject var store: FeatureStore
    @ObservedObject private var log = LifecycleLog.shared
    let close: () -> Void

    var body: some View {
        // Events of deleted or renamed features are not shown (DEC-012).
        let slugs = Set(store.features.map(\.slug))
        let events = store.lifecycleProject.map { log.events(project: $0) } ?? []
        let grouped = Dictionary(grouping: events.filter { slugs.contains($0.feature) }, by: \.feature)
        let summary = LifecycleAnalytics.summary(grouped)
        VStack(alignment: .leading, spacing: 10) {
            Text("Cycle time — \(store.root?.lastPathComponent ?? "project")").font(.system(size: 13, weight: .semibold))
            Text("Calendar time between adjacent stages over this project's features (\(grouped.count) with events). Only features with both boundary events count; inconsistent steps are left out.")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if grouped.isEmpty {
                Text("No lifecycle events recorded in this project yet.").font(.system(size: 11)).padding(.vertical, 12)
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        GridRow {
                            header("Step"); header("Median"); header("Mean"); header("Features")
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(summary.rows, id: \.step) { row in
                            statRow(row.step.title, row.statistic, bold: true)
                            ForEach(row.byModel, id: \.model) { entry in
                                statRow("    " + entry.model, entry.statistic, bold: false)
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        statRow("Idea created → verified (total)", summary.total, bold: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 200, maxHeight: 420)
            }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 580)
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
    }

    private func statRow(_ title: String, _ statistic: LifecycleAnalytics.Statistic?, bold: Bool) -> some View {
        GridRow {
            Text(title).font(.system(size: 11, weight: bold ? .medium : .regular)).lineLimit(1)
            Text(statistic.map { LifecycleAnalytics.format($0.median) } ?? "—").font(.system(size: 11, design: .monospaced))
            Text(statistic.map { LifecycleAnalytics.format($0.mean) } ?? "—").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            Text(statistic.map { "\($0.count)" } ?? "0").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                .gridColumnAlignment(.trailing)
        }
    }
}
