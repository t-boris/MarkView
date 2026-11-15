import AppKit
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What a change to a research map file came to.
enum ResearchMapChange {
    /// The file and the tab that holds it now have this text.
    case done(String)
    /// A rule refused the change (its reason is one line); nothing changed.
    case rejected(String)
    /// The file is not a readable research map (the reason is one line); nothing changed.
    case unreadable(String)
}

/// The text a tab holds for a file, and whether the person has unsaved edits in it.
struct ResearchTabText {
    var text: String
    var isModified: Bool
}

/// What the research features read of the window and do to its tabs and files. `WorkspaceManager` conforms: the maps and the jobs
/// never see the window itself.
@MainActor
protocol ResearchHost: AnyObject, Sendable {
    /// The tab that holds `file`: its text (unsaved edits included) and whether it has unsaved edits; nil when no tab holds it.
    func researchTab(for file: URL) -> ResearchTabText?
    /// The tab that holds `file` takes `text` as what is saved on disk.
    func researchTabSaved(_ file: URL, text: String)
    /// The file of the editor tab a message from the page belongs to (`documentID` nil: the selected tab); nil when that tab is
    /// gone or is not a file.
    func researchEditorFile(documentID: UUID?, event: String) -> URL?
    /// Edits saved in another editor appear in the open tabs.
    func researchWatchOpenFiles()
    func openFile(_ url: URL)
    func openFile(_ url: URL, line: Int?, endLine: Int?)
    func refreshFileTree()
    /// Before a research job reads `file`: unsaved edits in its tab are saved, or the person cancels. True when the disk is current.
    func saveBeforeResearch(_ file: URL, action: String) -> Bool
    /// A research job rewrote `file` on disk: its tab shows the new text; a tab with unsaved edits gets `applyToEdited` applied.
    func researchDocumentChanged(_ file: URL, content: String, applyToEdited: (String) -> String?)
}

/// The research maps of one window (feature mind-map, DEC-006, DEC-009): the single writer of a map file, the snapshot the page
/// draws, the actions the page sends, and the AI jobs that work on maps and research documents (`jobs`). It owns what a job
/// hands to the next snapshot (the node it added, the notice it ends with) and the PDF renderer of the editor page. The window
/// is reached only through `ResearchHost` and the open project through `ProjectProviding` (its folder, and its database where the
/// assistant's runs are recorded); the jobs' tasks are in the window's `TaskBag`.
@MainActor
final class ResearchMapController {
    /// The answer to a map action: the snapshot for the page and the text the tab holds now.
    struct Reply {
        var json: String
        var content: String?
    }

    private(set) weak var host: ResearchHost?
    private let project: any ProjectProviding
    private let tasks: TaskBag

    /// The jobs bar of the window: new research, follow-ups, comments and the map jobs.
    private(set) lazy var jobs = ResearchJobs(host: host, project: project, maps: self, tasks: tasks)

    /// The id of the node an AI job just added to a map (by map path); the next snapshot of that map carries it to the page.
    var jobCreated: [String: String] = [:]
    /// What an AI job tells the person when it ends (by map path); the next snapshot of that map carries it to the page as a notice.
    var jobNotice: [String: String] = [:]
    /// Set by the editor view: makes the PDF of a report (Markdown, file name) with the editor page's renderer and asks where to save it.
    var pdfExporter: ((String, String) -> Bool)?

    init(host: ResearchHost, project: any ProjectProviding, tasks: TaskBag) {
        self.host = host
        self.project = project
        self.tasks = tasks
    }

    // MARK: - The map file

    /// The current text of a map file: the tab that holds it (unsaved edits included), else the disk.
    func text(of file: URL) -> String? {
        if let tab = host?.researchTab(for: file) { return tab.text }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// Applies `change` to the map in `file` and writes the file at once, atomically. The tab that holds the
    /// file takes the new text as saved, so a map is never shown as modified. A refused change leaves the
    /// file and the tab as they were. The only writer of a map: the page's actions and the AI jobs go here.
    @discardableResult
    func update(_ file: URL, _ change: (inout ResearchMap) throws -> Void) -> ResearchMapChange {
        guard FileManager.default.fileExists(atPath: file.path) else { return .unreadable("The map file no longer exists.") }
        guard var text = self.text(of: file) else { return .unreadable("The file cannot be read.") }
        // A tab without unsaved edits may be behind the disk (another editor or a terminal saved the map less than
        // the watcher's two seconds ago): the change goes onto what is on disk, never over it.
        if let tab = host?.researchTab(for: file), !tab.isModified,
           let onDisk = try? String(contentsOf: file, encoding: .utf8), onDisk != text {
            text = onDisk
        }
        var map: ResearchMap
        switch ResearchMap.parse(text) {
        case .success(let parsed): map = parsed
        case .failure(let problem): return .unreadable(problem.message)
        }
        do {
            try change(&map)
        } catch let rejection as ResearchMap.Rejection {
            return .rejected(rejection.message)
        } catch {
            return .rejected(error.localizedDescription)
        }
        let updated = map.markdown()
        guard updated != text else {
            // The tab may still show older text than the disk (see above): bring it up to date without a write.
            if let tab = host?.researchTab(for: file), tab.text != text, !tab.isModified { host?.researchTabSaved(file, text: text) }
            return .done(text)
        }
        do {
            try AtomicFile.write(Data(updated.utf8), to: file)
        } catch {
            return .rejected("The map could not be saved: \(error.localizedDescription)")
        }
        host?.researchTabSaved(file, text: updated)
        return .done(updated)
    }

    // MARK: - The page

    /// The snapshot the page draws for `text`, with the AI job working on `file`.
    func snapshotJSON(text: String, file: URL, created: String = "", notice: String = "") -> String {
        // A node an AI job added (Draw): the first snapshot after it tells the page to show and select the node.
        let created = created.isEmpty ? (jobCreated.removeValue(forKey: file.standardizedFileURL.path) ?? "") : created
        let notice = notice.isEmpty ? (jobNotice.removeValue(forKey: file.standardizedFileURL.path) ?? "") : notice
        // `markdown` is the text of the tab: the page shows it in the Source view of the map document.
        var snapshot: [String: Any]
        switch ResearchMap.parse(text) {
        case .success(let map):
            snapshot = map.snapshot(job: jobs.mapJobInfo(for: file), created: created, notice: notice)
        case .failure(let problem):
            snapshot = ResearchMap.unreadableSnapshot(problem: problem.message)
        }
        snapshot["markdown"] = text
        return ResearchMap.json(snapshot)
    }

    /// One action of the map view (bridge message "researchMap"). Validation of every field happens here, at
    /// the boundary; the rules of the map itself are in `ResearchMap`. Returns the answer for the page, or nil
    /// when the tab the page names is gone.
    /// `carriedNotice`: a one-line message that is already known (the result of a picture saved off the main thread).
    func handleAction(_ action: String, payload: [String: Any], documentID: UUID?, carriedNotice: String = "") -> Reply? {
        // The action name comes from the page: it is logged only as plain letters.
        let loggedAction = String(action.filter { $0.isLetter }.prefix(24))
        guard let file = host?.researchEditorFile(documentID: documentID, event: "research map \(loggedAction)") else { return nil }
        // Edits saved in another editor appear in the map: the watcher reloads the tab (DEC-006).
        host?.researchWatchOpenFiles()
        settleInterrupted(file, stopping: action == "cancel")

        func string(_ key: String) -> String { (payload[key] as? String) ?? "" }
        func integer(_ key: String) -> Int? {
            guard let value = (payload[key] as? NSNumber)?.doubleValue, value.isFinite, abs(value) < 1e9 else { return nil }
            return Int(value.rounded())
        }
        /// An integer that may be cleared: absent leaves it alone, null clears it, a number sets it. Anything else
        /// becomes 0, which the map refuses with its own message.
        func clearableInteger(_ key: String) -> Int?? {
            guard let raw = payload[key] else { return nil }
            if raw is NSNull { return .some(nil) }
            return .some(integer(key) ?? 0)
        }
        var created = ""
        var notice = carriedNotice
        var change: ResearchMapChange?

        switch action {
        case "snapshot":
            break
        case "addChild":
            change = update(file) { created = try $0.addChild(parent: string("parent"), title: string("title")) }
        case "update":
            // A number, a width and a height are set with an integer and cleared with null; an absent key leaves it alone.
            let number = clearableInteger("number"), width = clearableInteger("width"), height = clearableInteger("height")
            change = update(file) { [number, width, height] map in
                try map.update(id: string("id"),
                               title: payload["title"] as? String,
                               tags: payload["tags"] as? [String],
                               color: payload["color"] as? String,
                               description: payload["description"] as? String,
                               icon: payload["icon"] as? String,
                               image: payload["image"] as? String,
                               number: number,
                               shape: payload["shape"] as? String,
                               width: width,
                               height: height,
                               visual: payload["visual"] as? String)
            }
        case "numberChildren":
            let clear = (payload["clear"] as? Bool) ?? false
            change = update(file) { _ = try $0.numberChildren(of: string("id"), clear: clear) }
        case "delete":
            change = update(file) { _ = try $0.delete(id: string("id")) }
        case "move":
            // An arrow dragged from the new parent onto a node (REQ-015): the node and its subtree become the parent's last child.
            change = update(file) { try $0.move(id: string("id"), to: string("parent")) }
        case "moveVisual":
            guard let x = integer("x"), let y = integer("y") else {
                notice = "That position is not valid."
                break
            }
            change = update(file) { try $0.moveVisual(id: string("id"), x: x, y: y) }
        case "link":
            change = update(file) { try $0.link(string("from"), string("to")) }
        case "unlink":
            change = update(file) { $0.unlink(string("from"), string("to")) }
        case "layout":
            change = update(file) { try $0.applyLayout(id: string("id"), layout: string("layout")) }
        case "develop":
            // Expand topic: the direction is optional (empty: the assistant chooses the sub-topics).
            let direction = string("direction").trimmingCharacters(in: .whitespacesAndNewlines)
            notice = jobs.developMap(file: file, node: string("id"), direction: String(direction.prefix(2000))) ?? ""
        case "describe":
            notice = jobs.describeMap(file: file, node: string("id")) ?? ""
        case "correct":
            let note = string("note").trimmingCharacters(in: .whitespacesAndNewlines)
            if note.isEmpty {
                notice = "Say what is wrong with this node."
            } else {
                notice = jobs.correctMap(file: file, node: string("id"), note: String(note.prefix(2000))) ?? ""
            }
        case "investigate":
            notice = jobs.investigateMap(file: file, node: string("id")) ?? ""
        case "draw":
            notice = jobs.drawMap(file: file, node: string("id"), kindID: string("kind"), instruction: string("instruction")) ?? ""
        case "export":
            let kind = string("kind")
            guard kind == "markdown" || kind == "pdf" else {
                notice = "Choose Markdown report or PDF."
                break
            }
            notice = jobs.reportMap(file: file, kind: kind, language: string("language")) ?? ""
        case "translate":
            notice = jobs.translateMap(file: file, language: string("language"), mode: string("mode")) ?? ""
        case "continue":
            notice = jobs.continueMap(file: file) ?? ""
        case "cancel":
            jobs.cancelJobs(on: file)   // the map of a job that no longer exists was settled above
        case "open":
            notice = openSource(string("source")) ?? ""
        default:
            AppLog.workspace.debug("unknown research map action \(loggedAction)")
            return nil
        }

        switch change {
        case .rejected(let reason)?, .unreadable(let reason)?: notice = reason
        default: break
        }
        let current = self.text(of: file) ?? ""
        return Reply(json: snapshotJSON(text: current, file: file, created: created, notice: notice), content: current)
    }

    /// A picture the page was given for a node (chosen, dropped or pasted, REQ-017): saved into `images/` beside the map
    /// off the main thread, then set on the node through the map's single writer. Returns a one-line reason when it
    /// fails, or an empty text.
    func attachImage(_ payload: [String: Any], documentID: UUID?) async -> String {
        guard let file = host?.researchEditorFile(documentID: documentID, event: "research map attachImage") else { return "" }
        let id = (payload["id"] as? String) ?? ""
        let name = String(((payload["name"] as? String) ?? "").prefix(200))
        let encoded = (payload["data"] as? String) ?? ""
        guard !id.isEmpty else { return "That node no longer exists." }
        let stored = await Self.storeImage(base64: encoded, suggestedName: name, besideMap: file)
        switch stored {
        case .failure(let failure):
            return failure.message
        case .success(let path):
            // The tab may have been closed while the file was written: then the picture stays in images/ and nothing else happens.
            guard host?.researchTab(for: file) != nil else { return "" }
            switch update(file, { try $0.update(id: id, image: path) }) {
            case .rejected(let reason), .unreadable(let reason): return reason
            case .done: return ""
            }
        }
    }

    /// Blocking file work, run off the main actor: the caller's task waits for it.
    private nonisolated static func storeImage(base64: String, suggestedName: String, besideMap map: URL) async -> Result<String, ResearchMapImages.Failure> {
        ResearchMapImages.store(base64: base64, suggestedName: suggestedName, besideMap: map)
    }

    /// A map that says "researching" while no job of this window works on it was interrupted (the app quit
    /// mid-run, or the last update of a run could not be written): it becomes incomplete, so Continue is offered
    /// and Stop never does nothing.
    private func settleInterrupted(_ file: URL, stopping: Bool) {
        guard !jobs.isRunning(on: file), let text = self.text(of: file),
              case .success(let map) = ResearchMap.parse(text), map.status == .researching else { return }
        update(file) { $0.markIncomplete(stopping ? "stopped" : "the research was interrupted") }
    }

    /// Opens the source of a finding: a web address in the browser, a project file (with an optional
    /// `:line` or `:from-to` suffix) in a tab. Returns a one-line reason when it cannot.
    private func openSource(_ source: String) -> String? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text) else { return "That web address is not valid." }
            NSWorkspace.shared.open(url)
            return nil
        }
        guard let root = project.root?.standardizedFileURL else { return "No project is open." }
        var path = text
        var line: Int?
        var endLine: Int?
        if let match = text.range(of: #":(\d+)(?:-(\d+))?$"#, options: .regularExpression) {
            let numbers = text[match].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            line = numbers.first
            endLine = numbers.count > 1 ? numbers[1] : nil
            path = String(text[..<match.lowerBound])
        }
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return "Only files inside the project can be opened." }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return "The file \(path) does not exist in the project." }
        host?.openFile(url, line: line, endLine: endLine)
        return nil
    }
}
