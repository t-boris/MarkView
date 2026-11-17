import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

extension EditorHostTests {
    func testProjectSearchIndexWithArchives() async throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("docs/readme.md", "# Title\nneedle in markdown\n")
        try write("src/app.swift", "func run() { print(\"needle in swift\") }\n")
        try write("web/Widget.vue", "<template><p>needle in vue</p></template>\n")        // not on the old extension list
        try write("infra/main.tf", "resource \"x\" \"needle_in_terraform\" {}\n")           // not on the old list
        try write("Procfile", "web: needle_in_procfile\n")                                  // no extension
        try write("node_modules/pkg/index.js", "needle in node_modules\n")                  // excluded directory
        try write(".worktrees/feature/worktree-copy.swift", "needle worktree_only_token\n")
        try write("nested/.worktrees/feature/nested-copy.swift", "needle worktree_only_token\n")
        try write("worktrees/notes.md", "needle in an ordinary folder\n")
        try write(".env", "SECRET=needle_secret\n")                                          // excluded file
        try Data([0x4e, 0x45, 0x00, 0x44, 0x4c, 0x45]).write(to: root.appendingPathComponent("blob.dat"))   // binary with NUL, no known extension
        try Data("needle".utf8).write(to: root.appendingPathComponent("picture.png"))        // text bytes but a binary extension

        // An archive with entries.
        try write("pack/inside/deep note.txt", "needle inside the zip\n")
        try write("pack/inside/diagram.drawio", "x\n")
        let archive = try Archive.compress([root.appendingPathComponent("pack")])
        try FileManager.default.moveItem(at: archive, to: root.appendingPathComponent("bundle.zip"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("pack"))

        let index = ProjectSearchIndex()
        let linked = LinkedFolder(path: root.appendingPathComponent("docs").path, name: "manuals", added: Date(timeIntervalSince1970: 0))
        let linkedRoot = ProjectSearchRoot.linked(linked)
        check(linkedRoot.prefix == "@linked/manuals/" && linkedRoot.url == linked.url, "linked search roots use the shipping folder model and document prefix")
        try await index.rebuild(roots: [.project(root)]) { _ in }
        let hits = await index.search("needle")
        let content = hits.filter { $0.scope == .content }
        let titles = Set(content.map(\.title))
        check(titles.contains("readme.md") && titles.contains("app.swift"), "markdown and swift are found")
        check(titles.contains("Widget.vue") && titles.contains("main.tf") && titles.contains("Procfile"), "text files of any extension are found: \(titles.sorted())")
        check(!titles.contains("index.js") && !titles.contains(".env"), "excluded directories and files stay out")
        let worktreeContent = await index.search("worktree_only_token")
        let worktreeNames = await index.search("worktree-copy")
        let nestedWorktreeNames = await index.search("nested-copy")
        check(!worktreeContent.contains { $0.scope == .content }
              && !worktreeNames.contains { $0.scope == .file }
              && !nestedWorktreeNames.contains { $0.scope == .file },
              "root and nested .worktrees copies stay out of content and file-name search")
        check(content.contains { $0.path == "worktrees/notes.md" }, "an ordinary worktrees folder is still searched")
        check(!titles.contains("blob.dat") && !titles.contains("picture.png"), "binary files are not read")
        check(content.first { $0.title == "app.swift" }?.line == 1, "a content hit carries its line")

        let names = await index.search("deep note")
        check(names.contains { $0.scope == .file && $0.path == "bundle.zip!/pack/inside/deep note.txt" }, "a file inside a zip is found by name: \(names.map { $0.path ?? "" })")
        let files = await index.search("diagram")
        check(files.contains { $0.scope == .file && ($0.path ?? "").hasSuffix("!/pack/inside/diagram.drawio") }, "another entry of the zip")
        check(!(await index.search("inside the zip")).contains { $0.scope == .content }, "the text inside a zip is not searched")
        check((await index.search("blob")).contains { $0.scope == .file && $0.path == "blob.dat" }, "a binary file is still found by name")
        check(ProjectSearchIndex.text(of: root.appendingPathComponent("Procfile"), known: false) != nil && ProjectSearchIndex.text(of: root.appendingPathComponent("blob.dat"), known: false) == nil, "text sniffing")
    }
}

extension EditorHostTests {
    func testLinkedFoldersAndSearch() async throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
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
        check(CLITool(rawValue: "claude")!.additionalFolderArgs([docs]) == ["--add-dir", docs.path], "Claude reads a linked folder through --add-dir")
        check(CLITool(rawValue: "codex")!.additionalFolderArgs([docs]).isEmpty, "Codex needs no argument")

        // Search index over the project and its linked folders.
        let roots = ProjectSearchRoot.all(project: project, linked: linked)
        check(roots.count == 3 && roots[0].prefix == "" && roots[1].prefix == "@linked/docs/", "search roots: the project first, then the linked folders")
        let index = ProjectSearchIndex()
        try await index.rebuild(roots: roots) { _ in }
        var results = await index.search("gamma")
        check(results.contains { $0.scope == .content && $0.path == "@linked/docs/guides/intro.md" }, "content in a linked folder is found with its @linked path")
        check(ProjectSearchRoot.url(for: "@linked/docs/guides/intro.md", in: roots)?.path == guide.path, "a linked result path resolves to the file")
        check(ProjectSearchRoot.url(for: "README.md", in: roots)?.path == project.appendingPathComponent("README.md").path, "a project result path resolves inside the project")
        results = await index.search(".env")
        check(!results.contains { $0.path?.hasSuffix(".env") == true }, "secret-like files in a linked folder are not indexed")
    }
}
