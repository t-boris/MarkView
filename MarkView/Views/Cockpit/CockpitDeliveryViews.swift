import SwiftUI

/// What a managed implementation run needs from the person on its run screen (agent-aware-implementation-runs): the Ask me action it
/// waits on, the delivery actions a review finding or a decline blocks, the processes of an interrupted step that still run, and how
/// to continue from the first step current evidence does not support.
struct CockpitManagedAttention: View {
    @ObservedObject var session: CockpitSession
    let run: CockpitRun
    /// The run is the one this window is running now, with its workflow alive.
    let live: Bool
    let phase: CockpitRunPhase
    @Environment(\.palette) private var palette

    private var failedStep: CockpitStep? {
        guard let index = run.currentIndex, run.steps.indices.contains(index), run.steps[index].status == .failed,
              run.plan.steps.indices.contains(index) else { return nil }
        return run.plan.steps[index]
    }

    var body: some View {
        VStack(spacing: 8) {
            if let delegates = run.managed?.delegates, !delegates.isEmpty { delegatesBanner(delegates) }
            if live, phase == .needsYou, let step = failedStep { failedBanner(step) }
            if phase == .interrupted || (!live && !phase.isFinished && phase != .running) { continueBanner }
            if let blocker = session.startBlocker { banner(icon: "hand.raised.fill", tint: palette.orange, title: blocker) {} }
        }
    }

    @ViewBuilder private func failedBanner(_ step: CockpitStep) -> some View {
        let decision = run.managed?.decision(for: step.id)
        let mandatory = step.doneItem.map { run.plan.feature?.mandatory.contains($0) ?? false } ?? false
        let detail = run.steps.first { $0.stepID == step.id }?.detail ?? ""
        if step.asksFirst == true, decision == nil {
            banner(icon: "person.fill.questionmark", tint: palette.orange, title: "Waiting for your approval: \(step.title)",
                   detail: "\(step.assignment)\n\nThe agent keeps its launch-profile permissions; Cockpit itself does nothing until you answer.") {
                Button("Approve") { session.decide(stepID: step.id, approved: true) }.buttonStyle(.borderedProminent)
                Button("Decline") { session.decide(stepID: step.id, approved: false) }
            }
        } else if decision?.approved == false, mandatory {
            banner(icon: "xmark.octagon.fill", tint: palette.red, title: "Delivery is blocked by \(step.title)",
                   detail: "You declined it, and the project requires it for delivery.") {
                Button("Approve after all") { session.decide(stepID: step.id, approved: true) }
                Button("Stop") { session.control("stop") }
            }
        } else if (step.kind ?? .work).isPublishing, !(run.managed?.findings ?? []).isEmpty, detail.contains("review findings") {
            banner(icon: "exclamationmark.shield.fill", tint: palette.red, title: "\(step.title) is blocked by review findings", detail: detail) {
                Button("Retry") { session.retryStep() }
                Button("Fix and verify again") { session.continueManaged(run) }.disabled(session.continuingManaged)
            }
        } else {
            banner(icon: "exclamationmark.circle.fill", tint: palette.red, title: "\(step.title) did not pass", detail: CockpitText.firstLine(detail)) {
                if step.isPrerequisite {
                    Button("Retry step") { session.retryStep() }.disabled(!(run.managed?.delegates ?? []).isEmpty)
                }
                Button("Continue from evidence") { session.continueManaged(run) }.disabled(session.continuingManaged)
            }
        }
    }

    private var continueBanner: some View {
        let alive = !(run.managed?.delegates ?? []).isEmpty
        let latest = run.steps.compactMap(\.progress).last ?? run.results.last?.progress
        let evidence = latest.map { "Latest report: pass \($0.passNumber), \($0.activity)" + ($0.blockers.isEmpty ? "" : " — blockers: " + $0.blockers.joined(separator: "; ")) } ?? ""
        return banner(icon: "arrow.uturn.forward.circle.fill", tint: palette.orange, title: "Continue this implementation run",
                      detail: [run.waitingReason, evidence, "Cockpit reads the checkout and GitHub again and continues at the first step their evidence does not support; changes in the checkout are kept."]
                        .filter { !$0.isEmpty }.joined(separator: "\n")) {
            Button(session.continuingManaged ? "Checking evidence…" : "Continue") { session.continueManaged(run) }
                .buttonStyle(.borderedProminent).disabled(alive || session.continuingManaged || session.execution?.isActive == true)
            if !live, run.isUnfinished { Button("End run") { session.endRun(run) } }
        }
    }

    private func delegatesBanner(_ delegates: [CockpitProcessRecord]) -> some View {
        banner(icon: "person.2.badge.gearshape.fill", tint: palette.red, title: "Processes of the step may still write to the checkout",
               detail: "A retry waits until these have stopped:\n" + delegates.map { "• \($0.command) (process \($0.pid))" }.joined(separator: "\n")) {
            Button("Stop these processes") { session.stopDelegates(run) }
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
}

/// Which delivery steps of a managed run completed, which were done outside Cockpit, and which are pending, declined or blocked
/// (REQ-004 partial delivery).
struct CockpitDeliveryCard: View {
    let run: CockpitRun
    @Environment(\.palette) private var palette

    var body: some View {
        let lines = CockpitManagedRun.deliveryStatus(run)
        VStack(alignment: .leading, spacing: 6) {
            CockpitSectionTitle(title: "Delivery", detail: CockpitManagedRun.deliveryComplete(run) ? "Every delivery step is done." : "What is done, and what is pending or blocked.")
            ForEach(lines) { line in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon(line.state)).foregroundColor(tint(line.state)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.title).uiFont(size: 12)
                        Text(text(line.state)).uiFont(size: 11).foregroundColor(palette.textDim).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.cockpitCard()
    }

    private func icon(_ state: CockpitManagedRun.DeliveryLine.State) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .external: return "checkmark.circle.badge.questionmark"
        case .declined(let blocking): return blocking ? "xmark.octagon.fill" : "minus.circle"
        case .blocked: return "exclamationmark.triangle.fill"
        case .running: return "play.circle.fill"
        case .pending: return "circle"
        }
    }

    private func tint(_ state: CockpitManagedRun.DeliveryLine.State) -> Color {
        switch state {
        case .done: return palette.green
        case .external: return palette.blue
        case .declined(let blocking): return blocking ? palette.red : palette.textDim
        case .blocked: return palette.orange
        case .running: return palette.accent
        case .pending: return palette.textDim
        }
    }

    private func text(_ state: CockpitManagedRun.DeliveryLine.State) -> String {
        switch state {
        case .done(let detail): return detail.isEmpty ? "Done." : detail
        case .external(let evidence): return "Done outside Cockpit, without its approval. " + evidence
        case .declined(let blocking): return blocking ? "Declined by you; the project requires it, so delivery is blocked." : "Declined by you."
        case .blocked(let reason): return reason
        case .running: return "Running now."
        case .pending: return "Pending."
        }
    }
}

/// The independent review's confirmed findings, what each violates, the revision it was found in, and its fix or accepted risk
/// (REQ-004, DEC-029, DEC-032). Risk can be accepted only for a finding against an acceptance criterion, with a rationale, for the
/// revision in the checkout.
struct CockpitReviewFindingsCard: View {
    @ObservedObject var session: CockpitSession
    let run: CockpitRun
    let live: Bool
    @State private var rationale: [String: String] = [:]
    @Environment(\.palette) private var palette

    var body: some View {
        let findings = run.managed?.findings ?? []
        VStack(alignment: .leading, spacing: 8) {
            CockpitSectionTitle(title: "Review findings", detail: findings.isEmpty ? "The independent review has reported no finding yet." : "Merge and release wait for each finding until its fix is verified or its risk is accepted for the revision delivered.")
            ForEach(findings) { finding in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(finding.id) · \(finding.title)").uiFont(size: 12, weight: .semibold)
                        Spacer()
                        CockpitChip(text: state(finding), tint: finding.state == .open ? palette.red : (finding.state == .fixed ? palette.green : palette.orange))
                    }
                    Text("Violates \(finding.basis == .criterion ? "acceptance criterion" : "project rule"): \(finding.reference)").uiFont(size: 11)
                    Text("Found in \(String(finding.revision.prefix(9))). \(finding.detail)").uiFont(size: 11).foregroundColor(palette.textDim).textSelection(.enabled)
                    if let evidence = finding.fixEvidence { Text("Fix evidence: \(evidence)").uiFont(size: 11).foregroundColor(palette.textDim).textSelection(.enabled) }
                    if let acceptance = finding.acceptance {
                        Text("You accepted the risk for \(String(acceptance.revision.prefix(9))): \(acceptance.rationale)").uiFont(size: 11).foregroundColor(palette.orange)
                    }
                    if live, finding.state != .fixed || finding.verifiedRevision == nil {
                        if finding.mayAcceptRisk {
                            HStack(spacing: 6) {
                                TextField("Why you accept this risk", text: Binding(get: { rationale[finding.id] ?? "" }, set: { rationale[finding.id] = $0 }))
                                    .textFieldStyle(.roundedBorder).uiFont(size: 11)
                                Button("Accept risk for this revision") { session.acceptRisk(findingID: finding.id, rationale: rationale[finding.id] ?? "") }
                                    .controlSize(.small).disabled((rationale[finding.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        } else {
                            Text("A mandatory project rule: only a verified fix lifts it.").uiFont(size: 10).foregroundColor(palette.textDim)
                        }
                    }
                }.cockpitCard(padding: 10)
            }
        }.cockpitCard()
    }

    private func state(_ finding: CockpitReviewFinding) -> String {
        switch finding.state {
        case .open: return "Open"
        case .fixed: return finding.verifiedRevision.map { "Fix verified at \(String($0.prefix(9)))" } ?? "Fixed, not yet verified"
        case .accepted: return "Risk accepted"
        }
    }
}
