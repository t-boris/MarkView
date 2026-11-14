import SwiftUI

/// Screen two of the Cockpit: one run, read as a control room. Who does what right now, how far it is, what happened, what needs the person.
struct CockpitRunScreen: View {
    @ObservedObject var session: CockpitSession
    @Environment(\.palette) private var palette
    /// nil: the run of this window (live); otherwise a saved run.
    let runID: UUID?
    @State private var tab: Tab = .timeline
    @State private var selectedStepID: String?

    enum Tab: String, CaseIterable, Identifiable {
        case timeline = "Timeline", steps = "Steps", questions = "Questions", findings = "Findings"
        var id: String { rawValue }
    }

    private var execution: CockpitExecution? { session.execution }
    private var isLive: Bool { runID == nil || execution?.runID == runID }

    private var run: CockpitRun? {
        if isLive, let record = execution?.record { return record }
        if let runID { return session.savedRuns.first { $0.id == runID } }
        return nil
    }

    var body: some View {
        if let run {
            // The clock runs between publishes of the run's state, so the screen refreshes on its own.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(run, now: context.date)
                        attention(run, now: context.date)
                        controlRoom(run, now: context.date)
                        flowStrip(run)
                        tabs(run)
                    }.padding(20).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        } else {
            VStack(spacing: 8) {
                if session.startingExecution { ProgressView("Starting local runtime…"); Button("Cancel startup") { session.cancelExecutionStartup() } }
                else { Text("This run is no longer available.").foregroundColor(palette.textDim) }
                if let error = session.error ?? execution?.error { Text(error).foregroundColor(palette.red).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Derived

    private func phase(_ run: CockpitRun) -> CockpitRunPhase { CockpitRunPhase(run: run, coordinator: isLive ? execution?.state?.status : nil) }
    private func step(_ run: CockpitRun, _ stepID: String) -> (index: Int, step: CockpitStep)? {
        run.plan.steps.enumerated().first { $0.element.id.uuidString == stepID }.map { ($0.offset, $0.element) }
    }
    private var activeNow: Bool { isLive && execution?.isActive == true }

    // MARK: Header

    private func header(_ run: CockpitRun, now: Date) -> some View {
        let phase = phase(run)
        let done = run.steps.filter { $0.status == .passed || $0.status == .skipped }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(CockpitFormat.firstLine(run.plan.goal)).uiFont(size: 18, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                CockpitChip(text: phase.title, icon: phase.icon, tint: phase.tint(palette))
            }
            Text(clockLine(run, phase: phase, now: now)).uiFont(size: 12).foregroundColor(palette.textDim)
            ProgressView(value: Double(done), total: Double(max(1, run.steps.count))).tint(phase.tint(palette))
            Text(usageLine(run)).uiFont(size: 11).foregroundColor(palette.textDim)
        }
    }

    private func clockLine(_ run: CockpitRun, phase: CockpitRunPhase, now: Date) -> String {
        guard let began = run.began else { return "Step \(position(run)) of \(run.steps.count)" }
        let end = phase == .running ? now : (run.lastKnownActivity ?? began)
        let state = phase == .running ? "running for" : "ran for"
        return "Step \(position(run)) of \(run.steps.count) · started \(CockpitFormat.moment(began, now: now)) · \(state) \(CockpitFormat.duration(end.timeIntervalSince(began)))"
    }

    private func position(_ run: CockpitRun) -> Int { (run.currentIndex ?? max(0, run.steps.count - 1)) + 1 }

    private func usageLine(_ run: CockpitRun) -> String {
        let seconds = isLive ? (execution?.usedSeconds ?? run.activeSeconds ?? 0) : (run.activeSeconds ?? 0)
        let cycles = isLive ? (execution?.usedFixCycles ?? run.fixCyclesUsed ?? 0) : (run.fixCyclesUsed ?? 0)
        var parts = ["Agents worked \(CockpitFormat.duration(seconds))" + (run.plan.controls.timeLimitMinutes.map { " of \(CockpitFormat.duration(Double($0) * 60))" } ?? "")]
        parts.append("Fix cycles \(cycles)" + (run.plan.controls.fixCycleLimit.map { " of \($0)" } ?? ""))
        return parts.joined(separator: " · ")
    }

    // MARK: Attention

    @ViewBuilder private func attention(_ run: CockpitRun, now: Date) -> some View {
        let phase = phase(run)
        VStack(spacing: 8) {
            if let error = session.error ?? execution?.error { banner(icon: "xmark.octagon.fill", tint: palette.red, title: error) {} }
            if isLive, let notice = execution?.limitNotice { banner(icon: "hourglass", tint: palette.orange, title: notice) {} }
            if phase == .needsYou { banner(icon: "exclamationmark.circle.fill", tint: palette.red, title: "A step failed", detail: run.waitingReason) { retryButton(run) } }
            if phase == .interrupted { interruptedBanner(run) }
            if phase == .paused { banner(icon: "pause.circle.fill", tint: palette.orange, title: "The run is paused", detail: run.waitingReason) { retryButton(run) } }
            if activeNow, phase == .running, let quiet = run.quietSeconds(now: now, activity: execution?.lastSignal), run.isSilent(now: now, activity: execution?.lastSignal) {
                banner(icon: "moon.zzz.fill", tint: palette.orange, title: "No report for \(CockpitFormat.duration(quiet))",
                       detail: "The agent may be waiting for an answer or a permission in its terminal, which MarkView cannot see.") {
                    Button("Show agent terminal") { session.showAgentTerminal() }
                    Button("Stop") { session.control("stop") }
                }
            }
            if phase == .finished { outcomeBanner(run) }
            if let pending = session.pendingPlan, isLive, execution?.isActive == true {
                let fingerprint = try? CockpitTemporalPlan(pending).fingerprint
                banner(icon: "arrow.triangle.2.circlepath", tint: palette.orange,
                       title: fingerprint == execution?.state?.pendingFingerprint ? "Approved changes will apply after the current step." : "Waiting for the coordinator to confirm the approved changes.") {}
            }
        }
    }

    private func banner<Actions: View>(icon: String, tint: Color, title: String, detail: String = "", @ViewBuilder _ actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).uiFont(size: 12, weight: .semibold).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !detail.isEmpty { Text(detail).uiFont(size: 11).foregroundColor(palette.textDim).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions() }.buttonStyle(.bordered).controlSize(.small)
        }.cockpitCard(outline: tint)
    }

    @ViewBuilder private func retryButton(_ run: CockpitRun) -> some View {
        if activeNow, let state = execution?.state, state.status == "paused", run.plan.steps.indices.contains(state.current), run.plan.steps[state.current].isPrerequisite {
            Button("Retry prerequisite") { session.control("retry") }
        }
    }

    private func interruptedBanner(_ run: CockpitRun) -> some View {
        let canContinue = !activeNow && (run.status == .paused || run.status == .stopped)
        return banner(icon: "bolt.circle.fill", tint: palette.orange, title: "A step was interrupted; its effects may be incomplete",
                      detail: activeNow ? "Stop this run before choosing how to continue." : "Choose a step to continue from. Separately detached background processes may still be running.") {
            if canContinue {
                Button("Choose how to continue") { session.prepareRecovery(run) }.disabled(session.loadingRecovery || session.execution?.isActive == true)
                if run.pendingRevision != nil { Button("Review the pending plan") { session.prepareRecovery(run, usePending: true) }.disabled(session.loadingRecovery || session.execution?.isActive == true) }
            }
        }
    }

    @ViewBuilder private func outcomeBanner(_ run: CockpitRun) -> some View {
        let progress = run.results.last?.progress
        switch CockpitOutcome.evaluate(criteria: run.plan.successCriteria, progress: progress) {
        case .success: banner(icon: "checkmark.seal.fill", tint: palette.green, title: "Success against the stated criteria") {}
        case .blocked: banner(icon: "exclamationmark.triangle.fill", tint: palette.orange, title: "Finished with remaining blockers") {}
        case .unverified: banner(icon: "questionmark.circle.fill", tint: palette.orange, title: "Finished, but the success criteria lack complete evidence") {}
        }
    }

    // MARK: Control room

    private func controlRoom(_ run: CockpitRun, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CockpitSectionTitle(title: "Control room", detail: "Who does what in this run, right now.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                coordinatorCard(run)
                stepAgentCard(run, now: now)
                supervisorCard(run)
                guardCard(run)
            }
        }
    }

    private func roleCard<Content: View>(icon: String, title: String, subtitle: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(palette.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).uiFont(size: 13, weight: .semibold)
                    Text(subtitle).uiFont(size: 10).foregroundColor(palette.textDim)
                }
            }
            content()
        }.cockpitCard().frame(maxHeight: .infinity, alignment: .top)
    }

    private func coordinatorCard(_ run: CockpitRun) -> some View {
        let state = execution?.state?.status
        return roleCard(icon: "gearshape.2", title: "Coordinator", subtitle: "The local runtime that moves from step to step") {
            Text(coordinatorText(run, status: state)).uiFont(size: 12).fixedSize(horizontal: false, vertical: true)
            if activeNow {
                HStack(spacing: 8) {
                    if state == "running" { Button { session.control("pause") } label: { Label("Pause", systemImage: "pause.fill") } }
                    Button(role: .destructive) { session.control("stop") } label: { Label("Stop", systemImage: "stop.fill") }
                }.buttonStyle(.bordered).controlSize(.small)
                if state == "running" {
                    Text("Pause interrupts the running step. You then choose which step to continue from.").uiFont(size: 10).foregroundColor(palette.textDim)
                }
            }
        }
    }

    private func coordinatorText(_ run: CockpitRun, status: String?) -> String {
        switch status ?? (isLive ? nil : run.status.rawValue) {
        case "running": return "Advancing through the plan. It starts the next step only after the previous one passed and was saved."
        case "paused": return "Waiting for you. It starts no step until the run is continued."
        case "interrupted": return "A step was interrupted. It waits for you to stop the run and choose how to continue."
        case "stopped": return "The run was stopped."
        case "finished": return "Every step has run."
        default: return activeNow ? "Starting." : "Not running. The runtime stops when MarkView quits; a run continues only when you choose to."
        }
    }

    private func stepAgentCard(_ run: CockpitRun, now: Date) -> some View {
        roleCard(icon: "cpu", title: "Step agent", subtitle: "The agent working on the current step") {
            if let index = run.currentIndex, run.plan.steps.indices.contains(index), run.steps.indices.contains(index) {
                let plan = run.plan.steps[index], record = run.steps[index]
                Text(plan.title).uiFont(size: 12, weight: .semibold)
                Text("\(plan.agent) · \(plan.chosenModel ?? "default model")").uiFont(size: 11).foregroundColor(palette.textDim)
                if record.status == .running, let started = record.startedAt {
                    Text("Working for \(CockpitFormat.duration(now.timeIntervalSince(started)))").uiFont(size: 11)
                }
                if let signal = isLive ? (execution?.lastSignal ?? run.lastSignal) : run.lastSignal {
                    Text("Last sign of life \(CockpitFormat.duration(now.timeIntervalSince(signal))) ago").uiFont(size: 11).foregroundColor(palette.textDim)
                }
                if activeNow && record.status == .running { Button("Show agent terminal") { session.showAgentTerminal() }.buttonStyle(.bordered).controlSize(.small) }
            } else {
                Text(run.status == .finished ? "No step is running; the run finished." : "No step is running.").uiFont(size: 12).foregroundColor(palette.textDim)
            }
        }
    }

    private func supervisorCard(_ run: CockpitRun) -> some View {
        let log = run.exchanges ?? []
        let controls = run.plan.controls
        return roleCard(icon: "person.badge.shield.checkmark", title: "Supervisor", subtitle: "Answers the step agents' questions") {
            if controls.supervisor {
                let tool = controls.supervisorAgent ?? "Project's assistant"
                Text("\(tool) · \(controls.supervisorModel ?? "default model")").uiFont(size: 11).foregroundColor(palette.textDim)
                Text("\(log.count) asked · \(log.filter(\.outOfScope).count) outside the plan · \(log.filter(\.failed).count) unanswered").uiFont(size: 11)
                if let last = log.last {
                    Text("Last: \(last.question)").uiFont(size: 11).lineLimit(2).foregroundColor(palette.textDim)
                    Text("→ \(last.answer)").uiFont(size: 11).lineLimit(2).foregroundColor(last.outOfScope || last.failed ? palette.orange : palette.textDim)
                }
            } else {
                Text("Off. Step agents cannot ask anything; they decide inside the controls or record a blocker.").uiFont(size: 12).foregroundColor(palette.textDim)
            }
        }
    }

    private func guardCard(_ run: CockpitRun) -> some View {
        let refusals = (run.events ?? []).filter { $0.kind == .refusal }.count
        return roleCard(icon: "lock.shield", title: "Guard", subtitle: "What MarkView enforces during every step") {
            Text(CockpitStepPolicy(controls: run.plan.controls).enforced.joined(separator: " · ")).uiFont(size: 11).foregroundColor(palette.textDim).lineLimit(4)
            Text("\(refusals) call\(refusals == 1 ? "" : "s") refused so far").uiFont(size: 11)
            Text(limitsLine(run.plan.controls)).uiFont(size: 11).foregroundColor(palette.textDim)
        }
    }

    private func limitsLine(_ controls: CockpitControls) -> String {
        var parts: [String] = []
        if let minutes = controls.timeLimitMinutes { parts.append("\(CockpitFormat.duration(Double(minutes) * 60)) of agent time") }
        if let cycles = controls.fixCycleLimit { parts.append("\(cycles) fix cycle\(cycles == 1 ? "" : "s")") }
        return parts.isEmpty ? "No time or fix cycle limit." : "Limits: " + parts.joined(separator: ", ")
    }

    // MARK: Flow

    private func flowStrip(_ run: CockpitRun) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(run.plan.steps.enumerated()), id: \.element.id) { index, plan in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundColor(palette.textDim) }
                    flowChip(index: index, plan: plan, record: run.steps.indices.contains(index) ? run.steps[index] : nil, current: run.currentIndex == index)
                }
            }.padding(.vertical, 2)
        }
    }

    private func flowChip(index: Int, plan: CockpitStep, record: CockpitRun.StepRecord?, current: Bool) -> some View {
        let tint = stepTint(record?.status)
        let selected = selectedStepID == plan.id.uuidString
        return Button { selectedStepID = selected ? nil : plan.id.uuidString } label: {
            HStack(spacing: 5) {
                Image(systemName: stepIcon(record?.status)).font(.system(size: 11))
                Text("\(index + 1). \(plan.title)").uiFont(size: 11, weight: current ? .semibold : .regular).lineLimit(1)
            }
            .foregroundColor(tint).padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? palette.accent : (current ? tint : Color.clear), lineWidth: 1.5))
        }.buttonStyle(.plain).help(plan.assignment)
    }

    private func stepTint(_ status: CockpitRun.StepStatus?) -> Color {
        switch status {
        case .running: return palette.accent
        case .passed: return palette.green
        case .failed: return palette.red
        case .interrupted: return palette.orange
        case .skipped, .waiting, .none: return palette.textDim
        }
    }

    private func stepIcon(_ status: CockpitRun.StepStatus?) -> String {
        switch status {
        case .running: return "play.circle.fill"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .interrupted: return "bolt.circle.fill"
        case .skipped: return "arrow.right.circle"
        case .waiting, .none: return "circle"
        }
    }

    // MARK: Tabs

    private func tabs(_ run: CockpitRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            switch tab {
            case .timeline: CockpitRunTimeline(session: session, run: run, selectedStepID: $selectedStepID)
            case .steps: stepsTab(run)
            case .questions: questionsTab(run)
            case .findings: findingsTab(run)
            }
        }
    }

    private func stepsTab(_ run: CockpitRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(run.plan.steps.enumerated()), id: \.element.id) { index, plan in
                let record = run.steps.indices.contains(index) ? run.steps[index] : nil
                let result = run.results.last { $0.stepID == plan.id }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: stepIcon(record?.status)).foregroundColor(stepTint(record?.status))
                        Text("\(index + 1). \(plan.title)").uiFont(size: 13, weight: .semibold)
                        Spacer()
                        CockpitChip(text: "\(plan.agent) · \(plan.chosenModel ?? "default model")", icon: "cpu")
                    }
                    if let started = record?.startedAt {
                        Text("Started \(CockpitFormat.moment(started))" + (record?.endedAt.map { " · \(CockpitFormat.duration($0.timeIntervalSince(started)))" } ?? "")).uiFont(size: 11).foregroundColor(palette.textDim)
                    }
                    Text(plan.assignment).uiFont(size: 12).textSelection(.enabled)
                    Label(plan.completionCondition, systemImage: "checkmark.circle").uiFont(size: 11).foregroundColor(palette.textDim)
                    if let result {
                        Text("\(result.passed ? "Passed" : "Failed"): \(result.detail)").uiFont(size: 12).textSelection(.enabled)
                        if let scenario = result.scenarioID, let id = result.qaRunID { qaButton(scenario, id) }
                    }
                    if let progress = record?.progress ?? result?.progress { progressBody(progress) }
                }
                .cockpitCard(outline: selectedStepID == plan.id.uuidString ? palette.accent : nil)
            }
        }
    }

    private func questionsTab(_ run: CockpitRun) -> some View {
        let log = run.exchanges ?? []
        return VStack(alignment: .leading, spacing: 8) {
            if log.isEmpty {
                Text(run.plan.controls.supervisor ? "No agent has asked a question yet." : "The supervisor is off, so agents cannot ask.").uiFont(size: 12).foregroundColor(palette.textDim)
            }
            ForEach(Array(log.reversed().enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(step(run, item.stepID).map { "Step \($0.index + 1): \($0.step.title)" } ?? "Step").uiFont(size: 11, weight: .semibold).foregroundColor(palette.textDim)
                        Spacer()
                        Text(CockpitFormat.moment(item.asked)).uiFont(size: 10).foregroundColor(palette.textDim)
                    }
                    Text("Q: " + item.question).uiFont(size: 12).textSelection(.enabled)
                    Text("A: " + item.answer).uiFont(size: 12).foregroundColor(item.outOfScope || item.failed ? palette.orange : palette.text).textSelection(.enabled)
                    if item.outOfScope { CockpitChip(text: "Outside the plan", tint: palette.orange) }
                    if item.failed { CockpitChip(text: "Could not be answered", tint: palette.orange) }
                }.cockpitCard(padding: 10)
            }
        }
    }

    private func findingsTab(_ run: CockpitRun) -> some View {
        let latest = run.results.last?.progress ?? run.steps.compactMap(\.progress).last
        let bugs = Array(Set(run.steps.compactMap(\.progress).flatMap(\.bugs) + run.results.compactMap(\.progress).flatMap(\.bugs))).sorted()
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                CockpitSectionTitle(title: "Success criteria", detail: "Judged against the evidence the agent reported.")
                ForEach(run.plan.successCriteria, id: \.self) { criterion in
                    let result = latest?.criteriaResults?.first { $0.criterion == criterion }
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: result.map { $0.met ? "checkmark.circle.fill" : "xmark.circle.fill" } ?? "circle").foregroundColor(result.map { $0.met ? palette.green : palette.red } ?? palette.textDim)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(criterion).uiFont(size: 12)
                            if let result { Text(result.evidence).uiFont(size: 11).foregroundColor(palette.textDim).textSelection(.enabled) }
                            else { Text("No evidence yet").uiFont(size: 11).foregroundColor(palette.textDim) }
                        }
                    }
                }
            }.cockpitCard()
            VStack(alignment: .leading, spacing: 6) {
                CockpitSectionTitle(title: "Bugs filed")
                if bugs.isEmpty { Text("None.").uiFont(size: 12).foregroundColor(palette.textDim) }
                ForEach(bugs, id: \.self) { bug in Button("Open \(bug)") { session.openBug(bug) }.buttonStyle(.borderless).uiFont(size: 12) }
                if let fixes = latest?.fixes, !fixes.isEmpty { Text("Confirmed fixes: " + fixes.joined(separator: ", ")).uiFont(size: 12) }
                if let blockers = latest?.blockers, !blockers.isEmpty {
                    ForEach(blockers, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").uiFont(size: 12).foregroundColor(palette.orange) }
                }
            }.cockpitCard()
        }
    }

    private func qaButton(_ scenario: String, _ id: String) -> some View {
        Group {
            if session.deletedQARuns.contains(id) { Text("QA run details deleted").uiFont(size: 11).foregroundColor(palette.orange) }
            else { Button("Open QA result") { session.openQAResult(scenarioID: scenario, runID: id) }.buttonStyle(.borderless).uiFont(size: 11) }
        }
    }

    private func progressBody(_ progress: CockpitProgress) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Pass \(progress.passNumber) · \(progress.activity)").uiFont(size: 11, weight: .semibold)
            if !progress.scenarioCoverage.isEmpty { Text("Scenario coverage: " + progress.scenarioCoverage.joined(separator: ", ")).uiFont(size: 11) }
            if !progress.latestChange.isEmpty { Text("Latest change: " + progress.latestChange).uiFont(size: 11) }
            if !progress.blockers.isEmpty { Text("Blockers: " + progress.blockers.joined(separator: ", ")).uiFont(size: 11).foregroundColor(palette.orange) }
            if let path = progress.buildLogPath, !path.isEmpty { Button("Open build log") { session.openBuildLog(path) }.buttonStyle(.borderless).uiFont(size: 11) }
        }.foregroundColor(palette.textDim).textSelection(.enabled)
    }
}
