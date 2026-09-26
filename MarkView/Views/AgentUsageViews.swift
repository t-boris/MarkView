import SwiftUI

// The Terminal tab's usage indicators (DEC-006): one compact chip per agent in the header, the
// details in a popover, and the fallback-limit form (DEC-014). No notifications (DEC-004).

extension UsageLevel {
    var color: Color {
        switch self {
        case .normal: return VSDark.green
        case .warning: return .orange
        case .critical: return VSDark.red
        }
    }
}

/// The chips of the detected agents the user has not hidden (Settings → DDE).
struct AgentUsageBar: View {
    @ObservedObject private var tracker = AgentUsageTracker.shared
    @AppStorage(UsageAgent.claude.hiddenKey) private var claudeHidden = false
    @AppStorage(UsageAgent.codex.hiddenKey) private var codexHidden = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(agents) { agent in AgentUsageChip(agent: agent, tracker: tracker) }
        }
        .onAppear { tracker.indicatorAppeared() }
        .onDisappear { tracker.indicatorDisappeared() }
    }

    private var agents: [UsageAgent] {
        tracker.detected.filter { $0 == .claude ? !claudeHidden : !codexHidden }
    }
}

private struct AgentUsageChip: View {
    let agent: UsageAgent
    @ObservedObject var tracker: AgentUsageTracker
    @State private var showingDetails = false

    var body: some View {
        let snapshot = tracker.snapshots[agent]
        Button { showingDetails.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                content(snapshot, detail: .full)
                content(snapshot, detail: .percent)
                content(snapshot, detail: .minimal)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(VSDark.border.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(snapshot))
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            AgentUsagePopover(agent: agent, tracker: tracker)
        }
    }

    private enum Detail { case full, percent, minimal }

    @ViewBuilder
    private func content(_ snapshot: AgentUsageSnapshot?, detail: Detail) -> some View {
        let name = detail == .minimal ? String(agent.shortName.prefix(2)) : agent.shortName
        HStack(spacing: 4) {
            if let snapshot {
                switch snapshot.state {
                case .official, .userLimit:
                    if let window = snapshot.state.headline {
                        let stale = snapshot.isStale(now: tracker.now)
                        UsageMeter(percent: window.percentUsed, color: window.level.color).frame(width: 22, height: 4)
                        Text(name).foregroundColor(VSDark.textDim)
                        Text((window.source == .estimated ? "~" : "") + UsageFormat.percent(window.percentUsed))
                            .fontWeight(.semibold).foregroundColor(window.level.color)
                        if detail == .full {
                            Text(resetText(window)).foregroundColor(VSDark.textDim)
                        }
                        if stale { Image(systemName: "clock").foregroundColor(VSDark.textDim) }
                    }
                case .noLimit(let today):
                    Text(name).foregroundColor(VSDark.textDim)
                    Text(UsageFormat.tokens(today.tokens)).foregroundColor(VSDark.text)
                    if detail == .full { Text("today · set a limit").foregroundColor(VSDark.textDim) }
                case .unavailable:
                    Image(systemName: "exclamationmark.triangle").foregroundColor(VSDark.textDim)
                    Text(name).foregroundColor(VSDark.textDim)
                    if detail != .minimal { Text("usage unavailable").foregroundColor(VSDark.textDim) }
                }
            } else {
                Text(name).foregroundColor(VSDark.textDim)
                ProgressView().scaleEffect(0.35).frame(width: 10, height: 10)
            }
        }
        .font(.system(size: 9))
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
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(VSDark.border)
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, percent / 100)))
            }
        }
    }
}

// MARK: - Popover

private struct AgentUsagePopover: View {
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
                    Text("Reading usage…").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func header(_ snapshot: AgentUsageSnapshot?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName).font(.system(size: 13, weight: .semibold))
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
                    .font(.system(size: 10)).foregroundColor(.secondary)
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
                Text(note).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
            }
        }
        switch snapshot.state {
        case .official(let windows):
            ForEach(windows) { window in windowRow(window, local: snapshot.localByWindow[window.id]) }
        case .userLimit(let window):
            windowRow(window, local: nil)
        case .noLimit:
            Text("No limit is set, so there is no percentage or reset time. Set the limit and window of your plan to see an estimate.")
                .font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        case .unavailable(let reason):
            Text("Usage unavailable: \(reason).").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        if let today = snapshot.today {
            Divider()
            HStack {
                Text("Today (local logs)").foregroundColor(.secondary)
                Spacer()
                Text(amountText(today))
            }
            .font(.system(size: 10))
        }
        Divider()
        limitRow
    }

    private func windowRow(_ window: QuotaWindow, local: UsageAmount?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(window.source == .official ? "Official" : "Estimated")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(window.source == .official ? VSDark.green : .orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().stroke(window.source == .official ? VSDark.green : .orange, lineWidth: 0.5))
            }
            UsageMeter(percent: window.percentUsed, color: window.level.color).frame(height: 5)
            Text(usedText(window)).font(.system(size: 10))
            if let resetsAt = window.resetsAt {
                Text(resetText(window, resetsAt: resetsAt)).font(.system(size: 10)).foregroundColor(.secondary)
            }
            if let local {
                Text("From local logs: \(amountText(local)) in this window")
                    .font(.system(size: 9)).foregroundColor(.secondary)
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
                    .font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                Text("No limit set").font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button(limit == nil ? "Set a limit…" : "Edit limit…") { editingLimit = true }
                .font(.system(size: 10))
        }
        if limit != nil, case .official = tracker.snapshots[agent]?.state {
            Text("Used only when official limit data is unavailable.")
                .font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
}

// MARK: - Fallback limit form (DEC-014)

private struct FallbackLimitForm: View {
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
            Text("Limit for \(agent.displayName)").font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            DatePicker("Window starts", selection: $anchor, displayedComponents: [.date, .hourAndMinute])
                .font(.system(size: 10))
            HStack {
                Text("Resets every").font(.system(size: 10))
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
                    .font(.system(size: 9)).foregroundColor(.secondary)
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
            .font(.system(size: 10))
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
