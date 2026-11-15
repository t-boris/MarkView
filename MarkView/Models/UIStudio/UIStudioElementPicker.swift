import AppKit
import Foundation
import WebKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The person's way into the page (PRE-01..PRE-09): the mode (interact, select, record), the element picked in the page with its source,
/// route, scenario and code revision, and finding the same element again after the page reloaded. Owns the mode, the selection and the
/// loop that waits for the next pick.
@MainActor
final class StudioElementPicker: ObservableObject {
    unowned let session: StudioSession

    @Published var mode: StudioSession.Mode = .interact {
        // A page the application loads while recording (a link, a form, a reload) records too (BUG-071).
        didSet { if (oldValue == .record) != (mode == .record) { _ = session.installRuntime() } }
    }

    @Published var selection: StudioSelectionContext?

    private(set) var pickTask: Task<Void, Never>?

    func setMode(_ next: StudioSession.Mode) {
        guard next != mode else { return }
        if next == .record, let busy = session.busy {
            // Recording starts from a restored baseline, which waits for the current work.
            session.notice = "Wait for \(busy) to finish before recording."
            return
        }
        let previous = mode
        mode = next
        if previous == .record { Task { _ = try? await session.call("return window.__markviewStudio.setRecording(false);") } }
        switch next {
        case .interact:
            pickTask?.cancel()
            Task { _ = try? await session.call("return window.__markviewStudio && window.__markviewStudio.setSelecting(false);") }
        case .select:
            startPicking()
        case .record:
            pickTask?.cancel()
            // Steps are recorded from the scenario's baseline, so that replaying them rebuilds the same state.
            session.recordedSteps = []
            session.runWork("Restoring the scenario before recording") { session in
                _ = await session.restore()
                self.mode = .record
                _ = try? await session.call("return window.__markviewStudio.setRecording(true);")
            }
        }
    }

    func startPicking() {
        pickTask?.cancel()
        pickTask = Task { [weak self] in
            while let self, self.mode == .select, !Task.isCancelled {
                do {
                    let result = try await self.session.call("return window.__markviewStudio ? await window.__markviewStudio.pick() : undefined;")
                    guard self.mode == .select, !Task.isCancelled else { return }
                    if let object = result as? [String: Any] {
                        await self.adopt(object)
                    } else if result is NSNull {
                        // Escape in the page.
                        self.mode = .interact
                        return
                    } else {
                        try await Task.sleep(nanoseconds: 300_000_000)
                    }
                } catch {
                    // The page reloaded while selecting: pick again in the new page.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
    }

    func selectParent() {
        Task {
            guard let object = try? await session.call("return window.__markviewStudio.parent();") as? [String: Any] else { return }
            await adopt(object)
        }
    }

    func selectChild() {
        Task {
            guard let object = try? await session.call("return window.__markviewStudio.child();") as? [String: Any] else { return }
            await adopt(object)
        }
    }

    func clearSelection() {
        selection = nil
        Task { _ = try? await session.call("return window.__markviewStudio.clear();") }
    }

    /// The selection as the session keeps it (PRE-06…PRE-08): the source path checked against the project, the source
    /// around the mapped line, a picture of the element, the route, the scenario and the code revision.
    private func adopt(_ object: [String: Any]) async {
        guard var context = StudioSelectionContext(object) else {
            session.notice = "That element has no size to select."
            return
        }
        let root = session.root, appFolder = session.appFolder, origin = session.appOrigin
        let tagName = String(context.tag.prefix { $0.isLetter || $0.isNumber || $0 == "-" })
        let reported = context
        let resolved = await Task.detached { () -> StudioSourceResolution in
            // A bundled chunk (Turbopack, Next.js 16) is mapped to its source file through its source map (BUG-069).
            let mapped = await StudioSourceMap.mapped(reported, appOrigin: origin, root: root, appFolder: appFolder)
            return StudioSourceResolution.resolve(mapped, root: root, appFolder: appFolder, tagName: tagName)
        }.value
        context.sourcePath = resolved.path
        context.line = resolved.line
        context.snippet = resolved.snippet
        context.snippetHash = resolved.lineHash
        if resolved.mapping != context.mapping { context.mapping = resolved.mapping }
        if let note = resolved.note { context.boundary = [context.boundary, note].compactMap { $0 }.joined(separator: " ") }
        context.scenarioId = session.scenario.id
        context.imagePath = await selectionPicture(context)
        context.revision = await StudioRevisionProbe.compute(root: root, editorBuffers: session.editorBuffers()).0
        selection = context
    }

    private func selectionPicture(_ context: StudioSelectionContext) async -> String? {
        _ = try? await session.call("return window.__markviewStudio.prepareCapture();")
        let rect = CGRect(x: context.rect.x, y: context.rect.y, width: context.rect.width, height: context.rect.height)
            .intersection(session.webView.bounds)
        defer { Task { _ = try? await self.session.call("return window.__markviewStudio.finishCapture();") } }
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let image = await session.snapshot(rect) else { return nil }
        let folder = StudioStore.selectionFolder(session.root)
        StudioStore.prepareLocalFolder(session.root)
        let file = folder.appendingPathComponent("selection-\(context.id).png")
        let written = await Task.detached { StudioImageDiff.writePNG(image, to: file) }.value
        return written ? file.path : nil
    }

    /// The selection is found again after the page was reloaded (PRE-09, BUG-068): the same instance is kept, a moved source
    /// is remapped, an element that is not the same one is never taken in its place. The old selector is tried first; when
    /// it no longer leads to the element (the page is laid out differently), the page is searched for the element itself.
    /// `afterEdit` is the check after a change, which may have altered the element's classes and text.
    @discardableResult
    func revalidateSelection(_ previous: StudioSelectionContext, afterEdit: Bool) async -> Bool {
        func candidates(_ script: String, _ arguments: [String: Any]) async -> [StudioSelectionContext] {
            ((try? await session.call(script, arguments)) as? [[String: Any]] ?? []).compactMap { StudioSelectionContext($0) }
        }
        func position(of chosen: StudioSelectionContext, in list: [StudioSelectionContext]) -> Int {
            list.firstIndex { $0.rect == chosen.rect && $0.tag == chosen.tag && $0.sourceNodeId == chosen.sourceNodeId } ?? 0
        }
        let bySelector = await candidates("return window.__markviewStudio.candidates(selector);", ["selector": previous.selector])
        var decision = StudioSelectionRevalidation.decide(previous: previous, candidates: bySelector, afterEdit: afterEdit)
        var select: (script: String, arguments: [String: Any])?
        switch decision {
        case .kept(let next), .remapped(let next):
            select = ("return window.__markviewStudio.selectMatching(selector, index);",
                      ["selector": previous.selector, "index": position(of: next, in: bySelector)])
        case .cleared:
            let similar = await candidates("return window.__markviewStudio.similar(fingerprint);", ["fingerprint": previous.fingerprint])
            decision = StudioSelectionRevalidation.decide(previous: previous, candidates: similar, afterEdit: afterEdit)
            switch decision {
            case .kept(let next), .remapped(let next):
                select = ("return window.__markviewStudio.selectSimilar(fingerprint, index);",
                          ["fingerprint": previous.fingerprint, "index": position(of: next, in: similar)])
            case .cleared: break
            }
        }
        if case .cleared(let reason) = decision {
            selection = nil
            session.notice = reason + (afterEdit ? "" : " The change uses the element as it was selected; select it again to see it.")
            return false
        }
        guard let select, let object = try? await session.call(select.script, select.arguments) as? [String: Any] else {
            selection = nil
            return false
        }
        await adopt(object)
        selection?.revalidated = true
        return true
    }

    init(session: StudioSession) {
        self.session = session
    }
}
