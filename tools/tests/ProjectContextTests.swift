// Behaviour of the open project of a window (MarkView/Models/Workspace/ProjectContext.swift, AR-14 step 8) on real folders, real
// files and real SQLite databases: opening a folder with its exclusions and recents, linked folders, the project's database from
// open to release (a folder's and a single file's), and what a feature reads through ProjectProviding. The index process
// (`--dde-index`) is the app's own binary and is covered by the app probe, not here.
import Foundation
import SQLite3

/// Stand-ins for app types the checked modules mention but this check never exercises: the assistant list that LinkedFolders.swift
/// extends, and the file-type table that decides which files the tree shows (the fixtures here are all Markdown).
enum CLITool { case claude, codex, cline, copilot, antigravity }
enum FileType { static func isOpenable(_ url: URL) -> Bool { ["md", "txt"].contains(url.pathExtension.lowercased()) } }

@MainActor
@main enum ProjectContextTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
    }

    /// Polls `condition` until it holds or `seconds` have passed.
    static func wait(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// What a feature that only needs the project sees of it, through the protocol alone.
    static func describe(_ project: any ProjectProviding) -> (root: URL?, searchRoots: [URL], hasDatabase: Bool) {
        (project.root, project.searchRoots, project.database != nil)
    }

    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("pc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        for key in [ProjectContext.lastFolderKey, ProjectContext.recentProjectsKey] { defaults.removeObject(forKey: key) }
        defer {
            try? fm.removeItem(at: base)
            for key in [ProjectContext.lastFolderKey, ProjectContext.recentProjectsKey, LinkedFolders.defaultsKey] { defaults.removeObject(forKey: key) }
        }

        try await openFolderWithExclusions(base)
        try await recents(base)
        try linkedFolders(base)
        try markdownFiles(base)
        try await singleFileDatabase(base)
        try await blockDeltas(base)
        try await staleTreeReload(base)

        if failures > 0 { print("\(failures) check(s) FAILED"); exit(1) }
        print("Project context checks passed")
    }

    // MARK: - A folder opens, a folder is excluded, the exclusion outlives the window

    static func openFolderWithExclusions(_ base: URL) async throws {
        let fm = FileManager.default
        let project = base.appendingPathComponent("proj", isDirectory: true)
        try write("# A\nalpha\n", to: project.appendingPathComponent("a.md"))
        try write("# B\nbeta\n", to: project.appendingPathComponent("docs/b.md"))
        try write("# C\ngamma\n", to: project.appendingPathComponent("skip/c.md"))
        let outside = base.appendingPathComponent("elsewhere/e.md")
        try write("# E\n", to: outside)
        let recentsFile = base.appendingPathComponent("recent-open.json")

        let context = ProjectContext(recentFilesURL: recentsFile)
        check(context.root == nil && !context.hasWorkspace && context.searchRoots.isEmpty, "a new project has no folder and no workspace")

        context.beginOpening(project)
        check(context.rootOpenedAsFolder && context.indexingProgress != nil && context.root == nil,
              "opening a folder shows progress and clears the previous tree")
        check(context.recentProjects.first == project.path && defaults(ProjectContext.lastFolderKey) == project.path,
              "the folder is the last folder and the first recent project")
        let loaded = await context.loadTree(of: project)
        check(loaded && context.root == project && context.projectFolder == project && context.aiProject == project,
              "the tree of the folder is loaded and the folder is the project")
        let names = (context.rootNode?.children ?? []).map(\.name).sorted()
        check(names == ["a.md", "docs", "skip"], "the tree lists the folder's entries (\(names))")
        check(context.searchRoots == [project], "search covers the project folder")

        let opened = try await context.openDatabase(at: project)
        check(opened && context.database != nil && context.hasWorkspace, "the project's database opens")
        check(fm.fileExists(atPath: project.appendingPathComponent(".dde/state.db").path), "the database is the folder's .dde/state.db")
        check(context.contains(project.appendingPathComponent("a.md")) && !context.contains(outside),
              "a file of the folder belongs to the project, a file elsewhere does not")

        let seen = describe(context)
        check(seen.root == project && seen.searchRoots == [project] && seen.hasDatabase, "a feature sees the project through ProjectProviding")
        check(context.relativePath(of: project.appendingPathComponent("docs/b.md")) == "docs/b.md", "relativePath names a file inside the project")
        check(context.cacheDirectory(for: project.appendingPathComponent("a.md")).path == project.appendingPathComponent(".dde/cache").path,
              "a project file caches in the folder's .dde/cache")
        check(context.cacheDirectory(for: outside).path == outside.deletingLastPathComponent().appendingPathComponent(".dde/cache").path,
              "a file elsewhere caches next to itself")

        let db = context.database!
        for file in ["a.md", "docs/b.md", "skip/c.md"] {
            try await db.upsertDocument(id: context.documentId(for: project.appendingPathComponent(file)), projectId: "proj",
                                        filePath: project.appendingPathComponent(file).path, fileName: file, fileExt: "md", contentHash: "h-\(file)")
        }
        for (file, word) in [("a.md", "alpha"), ("docs/b.md", "beta"), ("skip/c.md", "gamma")] {
            await db.indexDocumentFTS(documentId: file, title: file, content: word)
        }
        check(await db.allDocumentMeta().keys.sorted() == ["a.md", "docs/b.md", "skip/c.md"], "the database holds the three documents")
        check(await db.search(query: "gamma").map(\.documentId) == ["skip/c.md"], "the documents are searchable before the exclusion")

        context.excludeFolder(project.appendingPathComponent("skip"))
        check(context.isExcluded(project.appendingPathComponent("skip/c.md")) && !context.isExcluded(project.appendingPathComponent("a.md")),
              "an excluded folder and the files in it are excluded, the rest is not")
        let forgotten = await wait { await db.search(query: "gamma").isEmpty }
        check(forgotten, "the excluded folder's documents leave the search index")
        let alpha = await db.search(query: "alpha").map(\.documentId), beta = await db.search(query: "beta").map(\.documentId)
        check(alpha == ["a.md"] && beta == ["docs/b.md"], "the other documents stay searchable")

        let reopened = ProjectContext(recentFilesURL: recentsFile)
        reopened.beginOpening(project)
        _ = await reopened.loadTree(of: project)
        check(reopened.isExcluded(project.appendingPathComponent("skip/c.md")), "the exclusion is still there when the folder is opened again")
        let rule = reopened.fileTree.excludedFolders.first ?? ""
        reopened.includeFolder(rule)
        check(!reopened.isExcluded(project.appendingPathComponent("skip/c.md")), "an included folder is no longer excluded")
        let third = ProjectContext(recentFilesURL: recentsFile)
        third.beginOpening(project)
        _ = await third.loadTree(of: project)
        check(!third.isExcluded(project.appendingPathComponent("skip/c.md")), "the inclusion is kept too")

        // The database and the folder go away together when the folder closes; the recents stay.
        context.closeFolder()
        check(context.root == nil && context.database == nil && !context.hasWorkspace && context.linkedFolders.isEmpty,
              "closing the folder drops the tree, the links and the database")
        check(context.recentProjects.first == project.path, "closing the folder keeps the recent projects")
        check(context.indexingProgress == nil && context.structuralIndexProgress == nil, "closing the folder clears the progress")

        // Metadata written into the folder is found and removed; documents are not touched.
        let metadataContext = ProjectContext(recentFilesURL: recentsFile)
        metadataContext.beginOpening(project)
        _ = await metadataContext.loadTree(of: project)
        try write("# Project Context — Auto-generated by MarkView DDE\n", to: project.appendingPathComponent(".claude/CLAUDE.md"))
        try write("page", to: project.appendingPathComponent(".markview-insight/p.md"))
        let items = metadataContext.metadataItems()
        check(Set(items.map(\.lastPathComponent)) == [".dde", ".markview-insight", "CLAUDE.md"], "metadata items are the index, the insight pages and the generated CLAUDE.md")
        check(metadataContext.deleteMetadata(items).isEmpty, "the metadata is deleted")
        check(!fm.fileExists(atPath: project.appendingPathComponent(".dde").path) && !fm.fileExists(atPath: project.appendingPathComponent(".claude").path)
              && fm.fileExists(atPath: project.appendingPathComponent("a.md").path), "the metadata and the emptied .claude go, the documents stay")

        // A document id names a file of the project; a search hit resolves to the file.
        check(metadataContext.fileURL(forDocumentId: "docs/b.md") == project.appendingPathComponent("docs/b.md"), "a document id resolves to its file")
        check(metadataContext.fileURL(forDocumentId: "docs/missing.md") == nil, "an id of a missing file resolves to nothing")
        check(metadataContext.fileURL(filePath: "docs/b.md", fallbackDocumentId: nil) == project.appendingPathComponent("docs/b.md"),
              "a search hit's relative path resolves against the root")
        let byName = metadataContext.fileURL(filePath: nil, fallbackDocumentId: "b.md")
        check(byName?.resolvingSymlinksInPath().path == project.appendingPathComponent("docs/b.md").resolvingSymlinksInPath().path, "a search hit with only a file name finds the file in the folder (\(byName?.path ?? "nil"))")
        check(metadataContext.markdownFiles(in: project).map(\.lastPathComponent).sorted() == ["a.md", "b.md", "c.md"], "the Markdown files of the folder are listed")
    }

    static func defaults(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }

    // MARK: - The Markdown files of a folder, for Recursive Insight

    static func markdownFiles(_ base: URL) throws {
        let fm = FileManager.default
        let sandbox = base.appendingPathComponent("markdown-files", isDirectory: true)
        let outside = sandbox.appendingPathComponent("outside", isDirectory: true)
        let sibling = sandbox.appendingPathComponent("projectX", isDirectory: true)
        let project = sandbox.appendingPathComponent("project", isDirectory: true)
        try write("secret", to: outside.appendingPathComponent("secret.md"))
        try write("sibling", to: sibling.appendingPathComponent("other.md"))
        try write("# a", to: project.appendingPathComponent("a.md"))
        try write("# b", to: project.appendingPathComponent("docs/b.MD"))
        try write("text", to: project.appendingPathComponent("c.txt"))
        try write("# hidden", to: project.appendingPathComponent(".hidden/d.md"))
        try write("# dde", to: project.appendingPathComponent("tools.dde/e.md"))
        try write("# pkg", to: project.appendingPathComponent("Thing.app/Contents/f.md"))
        try write("# inner", to: project.appendingPathComponent("real/inner.md"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("escape.md"), withDestinationURL: outside.appendingPathComponent("secret.md"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("prefix.md"), withDestinationURL: sibling.appendingPathComponent("other.md"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("inside.md"), withDestinationURL: project.appendingPathComponent("a.md"))
        let context = ProjectContext(recentFilesURL: base.appendingPathComponent("markdown-files-recents.json"))
        // The enumerator reports /private/var paths for a /var folder, so the names are taken after the project's own folder name.
        let found = Set(context.markdownFiles(in: project).compactMap { $0.path.components(separatedBy: "/project/").last })
        check(found == ["a.md", "docs/b.MD", "real/inner.md", "inside.md"],
              "hidden, `.dde`, package and non-Markdown files are skipped; the case of the extension does not matter (found: \(found.sorted()))")
        check(!found.contains("escape.md") && !found.contains("prefix.md"),
              "a symlink out of the folder, also to a sibling that shares the folder's name prefix, is skipped")
        check(context.markdownFiles(in: sandbox.appendingPathComponent("missing")).isEmpty, "a folder that does not exist has no files")
    }

    // MARK: - Recent files and recent folders survive a restart

    static func recents(_ base: URL) async throws {
        let file = base.appendingPathComponent("recent-files.json")
        let first = ProjectContext(recentFilesURL: file)
        let urls = (0..<25).map { base.appendingPathComponent("f\($0).md") }
        urls.forEach { first.addRecentFile($0) }
        check(first.recentFiles.count == ProjectContext.maxRecentFiles && first.recentFiles.first == urls[24], "recent files keep the newest \(ProjectContext.maxRecentFiles)")
        first.addRecentFile(urls[10])
        check(first.recentFiles.first == urls[10] && first.recentFiles.filter { $0 == urls[10] }.count == 1, "opening a file again moves it to the front")
        let restarted = ProjectContext(recentFilesURL: file)
        check(restarted.recentFiles == first.recentFiles, "recent files are read back from disk in the same order")

        let folders = (0..<32).map { base.appendingPathComponent("folder\($0)", isDirectory: true) }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let projects = ProjectContext(recentFilesURL: file)
        folders.forEach { projects.beginOpening($0) }
        check(projects.recentProjects.count == ProjectContext.maxRecentProjects && projects.recentProjects.first == folders[31].path,
              "recent projects keep the newest \(ProjectContext.maxRecentProjects)")
        let victim = projects.recentProjects[3]
        projects.removeRecentProject(victim)
        check(!projects.recentProjects.contains(victim) && projects.recentProjects.count == ProjectContext.maxRecentProjects - 1,
              "a removed recent project leaves the list")
        check(ProjectContext(recentFilesURL: file).recentProjects == projects.recentProjects, "recent projects are shared by every window and read back")
        check(FileManager.default.fileExists(atPath: folders[0].path), "removing a recent project leaves the folder alone")
    }

    // MARK: - Linked folders

    static func linkedFolders(_ base: URL) throws {
        let project = base.appendingPathComponent("linked-proj", isDirectory: true)
        let shared = base.appendingPathComponent("shared/docs", isDirectory: true)
        try write("# Intro\n", to: shared.appendingPathComponent("guides/intro.md"))
        try write("# Home\n", to: project.appendingPathComponent("README.md"))
        let file = base.appendingPathComponent("recent-linked.json")

        let nothing = ProjectContext(recentFilesURL: file)
        check(nothing.linkFolders([shared]).count == 1 && nothing.linkedFolders.isEmpty, "nothing can be linked while no folder is open")

        let context = ProjectContext(recentFilesURL: file)
        context.beginOpening(project)
        context.fileTree.setRootNode(FileNode.buildTree(from: project, sortOrder: context.fileTree.sortOrder))
        context.loadLinkedFolders()
        check(context.linkFolders([shared]).isEmpty && context.linkedFolders.map(\.url.path) == [shared.path], "a folder elsewhere is linked")
        check(context.searchRoots == [project, shared], "search covers the project and its linked folder")
        check(context.searchRootsKey.contains(shared.path), "the searchable roots change when a folder is linked")
        check(context.linkFolders([project.appendingPathComponent("sub")]).count == 1 && context.linkFolders([shared]).count == 1,
              "a folder inside the project and a folder linked twice are refused with a reason")

        let intro = shared.appendingPathComponent("guides/intro.md")
        check(context.linkedFolder(containing: intro)?.url.path == shared.path, "the linked folder of a file is found")
        check(context.containerRoot(for: intro)?.path == shared.path && context.containerRoot(for: project.appendingPathComponent("README.md"))?.path == project.path
              && context.containerRoot(for: base.appendingPathComponent("x.md")) == nil, "the root a file belongs to is the project, a linked folder, or none")
        let documentId = context.relativePath(of: intro)
        check(documentId.hasPrefix(LinkedFolders.documentIdPrefix) && context.fileURL(forDocumentId: documentId)?.path == intro.path,
              "a file in a linked folder has a document id that resolves back to the file")

        let restarted = ProjectContext(recentFilesURL: file)
        restarted.beginOpening(project)
        restarted.fileTree.setRootNode(FileNode.buildTree(from: project, sortOrder: restarted.fileTree.sortOrder))
        restarted.loadLinkedFolders()
        check(restarted.linkedFolders.map(\.url.path) == [shared.path], "the link is still there when the folder is opened again")
        restarted.unlinkFolder(restarted.linkedFolders[0].id)
        check(restarted.linkedFolders.isEmpty && restarted.searchRoots == [project], "an unlinked folder leaves the search roots")
        context.loadLinkedFolders()
        check(context.linkedFolders.isEmpty, "the unlink is stored")
        check(FileManager.default.fileExists(atPath: intro.path), "unlinking leaves the folder alone")
    }

    // MARK: - A single file's database is for the window that is still open

    static func singleFileDatabase(_ base: URL) async throws {
        let fm = FileManager.default
        let notes = base.appendingPathComponent("notes", isDirectory: true)
        let todo = notes.appendingPathComponent("todo.md")
        try write("# Todo\nbuy zebra milk\n", to: todo)
        let file = base.appendingPathComponent("recent-single.json")

        let context = ProjectContext(recentFilesURL: file)
        context.openSingleFile(todo)
        check(!context.rootOpenedAsFolder && context.root == notes && context.projectFolder == nil && context.aiProject == nil,
              "a single file's folder is the root but not a project")
        check(context.hasWorkspace && context.contains(todo), "the single file belongs to the workspace while its database is being made")
        let ready = await wait { context.database != nil }
        check(ready && fm.fileExists(atPath: notes.appendingPathComponent(".dde/file_todo.db").path), "the single file's database is named after the file")
        let indexed = await wait { await context.database?.search(query: "zebra").isEmpty == false }
        check(indexed, "the single file is indexed for search")
        context.releaseDatabase()
        check(context.database == nil, "releasing the database drops it")

        // A window that closes while the database is still being made never publishes it.
        let closing = ProjectContext(recentFilesURL: file)
        closing.openSingleFile(todo)
        closing.closeFolder()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        check(closing.database == nil && closing.root == nil, "a database that finishes after the folder closed is not published")

        let closed = ProjectContext(recentFilesURL: file)
        closed.openSingleFile(todo)
        closed.close()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        check(closed.database == nil, "closing the window stops the single file's setup")
    }

    // MARK: - The blocks the editor extracts reach the database in order

    /// `SELECT` the first column of each row as text.
    static func column(_ path: String, _ sql: String) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "") }
        return rows
    }

    static func block(_ id: String, _ text: String, in document: String, position: Int) -> SemanticBlock {
        SemanticBlock(id: id, documentId: document, type: .paragraph, level: nil, content: text, plainText: text, contentHash: "h-" + text,
                      semanticHash: nil, headingPath: [], parentBlockId: nil, lineStart: position, lineEnd: position, position: position,
                      language: nil, anchor: nil)
    }

    static func blockDeltas(_ base: URL) async throws {
        let project = base.appendingPathComponent("blocks-project", isDirectory: true)
        let note = project.appendingPathComponent("note.md")
        try write("# Note\n\nfirst\n", to: note)
        let context = ProjectContext(recentFilesURL: base.appendingPathComponent("recent-blocks.json"))

        // Without a database a delta has nowhere to go and is dropped without a trace.
        context.saveBlocks(BlocksDelta(added: [block("early", "x", in: "note.md", position: 0)], removed: [], changed: [], unchanged: []), of: note)

        context.beginOpening(project)
        _ = await context.loadTree(of: project)
        _ = try await context.openDatabase(at: project)
        guard let db = context.database else { return check(false, "the database opens for the block checks") }
        let dbPath = project.appendingPathComponent(".dde/state.db").path
        try await db.upsertDocument(id: "note.md", projectId: project.lastPathComponent, filePath: note.path, fileName: "note.md", fileExt: "md", contentHash: "h")

        func delta(added: [SemanticBlock] = [], removed: [String] = [], changed: [SemanticBlock] = []) -> BlocksDelta {
            BlocksDelta(added: added, removed: removed, changed: changed, unchanged: [])
        }
        // Three deltas in a row, as the editor sends them while the person types: the blocks appear, one is rewritten, one goes and
        // another comes. Written out of order, "second" would survive its removal.
        context.saveBlocks(delta(added: [block("first", "one", in: "note.md", position: 0), block("second", "two", in: "note.md", position: 1)]), of: note)
        context.saveBlocks(delta(changed: [block("first", "one, rewritten", in: "note.md", position: 0)]), of: note)
        context.saveBlocks(delta(added: [block("third", "three", in: "note.md", position: 2)], removed: ["second"]), of: note)
        context.saveBlocks(delta(), of: note)
        let settled = await wait { column(dbPath, "SELECT block_id FROM blocks ORDER BY order_index") == ["first", "third"] }
        check(settled, "the deltas apply in the order they were sent: \(column(dbPath, "SELECT block_id FROM blocks ORDER BY order_index"))")
        check(column(dbPath, "SELECT raw_markdown FROM blocks WHERE block_id = 'first'") == ["one, rewritten"], "a changed block keeps its newest text")
        check(column(dbPath, "SELECT document_id FROM blocks WHERE block_id = 'third'") == [context.documentId(for: note)], "the blocks belong to the document of the file")
        check(column(dbPath, "SELECT block_id FROM blocks WHERE block_id = 'early'").isEmpty, "a delta that arrived without a database was dropped")
    }

    // MARK: - A tree rebuilt for a folder that has closed is dropped

    static func staleTreeReload(_ base: URL) async throws {
        let project = base.appendingPathComponent("reload-proj", isDirectory: true)
        try write("# One\n", to: project.appendingPathComponent("one.md"))
        let context = ProjectContext(recentFilesURL: base.appendingPathComponent("recent-reload.json"))
        context.beginOpening(project)
        _ = await context.loadTree(of: project)
        check((context.rootNode?.children ?? []).count == 1, "the folder starts with one entry")

        try write("# Two\n", to: project.appendingPathComponent("two.md"))
        context.fileTree.refresh()
        let refreshed = await wait { (context.rootNode?.children ?? []).count == 2 }
        check(refreshed, "refreshing the tree shows the file added on disk")

        context.fileTree.refresh()
        context.closeFolder()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        check(context.rootNode == nil && context.root == nil, "a rebuild that finishes after the folder closed does not bring the old tree back")
    }
}
