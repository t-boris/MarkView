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

extension EditorHostTests {
    func testArchiveContentsAndPathSafety() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        func sh(_ command: String, in dir: URL) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", command]
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("archive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Names and kinds.
        check(Archive.isArchive(URL(fileURLWithPath: "/x/a.ZIP")) && Archive.isArchive(URL(fileURLWithPath: "/x/a.tar.gz")) && Archive.isArchive(URL(fileURLWithPath: "/x/a.tgz")), "archive extensions, also compound ones")
        check(!Archive.isArchive(URL(fileURLWithPath: "/x/a.md")) && !Archive.isArchive(URL(fileURLWithPath: "/x/a.gz")), "other files are not archives")
        check(Archive.baseName(URL(fileURLWithPath: "/x/photos.tar.gz")) == "photos" && Archive.baseName(URL(fileURLWithPath: "/x/a.b.zip")) == "a.b", "base name drops the archive extension")
        check(Archive.isSafe("a/b.txt") && !Archive.isSafe("../x") && !Archive.isSafe("a/../../x") && !Archive.isSafe("/etc/passwd") && !Archive.isSafe(""), "safe and unsafe paths")
        check(Archive.escaped("a[1]*.txt") == "a\\[1\\]\\*.txt", "glob characters in member names are escaped")

        // A source tree with awkward names.
        let src = work.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("docs/sub dir"), withIntermediateDirectories: true)
        try "hello\n".write(to: src.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
        try "deep\n".write(to: src.appendingPathComponent("docs/sub dir/note one.md"), atomically: true, encoding: .utf8)
        try "star\n".write(to: src.appendingPathComponent("a[1].txt"), atomically: true, encoding: .utf8)
        try "wild\n".write(to: src.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "ds\n".write(to: src.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        // compress → zip → list.
        let zipped = try Archive.compress([src])
        check(zipped.lastPathComponent == "src.zip" && FileManager.default.fileExists(atPath: zipped.path), "compress makes src.zip next to the folder")
        let again = try Archive.compress([src])
        check(again.lastPathComponent == "src 2.zip", "a taken name gets a number")
        let many = try Archive.compress([src.appendingPathComponent("readme.md"), src.appendingPathComponent("b.txt")])
        check(many.lastPathComponent == "Archive.zip" && many.deletingLastPathComponent().standardizedFileURL == src.standardizedFileURL, "several items: Archive.zip in their common folder")
        let entries = try Archive.list(zipped)
        let paths = Set(entries.map(\.path))
        check(paths.contains("src/readme.md") && paths.contains("src/docs/sub dir/note one.md") && paths.contains("src/a[1].txt"), "listing keeps nested paths, spaces and brackets: \(paths.sorted())")
        check(!paths.contains("src/.DS_Store"), ".DS_Store is left out")
        check(entries.first { $0.path == "src/docs" }?.isDirectory == true, "directories are marked")
        check(entries.first { $0.path == "src/readme.md" }?.size == 6, "sizes are read")

        // One entry, including a name that looks like a glob.
        let noteEntry = entries.first { $0.path == "src/docs/sub dir/note one.md" }!
        let note = try Archive.extractEntry(noteEntry, from: zipped)
        var cacheFolder = note
        for _ in noteEntry.path.split(separator: "/") { cacheFolder.deleteLastPathComponent() }
        let expectedCacheRoot = Archive.cacheRoot.standardizedFileURL.resolvingSymlinksInPath()
        let cleanupFolder = cacheFolder.standardizedFileURL.resolvingSymlinksInPath()
        let cacheIsIsolated = cleanupFolder.deletingLastPathComponent() == expectedCacheRoot
        check(cacheIsIsolated, "archive fixture cache is in the expected directory")
        defer { if cacheIsIsolated { try? FileManager.default.removeItem(at: cleanupFolder) } }
        check((try? String(contentsOf: note, encoding: .utf8)) == "deep\n", "one entry is unpacked to the cache")
        let bracket = try Archive.extractEntry(entries.first { $0.path == "src/a[1].txt" }!, from: zipped)
        check((try? String(contentsOf: bracket, encoding: .utf8)) == "star\n", "a name with brackets is read, not matched as a pattern")
        let wildcardTarget = try Archive.extractEntry(entries.first { $0.path == "src/b.txt" }!, from: zipped)
        check((try? String(contentsOf: wildcardTarget, encoding: .utf8)) == "wild\n", "a plain name next to a glob-like one")
        do { _ = try Archive.extractEntry(entries.first { $0.path == "src/docs" }!, from: zipped); check(false, "a folder cannot be opened") }
        catch { check(true, "a folder cannot be opened") }

        // Extract everything.
        let dest = Archive.uniqueFolder(for: zipped)
        check(dest.lastPathComponent == "src" || dest.lastPathComponent == "src 2", "extract folder is named after the archive: \(dest.lastPathComponent)")
        let count = try Archive.extractAll(zipped, to: dest)
        check(count == 4 && FileManager.default.fileExists(atPath: dest.appendingPathComponent("src/docs/sub dir/note one.md").path), "extract all unpacks every file (\(count))")
        do { _ = try Archive.extractAll(zipped, to: dest); check(false, "an existing folder is never written into") }
        catch { check(true, "an existing folder is never written into") }

        // tar.gz.
        let tgz = work.appendingPathComponent("pack.tar.gz")
        sh("tar -czf pack.tar.gz -C src readme.md docs", in: work)
        let tgzEntries = try Archive.list(tgz)
        check(Set(tgzEntries.map(\.path)).isSuperset(of: ["readme.md", "docs/sub dir/note one.md"]), "tar.gz is listed")

        // Zip-slip: entries with .. and an absolute path.
        let evil = work.appendingPathComponent("evil.zip")
        sh("""
        python3 - <<'PY'
        import zipfile
        z = zipfile.ZipFile("evil.zip", "w")
        z.writestr("ok.txt", "fine")
        z.writestr("../escaped.txt", "bad")
        z.writestr("/abs/escaped.txt", "bad")
        z.close()
        PY
        """, in: work)
        let evilEntries = (try? Archive.list(evil)) ?? []
        check(evilEntries.contains { !$0.isSafe }, "an unsafe path in the archive is flagged")
        let evilDest = work.appendingPathComponent("evil-out")
        do { _ = try Archive.extractAll(evil, to: evilDest); check(false, "an archive with an unsafe path is refused") }
        catch let error as ArchiveError { check({ if case .unsafe = error { return true }; return false }(), "an archive with an unsafe path is refused") }
        check(!FileManager.default.fileExists(atPath: evilDest.path) && !FileManager.default.fileExists(atPath: work.appendingPathComponent("escaped.txt").path), "nothing was written")
        do { _ = try Archive.extractEntry(evilEntries.first { !$0.isSafe }!, from: evil); check(false, "an unsafe entry is not opened") }
        catch { check(true, "an unsafe entry is not opened") }

        // Not an archive / broken.
        let broken = work.appendingPathComponent("broken.zip")
        try "not a zip".write(to: broken, atomically: true, encoding: .utf8)
        do { _ = try Archive.list(broken); check(false, "a broken archive fails") } catch { check(true, "a broken archive fails with a message: \(error.localizedDescription)") }
    }
}
