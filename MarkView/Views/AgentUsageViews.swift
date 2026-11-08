import SwiftUI

// The usage indicators (DEC-006 of ai-agent-usage-quota-tracker-codex-claude-code): one compact chip per
// agent in the workspace top bar (flexible-files-views-and-visible-agent-usage, AC-6, AC-7), the details in
// a popover, and the fallback-limit form (DEC-014). No notifications (DEC-004).

extension UsageLevel {
    func color(_ palette: AppPalette) -> Color {
        switch self {
        case .normal: return palette.green
        case .warning: return palette.orange
        case .critical: return palette.red
        }
    }
}

/// The chips of the detected agents the user has not hidden (Settings → DDE), in the workspace top bar.
/// Appearing and disappearing start and stop the usage polling (DEC-010), so the host keeps the bar in the
/// view tree at every width. It takes the richest form that fits the width it is given (DEC-017): chips
/// with the reset time, chips with the percentage, minimal chips, and last a single gauge button whose
/// popover lists every agent, so the indicators stay reachable without crowding the other controls.
struct AgentUsageBar: View {
    @Environment(\.palette) private var palette
    @ObservedObject private var tracker = AgentUsageTracker.shared
    @AppStorage(UsageAgent.claude.hiddenKey) private var claudeHidden = false
    @AppStorage(UsageAgent.codex.hiddenKey) private var codexHidden = false
    @State private var showingAll = false
    /// The chip whose details are open; kept here so that switching to another form (a resize, a new countdown
    /// text) does not close it.
    @State private var detailsFor: UsageAgent?

    var body: some View {
        // With no agent to show the first form is empty and always fits, so the bar stays in the view tree (and
        // keeps the polling running) without drawing anything.
        ViewThatFits(in: .horizontal) {
            chips(.full)
            chips(.percent)
            chips(.minimal)
            gaugeButton
        }
        .onAppear { tracker.indicatorAppeared() }
        .onDisappear { tracker.indicatorDisappeared() }
    }

    private var agents: [UsageAgent] {
        tracker.detected.filter { $0 == .claude ? !claudeHidden : !codexHidden }
    }

    private func chips(_ detail: AgentUsageChip.Detail) -> some View {
        HStack(spacing: 4) {
            ForEach(agents) { agent in
                AgentUsageChip(agent: agent, tracker: tracker, detail: detail,
                               showingDetails: Binding(get: { detailsFor == agent },
                                                       set: { detailsFor = $0 ? agent : (detailsFor == agent ? nil : detailsFor) }))
            }
        }
        .fixedSize()
    }

    /// The narrowest form: one button, coloured by the most urgent quota, that opens every agent's details.
    private var gaugeButton: some View {
        Button { showingAll.toggle() } label: {
            Image(systemName: "gauge.with.needle")
                .uiFont(size: 13)
                .foregroundColor(urgentColor)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(palette.border.opacity(0.45)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Agent usage: " + agents.map { AgentUsageChip.summary(of: $0, snapshot: tracker.snapshots[$0], now: tracker.now) }.joined(separator: " "))
        .accessibilityLabel("Agent usage")
        .accessibilityValue(agents.map { AgentUsageChip.summary(of: $0, snapshot: tracker.snapshots[$0], now: tracker.now) }.joined(separator: " "))
        .popover(isPresented: $showingAll, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(agents) { agent in
                    AgentUsagePopover(agent: agent, tracker: tracker)
                    if agent != agents.last { Divider() }
                }
            }
        }
    }

    private var urgentColor: Color {
        let levels = agents.compactMap { agent -> UsageLevel? in
            guard let snapshot = tracker.snapshots[agent] else { return nil }
            switch snapshot.state {
            case .official, .userLimit: return snapshot.state.headline?.level
            case .noLimit, .unavailable: return nil
            }
        }
        if levels.contains(.critical) { return UsageLevel.critical.color(palette) }
        if levels.contains(.warning) { return UsageLevel.warning.color(palette) }
        return palette.textDim
    }
}

struct AgentUsageChip: View {
    @Environment(\.palette) private var palette
    let agent: UsageAgent
    @ObservedObject var tracker: AgentUsageTracker
    let detail: Detail
    @Binding var showingDetails: Bool

    /// How much the chip says: with the reset time, with the percentage and its label, or only the short form.
    enum Detail { case full, percent, minimal }

    var body: some View {
        let snapshot = tracker.snapshots[agent]
        Button { showingDetails.toggle() } label: {
            content(snapshot, detail: detail)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(palette.border.opacity(0.45)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(snapshot))
        .accessibilityLabel("\(agent.displayName) usage")
        .accessibilityValue(Self.summary(of: agent, snapshot: snapshot, now: tracker.now))
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            AgentUsagePopover(agent: agent, tracker: tracker)
        }
    }

    /// One sentence for VoiceOver and the gauge's tooltip: the agent, the quota used or why there is none, and how
    /// trustworthy it is. Unavailable usage is said to be unavailable, never zero.
    static func summary(of agent: UsageAgent, snapshot: AgentUsageSnapshot?, now: Date) -> String {
        guard let snapshot else { return "\(agent.displayName): reading usage." }
        switch snapshot.state {
        case .official, .userLimit:
            guard let window = snapshot.state.headline else { return "\(agent.displayName): no quota window." }
            var text = "\(agent.displayName): \(UsageFormat.percent(window.percentUsed)) of the \(window.label) quota used"
            if let resetsAt = window.resetsAt { text += ", resets in \(UsageFormat.countdown(resetsAt.timeIntervalSince(now)))" }
            if window.source == .estimated { text += ", estimated from local logs" }
            if snapshot.isStale(now: now) { text += ", stale" }
            return text + "."
        case .noLimit(let today):
            return "\(agent.displayName): \(UsageFormat.tokens(today.tokens)) tokens used today, no limit set."
        case .unavailable(let reason):
            return "\(agent.displayName): usage unavailable, \(reason)."
        }
    }

    @ViewBuilder
    private func content(_ snapshot: AgentUsageSnapshot?, detail: Detail) -> some View {
        let name = detail == .minimal ? String(agent.shortName.prefix(2)) : agent.shortName
        HStack(spacing: 4) {
            if let snapshot {
                switch snapshot.state {
                case .official, .userLimit:
                    if let window = snapshot.state.headline {
                        let stale = snapshot.isStale(now: tracker.now)
                        UsageMeter(percent: window.percentUsed, color: window.level.color(palette)).frame(width: 22, height: 4)
                        Text(name).foregroundColor(palette.textDim)
                        Text((window.source == .estimated ? "~" : "") + UsageFormat.percent(window.percentUsed)
                             + (detail == .minimal ? "" : " used"))
                            .fontWeight(.semibold).foregroundColor(window.level.color(palette))
                        if detail == .full {
                            Text(resetText(window)).foregroundColor(palette.textDim)
                        }
                        if stale { Image(systemName: "clock").foregroundColor(palette.textDim) }
                    }
                case .noLimit(let today):
                    Text(name).foregroundColor(palette.textDim)
                    Text(UsageFormat.tokens(today.tokens)).foregroundColor(palette.text)
                    if detail != .minimal { Text(detail == .full ? "today · set a limit" : "today").foregroundColor(palette.textDim) }
                case .unavailable:
                    Image(systemName: "exclamationmark.triangle").foregroundColor(palette.textDim)
                    Text(name).foregroundColor(palette.textDim)
                    if detail != .minimal { Text("usage unavailable").foregroundColor(palette.textDim) }
                }
            } else {
                Text(name).foregroundColor(palette.textDim)
                ProgressView().scaleEffect(0.35).frame(width: 10, height: 10)
            }
        }
        .uiFont(size: 9)
        .lineLimit(1)
        .fixedSize()
        .opacity(snapshot?.isStale(now: tracker.now) == true ? 0.6 : 1)
    }

    private func resetText(_ window: QuotaWindow) -> String {
        guard let resetsAt = window.resetsAt else { return window.label }
        return "\(window.label) · \(UsageFormat.countdown(resetsAt.timeIntervalSince(tracker.now)))"
    }

    private func help(_ snapshot: AgentUsageSnapshot?) -> String {
        guard let snapshot else { return "\(agent.displayName): reading usage…" }
        switch snapshot.state {
        case .official: return "\(agent.displayName): official limit data. Click for details."
        case .userLimit: return "\(agent.displayName): estimate from local logs against your limit. Click for details."
        case .noLimit: return "\(agent.displayName): tokens used today (local logs). Click to set a limit."
        case .unavailable(let reason): return "\(agent.displayName): usage unavailable — \(reason)"
        }
    }
}

/// A thin progress bar; over 100% it stays full.
private struct UsageMeter: View {
    @Environment(\.palette) private var palette
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.border)
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, percent / 100)))
            }
        }
    }
}

// MARK: - Popover

struct AgentUsagePopover: View {
    @Environment(\.palette) private var palette
    let agent: UsageAgent
    @ObservedObject var tracker: AgentUsageTracker
    @State private var editingLimit = false

    var body: some View {
        let snapshot = tracker.snapshots[agent]
        VStack(alignment: .leading, spacing: 10) {
            header(snapshot)
            if editingLimit {
                FallbackLimitForm(agent: agent, tracker: tracker, recordsCost: snapshot?.recordsCost ?? false) {
                    editingLimit = false
                }
            } else if let snapshot {
                details(snapshot)
            } else {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Reading usage…").uiFont(size: 11).foregroundColor(palette.textDim)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func header(_ snapshot: AgentUsageSnapshot?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName).uiFont(size: 13, weight: .semibold)
                if let snapshot {
                    HStack(spacing: 4) {
                        Text(sourceTitle(snapshot.state))
                        if let updated = snapshot.updatedAt {
                            Text("· updated \(UsageFormat.ago(tracker.now.timeIntervalSince(updated)))")
                        }
                        if snapshot.isStale(now: tracker.now) {
                            Label("stale", systemImage: "clock").foregroundColor(.orange)
                        }
                    }
                    .uiFont(size: 10).foregroundColor(palette.textDim)
                }
            }
            Spacer()
            refreshButton
        }
    }

    private var refreshButton: some View {
        let cooldown = tracker.cooldownRemaining(agent)
        return Button { tracker.refresh(agent) } label: {
            if tracker.refreshing.contains(agent) {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(cooldown > 0 || tracker.refreshing.contains(agent))
        .help(cooldown > 0 ? "Refresh again in \(Int(cooldown.rounded(.up))) s" : "Refresh now")
    }

    private func sourceTitle(_ state: AgentUsageState) -> String {
        switch state {
        case .official: return "Official limit data"
        case .userLimit: return "Estimate from local logs"
        case .noLimit: return "Local logs, no limit set"
        case .unavailable: return "Usage unavailable"
        }
    }

    @ViewBuilder
    private func details(_ snapshot: AgentUsageSnapshot) -> some View {
        if let note = snapshot.officialNote {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").foregroundColor(.orange)
                Text(note).uiFont(size: 10).fixedSize(horizontal: false, vertical: true)
            }
        }
        switch snapshot.state {
        case .official(let windows):
            ForEach(windows) { window in windowRow(window, local: snapshot.localByWindow[window.id]) }
        case .userLimit(let window):
            windowRow(window, local: nil)
        case .noLimit:
            Text("No limit is set, so there is no percentage or reset time. Set the limit and window of your plan to see an estimate.")
                .uiFont(size: 10).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true)
        case .unavailable(let reason):
            Text("Usage unavailable: \(reason).").uiFont(size: 11).fixedSize(horizontal: false, vertical: true)
        }
        if let today = snapshot.today {
            Divider()
            HStack {
                Text("Today (local logs)").foregroundColor(palette.textDim)
                Spacer()
                Text(amountText(today))
            }
            .uiFont(size: 10)
        }
        Divider()
        limitRow
    }

    private func windowRow(_ window: QuotaWindow, local: UsageAmount?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.title).uiFont(size: 11, weight: .medium)
                Spacer()
                Text(window.source == .official ? "Official" : "Estimated")
                    .uiFont(size: 9, weight: .semibold)
                    .foregroundColor(window.source == .official ? palette.green : .orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().stroke(window.source == .official ? palette.green : .orange, lineWidth: 0.5))
            }
            UsageMeter(percent: window.percentUsed, color: window.level.color(palette)).frame(height: 5)
            Text(usedText(window)).uiFont(size: 10)
            if let resetsAt = window.resetsAt {
                Text(resetText(window, resetsAt: resetsAt)).uiFont(size: 10).foregroundColor(palette.textDim)
            }
            if let local {
                Text("From local logs: \(amountText(local)) in this window")
                    .uiFont(size: 9).foregroundColor(palette.textDim)
            }
        }
    }

    /// Remaining in the limit's unit (DEC-015): percent on the official path, absolute on the fallback.
    private func usedText(_ window: QuotaWindow) -> String {
        let percent = UsageFormat.percent(window.percentUsed)
        if let unit = window.unit, let consumed = window.consumed, let limit = window.limit, let remaining = window.remainingAmount {
            return "\(percent) used · \(UsageFormat.amount(consumed, unit: unit)) of \(UsageFormat.amount(limit, unit: unit)) · "
                + "\(UsageFormat.amount(remaining, unit: unit)) left"
        }
        return "\(percent) used · \(UsageFormat.percent(window.remainingPercent)) left"
    }

    private func resetText(_ window: QuotaWindow, resetsAt: Date) -> String {
        var text = "Resets in \(UsageFormat.countdown(resetsAt.timeIntervalSince(tracker.now))) (\(Self.resetFormatter.string(from: resetsAt)))"
        if window.source == .estimated { text += ", estimated" }
        if let elapsed = window.elapsedFraction(now: tracker.now), let pace = window.pace(now: tracker.now) {
            text += " · \(UsageFormat.percent(elapsed * 100)) of window elapsed, \(pace.title)"
        }
        return text
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    private func amountText(_ amount: UsageAmount) -> String {
        var text = "\(UsageFormat.tokens(amount.tokens)) tokens"
        if let cost = amount.costUSD { text += " · \(UsageFormat.usd(cost))" }
        return text
    }

    @ViewBuilder
    private var limitRow: some View {
        let limit = AgentUsageTracker.limit(for: agent)
        HStack(alignment: .firstTextBaseline) {
            if let limit {
                Text("Your limit: \(UsageFormat.amount(limit.value, unit: limit.unit)) per \(limit.period.title)")
                    .uiFont(size: 10).foregroundColor(palette.textDim)
            } else {
                Text("No limit set").uiFont(size: 10).foregroundColor(palette.textDim)
            }
            Spacer()
            Button(limit == nil ? "Set a limit…" : "Edit limit…") { editingLimit = true }
                .uiFont(size: 10)
        }
        if limit != nil, case .official = tracker.snapshots[agent]?.state {
            Text("Used only when official limit data is unavailable.")
                .uiFont(size: 9).foregroundColor(palette.textDim)
        }
    }
}

// MARK: - Fallback limit form (DEC-014)

private struct FallbackLimitForm: View {
    @Environment(\.palette) private var palette
    let agent: UsageAgent
    @ObservedObject var tracker: AgentUsageTracker
    let recordsCost: Bool
    let done: () -> Void

    @State private var valueText = ""
    @State private var unit = UsageUnit.tokens
    @State private var anchor = Date()
    /// Index into `LimitPeriod.presets`, or -1 for a custom period.
    @State private var preset = 0
    @State private var customCount = 12
    @State private var customInDays = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Limit for \(agent.displayName)").uiFont(size: 11, weight: .semibold)
            HStack {
                TextField(unit == .tokens ? "e.g. 50M" : "e.g. 20", text: $valueText).textFieldStyle(.roundedBorder)
                Picker("", selection: $unit) {
                    Text("tokens").tag(UsageUnit.tokens)
                    Text("USD").tag(UsageUnit.usd).disabled(!recordsCost)
                }
                .labelsHidden().fixedSize()
            }
            if !recordsCost {
                Text("\(agent.displayName)'s logs record no cost, so the limit is in tokens.")
                    .uiFont(size: 9).foregroundColor(palette.textDim)
            }
            DatePicker("Window starts", selection: $anchor, displayedComponents: [.date, .hourAndMinute])
                .uiFont(size: 10)
            HStack {
                Text("Resets every").uiFont(size: 10)
                Picker("", selection: $preset) {
                    ForEach(LimitPeriod.presets.indices, id: \.self) { index in
                        Text(LimitPeriod.presets[index].title).tag(index)
                    }
                    Text("Custom").tag(-1)
                }
                .labelsHidden().fixedSize()
            }
            if preset == -1 {
                HStack {
                    TextField("", value: $customCount, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
                    Picker("", selection: $customInDays) {
                        Text("hours").tag(false)
                        Text("days").tag(true)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if let limit {
                let window = limit.window(containing: Date())
                Text("Current window: \(Self.windowFormatter.string(from: window.start)) – \(Self.windowFormatter.string(from: window.end))")
                    .uiFont(size: 9).foregroundColor(palette.textDim)
            }
            HStack {
                if AgentUsageTracker.limit(for: agent) != nil {
                    Button("Clear limit") {
                        tracker.setLimit(nil, for: agent)
                        done()
                    }
                }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    tracker.setLimit(limit, for: agent)
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(limit == nil)
            }
            .uiFont(size: 10)
        }
        .onAppear(perform: load)
    }

    private var period: LimitPeriod {
        if preset >= 0 && preset < LimitPeriod.presets.count { return LimitPeriod.presets[preset] }
        return customInDays ? .days(customCount) : .hours(customCount)
    }

    /// The limit as entered, or nil while it is not valid.
    private var limit: FallbackLimit? {
        guard let value = Self.parse(valueText) else { return nil }
        let limit = FallbackLimit(value: value, unit: recordsCost ? unit : .tokens, anchor: anchor, period: period)
        return limit.isValid ? limit : nil
    }

    /// "50M", "500k", "1.5b", "20".
    private static func parse(_ text: String) -> Double? {
        var string = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: "")
        var factor = 1.0
        if let last = string.last, let multiplier = ["k": 1e3, "m": 1e6, "b": 1e9][String(last)] {
            factor = multiplier
            string.removeLast()
        }
        guard let value = Double(string.trimmingCharacters(in: .whitespaces)) else { return nil }
        return value * factor
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        // The anchor defaults to now when the form is first opened (DEC-014).
        guard let existing = AgentUsageTracker.limit(for: agent) else { return }
        valueText = existing.unit == .tokens ? String(format: "%.0f", existing.value) : String(format: "%g", existing.value)
        unit = existing.unit
        anchor = existing.anchor
        if let index = LimitPeriod.presets.firstIndex(of: existing.period) {
            preset = index
        } else {
            preset = -1
            switch existing.period {
            case .hours(let n): customCount = n; customInDays = false
            case .days(let n): customCount = n; customInDays = true
            case .months(let n): customCount = n * 30; customInDays = true
            }
        }
    }

    private static let windowFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
