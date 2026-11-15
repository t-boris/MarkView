import SwiftUI

// Project Cycle Time (feature cycle-time-as-a-view-over-the-workflow): a read-only view over the workflow journal. The summary gives
// the measures by role, what needs attention and where items wait; every number opens into the items behind it, and every item into
// its stays. Pace (green, amber, red) is judged against the project's own history; marks about the quality of the data use a
// different symbol and never colour a number.

// MARK: - Entry point from the panels

/// One line in a feature or bug panel that opens the cycle-time window at that item.
struct CycleTimeLink: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    let kind: IssueKind
    let issue: String

    var body: some View {
        Button(action: { workspaceManager.cycleTimeItem = kind.rawValue + ":" + issue }) {
            HStack(spacing: 4) {
                Image(systemName: "timer").uiFont(size: 9).foregroundColor(palette.textDim)
                Text("Cycle time and timeline").uiFont(size: 10).foregroundColor(palette.textDim)
                Image(systemName: "chevron.right").uiFont(size: 8).foregroundColor(palette.textDim)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the stays of this \(kind.rawValue) in each status and how its durations were measured")
    }
}

// MARK: - The window

private enum CycleRoute: Equatable {
    case summary
    case metric(CycleMetric)
    case item(String, highlight: CycleMetric?)
}

struct CycleTimeSheet: View {
    @Environment(\.palette) private var palette
    @ObservedObject var store: FeatureStore
    @StateObject private var model: CycleTimeModel
    let open: (CycleItem) -> Void
    let close: () -> Void

    @State private var kind: IssueKind = .feature
    @State private var route: CycleRoute = .summary
    @State private var sinceOpen = false
    @State private var sinceDraft = Date()
    @State private var confirmDelete = false
    @State private var excludeReason = ""

    init(store: FeatureStore, focus: String?, open: @escaping (CycleItem) -> Void, close: @escaping () -> Void) {
        self.store = store
        self.open = open
        self.close = close
        _model = StateObject(wrappedValue: CycleTimeModel(store: store))
        if let focus, let split = focus.firstIndex(of: ":"), let kind = IssueKind(rawValue: String(focus[..<split])) {
            _kind = State(initialValue: kind)
            _route = State(initialValue: .item(focus, highlight: nil))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let problem = model.settingsProblem { notice(problem, color: palette.orange) }
            if let failure = model.failure { notice(failure, color: palette.red) }
            if let report = model.report {
                content(report.report(kind))
            } else {
                HStack(spacing: 8) {
                    if model.loading { ProgressView().controlSize(.small) }
                    Text(model.loading ? "Reading the lifecycle journal…" : "No cycle-time report yet.").uiFont(size: 11).foregroundColor(palette.textDim)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            }
            HStack {
                footer
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 720, height: 640)
        .background(palette.bg)
        .onAppear { model.reload() }
        .confirmationDialog("Delete the cycle-time evidence of this project from this Mac?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete evidence", role: .destructive) { model.deleteMacEvidence() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the pull request, CI and merge times and the AI models recorded on this Mac for this project. The workflow journal is not touched, so every duration is still computed from it.")
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            if route != .summary {
                Button(action: back) { Label("Summary", systemImage: "chevron.left") }.buttonStyle(.borderless)
            }
            Text("Cycle time — \(store.root?.lastPathComponent ?? "project")").uiFont(size: 13, weight: .semibold)
            Spacer()
            Picker("", selection: $kind) {
                Text("Features").tag(IssueKind.feature)
                Text("Bugs").tag(IssueKind.bug)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            .onChange(of: kind) { _ in route = .summary }
            Button(action: { model.reload() }) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Recompute: read the journal and the workflow again. Nothing is deleted.")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: { sinceDraft = model.settings.since ?? Date(); sinceOpen = true }) {
                Text(model.settings.since.map { "Measure since \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Measure since: all time").uiFont(size: 10)
            }
            .buttonStyle(.borderless).disabled(model.settingsProblem != nil)
            .help("Leave out items whose latest round began earlier. Only the numbers change; the journal keeps everything.")
            .popover(isPresented: $sinceOpen) { sincePopover }
            if !model.settings.excluded.isEmpty {
                Text("\(model.settings.excluded.count) excluded").uiFont(size: 10).foregroundColor(palette.textDim)
            }
            Button("Delete evidence…") { confirmDelete = true }
                .buttonStyle(.borderless).uiFont(size: 10).foregroundColor(palette.textDim)
                .help("Remove this project's pull request, CI, merge and model lines from this Mac's evidence log")
        }
    }

    private var sincePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Measure since").uiFont(size: 11, weight: .semibold)
            Text("Items whose latest round began before this date are left out of every row. Use it after a change of process, so the numbers describe the work you do now.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true).frame(width: 260, alignment: .leading)
            DatePicker("", selection: $sinceDraft, in: ...Date(), displayedComponents: .date).labelsHidden()
            HStack {
                Button("All time") { model.setSince(nil); sinceOpen = false }
                Spacer()
                Button("Apply") { model.setSince(Calendar.current.startOfDay(for: sinceDraft)); sinceOpen = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func notice(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").uiFont(size: 10).foregroundColor(color)
            Text(text).uiFont(size: 10).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func back() {
        switch route {
        case .item(_, let highlight?): route = .metric(highlight)
        default: route = .summary
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ report: CycleKindReport) -> some View {
        switch route {
        case .summary: CycleSummaryView(report: report, model: model, go: { route = $0 })
        case .metric(let metric):
            if let row = report.row(metric) { CycleMetricDetail(report: report, row: row, go: { route = $0 }) }
        case .item(let key, let highlight):
            if let item = report.items[key] ?? model.report?.features.items[key] ?? model.report?.bugs.items[key] {
                CycleItemDetail(item: item, evidence: model.evidence(for: item), highlight: highlight, excluded: model.settings.exclusion(item.kind, item.issue),
                                reason: $excludeReason, exclude: { model.exclude(item.kind, item.issue, reason: excludeReason); excludeReason = "" },
                                include: { model.include(item.kind, item.issue) }, open: { open(item) })
            } else {
                Text("This item no longer exists.").uiFont(size: 11).foregroundColor(palette.textDim)
            }
        }
    }
}

// MARK: - Pieces shared by the pages

private struct PaceDot: View {
    @Environment(\.palette) private var palette
    let pace: CyclePace

    var body: some View {
        switch pace {
        case .bad: Circle().fill(palette.red).frame(width: 9, height: 9).help("Slower than 85 % of this project's finished items")
        case .slow: Circle().fill(palette.orange).frame(width: 9, height: 9).help("Slower than the median, within the slowest 15 %")
        case .good: Circle().fill(palette.green).frame(width: 5, height: 5).frame(width: 9).help("At or under the project's median")
        case .unknown: Circle().stroke(palette.textDim, lineWidth: 1).frame(width: 5, height: 5).frame(width: 9)
                .help("Fewer than \(CyclePace.minimumSamples) finished items to compare with")
        case .neutral: Color.clear.frame(width: 9, height: 9)
        }
    }
}

/// Minimum, median, P85 and maximum on one line.
private struct DistributionBar: View {
    @Environment(\.palette) private var palette
    let distribution: CycleDistribution

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let top = max(distribution.highest, 1)
            let x = { (value: TimeInterval) -> CGFloat in CGFloat(value / top) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(palette.border.opacity(0.4)).frame(height: 5)
                Rectangle().fill(palette.green.opacity(0.7)).frame(width: x(distribution.p50), height: 5)
                Rectangle().fill(palette.orange.opacity(0.7)).frame(width: max(x(distribution.p85) - x(distribution.p50), 0), height: 5)
                    .offset(x: x(distribution.p50))
                Rectangle().fill(palette.red.opacity(0.7)).frame(width: max(width - x(distribution.p85), 0), height: 5).offset(x: x(distribution.p85))
            }
            .clipShape(Capsule())
        }
        .frame(height: 5)
    }
}

private func mark(_ quality: CycleQuality) -> some View {
    CycleMarkIcon(quality: quality)
}

private struct CycleMarkIcon: View {
    @Environment(\.palette) private var palette
    let quality: CycleQuality
    var body: some View {
        Image(systemName: quality == .excluded ? "eye.slash" : "diamond").uiFont(size: 8).foregroundColor(palette.purple).help(quality.title)
    }
}

private func sectionTitle(_ text: String, palette: AppPalette) -> some View {
    Text(text.uppercased()).uiFont(size: 9, weight: .bold).foregroundColor(palette.textDim).padding(.top, 6)
}

// MARK: - Summary

private struct CycleSummaryView: View {
    @Environment(\.palette) private var palette
    let report: CycleKindReport
    @ObservedObject var model: CycleTimeModel
    let go: (CycleRoute) -> Void
    @State private var showAllOpen = false

    var body: some View {
        let counts = report.counts
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if counts.total == 0 {
                    Text("This project has no \(report.kind == .feature ? "features" : "bugs") yet.").uiFont(size: 11).foregroundColor(palette.textDim)
                } else if counts.noHistory == counts.total {
                    Text("No lifecycle history has been recorded for these items yet. MarkView records it from the moment it first sees an item, and measures from there.")
                        .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                } else {
                    scope(counts)
                    attention
                    measures
                    inFlight
                    statuses
                    rework
                    models
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func scope(_ counts: CycleCounts) -> some View {
        var parts = ["\(counts.inScope) of \(counts.total) \(report.kind == .feature ? "features" : "bugs") counted"]
        if counts.excluded > 0 { parts.append("\(counts.excluded) excluded") }
        if counts.outsideWindow > 0 { parts.append("\(counts.outsideWindow) before the Measure since date") }
        var states = ["\(counts.finished) finished", "\(counts.open) in progress", "\(counts.cancelled) dropped"]
        if counts.finishedBeforeSight > 0 { states.append("\(counts.finishedBeforeSight) completed before MarkView watched them") }
        if counts.noHistory > 0 { states.append("\(counts.noHistory) with no history") }
        parts.append(states.joined(separator: " · "))
        return Text(parts.joined(separator: " · ")).uiFont(size: 10).foregroundColor(palette.textDim)
    }

    @ViewBuilder
    private var attention: some View {
        sectionTitle("Needs attention", palette: palette)
        if report.attention.isEmpty {
            Text(report.open.contains { $0.pace == .unknown }
                 ? "Nothing stands out. Some statuses have too little history to judge yet (under \(CyclePace.minimumSamples) finished items), so they are not coloured."
                 : "Nothing needs attention: no item is waiting longer than usual, none was reopened, and no request is refused.")
                .uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(report.attention.prefix(12)) { entry in
                Button(action: { go(.item(entry.key, highlight: nil)) }) {
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(entry.severity == .red ? palette.red : palette.orange).frame(width: 9, height: 9).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(report.items[entry.key]?.title ?? entry.key).uiFont(size: 11, weight: .medium).foregroundColor(palette.textBright).lineLimit(1)
                            ForEach(entry.reasons, id: \.self) { reason in
                                Text(reason).uiFont(size: 10).foregroundColor(palette.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if report.attention.count > 12 { Text("and \(report.attention.count - 12) more").uiFont(size: 10).foregroundColor(palette.textDim) }
        }
    }

    private var measures: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Measures", palette: palette)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    header("Measure"); header("Median"); header("85 %"); header("Mean"); header("Items"); header("Trend")
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(report.rows, id: \.metric) { row in
                    GridRow {
                        Button(action: { go(.metric(row.metric)) }) {
                            HStack(spacing: 3) { Text(row.metric.title).uiFont(size: 11, weight: .medium); Image(systemName: "chevron.right").uiFont(size: 8) }
                                .foregroundColor(palette.accent)
                        }.buttonStyle(.plain)
                        number(row.distribution?.p50)
                        number(row.distribution?.p85)
                        number(row.distribution?.mean, dim: true)
                        Text("\(row.used) of \(row.inScope)").uiFont(size: 11, design: .monospaced).foregroundColor(palette.textDim)
                        trend(row.trend)
                    }
                }
            }
            Text("Calendar time. An item is counted once per measure, from its latest round that has a value; the rest are listed under each measure with the reason.")
                .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var inFlight: some View {
        let open = report.open
        if !open.isEmpty {
            sectionTitle("In progress and waiting", palette: palette)
            let shown = showAllOpen ? open : Array(open.prefix(8))
            ForEach(shown) { entry in
                Button(action: { go(.item(entry.key, highlight: nil)) }) {
                    HStack(spacing: 6) {
                        PaceDot(pace: entry.pace)
                        Text(report.items[entry.key]?.title ?? entry.key).uiFont(size: 11).foregroundColor(palette.text).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(FeatureVocabulary.label(entry.status)).uiFont(size: 10).foregroundColor(palette.textDim)
                        Text((entry.ageIsLowerBound ? "≥ " : "") + CycleFormat.duration(entry.age)).uiFont(size: 10, design: .monospaced)
                            .foregroundColor(palette.textBright).frame(width: 88, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if open.count > 8 {
                Button(showAllOpen ? "Show fewer" : "Show all \(open.count)") { showAllOpen.toggle() }.buttonStyle(.borderless).uiFont(size: 10)
            }
        }
    }

    @ViewBuilder
    private var statuses: some View {
        let rows = report.statuses.filter { $0.visits != nil || $0.here > 0 }
        if !rows.isEmpty {
            sectionTitle("Time in each status", palette: palette)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { header("Status"); header("Typical visit"); header("85 %"); header("Visits"); header("Now") }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows, id: \.status) { row in
                    GridRow {
                        HStack(spacing: 4) {
                            Text(FeatureVocabulary.label(row.status)).uiFont(size: 11)
                            Text(row.role.map { $0.title.lowercased() } ?? "unknown role").uiFont(size: 9).foregroundColor(palette.textDim)
                        }
                        number(row.visits?.p50)
                        number(row.visits?.p85)
                        Text("\(row.visits?.count ?? 0)").uiFont(size: 11, design: .monospaced).foregroundColor(palette.textDim)
                        Text("\(row.here)").uiFont(size: 11, design: .monospaced).foregroundColor(palette.textDim)
                    }
                }
            }
            Text("Only visits that began and ended with a real move are counted; a status an item was found in, or was moved into when the flow changed, has no known start.")
                .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var rework: some View {
        let work = report.rework
        if work.inScope > 0 {
            sectionTitle("Rework", palette: palette)
            Text("\(work.itemsReopened) of \(work.inScope) reopened (\(work.reopens) reopening\(work.reopens == 1 ? "" : "s")) · \(work.rollbacks) sent back from work under way to waiting")
                .uiFont(size: 11).foregroundColor(palette.text)
        }
    }

    @ViewBuilder
    private var models: some View {
        if !report.models.isEmpty {
            sectionTitle("Cycle time by AI model", palette: palette)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { header("Model"); header("Median"); header("85 %"); header("Items") }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(report.models, id: \.model) { row in
                    GridRow {
                        Text(row.model).uiFont(size: 11).foregroundColor(row.tooFew ? palette.textDim : palette.text)
                        number(row.distribution.p50, dim: row.tooFew)
                        number(row.distribution.p85, dim: row.tooFew)
                        Text("\(row.distribution.count)" + (row.tooFew ? " · too few to compare" : "")).uiFont(size: 10, design: .monospaced).foregroundColor(palette.textDim)
                    }
                }
            }
            Text("Task size is not normalised: a model that was given larger work looks slower. The model is the one on the hand-off that started the feature.")
                .uiFont(size: 9).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Cells

    private func header(_ text: String) -> some View { Text(text).uiFont(size: 10, weight: .bold).foregroundColor(palette.textDim) }

    private func number(_ seconds: TimeInterval?, dim: Bool = false) -> some View {
        Text(seconds.map(CycleFormat.duration) ?? "—").uiFont(size: 11, design: .monospaced).foregroundColor(dim ? palette.textDim : palette.textBright)
    }

    @ViewBuilder
    private func trend(_ trend: CycleTrend?) -> some View {
        if let trend {
            let color: Color = trend.direction == .slower ? palette.red : trend.direction == .faster ? palette.green : palette.textDim
            HStack(spacing: 3) {
                Image(systemName: trend.direction == .slower ? "arrow.up.right" : trend.direction == .faster ? "arrow.down.right" : "arrow.right").uiFont(size: 9)
                Text(String(format: "%+.0f%%", trend.change * 100)).uiFont(size: 10, design: .monospaced)
            }
            .foregroundColor(color)
            .help("Median of the last 30 days: \(CycleFormat.duration(trend.recent)) (\(trend.recentCount) items); the 30 days before: \(CycleFormat.duration(trend.previous)) (\(trend.previousCount) items)")
        } else {
            Text("—").uiFont(size: 10).foregroundColor(palette.textDim).help("Needs at least \(CycleTrend.minimumSamples) finished items in each of the last two 30-day windows")
        }
    }
}

// MARK: - One measure

private struct CycleMetricDetail: View {
    @Environment(\.palette) private var palette
    let report: CycleKindReport
    let row: CycleMetricRow
    let go: (CycleRoute) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(row.metric.title).uiFont(size: 13, weight: .semibold)
                Text(row.metric.definition).uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                if let d = row.distribution {
                    DistributionBar(distribution: d)
                    HStack(spacing: 14) {
                        stat("fastest", d.lowest); stat("median", d.p50); stat("85 %", d.p85); stat("slowest", d.highest); stat("mean", d.mean)
                        Spacer(minLength: 0)
                    }
                    Text("\(row.used) of \(row.inScope) items have this measure.").uiFont(size: 10).foregroundColor(palette.textDim)
                } else {
                    Text("No item has this measure yet.").uiFont(size: 11).foregroundColor(palette.textDim)
                }
                if !row.samples.isEmpty {
                    sectionTitle("Items behind the number, slowest first", palette: palette)
                    let top = max(row.samples.first?.seconds ?? 1, 1)
                    ForEach(row.samples) { sample in
                        Button(action: { go(.item(sample.key, highlight: row.metric)) }) {
                            HStack(spacing: 6) {
                                PaceDot(pace: sample.pace)
                                Text(report.items[sample.key]?.title ?? sample.key).uiFont(size: 11).foregroundColor(palette.text).lineLimit(1).frame(width: 300, alignment: .leading)
                                GeometryReader { geometry in
                                    Capsule().fill(color(sample.pace)).frame(width: max(CGFloat(sample.seconds / top) * geometry.size.width, 2), height: 4)
                                        .frame(maxHeight: .infinity, alignment: .center)
                                }
                                .frame(height: 12)
                                ForEach(Array(report.items[sample.key]?.marks.sorted { $0.rawValue < $1.rawValue } ?? []), id: \.self) { mark($0) }
                                Text(CycleFormat.duration(sample.seconds)).uiFont(size: 10, design: .monospaced).foregroundColor(palette.textBright)
                                    .frame(width: 88, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !row.leftOut.isEmpty {
                    sectionTitle("Left out, and why", palette: palette)
                    ForEach(row.leftOut, id: \.reason) { group in
                        DisclosureGroup {
                            ForEach(group.keys, id: \.self) { key in
                                Button(action: { go(.item(key, highlight: nil)) }) {
                                    Text(report.items[key]?.title ?? key).uiFont(size: 10).foregroundColor(palette.accent).lineLimit(1)
                                }.buttonStyle(.plain)
                            }
                        } label: {
                            Text("\(group.keys.count) · \(group.reason.title)").uiFont(size: 11).foregroundColor(palette.text)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stat(_ label: String, _ seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(CycleFormat.duration(seconds)).uiFont(size: 11, design: .monospaced).foregroundColor(palette.textBright)
            Text(label).uiFont(size: 9).foregroundColor(palette.textDim)
        }
    }

    private func color(_ pace: CyclePace) -> Color {
        switch pace {
        case .bad: return palette.red
        case .slow: return palette.orange
        case .good: return palette.green.opacity(0.7)
        case .unknown, .neutral: return palette.textDim.opacity(0.5)
        }
    }
}

// MARK: - One item

private struct CycleItemDetail: View {
    @Environment(\.palette) private var palette
    let item: CycleItem
    let evidence: EvidenceTimeline?
    let highlight: CycleMetric?
    let excluded: CycleExclusion?
    @Binding var reason: String
    let exclude: () -> Void
    let include: () -> Void
    let open: () -> Void

    var body: some View {
        let lit = highlighted()
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).uiFont(size: 13, weight: .semibold).lineLimit(2)
                        Text("\(item.kind.rawValue) \(item.issue) · \(FeatureVocabulary.label(item.status))").uiFont(size: 10).foregroundColor(palette.textDim)
                    }
                    Spacer()
                    Button(item.kind == .feature ? "Open feature" : "Open bug report", action: open)
                }
                if item.stays.isEmpty {
                    Text("The journal has no record of this item yet.").uiFont(size: 11).foregroundColor(palette.textDim)
                } else {
                    measures
                    marks
                    sectionTitle("Stays", palette: palette)
                    stays(lit)
                    if let evidence { delivery(evidence) }
                }
                excludeControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Measures

    private var measures: some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionTitle("Measures", palette: palette)
            ForEach(CycleMetric.allCases, id: \.self) { metric in
                switch item.value(metric) {
                case .value(let seconds, _, let round):
                    HStack(spacing: 6) {
                        Text(metric.title).uiFont(size: 11, weight: metric == highlight ? .semibold : .regular).foregroundColor(palette.text)
                        Spacer(minLength: 6)
                        Text(CycleFormat.duration(seconds)).uiFont(size: 11, design: .monospaced).foregroundColor(palette.textBright)
                        if item.rounds.count > 1 { Text("round \(round + 1)").uiFont(size: 9).foregroundColor(palette.textDim) }
                    }
                    .help(metric.definition)
                case .missing(let reason):
                    if metric != .acceptance || reason != .notAccepted || item.state == .finished {
                        HStack(spacing: 6) {
                            Text(metric.title).uiFont(size: 11).foregroundColor(palette.textDim)
                            Spacer(minLength: 6)
                            Text(reason.title).uiFont(size: 10).foregroundColor(palette.textDim)
                        }
                        .help(metric.definition)
                    }
                }
            }
            if item.reopens > 0 {
                Text("Reopened \(item.reopens) time\(item.reopens == 1 ? "" : "s"): each reopening starts a new round, and a measure uses its latest round that has a value.")
                    .uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let blocked = item.blocked, let message = blocked.message {
                Text("The last request to move it was refused: \(message.split(separator: "\n").first.map(String.init) ?? message)")
                    .uiFont(size: 10).foregroundColor(palette.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var marks: some View {
        let list = item.marks.sorted { $0.rawValue < $1.rawValue }
        if !list.isEmpty {
            sectionTitle("About the data", palette: palette)
            ForEach(list, id: \.self) { quality in
                HStack(alignment: .top, spacing: 5) {
                    CycleMarkIcon(quality: quality)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(quality.title).uiFont(size: 10, weight: .medium).foregroundColor(palette.text)
                        Text(quality.explanation).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Stays

    /// The stays whose entry times formed the chosen duration.
    private func highlighted() -> Set<Int> {
        guard let metric = highlight, case .value(_, _, let roundIndex) = item.value(metric), item.rounds.indices.contains(roundIndex) else { return [] }
        let round = item.rounds[roundIndex]
        func stay(at date: Date?) -> Int? { date.flatMap { date in round.stays.first { item.stays[$0].entered == date } } }
        switch metric {
        case .waiting: return Set([round.stays.lowerBound, stay(at: round.firstActive)].compactMap { $0 })
        case .cycle: return Set([stay(at: round.firstActive), stay(at: round.completed)].compactMap { $0 })
        case .lead: return Set([round.stays.lowerBound, stay(at: round.completed)].compactMap { $0 })
        case .acceptance: return Set([stay(at: round.completed), stay(at: round.accepted)].compactMap { $0 })
        }
    }

    private func stays(_ lit: Set<Int>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(item.stays.enumerated()), id: \.offset) { index, stay in
                if let round = item.rounds.first(where: { $0.index > 0 && $0.stays.lowerBound == index }) {
                    Text("Round \(round.index + 1): reopened").uiFont(size: 9, weight: .bold).foregroundColor(palette.orange).padding(.top, 5)
                }
                HStack(alignment: .top, spacing: 8) {
                    Text(stay.entered.formatted(.dateTime.month(.abbreviated).day().hour().minute())).uiFont(size: 10, design: .monospaced)
                        .foregroundColor(palette.textDim).frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(FeatureVocabulary.label(stay.status)).uiFont(size: 11, weight: .semibold).foregroundColor(palette.textBright)
                            Text(stay.role.map { $0.title.lowercased() } ?? "unknown role").uiFont(size: 9).foregroundColor(palette.textDim)
                            if stay.forced { Text("forced").uiFont(size: 9).foregroundColor(palette.orange) }
                        }
                        Text(cause(stay)).uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Text(duration(stay)).uiFont(size: 10, design: .monospaced).foregroundColor(stay.dwellKnown ? palette.textBright : palette.textDim)
                }
                .padding(.vertical, 3).padding(.horizontal, 4)
                .background(lit.contains(index) ? palette.selection.opacity(0.6) : Color.clear)
            }
        }
    }

    private func cause(_ stay: CycleStay) -> String {
        let how: String
        switch stay.cause {
        case .firstSight: how = "first seen by MarkView in this status"
        case .transition(let kind): how = kind.map { "moved here (\($0.rawValue))" } ?? "moved here"
        case .replacement: how = "put here when the flow changed; not a move of the work"
        case .outsideEdit: how = "edited outside MarkView and found at this time"
        }
        return how + " · " + stay.actorText + (stay.reason.map { " · " + $0 } ?? "")
    }

    private func duration(_ stay: CycleStay) -> String {
        let text = CycleFormat.duration(stay.duration(now: Date()))
        if stay.left == nil { return "now · " + text }
        return stay.dwellKnown ? text : "≥ " + text
    }

    // MARK: Delivery evidence

    @ViewBuilder
    private func delivery(_ evidence: EvidenceTimeline) -> some View {
        sectionTitle("Delivery evidence on this Mac", palette: palette)
        if let started = evidence.started {
            Text("Handed to an AI assistant \(started.formatted(date: .abbreviated, time: .shortened))" + (evidence.model.map { " · \($0)" } ?? ""))
                .uiFont(size: 10).foregroundColor(palette.text)
        }
        ForEach(evidence.units) { unit in
            VStack(alignment: .leading, spacing: 1) {
                Text(unit.name).uiFont(size: 10, weight: .semibold).foregroundColor(palette.textBright)
                ForEach(unit.rows) { row in
                    HStack(spacing: 6) {
                        Text(row.stage.title).uiFont(size: 10).foregroundColor(palette.text)
                        Spacer(minLength: 6)
                        Text(row.at.formatted(date: .abbreviated, time: .shortened)).uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
                        Text(row.since.map { "+" + CycleFormat.duration($0) } ?? "").uiFont(size: 9, design: .monospaced).foregroundColor(palette.textDim)
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                if unit.queue != nil || unit.ciTime != nil || unit.reruns > 0 {
                    Text(["waited for a runner " + (unit.queue.map(CycleFormat.duration) ?? "—"), "CI " + (unit.ciTime.map(CycleFormat.duration) ?? "—"),
                          "\(unit.reruns) re-run\(unit.reruns == 1 ? "" : "s")"].joined(separator: " · "))
                        .uiFont(size: 9).foregroundColor(palette.textDim)
                }
            }
            .padding(.leading, 4)
        }
    }

    // MARK: Exclusion

    @ViewBuilder
    private var excludeControls: some View {
        sectionTitle("Statistics", palette: palette)
        if let excluded {
            HStack {
                Text("Excluded \(excluded.at.formatted(date: .abbreviated, time: .omitted))" + (excluded.reason.isEmpty ? "" : ": " + excluded.reason))
                    .uiFont(size: 10).foregroundColor(palette.textDim)
                Spacer()
                Button("Include again", action: include)
            }
        } else {
            HStack {
                TextField("Reason (for example: imported, test data)", text: $reason).textFieldStyle(.roundedBorder).uiFont(size: 10)
                Button("Exclude from statistics", action: exclude)
            }
            Text("The item stays in the journal and in this list; only the project numbers stop counting it.").uiFont(size: 9).foregroundColor(palette.textDim)
        }
    }
}
