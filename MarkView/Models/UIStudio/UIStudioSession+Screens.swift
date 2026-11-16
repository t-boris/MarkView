import Foundation

/// The application's main screens, ready before the first click (REQ-021, DEC-014). The list is kept in `.markview/studio/screens.json`.
/// The assistant prepares a scenario for each main screen in the background without a page (a context change from the built-in Populated
/// scenario, checked statically); the first opening verifies it on the page at no assistant cost, and one that does not reach its screen
/// falls back to the correction path of the request box.
extension StudioSession {
    /// What a screen's first opening came to, for the menu action to follow.
    private final class OpenBox {
        var ran = false
        var problem: String?
    }

    // MARK: - The list

    /// A new listing of the screens: kept by screen, saved, and the hashes of their evidence read.
    func adoptScreens(_ found: [StudioScreen]) {
        screenBook.appFolder = relativeAppFolder
        screenBook.merge(found: found)
        persistScreenBook()
        startPartTask { session in await session.refreshScreenHashes() }
    }

    /// Reads the current hashes of the files the screens name as evidence, so that a changed file shows as "needs refresh".
    func refreshScreenHashes() async {
        let paths = Array(Set(screenBook.entries.flatMap { StudioScreenBook.sourcePaths(of: $0.screen) }))
        guard !paths.isEmpty else { return }
        let root = root
        let hashes = await Task.detached { StudioRevisionProbe.currentHashes(paths, root: root) }.value
        guard !closed else { return }
        screenHashes = hashes
    }

    /// The hashes of the files one screen names as evidence, now.
    private func sourceHashes(of screen: StudioScreen) async -> [String: String] {
        let paths = StudioScreenBook.sourcePaths(of: screen)
        guard !paths.isEmpty else { return [:] }
        let root = root
        return await Task.detached { StudioRevisionProbe.currentHashes(paths, root: root) }.value
    }

    func state(of screen: StudioScreen) -> StudioScreenBook.State {
        guard let entry = screenBook.entry(for: screen) else { return .notPrepared }
        return screenBook.state(of: entry, preparing: preparingScreens, current: screenHashes)
    }

    // MARK: - Ahead of the click

    /// Starts the background work once the application and its map are there: lists the screens when they never were, then prepares
    /// the main ones that are not ready. Called after the application opened, after the map finished and after the list changed.
    func scheduleScreenWork() {
        guard spec.preparesScreens, !closed, screenTask == nil else { return }
        screenTask = Task { [weak self] in
            await self?.runScreenWork()
            self?.screenTask = nil
        }
    }

    func cancelScreenWork() {
        screenTask?.cancel()
        screenTask = nil
        screenWork = nil
        preparingScreens = []
    }

    private func runScreenWork() async {
        // The application and the map come first: they have the assistant's attention.
        while !closed, !Task.isCancelled, state != .failed, appURL == nil || mapping.isRunning || restoringPage || reviewTask != nil || ![.ready, .degraded].contains(state) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard !closed, !Task.isCancelled, state != .failed else { return }
        await refreshScreenHashes()
        if screenBook.discovered == nil {
            screenWork = ScreenWork(text: "Finding the application's screens")
            do {
                let (found, notes) = try await requestScreens(reportProgress: false)
                guard !Task.isCancelled, !closed else { return }
                adoptScreens(found)
                sessionLog.add(.preparation, "Found \(found.count) application screens." + (notes.isEmpty ? "" : " " + notes))
            } catch is CancellationError {
                screenWork = nil
                return
            } catch {
                screenWork = nil
                sessionLog.add(.preparation, problem: true, "Finding the application's screens failed: \(error.localizedDescription)")
                return
            }
        }
        let pending = screenBook.pending(preparing: preparingScreens, current: screenHashes)
        guard !pending.isEmpty else {
            screenWork = nil
            return
        }
        for (index, entry) in pending.enumerated() {
            guard !closed, !Task.isCancelled, spec.preparesScreens else { break }
            screenWork = ScreenWork(text: "Preparing screens: \(entry.screen.name)", done: index, total: pending.count)
            _ = await prepareScreen(entry)
        }
        screenWork = nil
    }

    /// Prepares the scenario of one screen without touching the page: the assistant proposes a context change from the built-in
    /// Populated scenario (never chained on another scenario), MarkView checks it statically (the page check is the first opening),
    /// and the scenario is saved under the screen's own id. Returns whether a scenario was saved.
    @discardableResult
    func prepareScreen(_ entry: StudioScreenBook.Entry) async -> Bool {
        let screen = entry.screen
        preparingScreens.insert(entry.id)
        defer { preparingScreens.remove(entry.id) }
        sessionLog.add(.preparation, "Preparing the screen \(screen.name) (\(screen.route))")
        func fail(_ reason: String) -> Bool {
            screenBook.markFailed(entry.id, reason)
            persistScreenBook()
            sessionLog.add(.preparation, problem: true, "The screen \(screen.name) was not prepared: \(reason)")
            return false
        }
        let base = presets.first { $0.id == "builtin-populated" } ?? presets[0]
        let (revision, snapshot) = await StudioRevisionProbe.compute(root: root, editorBuffers: editorBuffers())
        func screenRequest(refusedContext refused: [String]?) -> CLICompletion.Request {
            var call = CLICompletion.Request(project: root,
                                             prompt: StudioPrompts.editPrompt(screen.request, selection: nil, scenario: base, revision: revision,
                                                                              history: [], redactor: redactor, clarification: nil,
                                                                              retryProblem: nil, route: screen.route, pageImage: nil,
                                                                              spec: spec, refusedContext: refused, reached: servedRules,
                                                                              attachments: [],
                                                                              supabaseAuth: simulator.authMock != nil && !hasRealSupabase,
                                                                              supabaseAuthReal: hasRealSupabase),
                                             systemPrompt: StudioPrompts.editSystem, jsonSchema: StudioPrompts.editSchema, readableFolder: root)
            call.timeout = 240
            call.effort = "medium"
            call.label = "ui-studio:screen"
            return call
        }
        // Asked twice at most: the second time with the problems the check found in the first answer.
        let preparing = AIOperation<[String]?, StudioContextPlan>(
            name: "ui-studio:screen",
            maxRepairAttempts: 1,
            buildRequest: { refused in screenRequest(refusedContext: refused) },
            parse: { _, result, _ in
                guard let plan = StudioPrompts.editPlan(from: result.structured) else { throw ScreenFailure("The assistant's answer was not a set of changes.") }
                guard plan.kind == .context, !plan.needsClarification else {
                    throw ScreenFailure(plan.needsClarification ? "The assistant asked a question instead of preparing the scenario." : "The assistant proposed no scenario change.")
                }
                var context = plan.context ?? StudioContextPlan(structured: nil)
                context.expectedPath = screen.expectedPath ?? ""
                context.expectedSelector = screen.selector
                // A scenario with no steps starts where its screen is; one with steps starts where the assistant says and navigates.
                if context.route.isEmpty, context.steps.isEmpty, !screen.hasPlaceholderRoute { context.route = screen.route }
                // A route with a placeholder names no page to load: without steps (or a route the assistant made concrete) the scenario
                // cannot reach it, so it is not saved as prepared; the click asks the assistant, which can navigate to a real record.
                if screen.hasPlaceholderRoute, context.route.isEmpty, context.steps.isEmpty {
                    throw ScreenFailure("The screen's address (\(screen.route)) has a placeholder and the assistant gave no steps that reach a real page.")
                }
                return context
            },
            validate: { [weak self] _, context, attempt in
                guard let self else { throw CancellationError() }
                var problems = StudioContextValidator.problems(context, current: base, spec: self.spec)
                if attempt.number == 1 { problems += StudioContextValidator.givenUpProblems(context, current: base, spec: self.spec) }
                guard problems.isEmpty else {
                    if attempt.isLast { throw ScreenFailure("The scenario was refused: " + problems.prefix(3).joined(separator: " ")) }
                    // A closed session does not ask again.
                    guard !self.closed else { throw CancellationError() }
                    throw ScreenRefusal(problems: problems)
                }
            },
            repair: { context in screenRequest(refusedContext: (context.error as? ScreenRefusal)?.problems) },
            onResult: { [weak self] result in self?.recordUsage(result.inputTokens, result.outputTokens, result.costUSD ?? 0) })
        guard !closed, !Task.isCancelled else { return false }
        let context: StudioContextPlan
        do {
            context = try await preparing.execute(nil).output
        } catch is CancellationError {
            return false
        } catch {
            return fail(error.localizedDescription)
        }
        let id = StudioScreenBook.scenarioID(for: screen)
        var next = StudioContextValidator.scenario(context, from: base, spec: spec, request: screen.request,
                                                   taken: (savedScenarios + presets).filter { $0.id != id })
        next.id = id
        let unique = StudioContextValidator.uniqueName(screen.name, taken: (savedScenarios + presets).filter { $0.id != id })
        next.name = unique.name
        next.contractFingerprint = StudioScenarioCompatibility.fingerprint(next, spec: spec)
        guard StudioContextValidator.sameSources(snapshot, await StudioRevisionProbe.compute(root: root, editorBuffers: editorBuffers()).1) else {
            return fail("The project's files changed while the assistant worked; it is prepared again next time.")
        }
        let projectRoot = root
        do {
            let scenarios = try await Task.detached { () throws -> [StudioScenario] in
                try StudioStore.saveScenario(next, root: projectRoot)
                return StudioStore.loadScenarios(projectRoot)
            }.value
            reloadSavedScenarios(scenarios)
        } catch {
            return fail("The scenario could not be saved: \(error.localizedDescription)")
        }
        screenBook.markPrepared(entry.id, scenarioID: id, sources: await sourceHashes(of: screen))
        persistScreenBook()
        sessionLog.add(.preparation, "The screen \(screen.name) is prepared as the scenario \(next.name)")
        return true
    }

    // MARK: - The click

    /// Opens a screen. A prepared one opens at once, without the assistant, and the page proves it: if the scenario does not reach the
    /// screen it is opened through the assistant instead (the request box's path, with its verification and correction).
    func openScreen(_ screen: StudioScreen) {
        clearSelection()
        guard let entry = screenBook.entry(for: screen) else { return change(screen.request, destination: screen) }
        switch screenBook.state(of: entry, preparing: preparingScreens, current: screenHashes) {
        case .preparing:
            notice = "\(screen.name) is being prepared; it opens when it is ready."
        case .prepared, .ready:
            guard busy == nil, let saved = savedScenarios.first(where: { $0.id == entry.scenarioID }),
                  StudioScenarioCompatibility.isCurrent(saved, spec: spec) else { return openThroughAssistant(entry) }
            openPrepared(entry, scenario: saved)
        case .notPrepared, .needsRefresh, .failed:
            openThroughAssistant(entry)
        }
    }

    private func openPrepared(_ entry: StudioScreenBook.Entry, scenario saved: StudioScenario) {
        startPartTask { session in
            let box = OpenBox()
            session.runWork("Opening \(entry.screen.name)") { session in
                box.ran = true
                box.problem = await session.activateReturningProblem(saved)
            }
            await session.awaitWork()
            guard box.ran, !session.closed else { return }
            guard let problem = box.problem else {
                session.screenBook.markVerified(entry.id)
                session.persistScreenBook()
                return
            }
            session.sessionLog.add(.preparation, problem: true,
                                   "The prepared scenario for \(entry.screen.name) did not reach the screen: \(problem) The assistant opens it instead.")
            session.openThroughAssistant(entry)
        }
    }

    /// The request box's path for a destination, and what it made is kept as the screen's scenario for the next click.
    private func openThroughAssistant(_ entry: StudioScreenBook.Entry) {
        guard busy == nil else { return }
        change(entry.screen.request, destination: entry.screen)
        startPartTask { session in
            await session.awaitWork()
            guard !session.closed, let operation = session.history.last, operation.destinationScreen?.id == entry.id, operation.kind == .context,
                  [.applied, .kept].contains(operation.status), let id = operation.context?.scenarioId, !id.isEmpty else { return }
            session.screenBook.markVerified(entry.id, scenarioID: id, sources: await session.sourceHashes(of: entry.screen))
            session.persistScreenBook()
        }
    }

    /// The menu's "Prepare Main Screens": the main screens that are not ready, including those that failed before.
    func prepareMainScreens() {
        guard !closed, screenTask == nil else { return }
        screenTask = Task { [weak self] in
            guard let self else { return }
            let pending = self.screenBook.main.filter { [.notPrepared, .needsRefresh, .failed].contains(self.state(of: $0.screen)) }
            for (index, entry) in pending.enumerated() {
                guard !closed, !Task.isCancelled else { break }
                screenWork = ScreenWork(text: "Preparing screens: \(entry.screen.name)", done: index, total: pending.count)
                _ = await prepareScreen(entry)
            }
            screenWork = nil
            screenTask = nil
        }
    }
}

/// A screen's preparation ended for a reason that asking again cannot mend; `reason` is what the screen book shows.
private struct ScreenFailure: LocalizedError, AIUnrepairable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

/// The static check refused the scenario; its problems go back to the assistant once.
private struct ScreenRefusal: LocalizedError {
    let problems: [String]
    var errorDescription: String? { problems.joined(separator: " ") }
}
