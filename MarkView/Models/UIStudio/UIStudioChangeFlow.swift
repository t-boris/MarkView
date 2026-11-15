import AppKit
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The request box of UI Studio (DEC-010; EDIT-01..EDIT-08, REQ-013): one request answered, checked and recorded; the check of a rebuilt
/// application; and the undo of what a request did. Owns the undo conflicts waiting for the person and the trial of a requested scenario.
@MainActor
final class StudioChangeFlow: ObservableObject {
    unowned let session: StudioSession

    private(set) var tryingScenario = false

    /// Undo conflicts by operation: the merged text with conflict markers per file.
    @Published private(set) var undoConflicts: [String: [(path: String, merged: String)]] = [:]

    /// The element as a turn records it: its tag and, when known, its source file.
    private static func turnElement(_ selection: StudioSelectionContext) -> String {
        selection.tag + (selection.sourcePath.map { " · \($0)" } ?? "")
    }

    /// One request of the request box (DEC-010; EDIT-01…EDIT-08, AC-11…AC-15, REQ-013). The assistant chooses its kind: an
    /// answer changes nothing; a context change is checked (and corrected once) and becomes a new saved scenario derived
    /// from the current one; a code change names the scope and proposes exact edits, which MarkView checks against the
    /// working tree as it was when the request started, writes after restoring and capturing the scenario, and verifies in
    /// the rebuilt application. A selection is optional: without one, the request is about the current page. The images
    /// attached to the request (REQ-005) are saved under `.dde/studio/attachments/`, recorded on the turn, given to the
    /// assistant with the request, and named in its prompt; a request of images alone is allowed. Answering a clarification
    /// sends the images of the turn again.
    func change(_ text: String, attachments: [ImageAttachment] = [], clarification: String? = nil,
                replacing pending: StudioOperation? = nil, destination: StudioScreen? = nil) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = typed.isEmpty && !attachments.isEmpty ? StudioPrompts.imageOnlyRequest : typed
        let destination = destination ?? pending?.destinationScreen
        guard !request.isEmpty, session.appURL != nil else { return }
        var selection = session.selection
        let pageRoute = session.route
        let element = selection.map(Self.turnElement) ?? StudioPrompts.pageElement(pageRoute)
        // An answer to the assistant's question is what the person just said; the question itself stays in the thread.
        let turn = StudioSession.PendingTurn(kind: .edit, request: clarification ?? request, element: element, attachments: pending?.attachedImages ?? [])
        let newImages = attachments.map(\.data)
        session.runWork("Working on the request", pending: turn) { session in
            let (revision, snapshot) = await StudioRevisionProbe.compute(root: session.root, editorBuffers: session.editorBuffers())
            var operation = pending ?? StudioOperation(id: session.historyStore.newOperationID(), kind: .edit, request: request, status: .applied)
            operation.destinationScreen = destination
            operation.status = .applied
            operation.question = nil
            operation.options = []
            operation.selection = element
            operation.scenarioId = session.scenario.id
            operation.baseRevision = revision
            // The images of the request: those of the turn being answered, then the ones just attached, saved now.
            var attached = operation.attachedImages
            if !newImages.isEmpty {
                do {
                    attached += try await Self.saveAttachments(newImages, root: session.root)
                } catch {
                    operation.status = .failed
                    operation.answer = "The attached images could not be saved, so the request was not sent: \(error.localizedDescription)"
                    return session.historyStore.append(operation)
                }
                operation.attachments = attached
                session.pendingTurn?.attachments = attached
            }
            // Only files that are there are sent: an image of an earlier turn may have been deleted since.
            let sentImages = attached.filter { StudioStore.isAttachmentPath($0) && FileManager.default.fileExists(atPath: session.root.appendingPathComponent($0).path) }
            // Without a selection the assistant sees the page as it is.
            var pageImage = selection == nil ? await self.pagePicture() : nil
            var retryProblem: String?
            var refusedContext: [String]?
            var trialFailure: String?
            var contextValidationRetries = 0
            var restored = false
            for attempt in 1...3 {
                session.busyDetail = attempt == 1 ? "The assistant is reading the project"
                    : refusedContext != nil ? "The assistant is correcting its context change" : "The assistant is correcting its edits"
                // The history includes a clarification being answered: its turn says what the assistant asked.
                var call = CLICompletion.Request(project: session.root,
                                                 prompt: StudioPrompts.editPrompt(request, selection: selection, scenario: session.scenario,
                                                                                  revision: revision, history: session.conversation,
                                                                                  redactor: session.redactor, clarification: clarification,
                                                                                  retryProblem: retryProblem, route: pageRoute,
                                                                                  pageImage: pageImage, spec: session.spec,
                                                                                  refusedContext: refusedContext,
                                                                                  reached: session.servedRules, attachments: sentImages,
                                                                                  supabaseAuth: session.simulator.authMock != nil && !session.hasRealSupabase,
                                                                                  supabaseAuthReal: session.hasRealSupabase),
                                                 systemPrompt: StudioPrompts.editSystem, jsonSchema: StudioPrompts.editSchema,
                                                 readableFolder: session.root)
                let shownImage = refusedContext != nil ? (pageImage ?? selection?.imagePath) : (selection?.imagePath ?? pageImage)
                call.images = shownImage.map { [URL(fileURLWithPath: $0)] } ?? []
                call.images += sentImages.map { session.root.appendingPathComponent($0) }
                call.timeout = 900
                call.effort = "medium"
                call.label = "ui-studio:edit"
                let plan: StudioEditPlan
                do {
                    // One ask of the request box; what the loop around it does with the answer (a trial on the live page, edits written to
                    // the project) cannot run inside a validator.
                    let asking = AIOperation<CLICompletion.Request, StudioEditPlan?>(
                        name: "ui-studio:edit",
                        parse: { StudioPrompts.editPlan(from: $0.structured) },
                        onResult: { [weak session] result in session?.recordUsage(result.inputTokens, result.outputTokens, result.costUSD ?? 0) })
                    let (answered, _) = try await asking.execute(call, onActivity: { activity in
                        Task { @MainActor in session.progress(activity) }
                    })
                    guard let parsed = answered else {
                        operation.status = .failed
                        operation.answer = "The assistant's answer was not a set of edits."
                        return session.historyStore.append(operation)
                    }
                    plan = parsed
                } catch is CancellationError {
                    return
                } catch {
                    operation.status = .failed
                    operation.answer = error.localizedDescription
                    return session.historyStore.append(operation)
                }
                if plan.needsClarification && clarification == nil {
                    operation.kind = plan.kind == .context ? .context : .edit
                    operation.scope = plan.scope
                    operation.scopeNote = plan.scopeNote
                    operation.summary = plan.summary
                    operation.status = .clarification
                    operation.question = plan.question
                    operation.options = plan.options
                    return session.historyStore.append(operation)
                }
                if let failure = trialFailure, plan.kind != .context {
                    operation.kind = .context
                    operation.status = .failed
                    operation.answer = "The requested page was not reached, so the new scenario was not saved: " + failure
                    let explanation = plan.answer.isEmpty ? plan.summary : plan.answer
                    if !explanation.isEmpty { operation.answer += "\n\n" + explanation }
                    return session.historyStore.append(operation)
                }
                if destination != nil && plan.kind != .context {
                    operation.kind = .context
                    operation.status = .failed
                    operation.answer = "The selected screen was not opened: the assistant did not propose a scenario change."
                    return session.historyStore.append(operation)
                }
                switch plan.kind {
                case .answer:
                    operation.kind = .question
                    operation.status = .answered
                    operation.answer = plan.answer.isEmpty ? plan.summary : plan.answer
                    let after = await StudioRevisionProbe.compute(root: session.root, editorBuffers: session.editorBuffers()).0
                    operation.finalRevision = after
                    operation.checks = [StudioCheck(name: "Project files unchanged", passed: after.id == revision.id,
                                                    detail: after.id == revision.id ? "" : "The working tree changed while the request ran; the assistant itself had read-only access.")]
                    return session.historyStore.append(operation)
                case .context:
                    var context = plan.context ?? StudioContextPlan(structured: nil)
                    if let destination {
                        context.expectedPath = destination.expectedPath ?? ""
                        context.expectedSelector = destination.selector
                    }
                    // A scenario may name a request that has no rule yet (the page failed before it asked): the rule is prepared once, not refused.
                    for request in StudioContextValidator.unservedRequests(context.overrides, spec: session.spec).prefix(3) {
                        guard !Task.isCancelled, !session.closed else { return }
                        _ = await session.requestPath.prepareNamedRequest(method: request.method, path: request.path)
                    }
                    var problems = StudioContextValidator.problems(context, current: session.scenario, spec: session.spec)
                    // Giving up on data the application can change is asked about once, and never blocks a second answer.
                    if contextValidationRetries == 0 {
                        problems += StudioContextValidator.givenUpProblems(context, current: session.scenario, spec: session.spec)
                    }
                    if problems.isEmpty {
                        if (!context.expectedPath.isEmpty || !context.expectedSelector.isEmpty), let failure = await self.tryContext(context, request: operation.request) {
                            guard !Task.isCancelled, !session.closed else { return }
                            if trialFailure == nil {
                                let attemptedSteps = context.steps.map { step in
                                    step.action.rawValue + (step.selector.map { " " + $0 } ?? "")
                                        + (step.action == .navigate ? (step.text.map { " " + $0 } ?? "") : "")
                                }.joined(separator: "; ")
                                let attempted = "The attempted starting route was \(context.route.isEmpty ? session.scenario.route : context.route); steps: \(attemptedSteps)."
                                trialFailure = failure.problem
                                refusedContext = [failure.problem, session.redactor.redact(text: attempted)]
                                if let image = failure.image { pageImage = image }
                                retryProblem = nil
                                continue
                            }
                            operation.kind = .context
                            operation.status = .failed
                            operation.summary = plan.summary
                            operation.answer = "The requested page was not reached, so the new scenario was not saved: " + failure.problem
                            operation.context = StudioContextChange(previousScenarioId: session.scenario.id,
                                                                    previousScenarioName: session.scenario.name,
                                                                    unsupported: context.unsupported)
                            return session.historyStore.append(operation)
                        }
                        return await self.applyContext(context, operation: operation, summary: plan.summary, snapshot: snapshot,
                                                          selection: selection)
                    }
                    if contextValidationRetries == 0 {
                        contextValidationRetries += 1
                        refusedContext = problems
                        retryProblem = nil
                        continue
                    }
                    operation.kind = .context
                    operation.status = .failed
                    operation.summary = plan.summary
                    operation.answer = "The context change was refused, so the scenario did not change: "
                        + problems.prefix(5).joined(separator: " ") + (problems.count > 5 ? " (and \(problems.count - 5) more)" : "")
                    operation.context = StudioContextChange(previousScenarioId: session.scenario.id, previousScenarioName: session.scenario.name,
                                                            unsupported: context.unsupported)
                    return session.historyStore.append(operation)
                case .code:
                    break
                }
                operation.scope = plan.scope
                operation.scopeNote = plan.scopeNote
                operation.summary = plan.summary
                operation.changeKind = plan.changeKind
                operation.changeReason = plan.changeReason.isEmpty ? nil : plan.changeReason
                if plan.edits.isEmpty {
                    operation.status = .answered
                    operation.answer = plan.scope == .recordData
                        ? "The text comes from the simulated data of one record, not from the source code. " + plan.summary
                        : (plan.summary.isEmpty ? "The assistant proposed no change." : plan.summary)
                    return session.historyStore.append(operation)
                }
                if !restored {
                    // The scenario's baseline and its picture before anything is written.
                    restored = true
                    session.busyDetail = "Restoring the scenario"
                    _ = await session.restore()
                    if let previous = selection, session.selection == nil {
                        await session.elementPicker.revalidateSelection(previous, afterEdit: false)
                        if let current = session.selection { selection = current }
                    }
                    operation.beforeCapture = await session.captureStore.capture(label: "Before: " + String(request.prefix(60)))?.id
                }
                do {
                    let unsaved = Set(session.editorBuffers().keys)
                    let changes = try await StudioChanges.plan(plan.edits, snapshot: snapshot, unsavedNow: unsaved)
                    let root = session.root
                    try await Task.detached { try StudioChanges.write(changes, root: root) }.value
                    operation.files = changes
                    retryProblem = nil
                    break
                } catch StudioChangeError.conflict(let paths) {
                    operation.status = .conflict
                    operation.conflict = StudioChangeError.conflict(paths).localizedDescription
                    return session.historyStore.append(operation)
                } catch let error as StudioChangeError where attempt == 1 {
                    retryProblem = error.localizedDescription
                    refusedContext = nil
                } catch {
                    operation.status = .failed
                    operation.answer = error.localizedDescription
                    return session.historyStore.append(operation)
                }
            }
            guard !operation.files.isEmpty else {
                operation.status = .failed
                operation.answer = retryProblem ?? "No edit could be applied."
                return session.historyStore.append(operation)
            }
            operation.patch = await StudioChanges.unifiedDiff(operation.files)
            session.historyStore.append(operation)
            await self.verify(&operation, previous: selection, label: "After: " + String(request.prefix(60)))
            await session.trackChange(&operation)
            session.historyStore.replace(operation)
        }
    }

    /// Answers the assistant's question and runs the change with it. The images of the request are sent again, with any the
    /// person added to the answer.
    func answerClarification(_ operation: StudioOperation, choice: String, attachments: [ImageAttachment] = []) {
        // The question being answered belongs to the conversation.
        session.historyStore.rejoinConversation(operation.id)
        let answer = choice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attachments.isEmpty ? StudioPrompts.imageOnlyAnswer : choice
        change(operation.request, attachments: attachments, clarification: answer, replacing: operation)
    }

    /// Saves the PNG images of a request under `.dde/studio/attachments/` (ignored by Git) and returns their project-relative
    /// paths, in order. When one cannot be written, the ones written before it are removed again.
    private static func saveAttachments(_ pngs: [Data], root: URL) async throws -> [String] {
        try await Task.detached {
            StudioStore.prepareLocalFolder(root)
            var written: [URL] = []
            do {
                for png in pngs { written.append(try ImageAttachments.save(png, into: StudioStore.attachmentsFolder(root))) }
            } catch {
                for url in written { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            return written.map { StudioStore.attachmentsPath + "/" + $0.lastPathComponent }
        }.value
    }

    /// A picture of the page as it is, for a request made without a selection (DEC-010). It is overwritten by the next one.
    private func pagePicture() async -> String? {
        _ = try? await session.call("return window.__markviewStudio.prepareCapture();")
        let image = await session.snapshot(nil)
        _ = try? await session.call("return window.__markviewStudio.finishCapture();")
        guard let image else { return nil }
        let root = session.root, file = StudioStore.selectionFolder(root).appendingPathComponent("page.png")
        let written = await Task.detached { () -> Bool in
            StudioStore.prepareLocalFolder(root)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            return StudioImageDiff.writePNG(image, to: file)
        }.value
        return written ? file.path : nil
    }

    /// Try a requested destination before saving it. A failed attempt is shown to the assistant for one correction; the
    /// original scenario is restored and no temporary scenario is written to the project.
    private func tryContext(_ plan: StudioContextPlan, request: String) async -> (problem: String, image: String?)? {
        let previous = session.scenario, previousSteps = session.recordedSteps
        let candidate = StudioContextValidator.scenario(plan, from: previous, spec: session.spec, request: request, taken: session.savedScenarios + session.presets)
        tryingScenario = true
        session.switchScenario(to: candidate, keepingRecordedSteps: true)
        session.busyDetail = "Checking that the requested page opens"
        let problem = await session.restore()
        let picture = problem == nil ? nil : await pagePicture()
        session.switchScenario(to: previous, keepingRecordedSteps: true)
        tryingScenario = false
        _ = await session.restore()
        session.recordedSteps = previousSteps
        if let problem { return (problem, picture) }
        return nil
    }

    /// Applies a checked context change (REQ-013, DEC-009): the new scenario derived from the current one is saved, made the
    /// active one and restored, and the turn records what changed and what could not be done. No source file is written;
    /// Undo returns to the scenario it was made from.
    private func applyContext(_ plan: StudioContextPlan, operation start: StudioOperation, summary: String,
                              snapshot: StudioWorkingSnapshot, selection: StudioSelectionContext?) async {
        var operation = start
        operation.kind = .context
        operation.summary = summary.isEmpty ? plan.description : summary
        let current = session.scenario
        let next = StudioContextValidator.scenario(plan, from: current, spec: session.spec, request: operation.request,
                                                   taken: session.savedScenarios + session.presets)
        var change = StudioContextValidator.change(from: current, to: next, spec: session.spec,
                                                   unsupported: plan.unsupported + StudioContextValidator.notes(plan, spec: session.spec))
        guard change.changesAnything else {
            // Nothing to show differently: no scenario is made.
            change.previous = nil
            change.scenarioId = ""
            change.scenarioName = ""
            operation.context = change
            operation.status = .answered
            if operation.summary.isEmpty { operation.answer = "Nothing in the scenario needed to change." }
            return session.historyStore.append(operation)
        }
        session.busyDetail = "Saving the new scenario"
        let root = session.root
        do {
            session.savedScenarios = try await Task.detached { () throws -> [StudioScenario] in
                try StudioStore.saveScenario(next, root: root)
                return StudioStore.loadScenarios(root)
            }.value
        } catch {
            operation.status = .failed
            operation.answer = "The new scenario could not be saved, so the scenario did not change: \(error.localizedDescription)"
            change.scenarioId = ""
            change.previous = nil
            operation.context = change
            return session.historyStore.append(operation)
        }
        operation.beforeCapture = await session.captureStore.capture(label: "Before: " + String(operation.request.prefix(60)))?.id
        operation.context = change
        operation.scenarioId = next.id
        operation.status = .applied
        session.switchScenario(to: next)
        session.historyStore.append(operation)
        session.busyDetail = "Restoring the new scenario"
        let problem = await session.restore()
        let errors = session.events.filter { $0.kind == .runtimeError && $0.generation == session.simulator.generation }
        let (revision, after) = await StudioRevisionProbe.compute(root: root, editorBuffers: session.editorBuffers())
        let pageLoaded = problem == nil || problem?.hasPrefix("Restoration step") == true
        var checks = [StudioCheck(name: "Scenario saved", passed: true, detail: ".markview/studio/scenarios/\(StudioStore.safeID(next.id)).json"),
                      StudioCheck(name: "Page loaded in the new scenario", passed: pageLoaded, detail: pageLoaded ? next.name : problem ?? "")]
        if !next.steps.isEmpty { checks.append(StudioCheck(name: "Restoration steps replayed", passed: problem == nil, detail: problem ?? "")) }
        if next.expectedPath != nil || next.expectedSelector != nil {
            let reached = problem == nil
            let expected = session.redactor.redact(text: [next.expectedPath, next.expectedSelector].compactMap { $0 }.joined(separator: " · "))
            checks.append(StudioCheck(name: "Requested page reached", passed: reached, detail: reached ? expected : problem ?? "Expected " + expected))
            if !reached { operation.status = .failed; operation.answer = problem ?? "The requested page was not reached." }
        }
        checks.append(StudioCheck(name: "No runtime errors", passed: errors.isEmpty,
                                  detail: errors.prefix(3).map { String($0.detail.prefix(300)) }.joined(separator: "\n")))
        let same = StudioContextValidator.sameSources(snapshot, after)
        checks.append(StudioCheck(name: "Project files unchanged", passed: same,
                                  detail: same ? "" : "The working tree changed while the request ran; the context change itself writes no source file."))
        operation.checks = checks
        if checks.contains(where: { !$0.passed }) {
            operation.status = .failed
            if operation.answer.isEmpty {
                operation.answer = "The scenario was saved, but verification failed: "
                    + checks.filter { !$0.passed }.map { $0.name + ($0.detail.isEmpty ? "" : ": " + $0.detail) }.joined(separator: "\n")
            }
        }
        operation.finalRevision = revision
        if pageLoaded, let capture = await session.captureStore.capture(label: "After: " + String(operation.request.prefix(60)), operationId: operation.id) {
            operation.afterCapture = capture.id
        }
        if let selection { await session.elementPicker.revalidateSelection(selection, afterEdit: true) }
        await session.trackContextChange(&operation)
        session.historyStore.replace(operation)
    }

    /// Undo of a context change (REQ-013): the scenario it was made from is active again and the turn is marked undone. The
    /// new scenario is never deleted; it stays saved in the Scenario menu.
    private func undoContext(_ operation: StudioOperation) {
        guard let change = operation.context, !change.scenarioId.isEmpty, [.applied, .kept, .failed].contains(operation.status) else { return }
        guard let previous = change.previous ?? (session.savedScenarios + session.presets).first(where: { $0.id == change.previousScenarioId }) else {
            session.notice = "The scenario \(change.previousScenarioName) is no longer available."
            return
        }
        session.runWork("Returning to the previous scenario") { session in
            session.switchScenario(to: previous)
            _ = await session.restore()
            var next = operation
            next.status = .undone
            session.trackUndo(next)
            session.historyStore.replace(next)
            session.notice = "Back to \(previous.name). \(change.scenarioName) stays saved in the Scenario menu."
        }
    }

    /// Waits for the rebuilt application, restores the scenario and records the checks (EDIT-08, AC-15).
    private func verify(_ operation: inout StudioOperation, previous: StudioSelectionContext?, label: String) async {
        session.busyDetail = "Waiting for the application to rebuild"
        let mark = session.server?.output.count ?? 0
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        session.busyDetail = "Restoring the scenario"
        let problem = await session.restore()
        let logErrors = serverErrors(since: mark)
        let errors = session.events.filter { $0.kind == .runtimeError && $0.generation == session.simulator.generation }
        var checks = [StudioCheck(name: "Application rebuilt and reloaded", passed: session.buildError == nil && logErrors == nil,
                                  detail: session.buildError ?? logErrors ?? "")]
        checks.append(StudioCheck(name: "Scenario restored", passed: problem == nil, detail: problem ?? session.scenario.name))
        checks.append(StudioCheck(name: "No runtime errors", passed: errors.isEmpty,
                                  detail: errors.prefix(3).map { String($0.detail.prefix(300)) }.joined(separator: "\n")))
        operation.checks = checks
        operation.finalRevision = await StudioRevisionProbe.compute(root: session.root, editorBuffers: session.editorBuffers()).0
        if session.buildError == nil && logErrors == nil {
            session.stalePreview = nil
            if let after = await session.captureStore.capture(label: label, operationId: operation.id) { operation.afterCapture = after.id }
            if let previous { await session.elementPicker.revalidateSelection(previous, afterEdit: true) }
        } else {
            session.buildError = session.buildError ?? logErrors
            if session.stalePreview == nil, let before = operation.beforeCapture { session.stalePreview = session.captures.first { $0.id == before } }
            session.updateReadiness()
        }
        await session.revalidatePackages()
    }

    private func serverErrors(since mark: Int) -> String? {
        guard let output = session.server?.output, output.count > mark else { return nil }
        return Self.buildFailure(in: String(output.suffix(output.count - mark))).map { session.redactor.redact(text: $0) }
    }

    /// The first line of a dev server's log that reports a failed build, or nil. Only compile and bundle
    /// failures count: an application that built also logs errors (a handled `console.error`, a failed
    /// request, a runtime exception), and those are not a reason to call the preview stale.
    nonisolated static func buildFailure(in log: String) -> String? {
        let markers = [
            #"failed to compile"#, #"module not found"#, #"cannot find module"#, #"failed to resolve import"#,
            #"module build failed"#, #"(?-i:^\s*ERROR in )"#, #"✘ \[ERROR\]"#, #"\berror TS\d+"#,
            #"\[vite\] internal server error"#, #"\[plugin:[^\]]+\]"#, #"parsing \S+ source code failed"#,
            #"SyntaxError: \S+\.(?:[cm]?[jt]sx?|vue|svelte|astro)\b"#, #"^\s*syntax error\s*$"#,
        ]
        let pattern = "(?im)^.*(?:" + markers.joined(separator: "|") + ").*$"
        guard let range = log.range(of: pattern, options: .regularExpression) else { return nil }
        return String(log[range]).trimmingCharacters(in: .whitespaces)
    }

    /// Selective undo (EDIT-07, AC-14): the operation's reverse change is merged into the files as they are now; later
    /// independent edits stay. Overlapping edits are a conflict, shown for resolution, and nothing is written.
    func undo(_ id: String) {
        if let operation = session.history.first(where: { $0.id == id }), operation.kind == .context { return undoContext(operation) }
        guard let operation = session.history.first(where: { $0.id == id }), operation.kind == .edit, !operation.files.isEmpty,
              [.applied, .kept, .conflict].contains(operation.status) else { return }
        session.runWork("Undoing the change") { session in
            var plans: [StudioChanges.UndoPlan] = []
            for change in operation.files { plans.append(await StudioChanges.undoPlan(change, root: session.root)) }
            let unsaved = Set(session.editorBuffers().keys)
            var conflicts: [(path: String, merged: String)] = []
            var writes: [StudioFileChange] = []
            for plan in plans {
                switch plan {
                case .clean(let path, let text):
                    if unsaved.contains(path) {
                        conflicts.append((path, "The file has unsaved changes in the editor. Save or revert them, then undo again."))
                    } else {
                        let current = try? String(contentsOf: session.root.appendingPathComponent(path), encoding: .utf8)
                        writes.append(StudioFileChange(path: path, before: current, after: text))
                    }
                case .conflict(let path, let merged, _):
                    conflicts.append((path, merged))
                case .unchanged:
                    break
                }
            }
            var next = operation
            guard conflicts.isEmpty else {
                self.undoConflicts[id] = conflicts
                next.status = .conflict
                next.conflict = "Undo overlaps later changes in " + conflicts.map(\.path).joined(separator: ", ")
                    + ". Nothing was written; resolve the conflict or keep the change."
                return session.historyStore.replace(next)
            }
            do {
                let root = session.root
                try await Task.detached { try StudioChanges.write(writes, root: root) }.value
            } catch {
                session.notice = error.localizedDescription
                return
            }
            self.undoConflicts[id] = nil
            next.status = .undone
            next.conflict = nil
            await self.verify(&next, previous: session.selection, label: "After undo: " + String(operation.request.prefix(50)))
            session.trackUndo(next)
            session.historyStore.replace(next)
        }
    }

    /// Writes an undo conflict into its files with conflict markers, so it can be resolved in the editor (AR-13).
    func resolveUndoConflictInEditor(_ id: String) {
        guard let conflicts = undoConflicts[id] else { return }
        var failed: [(path: String, merged: String)] = []
        var firstError: String?
        for conflict in conflicts where conflict.merged.contains("<<<<<<<") {
            guard let url = StudioChanges.validatedURL(conflict.path, root: session.root) else {
                failed.append(conflict)
                if firstError == nil { firstError = "Invalid conflict path: \(conflict.path)" }
                continue
            }
            do {
                try AtomicFile.write(conflict.merged, to: url)
                session.openFile(url)
            } catch {
                failed.append(conflict)
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        if failed.isEmpty {
            undoConflicts[id] = nil
            session.notice = "The conflict markers are in the files; resolve them in the editor."
        } else {
            undoConflicts[id] = failed
            session.notice = "Could not write conflict markers to \(failed.map(\.path).joined(separator: ", ")): \(firstError ?? "write failed")."
        }
    }

    init(session: StudioSession) {
        self.session = session
    }
}
