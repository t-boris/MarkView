// Checks linked folders (MarkView/Models/LinkedFolders.swift, Task 59): what can be linked, unique
// names, document ids and their resolution, and the project search index walking linked folders
// (MarkView/Models/ProjectSearch.swift).
import Foundation

/// Stand-ins for app types the checked modules mention but never exercise here.
enum CLITool { case claude, codex, cline, copilot }
enum SemanticDatabase {
    nonisolated static func documentId(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if filePath.hasPrefix(prefix) { return String(filePath.dropFirst(prefix.count)) }
        return fileURL.lastPathComponent
    }
}

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let fm = FileManager.default
let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("lf-\(UUID().uuidString)", isDirectory: true)
let project = base.appendingPathComponent("project", isDirectory: true)
let docs = base.appendingPathComponent("shared/docs", isDirectory: true)
let other = base.appendingPathComponent("other/docs", isDirectory: true)
let inside = project.appendingPathComponent("sub", isDirectory: true)
for url in [project, docs, other, inside, docs.appendingPathComponent("guides", isDirectory: true)] {
    try! fm.createDirectory(at: url, withIntermediateDirectories: true)
}
try! "# Project readme\nalpha beta\n".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
try! "# Shared guide\ngamma delta\n".write(to: docs.appendingPathComponent("guides/intro.md"), atomically: true, encoding: .utf8)
try! "secret".write(to: docs.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
defer { try? fm.removeItem(at: base) }

// Linking rules.
check(LinkedFolders.problem(linking: docs, to: project, existing: []) == nil, "a folder elsewhere can be linked")
check(LinkedFolders.problem(linking: project, to: project, existing: []) != nil, "the project itself cannot")
check(LinkedFolders.problem(linking: inside, to: project, existing: []) != nil, "a folder inside the project cannot")
check(LinkedFolders.problem(linking: base, to: project, existing: []) != nil, "a folder containing the project cannot")
check(LinkedFolders.problem(linking: base.appendingPathComponent("missing"), to: project, existing: []) != nil, "a missing folder cannot")
check(LinkedFolders.problem(linking: project.appendingPathComponent("README.md"), to: project, existing: []) != nil, "a file cannot")

guard case .success(let first) = LinkedFolders.link(docs, to: project, existing: []) else { fatalError("link failed") }
check(first.name == "docs", "the name is the folder's name")
check(first.path == docs.path, "the path is canonical")
check(LinkedFolders.problem(linking: docs, to: project, existing: [first]) != nil, "the same folder cannot be linked twice")
check(LinkedFolders.problem(linking: docs.appendingPathComponent("guides"), to: project, existing: [first]) != nil, "a folder inside a linked one cannot")
check(LinkedFolders.problem(linking: base.appendingPathComponent("shared"), to: project, existing: [first]) != nil, "a folder containing a linked one cannot")
guard case .success(let second) = LinkedFolders.link(other, to: project, existing: [first]) else { fatalError("second link failed") }
check(second.name == "docs-2", "a second folder with the same name gets a numbered name")
let linked = [first, second]

// Document ids.
check(LinkedFolders.documentId(for: project.appendingPathComponent("README.md"), root: project, linked: linked) == "README.md", "project files keep their path id")
let guide = docs.appendingPathComponent("guides/intro.md")
check(LinkedFolders.documentId(for: guide, root: project, linked: linked) == "@linked/docs/guides/intro.md", "linked files get @linked/<name>/<path>")
check(LinkedFolders.documentId(for: other.appendingPathComponent("a.md"), root: project, linked: linked) == "@linked/docs-2/a.md", "the numbered name is used")
check(LinkedFolders.documentId(for: base.appendingPathComponent("elsewhere.md"), root: project, linked: linked) == "elsewhere.md", "a file outside both falls back to its name")
check(LinkedFolders.resolve(documentId: "@linked/docs/guides/intro.md", in: linked)?.path == guide.path, "a linked id resolves to the file")
check(LinkedFolders.resolve(documentId: "@linked/unknown/x.md", in: linked) == nil, "an unknown linked name does not resolve")
check(LinkedFolders.resolve(documentId: "README.md", in: linked) == nil, "a project id is not a linked id")
check(LinkedFolders.folder(containing: guide, in: linked)?.name == "docs", "the containing folder is found")
check(LinkedFolders.folder(containing: project.appendingPathComponent("README.md"), in: linked) == nil, "a project file is in no linked folder")

// Store round trip (in memory).
let data = LinkedFolders.encode(linked)!
check(LinkedFolders.decode(data) == linked, "encode and decode round-trip")

// CLI arguments.
check(CLITool.claude.additionalFolderArgs([docs]) == ["--add-dir", docs.path], "Claude reads a linked folder through --add-dir")
check(CLITool.codex.additionalFolderArgs([docs]).isEmpty, "Codex needs no argument")

// Search index over the project and its linked folders.
let roots = ProjectSearchRoot.all(project: project, linked: linked)
check(roots.count == 3 && roots[0].prefix == "" && roots[1].prefix == "@linked/docs/", "search roots: the project first, then the linked folders")
let index = ProjectSearchIndex()
let semaphore = DispatchSemaphore(value: 0)
var results: [ProjectSearchResult] = []
Task {
    try! await index.rebuild(roots: roots) { _ in }
    results = await index.search("gamma")
    semaphore.signal()
}
semaphore.wait()
check(results.contains { $0.scope == .content && $0.path == "@linked/docs/guides/intro.md" }, "content in a linked folder is found with its @linked path")
check(ProjectSearchRoot.url(for: "@linked/docs/guides/intro.md", in: roots)?.path == guide.path, "a linked result path resolves to the file")
check(ProjectSearchRoot.url(for: "README.md", in: roots)?.path == project.appendingPathComponent("README.md").path, "a project result path resolves inside the project")
Task {
    results = await index.search(".env")
    semaphore.signal()
}
semaphore.wait()
check(!results.contains { $0.path?.hasSuffix(".env") == true }, "secret-like files in a linked folder are not indexed")

print(failures == 0 ? "All linked-folder checks passed." : "\(failures) linked-folder check(s) failed.")
exit(failures == 0 ? 0 : 1)
