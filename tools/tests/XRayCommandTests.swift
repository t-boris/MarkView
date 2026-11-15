// What an X-Ray page may ask of the window (MarkView/Models/Architecture/XRayCommand.swift, AR-14 step 11): every action maps to its
// command with its arguments, a request that is malformed or unsafe is dropped before it reaches a store, the operations strip is
// reachable only from the project's own X-Ray, and a file or part the page names must lie inside the X-Ray's folder or the open
// project, on real folders. The dispatcher that performs a command needs the app's stores and is covered by the app probe.
import Foundation

@main enum XRayCommandTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
    }

    static func parse(_ action: String, _ payload: [String: Any] = [:]) -> XRayCommand? { XRayCommand.parse(action, payload: payload) }

    static func main() throws {
        routing()
        dropped()
        pullRequestNumber()
        scopes()
        try paths()
        print(failures == 0 ? "X-Ray command checks passed" : "\(failures) X-Ray command checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Each action reaches its command with its arguments

    static func routing() {
        check(parse("operationRun", ["id": "build"]) == .operation(.run(id: "build")), "operationRun carries the operation id")
        check(parse("operationOpen", ["id": "build"]) == .operation(.open(id: "build")), "operationOpen carries the operation id")
        check(parse("operationEdit", ["id": "build"]) == .operation(.edit(id: "build")), "operationEdit carries the operation id")
        check(parse("operationAdd") == .operation(.add), "operationAdd needs no payload")
        check(parse("operationAdopt", ["id": "d1"]) == .operation(.adopt(id: "d1")), "operationAdopt carries the discovered id")
        check(parse("operationDiscover") == .operation(.discover), "operationDiscover")
        check(parse("operationCancelDiscovery") == .operation(.cancelDiscovery), "operationCancelDiscovery")
        check(parse("operationDismissReport") == .operation(.dismissReport), "operationDismissReport")
        check(parse("operationAcceptProposal", ["index": 2]) == .operation(.acceptProposal(index: 2)), "operationAcceptProposal carries the index")
        check(parse("operationRejectProposal", ["index": 3]) == .operation(.rejectProposal(index: 3)), "operationRejectProposal carries the index")
        check(parse("operationAddUnknown", ["index": 0]) == .operation(.addUnknown(index: 0)), "operationAddUnknown carries the index")

        check(parse("openFile", ["path": "a/b.swift", "line": 7, "endLine": 9, "find": "x", "fromSearch": true, "fromPR": true])
              == .openFile(.init(path: "a/b.swift", line: 7, endLine: 9, find: "x", fromSearch: true, fromPR: true)),
              "openFile carries the places, the text to find and where the request came from")
        check(parse("openFile", ["path": "a.md"]) == .openFile(.init(path: "a.md", line: nil, endLine: nil, find: nil, fromSearch: false, fromPR: false)),
              "openFile without places or origin opens the file plainly")
        check(parse("rescan") == .rescan, "rescan")
        check(parse("analyze") == .analyze, "analyze")
        check(parse("describeBook", ["path": "ch1.md"]) == .describeBook(path: "ch1.md"), "describeBook of one chapter")
        check(parse("describeBook") == .describeBook(path: nil), "describeBook of the remaining chapters has no path")
        check(parse("recursiveInsight", ["path": "docs"]) == .recursiveInsight(path: "docs"), "recursiveInsight of a part")
        check(parse("recursiveInsight") == .recursiveInsight(path: ""), "recursiveInsight of the whole X-Ray has an empty path")
        check(parse("askBook", ["question": "  why?  "]) == .askBook(question: "why?"), "askBook trims the question")
        check(parse("cancelAnalysis") == .cancelAnalysis, "cancelAnalysis")
        check(parse("tempFilter", ["criterion": "auth"]) == .temporaryFilter(criterion: "auth"), "tempFilter carries the criterion")
        check(parse("tempFilter") == .temporaryFilter(criterion: ""), "tempFilter without a criterion clears the filter")
        check(parse("openPRXRay", ["source": "gh:5"]) == .openPRXRay(source: "gh:5"), "openPRXRay carries the source")
        check(parse("openPRXRay") == .openPRXRay(source: nil), "openPRXRay without a source opens the default comparison")
        check(parse("analyzePR") == .analyzePR(again: false), "analyzePR runs once by default")
        check(parse("analyzePR", ["again": true]) == .analyzePR(again: true), "analyzePR can start over")
        check(parse("historyCommits", ["day": "2026-11-01"]) == .historyCommits(day: "2026-11-01"), "historyCommits carries the day")
        check(parse("compareWithCommit", ["sha": "abc"]) == .compareWithCommit(sha: "abc"), "compareWithCommit carries the commit")
        check(parse("prFileDiff", ["path": "x"]) == .prFileDiff(path: "x"), "prFileDiff carries the path")
        check(parse("explainPRFile", ["path": "x"]) == .explainPRFile(path: "x"), "explainPRFile carries the path")
        check(parse("askPR", ["question": "q", "path": "x"]) == .askPR(question: "q", path: "x"), "askPR about one file")
        check(parse("askPR", ["question": "q", "path": ""]) == .askPR(question: "q", path: nil), "askPR with an empty path asks about the whole change")
        check(parse("filterSearch", ["filter": "f1"]) == .filterSearch(filter: "f1"), "filterSearch carries the filter")
        check(parse("showPR", ["source": "gh:5"]) == .showPR(source: "gh:5"), "showPR carries the source")
        check(parse("reviewPR") == .reviewPR(again: false), "reviewPR reviews once by default")
        check(parse("reviewPR", ["again": true]) == .reviewPR(again: true), "reviewPR can review again")
        check(parse("prTasksToTerminal") == .prTasksToTerminal, "prTasksToTerminal")
        check(parse("copyPRTasks") == .copyPRTasks, "copyPRTasks")
        check(parse("refreshPRSources") == .refreshPRSources, "refreshPRSources")
        check(parse("prAction", ["op": "merge", "body": "ok", "method": "rebase"]) == .prAction(op: "merge", body: "ok", method: "rebase"),
              "prAction carries the operation, the text and the merge method")
        check(parse("prAction", ["op": "approve"]) == .prAction(op: "approve", body: "", method: "squash"), "prAction defaults to a squash merge and no text")
        let finding = XRayCommand.Finding(path: "x.swift", index: 4)
        check(parse("prFindingFix", ["path": "x.swift", "index": 4]) == .prFindingFix(finding), "prFindingFix names the finding")
        check(parse("prFixAll") == .prFixAll, "prFixAll")
        check(parse("prFindingExplain", ["path": "x.swift", "index": 4]) == .prFindingExplain(finding), "prFindingExplain names the finding")
        check(parse("prFindingComment", ["path": "x.swift", "index": 4]) == .prFindingComment(finding), "prFindingComment names the finding")
        check(parse("prFindingIssue", ["path": "x.swift", "index": 4]) == .prFindingIssue(finding), "prFindingIssue names the finding")
        check(parse("prFindingDismiss", ["path": "x.swift", "index": 4]) == .prFindingDismiss(finding), "prFindingDismiss names the finding")
        check(parse("prFindingFix", ["path": "x.swift"]) == .prFindingFix(.init(path: "x.swift", index: -1)), "a finding without an index is -1, which no finding has")
        check(parse("openURL", ["url": "https://github.com/o/r/pull/1"]) == .openURL(URL(string: "https://github.com/o/r/pull/1")!), "openURL of a GitHub link")
        check(parse("setComponent", ["path": "a", "component": "core"]) == .setComponent(path: "a", component: "core"), "setComponent carries path and component")
        check(parse("rateImportance") == .rateImportance(view: "modules", parent: "", filter: "importance"), "rateImportance defaults to the modules view and importance")
        check(parse("rateImportance", ["view": "code", "parent": "p", "filter": "f"]) == .rateImportance(view: "code", parent: "p", filter: "f"), "rateImportance carries view, parent and filter")
        check(parse("createFilter", ["name": "n", "criterion": "c"]) == .createFilter(name: "n", criterion: "c"), "createFilter carries name and criterion")
        check(parse("deleteFilter", ["id": "u1"]) == .deleteFilter(id: "u1"), "deleteFilter carries the id")
        check(parse("outlineFile", ["path": "x.md"]) == .outlineFile(path: "x.md"), "outlineFile carries the path")
        check(parse("saveSearchAnswer", ["filter": "f"]) == .saveSearchAnswer(filter: "f"), "saveSearchAnswer carries the filter")
        check(parse("retryUnderstanding", ["filter": "f"]) == .retryUnderstanding(filter: "f"), "retryUnderstanding carries the filter")
        check(parse("openUnderstandingSource", ["filter": "f", "source": "s1"]) == .openUnderstandingSource(filter: "f", source: "s1"), "openUnderstandingSource carries filter and source")
        check(parse("explainEdge", ["source": "a", "target": "b"]) == .explainEdge(view: "modules", source: "a", target: "b", kind: "uses", label: nil, again: false),
              "explainEdge defaults to a modules edge of kind uses")
        check(parse("explainEdge", ["view": "code", "source": "a", "target": "b", "kind": "calls", "label": "l", "again": true])
              == .explainEdge(view: "code", source: "a", target: "b", kind: "calls", label: "l", again: true), "explainEdge carries the edge and can start over")
        check(parse("refreshCode") == .refreshCode, "refreshCode")
        check(parse("traceCode", ["scope": "s", "question": "q"]) == .traceCode(scope: "s", question: "q"), "traceCode carries scope and question")
        check(parse("describe", ["view": "code", "id": "n1"]) == .describe(view: "code", id: "n1"), "describe carries view and node")
    }

    // MARK: - What is dropped before it reaches a store

    static func dropped() {
        check(parse("doSomethingElse") == nil && parse("") == nil, "an unknown action is dropped")
        for action in ["operationRun", "operationOpen", "operationEdit", "operationAdopt"] {
            check(parse(action) == nil, "\(action) without an id is dropped")
        }
        for action in ["operationAcceptProposal", "operationRejectProposal", "operationAddUnknown"] {
            check(parse(action) == nil && parse(action, ["index": "2"]) == nil, "\(action) without a numeric index is dropped")
        }
        check(parse("openFile") == nil && parse("openFile", ["path": ""]) == nil, "openFile without a path is dropped")
        check(parse("askBook") == nil && parse("askBook", ["question": "  \n "]) == nil, "askBook with a blank question is dropped")
        check(parse("prAction", ["op": "delete"]) == nil && parse("prAction") == nil, "prAction with an operation the page may not ask for is dropped")
        for op in XRayCommand.prOperations {
            check(parse("prAction", ["op": op]) != nil, "prAction accepts \(op)")
        }
        check(parse("openURL", ["url": "http://github.com/o/r"]) == nil, "openURL of a plain http link is dropped")
        check(parse("openURL", ["url": "https://example.com/o/r"]) == nil, "openURL of another host is dropped")
        check(parse("openURL", ["url": "https://github.com.evil.example/o"]) == nil, "openURL of a host that only starts with github.com is dropped")
        check(parse("openURL", ["url": "javascript:alert(1)"]) == nil && parse("openURL") == nil, "openURL of a script or nothing is dropped")
        check(parse("outlineFile") == nil && parse("outlineFile", ["path": ""]) == nil, "outlineFile without a path is dropped")
        check(parse("explainEdge", ["source": "a"]) == nil && parse("explainEdge", ["target": "b"]) == nil, "explainEdge without both ends is dropped")
        check(parse("traceCode", ["scope": "s"]) == nil && parse("traceCode", ["question": "q"]) == nil, "traceCode without scope or question is dropped")
    }

    // MARK: - "123", "#123" or a link to a pull request

    static func pullRequestNumber() {
        func source(_ text: String) -> XRayCommand? { parse("openPRNumber", ["text": text]) }
        check(source("123") == .openPRXRay(source: "gh:123"), "a bare number opens that pull request")
        check(source("#123") == .openPRXRay(source: "gh:123"), "#123 opens that pull request")
        check(source("  7  ") == .openPRXRay(source: "gh:7"), "spaces around the number do not matter")
        check(source("https://github.com/o/r/pull/42") == .openPRXRay(source: "gh:42"), "a pull request link opens that pull request")
        check(source("https://github.com/o/r/pull/42/files") == .openPRXRay(source: "gh:42"), "a link to its files tab opens that pull request")
        check(source("not a number") == nil && source("") == nil && parse("openPRNumber") == nil, "text without a number is dropped")
    }

    // MARK: - The operations strip belongs to the project's own X-Ray

    static func scopes() {
        let operation = XRayCommand.operation(.run(id: "build"))
        check(operation.isAllowed(inScope: ""), "the operations strip works from the project's X-Ray")
        check(!operation.isAllowed(inScope: "Sources") && !operation.isAllowed(inScope: "#pr") && !operation.isAllowed(inScope: nil),
              "the operations strip is refused from a folder's X-Ray, the pull request's and a tab that is no X-Ray")
        for command in [XRayCommand.rescan, .reviewPR(again: false), .openFile(.init(path: "a", line: nil, endLine: nil, find: nil, fromSearch: false, fromPR: false))] {
            check(command.isAllowed(inScope: "") && command.isAllowed(inScope: "Sources") && command.isAllowed(inScope: "#pr") && command.isAllowed(inScope: nil),
                  "\(command) works from every X-Ray")
        }
    }

    // MARK: - A file or part the page names must lie inside

    static func paths() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("xray-command-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let project = base.appendingPathComponent("project", isDirectory: true)
        let folder = project.appendingPathComponent("Sources", isDirectory: true)
        let sibling = base.appendingPathComponent("project-evil", isDirectory: true)
        for directory in [folder, folder.appendingPathComponent("Core", isDirectory: true), sibling] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let inFolder = XRayCommand.file(at: "Core/a.swift", root: folder, projectRoot: project)
        check(inFolder?.path == folder.appendingPathComponent("Core/a.swift").standardizedFileURL.path, "a relative path inside the X-Ray's folder resolves")
        let inProject = XRayCommand.file(at: project.appendingPathComponent("README.md").path, root: folder, projectRoot: project)
        check(inProject?.path == project.appendingPathComponent("README.md").standardizedFileURL.path, "an absolute path elsewhere in the project resolves for a folder X-Ray")
        check(XRayCommand.file(at: "../../outside.md", root: folder, projectRoot: project) == nil, "a path that climbs out of the project is refused")
        check(XRayCommand.file(at: "../README.md", root: folder, projectRoot: project) != nil, "a path that climbs to a file still inside the project resolves")
        check(XRayCommand.file(at: "/etc/passwd", root: folder, projectRoot: project) == nil, "an absolute path outside the project is refused")
        check(XRayCommand.file(at: sibling.appendingPathComponent("x.md").path, root: folder, projectRoot: project) == nil,
              "a folder whose name only starts like the project's is refused")
        check(XRayCommand.file(at: project.path, root: folder, projectRoot: project) == nil, "the project folder itself is not a file to open")

        check(XRayCommand.insightTarget("", root: folder)?.path == folder.path, "an empty part is the X-Ray's folder")
        check(XRayCommand.insightTarget("Core", root: folder)?.path == folder.appendingPathComponent("Core").standardizedFileURL.path, "an existing part inside the folder resolves")
        check(XRayCommand.insightTarget("Missing", root: folder) == nil, "a part that is not on disk is refused")
        check(XRayCommand.insightTarget("..", root: folder) == nil && XRayCommand.insightTarget("../../project-evil", root: folder) == nil,
              "a part outside the X-Ray's folder is refused")
    }
}
