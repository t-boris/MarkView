import Foundation

/// The one-time review of an environment prepared before it could model the application's transport envelope and the state the
/// application changes (DEC-015). It runs once per project, after the map, when nothing else wants the assistant, and leaves a
/// decision in environment.json (`envelopes`, an empty list meaning "none"), so it is never asked again.
extension StudioSession {
    /// Whether the environment still has to be looked at: it generates answers from state (so an envelope matters), it was never
    /// reviewed, the person has not turned automatic repair off, and this open has not tried yet.
    var needsEnvironmentReview: Bool {
        spec.envelopes == nil && spec.repairsAutomatically && !environmentReviewTried && spec.rules.contains { $0.operation != .respond }
    }

    func scheduleEnvironmentReview() {
        guard needsEnvironmentReview, !closed, reviewTask == nil else { return }
        reviewTask = Task { [weak self] in
            await self?.runEnvironmentReview()
            self?.reviewTask = nil
        }
    }

    private func runEnvironmentReview() async {
        // The application and the map come first: they have the assistant's attention.
        while !closed, !Task.isCancelled, state != .failed, appURL == nil || mapping.isRunning || restoringPage || busy != nil || isPreparing
                || ![.ready, .degraded].contains(state) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard !closed, !Task.isCancelled, state != .failed, needsEnvironmentReview else { return }
        environmentReviewTried = true
        // Background work like the screens' preparation: a banner, not the busy state, so the person is never locked out meanwhile.
        screenWork = ScreenWork(text: "Checking how the application reads responses")
        defer { if screenWork?.text == "Checking how the application reads responses" { screenWork = nil } }
        let startingRules = spec.rules.map(\.id)
        do {
            var request = CLICompletion.Request(project: root, prompt: redactor.redact(text: StudioReview.prompt(spec: spec, appFolder: relativeAppFolder)),
                                                systemPrompt: StudioReview.system, jsonSchema: StudioReview.schema, readableFolder: root)
            request.label = "ui-studio:review"
            request.timeout = 900
            request.effort = "medium"
            let result = try await CLICompletion.run(request)
            recordUsage(result.inputTokens, result.outputTokens, result.costUSD ?? 0)
            guard !Task.isCancelled, !closed else { return }
            guard let outcome = StudioReview.outcome(from: result.structured) else {
                sessionLog.add(.preparation, problem: true, "The review of the environment came back in a form MarkView cannot read; it is tried again at the next open.")
                return
            }
            // The rules changed while the assistant read the project (Map Again, a new rule): its answer was about another environment.
            guard spec.rules.map(\.id) == startingRules else {
                sessionLog.add(.preparation, "The environment changed while it was reviewed; the review is tried again at the next open.")
                return
            }
            let rulesBefore = spec.rules
            let problems = adoptReview(outcome)
            guard problems.isEmpty else {
                sessionLog.add(.preparation, problem: true, "The review of the environment was refused: " + problems.prefix(3).joined(separator: " ")
                               + " It is tried again at the next open.")
                return
            }
            let envelopes = outcome.proposal.envelopes?.count ?? 0
            sessionLog.add(.preparation, "Reviewed how the application reads responses: \(envelopes) envelope\(envelopes == 1 ? "" : "s"), "
                           + "\(outcome.replaces.count) fixed answer\(outcome.replaces.count == 1 ? "" : "s") now follow state." + (outcome.notes.isEmpty ? "" : " " + outcome.notes))
            // The page asked with the old answers: it loads again on the corrected ones, when anything changed what is answered.
            guard spec.rules != rulesBefore || envelopes > 0 else { return }
            notice = "Studio corrected how the simulation answers: the application's response envelope and the state it changes."
            reloadPage()
        } catch is CancellationError {
            return
        } catch {
            sessionLog.add(.preparation, problem: true, "The review of the environment did not finish: \(error.localizedDescription) It is tried again at the next open.")
        }
    }
}
