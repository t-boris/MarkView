import Foundation

/// What an X-Ray tab's page asks for, parsed from its bridge message (`AR-14` step 11). The page sends an action name and a loose
/// payload; this turns them into one case with typed arguments, so what the page may ask is listed in one place and a request that is
/// malformed (a missing id, an unknown pull-request operation, no pull-request number) is dropped before it reaches a store.
/// `CodeAndXRayCoordinator` performs a command; nothing here knows a store, a tab or the window.
enum XRayCommand: Equatable {
    /// What the project's operations strip (Run, Open, Edit, discovery) can do; only the project's own X-Ray has the strip.
    enum Operation: Equatable {
        case run(id: String), open(id: String), edit(id: String), add
        case adopt(id: String), discover, cancelDiscovery, dismissReport
        case acceptProposal(index: Int), rejectProposal(index: Int), addUnknown(index: Int)
    }

    /// Opening a file from the page: the places inside it to show and, for Markdown, the text to scroll to.
    struct OpenFile: Equatable {
        var path: String
        var line: Int?
        var endLine: Int?
        var find: String?
        /// From the ⚡ search's answer: the viewer opens on the search's places in the file.
        var fromSearch: Bool
        /// From the PR X-Ray: the viewer opens on the change.
        var fromPR: Bool
    }

    /// An answer's source (document, pull request or commit) the person opened.
    struct Finding: Equatable {
        var path: String
        var index: Int
    }

    case operation(Operation)
    case openFile(OpenFile)
    case rescan
    case analyze
    case describeBook(path: String?)
    case recursiveInsight(path: String)
    case askBook(question: String)
    case cancelAnalysis
    case temporaryFilter(criterion: String)
    case openPRXRay(source: String?)
    case analyzePR(again: Bool)
    case historyCommits(day: String)
    case compareWithCommit(sha: String)
    case prFileDiff(path: String)
    case explainPRFile(path: String)
    case askPR(question: String, path: String?)
    case filterSearch(filter: String)
    case showPR(source: String)
    case reviewPR(again: Bool)
    case prTasksToTerminal
    case copyPRTasks
    case refreshPRSources
    case prAction(op: String, body: String, method: String)
    case prFindingFix(Finding)
    case prFixAll
    case prFindingExplain(Finding)
    case prFindingComment(Finding)
    case prFindingIssue(Finding)
    case prFindingDismiss(Finding)
    case openURL(URL)
    case setComponent(path: String, component: String)
    case rateImportance(view: String, parent: String, filter: String)
    case createFilter(name: String, criterion: String)
    case deleteFilter(id: String)
    case outlineFile(path: String)
    case saveSearchAnswer(filter: String)
    case retryUnderstanding(filter: String)
    case openUnderstandingSource(filter: String, source: String)
    case explainEdge(view: String, source: String, target: String, kind: String, label: String?, again: Bool)
    case refreshCode
    case traceCode(scope: String, question: String)
    case describe(view: String, id: String)

    /// The pull-request operations the page may ask for.
    static let prOperations: Set<String> = ["approve", "requestChanges", "comment", "merge", "close"]

    /// Whether the command may run for the X-Ray the active tab shows (`activeScope`: "" for the project's, a folder's path, the pull
    /// request's scope, nil when the active tab is no X-Ray). The operations strip belongs to the project's own X-Ray.
    func isAllowed(inScope activeScope: String?) -> Bool {
        if case .operation = self { return activeScope == "" }
        return true
    }

    /// The file a page's path names, relative to the X-Ray's folder or absolute. Only a file inside that folder or, for a folder
    /// X-Ray's answer, inside the open project qualifies.
    static func file(at path: String, root: URL, projectRoot: URL) -> URL? {
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).standardizedFileURL
        let inside = { (folder: URL) in url.path.hasPrefix(folder.standardizedFileURL.path + "/") }
        return inside(root) || inside(projectRoot) ? url : nil
    }

    /// The part (folder) or chapter (document) the book panel asked for, inside the X-Ray's folder and on disk; the folder itself for an
    /// empty path.
    static func insightTarget(_ relative: String, root: URL) -> URL? {
        let target = relative.isEmpty ? root : root.appendingPathComponent(relative).standardizedFileURL
        guard target.path == root.standardizedFileURL.path || target.path.hasPrefix(root.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: target.path) else { return nil }
        return target
    }

    /// The command a page message stands for, or nil for an unknown action or a request missing what it needs.
    static func parse(_ action: String, payload p: [String: Any]) -> XRayCommand? {
        func text(_ key: String) -> String { p[key] as? String ?? "" }
        func again() -> Bool { p["again"] as? Bool == true }
        func finding() -> Finding { Finding(path: text("path"), index: p["index"] as? Int ?? -1) }
        func id() -> String? { p["id"] as? String }
        func index() -> Int? { p["index"] as? Int }
        switch action {
        case "operationRun": return id().map { .operation(.run(id: $0)) }
        case "operationOpen": return id().map { .operation(.open(id: $0)) }
        case "operationEdit": return id().map { .operation(.edit(id: $0)) }
        case "operationAdd": return .operation(.add)
        case "operationAdopt": return id().map { .operation(.adopt(id: $0)) }
        case "operationDiscover": return .operation(.discover)
        case "operationCancelDiscovery": return .operation(.cancelDiscovery)
        case "operationDismissReport": return .operation(.dismissReport)
        case "operationAcceptProposal": return index().map { .operation(.acceptProposal(index: $0)) }
        case "operationRejectProposal": return index().map { .operation(.rejectProposal(index: $0)) }
        case "operationAddUnknown": return index().map { .operation(.addUnknown(index: $0)) }
        case "openFile":
            guard let path = p["path"] as? String, !path.isEmpty else { return nil }
            return .openFile(OpenFile(path: path, line: p["line"] as? Int, endLine: p["endLine"] as? Int, find: p["find"] as? String,
                                      fromSearch: p["fromSearch"] as? Bool == true, fromPR: p["fromPR"] as? Bool == true))
        case "rescan": return .rescan
        case "analyze": return .analyze
        case "describeBook": return .describeBook(path: p["path"] as? String)
        case "recursiveInsight": return .recursiveInsight(path: text("path"))
        case "askBook":
            // A question about the book, answered like "I need to understand": what, why, how, origin, with sources.
            let question = text("question").trimmingCharacters(in: .whitespacesAndNewlines)
            return question.isEmpty ? nil : .askBook(question: question)
        case "cancelAnalysis": return .cancelAnalysis
        case "tempFilter": return .temporaryFilter(criterion: text("criterion"))
        case "openPRXRay": return .openPRXRay(source: p["source"] as? String)
        case "openPRNumber":
            // "123", "#123" or a GitHub link ".../pull/123".
            let typed = text("text").trimmingCharacters(in: .whitespaces)
            let number = typed.range(of: #"(\d+)\s*$|pull/(\d+)"#, options: .regularExpression)
                .map { String(typed[$0]).filter(\.isNumber) } ?? ""
            return number.isEmpty ? nil : .openPRXRay(source: "gh:" + number)
        case "analyzePR": return .analyzePR(again: again())
        case "historyCommits": return .historyCommits(day: text("day"))
        case "compareWithCommit": return .compareWithCommit(sha: text("sha"))
        case "prFileDiff": return .prFileDiff(path: text("path"))
        case "explainPRFile": return .explainPRFile(path: text("path"))
        case "askPR":
            let path = p["path"] as? String
            return .askPR(question: text("question"), path: path?.isEmpty == true ? nil : path)
        case "filterSearch": return .filterSearch(filter: text("filter"))
        case "showPR": return .showPR(source: text("source"))
        case "reviewPR": return .reviewPR(again: again())
        case "prTasksToTerminal": return .prTasksToTerminal
        case "copyPRTasks": return .copyPRTasks
        case "refreshPRSources": return .refreshPRSources
        case "prAction":
            // op: approve | requestChanges | comment | merge | close; method: merge | squash | rebase.
            let op = text("op")
            guard prOperations.contains(op) else { return nil }
            return .prAction(op: op, body: text("body"), method: p["method"] as? String ?? "squash")
        case "prFindingFix": return .prFindingFix(finding())
        case "prFixAll": return .prFixAll
        case "prFindingExplain": return .prFindingExplain(finding())
        case "prFindingComment": return .prFindingComment(finding())
        case "prFindingIssue": return .prFindingIssue(finding())
        case "prFindingDismiss": return .prFindingDismiss(finding())
        case "openURL":
            // Only GitHub links, opened in the browser.
            guard let link = URL(string: text("url")), link.scheme == "https", link.host == "github.com" else { return nil }
            return .openURL(link)
        case "setComponent": return .setComponent(path: text("path"), component: text("component"))
        case "rateImportance":
            return .rateImportance(view: p["view"] as? String ?? "modules", parent: text("parent"),
                                   filter: p["filter"] as? String ?? "importance")
        case "createFilter": return .createFilter(name: text("name"), criterion: text("criterion"))
        case "deleteFilter": return .deleteFilter(id: text("id"))
        case "outlineFile":
            guard let path = p["path"] as? String, !path.isEmpty else { return nil }
            return .outlineFile(path: path)
        case "saveSearchAnswer": return .saveSearchAnswer(filter: text("filter"))
        case "retryUnderstanding": return .retryUnderstanding(filter: text("filter"))
        case "openUnderstandingSource": return .openUnderstandingSource(filter: text("filter"), source: text("source"))
        case "explainEdge":
            guard let source = p["source"] as? String, let target = p["target"] as? String else { return nil }
            return .explainEdge(view: p["view"] as? String ?? "modules", source: source, target: target,
                                kind: p["kind"] as? String ?? "uses", label: p["label"] as? String, again: again())
        case "refreshCode": return .refreshCode
        case "traceCode":
            guard let scope = p["scope"] as? String, let question = p["question"] as? String else { return nil }
            return .traceCode(scope: scope, question: question)
        case "describe": return .describe(view: p["view"] as? String ?? "modules", id: text("id"))
        default: return nil
        }
    }
}
