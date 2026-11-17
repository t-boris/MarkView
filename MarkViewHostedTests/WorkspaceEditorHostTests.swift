import AppKit
import Combine
import MarkViewCore
import SwiftUI
import WebKit
import XCTest
@testable import MarkView

extension EditorHostTests {
    @MainActor func testFileBrowserRulesOnTemporaryProject() throws {
        func check(_ condition: Bool, _ label: String, line: UInt = #line) {
            XCTAssertTrue(condition, label, line: line)
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("file-browser-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let project = base.appendingPathComponent("project", isDirectory: true)
        let linked = base.appendingPathComponent("notes", isDirectory: true)

        func path(_ root: URL, _ relative: String) -> URL { root.appendingPathComponent(relative) }
        func makeFolder(_ root: URL, _ relative: String) throws {
            try fm.createDirectory(at: path(root, relative), withIntermediateDirectories: true)
        }
        func makeFile(_ root: URL, _ relative: String, modified: Date? = nil) throws {
            try fm.createDirectory(at: path(root, relative).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: path(root, relative))
            if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: path(root, relative).path) }
        }

        // project/
        //   src/{main.swift, notes.md}   .hidden/secret.md   .env   build/out.o (ignored)   docs/deep/er/needle.md
        //   video.mov (no viewer)   readme.md   Zeta.txt   alpha.txt   image.png
        let old = Date(timeIntervalSince1970: 1_000_000)
        let mid = Date(timeIntervalSince1970: 2_000_000)
        let new = Date(timeIntervalSince1970: 3_000_000)
        try makeFile(project, "src/main.swift")
        try makeFile(project, "src/notes.md")
        try makeFile(project, ".hidden/secret.md")
        try makeFile(project, ".env")
        try makeFile(project, "build/out.o")
        try makeFile(project, "docs/deep/er/needle.md")
        try makeFile(project, "video.mov", modified: mid)
        try makeFile(project, "readme.md", modified: old)
        try makeFile(project, "Zeta.txt", modified: new)
        try makeFile(project, "alpha.txt", modified: new)
        try makeFile(project, "image.png", modified: mid)
        try makeFile(linked, "todo.md")
        try makeFile(linked, "deep/needle-linked.md")

        let projectRoot = FileBrowserRoot(url: project, name: "project", linkedID: nil)
        let linkedRoot = FileBrowserRoot(url: linked, name: "Notes", linkedID: linked.path)
        let roots = [projectRoot, linkedRoot]
        let ignoredPaths: Set<String> = [FileBrowser.key(path(project, "build"))]

        func source(_ filter: FileBrowserFilter = FileBrowserFilter(), sort: FileTreeSortOrder = FileTreeSortOrder(),
                    roots: [FileBrowserRoot] = roots) -> FileBrowserSource {
            FileBrowserSource(roots: roots, filter: filter, sort: sort,
                              hasViewer: { FileType.hasViewer($0) },
                              isIgnored: { url, _ in
                                  let key = FileBrowser.key(url)
                                  return ignoredPaths.contains { key == $0 || key.hasPrefix($0 + "/") }
                              })
        }
        func names(_ entries: [FileBrowserEntry]) -> [String] { entries.map(\.name) }
        func list(_ filter: FileBrowserFilter = FileBrowserFilter(), sort: FileTreeSortOrder = FileTreeSortOrder(),
                  query: Bool = true) -> [String] {
            names(FileBrowser.listing(of: project, source: source(filter, sort: sort), applyQuery: query))
        }

        // MARK: Viewer classification (DEC-004)

        for name in ["a.md", "a.swift", "a.json", "a.yaml", "a.pdf", "a.png", "a.zip", "a.csv", "a.sqlite", "a.log", "a.canvas", "Makefile", "a.html"] {
            check(FileType.hasViewer(URL(fileURLWithPath: "/x/\(name)")), "\(name) has a viewer")
        }
        for name in [".gitignore", ".dockerignore", ".zshrc", ".env", ".env.local", "LICENSE", "a.conf", "a.txt"] {
            check(FileType.hasViewer(URL(fileURLWithPath: "/x/\(name)")), "\(name) (configuration file) has a viewer")
        }
        for name in ["a.mov", "a.dylib", "a.bin", "a.unknownext", "NOEXTENSION", ".custom"] {
            check(!FileType.hasViewer(URL(fileURLWithPath: "/x/\(name)")), "\(name) has no viewer")
        }

        // MARK: Preferences (AC-5, DEC-008)

        // WindowUIState belongs to the main actor, as the views that read it do.
        @MainActor func windowPreferenceChecks() {
            let suite = "file-browser-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            // Each window keeps its own view and filter choices (`FileTreeView` stores them in the window's `WindowUIState`).
            func browserPreferences(_ state: WindowUIState) -> FileBrowserPreferences {
                FileBrowserPreferences(mode: FileBrowserViewMode(rawValue: state.value(Setting.fileBrowserViewMode)) ?? .list,
                                       showHidden: state.value(Setting.fileBrowserShowHidden),
                                       hideIgnored: state.value(Setting.fileBrowserHideIgnored),
                                       category: FileBrowserCategory(rawValue: state.value(Setting.fileBrowserCategory)) ?? .all)
            }
            let windowA = WindowUIState(defaults: defaults), windowB = WindowUIState(defaults: defaults)
            check(browserPreferences(windowA) == FileBrowserPreferences(), "defaults: list, hidden off, ignored shown, all")
            check(browserPreferences(windowB) == FileBrowserPreferences(), "a second window starts the same")
            check(FileBrowserPreferences().mode == .list && !FileBrowserPreferences().showHidden, "hidden items are excluded by default")
            windowA.set(FileBrowserViewMode.tree.rawValue, for: Setting.fileBrowserViewMode)
            windowA.set(true, for: Setting.fileBrowserShowHidden)
            windowA.set(FileBrowserCategory.openable.rawValue, for: Setting.fileBrowserCategory)
            check(browserPreferences(windowA).mode == .tree && browserPreferences(windowA).showHidden && browserPreferences(windowA).category == .openable,
                  "the window that changed its view shows it")
            check(browserPreferences(windowB) == FileBrowserPreferences(), "another window that already shows its files keeps its own view")
            let windowC = WindowUIState(defaults: defaults)
            check(browserPreferences(windowC).mode == .tree && browserPreferences(windowC).showHidden, "a window opened later starts from the last choice")
            defer { UserDefaults(suiteName: suite + "-empty")?.removePersistentDomain(forName: suite + "-empty") }
        let restored = WindowUIState(defaults: UserDefaults(suiteName: suite + "-empty")!)
            restored.restore(windowA.saved)
            check(browserPreferences(restored).mode == .tree && browserPreferences(restored).category == .openable,
                  "the view, hidden and category come back with the window's session")
            defaults.set("nonsense", forKey: "fileBrowser.viewMode")
            defaults.set("nonsense", forKey: "fileBrowser.category")
            let windowD = WindowUIState(defaults: defaults)
            check(browserPreferences(windowD).mode == .list && browserPreferences(windowD).category == .all,
                  "unknown stored values fall back to the defaults")
        }
        windowPreferenceChecks()
        check(!FileBrowserFilter().isActive && FileBrowserFilter(query: "a").isActive && FileBrowserFilter(hideIgnored: true).hasSettings,
              "an active filter is reported")

        // MARK: Listing and filters (AC-3, REQ-001)

        let everything = list()
        check(!everything.contains(".hidden") && !everything.contains(".env"), "hidden items are excluded by default")
        check(everything.contains("build"), "ignored items stay visible by default")
        check(everything.contains("video.mov"), "All shows files MarkView cannot open (DEC-003)")
        check(list(FileBrowserFilter(showHidden: true)).contains(".hidden") && list(FileBrowserFilter(showHidden: true)).contains(".env"),
              "the hidden toggle shows dot items")
        check(!list(FileBrowserFilter(hideIgnored: true)).contains("build"), "Hide Git-ignored removes ignored folders")
        check(list(FileBrowserFilter(hideIgnored: true)).contains("src"), "Hide Git-ignored keeps other folders")
        check(list(FileBrowserFilter(showHidden: true, hideIgnored: true)).contains(".hidden"),
              "the two toggles are independent: ignored off, hidden on keeps dot items")
        check(list(FileBrowserFilter(category: .folders)) == ["build", "docs", "src"], "Folders shows only folders: \(list(FileBrowserFilter(category: .folders)))")
        let openable = list(FileBrowserFilter(category: .openable))
        check(openable.contains("src") && openable.contains("readme.md") && openable.contains("image.png"), "Openable keeps folders and viewer files")
        check(!openable.contains("video.mov"), "Openable drops files without a viewer")
        check(list(FileBrowserFilter(query: "ALPHA")) == ["alpha.txt"], "the name query is case-insensitive")
        check(list(FileBrowserFilter(query: "a"), query: false).count == everything.count, "children of a tree folder ignore the query")
        check(list(FileBrowserFilter(query: "zz-none")).isEmpty, "a query without a match lists nothing")
        check(list(FileBrowserFilter(query: "ALPHA", category: .folders)).isEmpty, "the query applies on top of the category")

        // MARK: Sort (AC-4)

        check(list(sort: FileTreeSortOrder(field: .name, ascending: true)) ==
              ["build", "docs", "src", "alpha.txt", "image.png", "readme.md", "video.mov", "Zeta.txt"], "name ascending: folders first, case-insensitive")
        check(list(sort: FileTreeSortOrder(field: .name, ascending: false)) ==
              ["src", "docs", "build", "Zeta.txt", "video.mov", "readme.md", "image.png", "alpha.txt"], "name descending: folders still first")
        let byDateDescending = list(sort: FileTreeSortOrder(field: .dateModified, ascending: false)).filter { !["build", "docs", "src"].contains($0) }
        check(byDateDescending == ["alpha.txt", "Zeta.txt", "image.png", "video.mov", "readme.md"],
              "date descending; equal dates fall back to name ascending: \(byDateDescending)")
        let byDateAscending = list(sort: FileTreeSortOrder(field: .dateModified, ascending: true)).filter { !["build", "docs", "src"].contains($0) }
        check(byDateAscending == ["readme.md", "image.png", "video.mov", "alpha.txt", "Zeta.txt"], "date ascending: \(byDateAscending)")
        check(Array(list(sort: FileTreeSortOrder(field: .dateModified, ascending: false)).prefix(3)).allSatisfy { ["build", "docs", "src"].contains($0) },
              "folders precede files whatever the field")

        // MARK: Workspace level (AC-2)

        let places = FileBrowser.workspaceEntries(source: source(), applyQuery: true)
        check(names(places) == ["project", "Notes"], "the project folder and the linked folder are siblings: \(names(places))")
        check(places.allSatisfy { $0.isDirectory && $0.root != nil }, "places are folders that carry their root")
        check(names(FileBrowser.workspaceEntries(source: source(FileBrowserFilter(query: "note")), applyQuery: true)) == ["Notes"],
              "the query filters the places")
        check(names(FileBrowser.workspaceEntries(source: source(FileBrowserFilter(hideIgnored: true, category: .folders)), applyQuery: true)) == ["project", "Notes"],
              "category and ignore filters never remove a place")
        let dotted = FileBrowserRoot(url: path(base, ".dotproject"), name: ".dotproject", linkedID: nil)
        try fm.createDirectory(at: dotted.url, withIntermediateDirectories: true)
        check(names(FileBrowser.workspaceEntries(source: source(roots: [dotted]), applyQuery: true)) == [".dotproject"],
              "a project folder whose name starts with a dot is still shown")

        // MARK: Tree (AC-1)

        let collapsed = FileBrowser.treeRows(source: source(), expanded: [])
        check(collapsed.map(\.depth) == [0, 0] && collapsed.allSatisfy { !$0.isExpanded && $0.isExpandable }, "a collapsed tree shows the two places")
        let opened = FileBrowser.treeRows(source: source(), expanded: [projectRoot.key, FileBrowser.key(path(project, "src"))])
        check(opened.map(\.entry.name).prefix(4) == ["project", "build", "docs", "src"], "expanding the project lists its children below it")
        let srcIndex = opened.firstIndex { $0.entry.name == "src" }!
        check(opened[srcIndex].depth == 1 && opened[srcIndex].isExpanded, "the expanded folder is marked open")
        check(opened[srcIndex + 1].entry.name == "main.swift" && opened[srcIndex + 1].depth == 2, "grandchildren sit one level deeper")
        check(opened.last?.entry.name == "Notes" && opened.last?.depth == 0, "the linked folder follows as a sibling of the project")
        let folderTree = FileBrowser.treeRows(source: source(FileBrowserFilter(category: .folders)), expanded: [projectRoot.key])
        check(folderTree.filter { $0.depth == 1 }.allSatisfy { $0.entry.isDirectory }, "Folders applies to the tree")

        // MARK: Search (DEC-001)

        let found = FileBrowser.search(source: source(FileBrowserFilter(query: "needle")))
        check(Set(names(found.matches)) == ["needle.md", "needle-linked.md"], "search finds files in never-opened folders of the project and of a linked folder: \(names(found.matches))")
        let rows = FileBrowser.searchRows(found, source: source(FileBrowserFilter(query: "needle")))
        check(rows.map(\.entry.name) == ["project", "docs", "deep", "er", "needle.md", "Notes", "deep", "needle-linked.md"],
              "ancestors are kept to reach each match: \(rows.map(\.entry.name))")
        check(rows.map(\.depth) == [0, 1, 2, 3, 4, 0, 1, 2], "the rows carry their depth")
        check(rows.filter(\.isMatch).map(\.entry.name).sorted() == ["Notes", "needle-linked.md", "needle.md", "project"],
              "only the matches (and the places) are drawn as matches")
        check(rows.allSatisfy { $0.entry.isDirectory ? $0.isExpanded : true }, "every ancestor is open")
        check(FileBrowser.searchRows(FileBrowser.search(source: source(FileBrowserFilter(query: "todo"))), source: source(FileBrowserFilter(query: "todo"))).map(\.entry.name)
              == ["Notes", "todo.md"], "a place without a match is left out")
        check(FileBrowser.search(source: source(FileBrowserFilter(query: "secret"))).matches.isEmpty, "hidden folders are not searched by default")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "secret", showHidden: true))).matches) == ["secret.md"], "…and are with the hidden toggle")
        check(FileBrowser.search(source: source(FileBrowserFilter(query: "out.o"))).matches.count == 1, "ignored folders are searched when shown")
        check(FileBrowser.search(source: source(FileBrowserFilter(query: "out.o", hideIgnored: true))).matches.isEmpty, "Hide Git-ignored also hides search results")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "e", category: .folders))).matches).allSatisfy { ["deep", "er", "docs"].contains($0) || $0 == "deep" },
              "category Folders searches folders only")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "video", category: .openable))).matches).isEmpty,
              "category Openable drops files without a viewer from the results")
        check(names(FileBrowser.search(source: source(FileBrowserFilter(query: "video"))).matches) == ["video.mov"], "All keeps them")

        let limited = FileBrowser.search(source: source(FileBrowserFilter(query: "e")), matchLimit: 3)
        check(limited.truncated && limited.matches.count == 3, "a search stops at the match limit and says so")
        var cancelAfter = 2
        let cancelled = FileBrowser.search(source: source(FileBrowserFilter(query: "e")), isCancelled: { cancelAfter -= 1; return cancelAfter < 0 })
        check(!cancelled.truncated, "a cancelled search returns what it had")
        try fm.createSymbolicLink(at: path(project, "loop"), withDestinationURL: project)
        let withLoop = FileBrowser.search(source: source(FileBrowserFilter(query: "needle")))
        check(Set(names(withLoop.matches)) == ["needle.md", "needle-linked.md"] && !withLoop.truncated, "a symbolic link to a folder is not followed")
        try fm.removeItem(at: path(project, "loop"))
        let locked = path(project, "locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let withLocked = FileBrowser.search(source: source(FileBrowserFilter(query: "needle")))
        check(withLocked.unreadableFolders == 1 && withLocked.matches.count == 2, "an unreadable folder is counted, the rest is searched")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        // Breadth-first: a cap reached deep inside the project must not starve a linked folder or a shallow match.
        let capBase = base.appendingPathComponent("cap-project", isDirectory: true)
        let capLinked = base.appendingPathComponent("cap-linked", isDirectory: true)
        for index in 0..<40 { try makeFile(capBase, "node_modules/pkg\(index)/needle-\(index).js") }
        try makeFile(capBase, "needle-shallow.md")
        try makeFile(capLinked, "needle-linked-shallow.md")
        let capRoots = [FileBrowserRoot(url: capBase, name: "cap-project", linkedID: nil),
                        FileBrowserRoot(url: capLinked, name: "Cap linked", linkedID: capLinked.path)]
        let capped = FileBrowser.search(source: source(FileBrowserFilter(query: "needle"), roots: capRoots), matchLimit: 5)
        check(capped.truncated, "the capped search reports that more exist")
        check(Set(names(capped.matches)).isSuperset(of: ["needle-shallow.md", "needle-linked-shallow.md"]),
              "a capped search still returns the shallow matches of every place: \(names(capped.matches))")

        // A linked folder that vanished is still a folder row, so it can be unlinked.
        let gone = FileBrowserRoot(url: base.appendingPathComponent("gone-\(UUID().uuidString)"), name: "Gone", linkedID: "gone")
        let goneEntries = FileBrowser.workspaceEntries(source: source(roots: roots + [gone]), applyQuery: false)
        check(goneEntries.first { $0.name == "Gone" }?.isDirectory == true, "a vanished linked folder stays a folder row")
        check(FileBrowser.listing(of: gone.url, source: source(roots: [gone]), applyQuery: false).isEmpty, "…and lists nothing")

        // MARK: Navigation (AC-2)

        let inside = path(project, "docs/deep")
        check(FileBrowser.parent(of: .workspace, roots: roots) == nil, "the Workspace level has no parent")
        check(FileBrowser.parent(of: .folder(project), roots: roots) == .workspace, ".. from the project root goes to the Workspace level")
        check(FileBrowser.parent(of: .folder(linked), roots: roots) == .workspace, ".. from a linked folder's root goes to the Workspace level")
        check(FileBrowser.parent(of: .folder(inside), roots: roots) == .folder(path(project, "docs")), ".. inside a place goes to the parent folder")
        check(FileBrowser.crumbs(for: .workspace, roots: roots).map(\.title) == ["Workspace"], "the Workspace breadcrumb is alone at the top")
        check(FileBrowser.crumbs(for: .folder(inside), roots: roots).map(\.title) == ["Workspace", "project", "docs", "deep"], "breadcrumbs run from Workspace to the folder")
        check(FileBrowser.crumbs(for: .folder(inside), roots: roots).last?.location == .folder(inside), "the last crumb is the folder itself")
        check(FileBrowser.crumbs(for: .folder(path(linked, "deep")), roots: roots).map(\.title) == ["Workspace", "Notes", "deep"], "a linked folder shows its own name")
        check(FileBrowser.root(containing: path(linked, "deep"), in: roots)?.name == "Notes", "the root of an item is found")
        check(FileBrowser.root(containing: base, in: roots) == nil, "an item outside every place has no root")
        let nested = FileBrowserRoot(url: path(project, "docs"), name: "docs-link", linkedID: "x")
        check(FileBrowser.root(containing: inside, in: roots + [nested])?.name == "docs-link", "the innermost root wins")
        check(FileBrowser.ancestors(of: path(project, "docs/deep/er/needle.md"), roots: roots).map { $0.lastPathComponent } == ["project", "docs", "deep", "er"],
              "ancestors lead from the place's root to the item")
        check(FileBrowser.ancestors(of: project, roots: roots).isEmpty, "a place has no ancestors")

        // MARK: Reveal vs filters (DEC-008)

        let secret = path(project, ".hidden/secret.md")
        let everyFilter = FileBrowserFilter(query: "typed", showHidden: false, hideIgnored: true, category: .folders)
        let toSecret = FileBrowser.relaxing(everyFilter, toShow: secret, source: source(everyFilter))
        check(toSecret.showHidden && toSecret.category == .all && toSecret.query.isEmpty && toSecret.hideIgnored,
              "revealing a file in a hidden folder turns Hidden on, resets Folders to All and clears the query, nothing else")
        let toOut = FileBrowser.relaxing(everyFilter, toShow: path(project, "build/out.o"), source: source(everyFilter))
        check(!toOut.hideIgnored && !toOut.showHidden, "revealing an ignored file turns Hide Git-ignored off only")
        let plain = FileBrowserFilter(category: .openable)
        check(FileBrowser.relaxing(plain, toShow: path(project, "src/notes.md"), source: source(plain)) == FileBrowserFilter(category: .openable),
              "a visible item leaves the filter as it is")
        check(FileBrowser.relaxing(plain, toShow: path(project, "video.mov"), source: source(plain)).category == .all,
              "an item the category hides resets it to All")
        check(FileBrowser.relaxing(everyFilter, toShow: project, source: source(everyFilter)).hideIgnored,
              "revealing a place changes no setting")

    }
}


extension EditorHostTests {
    func testWindowTitleUsesDisplayName() throws {
        func check(_ name: String, _ got: String, _ want: String, line: UInt = #line) {
            XCTAssertEqual(got, want, name, line: line)
        }
        check("folder open", WindowTitle.text(version: "1.4", folderName: "my-project"), "my-project — MarkView 1.4")
        check("no folder", WindowTitle.text(version: "1.4", folderName: nil), "MarkView 1.4")
        check("empty folder name", WindowTitle.text(version: "1.4", folderName: ""), "MarkView 1.4")
        check("empty version, folder", WindowTitle.text(version: "", folderName: "foo"), "foo — MarkView")
        check("empty version, no folder", WindowTitle.text(version: "", folderName: nil), "MarkView")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)/my-project", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let name = WindowTitle.folderName(of: dir)
        check("display name of a folder", name, "my-project")
        let title = WindowTitle.text(version: "1.4", folderName: name)
        check("full path never in the title", String(title.contains(dir.path) || title.contains("/")), "false")
        let volume = WindowTitle.folderName(of: URL(fileURLWithPath: "/"))
        check("root volume has a name, not '/'", String(!volume.isEmpty && volume != "/"), "true")
        check("missing folder falls back to last component", WindowTitle.folderName(of: URL(fileURLWithPath: "/no/such/place-xyz")), "place-xyz")

    }
}


/// A view that fills itself with its window's background colour, read from the environment.
private struct ThemeTestProbe: View {
    @Environment(\.palette) private var palette
    var body: some View { palette.bg.frame(width: 40, height: 40) }
}


private extension AppTheme {
    static let darcula = AppTheme("darcula"), midnight = AppTheme("midnight"), graphite = AppTheme("graphite")
    static let tokyoNight = AppTheme("tokyo-night"), carbonRed = AppTheme("carbon-red"), nord = AppTheme("nord")
    static let forest = AppTheme("forest"), paper = AppTheme("paper"), daylight = AppTheme("daylight")
}


extension EditorHostTests {
    @MainActor func testIndependentWindowThemes() {
        var testDefaultsNames: [String] = []
        defer { for name in testDefaultsNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) } }
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        func freshStore() -> ThemeSettingsStore {
            let name = "window-theme-tests-\(UUID().uuidString)"
            testDefaultsNames.append(name)
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return ThemeSettingsStore(defaults: defaults)
        }
        func spin(_ what: String, until done: () -> Bool) {
            let limit = Date().addingTimeInterval(5)
            while !done() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            check(done(), "timed out waiting for \(what)")
        }
        /// The colour at the middle of a rendered image, as 0xRRGGBB in sRGB (the image is redrawn into an sRGB bitmap first).
        func centre(_ image: NSImage?) -> UInt32? {
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let offset = ((cg.height / 2) * cg.width + cg.width / 2) * 4
            return UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
        }

        _ = NSApplication.shared
        // The shipped themes only: a window of this program never reads the real themes folder of the person running it.
        let catalog = ThemeCatalog(userFolder: nil)
        check(catalog.library.ignored.isEmpty && catalog.library.themes.count == 11, "the shipped themes are all there")
        let outFolder = ProcessInfo.processInfo.environment["MARKVIEW_THEME_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 }

        // Project transparency persists independently and is shared by windows of the same project.
        let transparencyName = "transparency-test-\(UUID().uuidString)"
        let transparencyDefaults = UserDefaults(suiteName: transparencyName)!
        let projectA = URL(fileURLWithPath: "/tmp/project-a", isDirectory: true)
        let projectB = URL(fileURLWithPath: "/tmp/project-b", isDirectory: true)
        let transparency = ProjectTransparencyStore(defaults: transparencyDefaults)
        transparency.set(0.45, for: projectA)
        check(transparency.value(for: projectA) == 0.45 && transparency.value(for: projectB) == 0, "projects have independent transparency")
        let restoredTransparency = ProjectTransparencyStore(defaults: transparencyDefaults)
        check(restoredTransparency.value(for: projectA) == 0.45, "project transparency survives relaunch")
        transparency.set(0.2, for: nil)
        check(transparency.value(for: nil) == 0, "a window without a project cannot change a project")
        transparencyDefaults.removePersistentDomain(forName: transparencyName)

        // MARK: windows are independent (criterion 3)
        let store = freshStore()
        let a = WindowTheme(store: store, catalog: catalog), b = WindowTheme(store: store, catalog: catalog)
        check(a.settings.theme == .classicDark && b.settings.theme == .classicDark, "windows start as Classic Dark with nothing saved")
        a.select(.midnight)
        check(a.settings.theme == .midnight && a.webID == "midnight" && a.isDark, "window A takes Midnight")
        check(b.settings.theme == .classicDark && b.webID == "classic-dark", "window B is not changed by A")
        b.select(.paper)
        check(b.webID == "paper" && !b.isDark && a.webID == "midnight", "B takes Paper and A keeps Midnight")
        a.setAccent(ThemeColor(0xFF4D9A))
        check(a.palette.model.accent.rgb == 0xFF4D9A && b.palette.model.accent.rgb == 0x315E9B, "an accent in A does not change B")
        check(a.webAccent == "#FF4D9A" && b.webAccent == nil, "the web payload carries the accent only where it was chosen")
        check(a.webArguments.id == "midnight" && a.webArguments.accent == "#FF4D9A" && a.webArguments.list.count == 3 &&
              b.webArguments.id == "paper" && b.webArguments.accent == nil && b.webArguments.list[1] is NSNull, "web call arguments: id, accent, theme")
        let tail = a.webArguments.payload
        let sent = (try? JSONSerialization.jsonObject(with: Data(tail.utf8))) as? [String: Any]
        check(sent?["id"] as? String == "midnight" && sent?["mode"] as? String == "dark" && (sent?["t"] as? [String: String])?.isEmpty == false,
              "the web call carries the whole theme as JSON")
        check((sent?["base"] as? [String: String])?["bg"] == "#151c2b", "and it is the theme's own colours")
        let attributes = a.htmlAttributes
        check(attributes.hasPrefix(##"data-preset="midnight" data-theme="dark" data-accent="#FF4D9A" data-theme-tokens=""##) &&
              b.htmlAttributes.hasPrefix(##"data-preset="paper" data-theme="light" data-theme-tokens=""##), "html attributes for the first paint")
        let escaped = attributes.components(separatedBy: #"data-theme-tokens=""#).last.map { String($0.dropLast()) } ?? ""
        check(!escaped.contains("\"") && !escaped.contains("<") &&
              escaped.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&") == tail,
              "the tokens in the page text are the same JSON, escaped for an attribute")
        let script = a.firstPaintScript
        check(script.contains("setAttribute('data-preset', \"midnight\")") && script.contains("setAttribute('data-accent', \"#FF4D9A\")") &&
              script.contains("setAttribute('data-theme-tokens', \"{") && !script.contains("\n"), "first-paint script sets the same attributes")

        // MARK: accents are remembered per appearance (DEC-002)
        a.select(.graphite)
        check(a.webAccent == nil, "Graphite has no accent of its own yet")
        a.select(.midnight)
        check(a.webAccent == "#FF4D9A", "Midnight gets its accent back")
        a.setAccent(nil)
        check(a.webAccent == nil && a.settings.accentOverride(for: .midnight) == nil, "reset removes the override")

        // MARK: a new window inherits the last change with every accent (DEC-005)
        let s2 = freshStore()
        let first = WindowTheme(store: s2, catalog: catalog)
        first.select(.paper); first.setAccent(ThemeColor(0x00AA00)); first.select(.darcula); first.setAccent(ThemeColor(0x123456))
        let second = WindowTheme(store: s2, catalog: catalog)
        check(second.settings == first.settings, "a new window starts from the last change, accents included")
        second.select(.graphite)
        check(first.settings.theme == .darcula, "the new window is independent of the first")
        let third = WindowTheme(store: s2, catalog: catalog)
        check(third.settings.theme == .graphite && third.settings.accentOverride(for: .paper)?.rgb == 0x00AA00,
              "the next window follows the newest change")

        // MARK: restoring a saved window is not a change anyone made
        let s3 = freshStore()
        let seed = WindowTheme(store: s3, catalog: catalog); seed.select(.midnight)
        let restored = WindowTheme(store: s3, catalog: catalog)
        restored.restore(WindowThemeSettings(theme: .paper, accents: [.paper: ThemeColor(0xABCDEF)]))
        check(restored.settings.theme == .paper && restored.webAccent == "#ABCDEF", "a restored window shows its saved theme and accent")
        check(WindowTheme(store: s3, catalog: catalog).settings.theme == .midnight, "restoring does not become the starting value of new windows")

        // MARK: the window's own appearance
        func makeWindow() -> NSWindow {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
        }
        let w1 = makeWindow(), w2 = makeWindow()
        let t1 = WindowTheme(store: freshStore(), catalog: catalog), t2 = WindowTheme(store: freshStore(), catalog: catalog)
        t1.attach(w1); t2.attach(w2)
        t1.select(.darcula); t2.select(.paper)
        check(w1.appearance?.name == .darkAqua, "a dark preset gives its window the dark appearance")
        check(w2.appearance?.name == .aqua, "Paper gives its window the light appearance")
        t1.select(.system)
        check(w1.appearance == nil, "System leaves the window on the macOS appearance")
        t1.select(.classicLight)
        check(w1.appearance?.name == .aqua, "Classic Light is light")
        t2.detach(w2); t2.select(.midnight)
        check(w2.appearance?.name == .aqua, "a detached window is left alone")

        // MARK: two windows render with two palettes at the same time (criteria 2 and 3)
        @MainActor func render<V: View>(_ view: V) -> NSImage? {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return renderer.nsImage
        }
        let ta = WindowTheme(store: freshStore(), catalog: catalog), tb = WindowTheme(store: freshStore(), catalog: catalog)
        ta.select(.darcula); tb.select(.paper)
        let imageA = render(ThemeTestProbe().windowThemed(ta)), imageB = render(ThemeTestProbe().windowThemed(tb))
        check(centre(imageA) == 0x2B2B2B, "a view in a Darcula window draws the Darcula background (got \(String(describing: centre(imageA))))")
        check(centre(imageB) == 0xFFFCF5, "a view in a Paper window draws the Paper background (got \(String(describing: centre(imageB))))")
        ta.select(.midnight)
        check(centre(render(ThemeTestProbe().windowThemed(ta))) == 0x151C2B, "the view follows a theme change at once")
        check(centre(render(ThemeTestProbe().windowThemed(tb))) == 0xFFFCF5, "and the other window does not")
        ta.select(.nord); tb.select(.daylight)
        check(centre(render(ThemeTestProbe().windowThemed(ta))) == 0x2E3440, "a view in a Nord window draws the Nord background")
        check(centre(render(ThemeTestProbe().windowThemed(tb))) == 0xF7F9FC, "a view in a Daylight window draws the Daylight background")
        ta.select(.forest)
        check(centre(render(ThemeTestProbe().windowThemed(ta))) == 0x1E2A22, "a view in a Forest window draws the Forest background")

        // MARK: the picker draws in every theme and lists what it should
        for theme in [AppTheme.classicDark, .darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .nord, .forest, .paper, .daylight] {
            let t = WindowTheme(store: freshStore(), catalog: catalog)
            t.select(theme)
            let image = render(ThemePickerView().windowThemed(t))
            check((image?.size.width ?? 0) >= 300 && (image?.size.height ?? 0) > 200, "the picker renders for \(theme)")
            if let outFolder, let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(atPath: outFolder, withIntermediateDirectories: true)
                try? png.write(to: URL(fileURLWithPath: outFolder).appendingPathComponent("picker-\(theme.id).png"))
            }
        }
        // MARK: a theme file of the person's own is a theme of the window (DEC-003)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("window-theme-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func put(_ name: String, _ text: String) { try? Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        func themeFile(_ id: String, bg: String) -> String {
            ##"{"schema":1,"id":"\##(id)","name":"\##(id.capitalized)","summary":"mine","native":{"bg":"\##(bg)","bgSidebar":"#16222E","text":"#E6EEF5","accent":"#4FC3F7"}}"##
        }
        put("ocean.json", themeFile("ocean", bg: "#0B1620"))
        put("broken.json", "{ not json")
        let own = ThemeCatalog(userFolder: folder)
        check(own.library.definition("ocean") != nil && own.library.ignored.map(\.file) == ["broken.json"], "the person's folder is read and the bad file is reported")
        let mine = WindowTheme(store: freshStore(), catalog: own)
        mine.select(AppTheme("ocean"))
        check(mine.webID == "ocean" && mine.isDark && mine.palette.model.bg.rgb == 0x0B1620 && mine.webArguments.payload.contains(#""id":"ocean""#),
              "a user theme draws natively and is sent to the web pages by the same data")
        check(centre(render(ThemeTestProbe().windowThemed(mine))) == 0x0B1620, "a view in a user-theme window draws the file's background")
        check(own.library.choices(current: .system).contains { $0.name == "Ocean" } && render(ThemePickerView().windowThemed(mine)) != nil,
              "the picker lists it and draws with the notice of the ignored file")

        // A stored theme that is not there is shown as Classic Dark, said once, and comes back with its file.
        let ghost = WindowTheme(settings: WindowThemeSettings(theme: AppTheme("ghost")), store: freshStore(), catalog: own)
        check(ghost.webID == "classic-dark" && ghost.settings.theme == AppTheme("ghost") && own.missing == ["ghost"], "an unknown stored theme is shown as Classic Dark and reported")
        let again = WindowTheme(settings: WindowThemeSettings(theme: AppTheme("ghost")), store: freshStore(), catalog: own)
        check(again.webID == "classic-dark" && own.missing == ["ghost"], "and reported once")
        put("ghost.json", themeFile("ghost", bg: "#201830"))
        put("late.json", themeFile("late", bg: "#102030"))
        var reloaded = false
        Task { @MainActor in await own.reload(); reloaded = true }
        spin("the catalog to reload") { reloaded }
        check(own.library.definition("late") != nil && own.library.definition("ghost") != nil && own.missing.isEmpty, "a file added while the app runs is found, and the missing theme is no longer missing")
        spin("the windows to follow the catalog") { ghost.webID == "ghost" }
        check(ghost.webID == "ghost" && ghost.palette.model.bg.rgb == 0x201830 && again.webID == "ghost", "windows that had stored it draw it as soon as it is there")
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("ghost.json"))
        reloaded = false
        Task { @MainActor in await own.reload(); reloaded = true }
        spin("the catalog to reload again") { reloaded }
        spin("the window to fall back") { ghost.webID == "classic-dark" }
        check(ghost.settings.theme == AppTheme("ghost") && own.missing == ["ghost"], "a deleted file falls back again, and the choice is kept for when the file returns")

        let system = SystemAppearance.shared
        check(system.isDark == (NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua), "system appearance is read")

    }
}


extension EditorHostTests {
    func testThemeModelAndStoredSettings() throws {
        var testDefaultsNames: [String] = []
        defer { for name in testDefaultsNames { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) } }
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        func ratio(_ a: ThemeColor, _ b: ThemeColor) -> String { String(format: "%.2f", ThemeColor.contrast(a, b)) }
        let builtInFolder = try XCTUnwrap(ThemeCatalog.bundledFolder)
        let library = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: nil)
        func def(_ id: String) -> ThemeDefinition { library.definition(id)! }
        func palette(_ theme: AppTheme, accent: ThemeColor? = nil) -> ThemePalette { ThemePalette.make(def(theme.id), accent: accent) }

        let presets: [AppTheme] = [.darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .nord, .forest, .paper, .daylight]
        let lightPresets: [AppTheme] = [.paper, .daylight]
        let classics: [AppTheme] = [.classicDark, .classicLight]
        let everyBuiltIn = classics + presets

        // MARK: colour basics
        check(ThemeColor(hex: "#12ab34")?.rgb == 0x12AB34, "lower-case hex with # parses")
        check(ThemeColor(hex: "12AB34")?.hex == "#12AB34", "hex without # parses and prints upper case")
        for bad in ["", "#12", "zzzzzz", "#1234567", "12 456", "#12AB3G"] { check(ThemeColor(hex: bad) == nil, "'\(bad)' is not a colour") }
        check(abs(ThemeColor.contrast(ThemeColor(0x000000), ThemeColor(0xFFFFFF)) - 21) < 0.01, "black on white is 21:1")
        check(abs(ThemeColor.contrast(ThemeColor(0x777777), ThemeColor(0x777777)) - 1) < 0.001, "a colour on itself is 1:1")
        check(ThemeColor(0xFFFFFF).readableText.rgb == 0x000000 && ThemeColor(0x000000).readableText.rgb == 0xFFFFFF, "readable text flips")
        check(ThemeColor(0x000000).mixed(with: ThemeColor(0xFFFFFF), fraction: 0.5).rgb == 0x808080, "mixing halfway")
        check(ThemeColor(0xAB12CD).cssHex == "#ab12cd", "the pages get lower-case #rrggbb")

        // MARK: the catalog of built-in themes is the files in Resources/Themes
        check(library.ignored.isEmpty, "no built-in theme file is ignored: \(library.ignored.map { "\($0.file): \($0.reason)" })")
        check(library.themes.map(\.id) == everyBuiltIn.map(\.id), "the built-in themes come in picker order: \(library.themes.map(\.id))")
        check(library.themes.allSatisfy { $0.source == .builtIn }, "every shipped theme is built in")
        check(Set(library.themes.map(\.name)).count == library.themes.count && library.themes.allSatisfy { !$0.summary.isEmpty }, "every theme has its own name and a summary")
        for t in lightPresets { check(!def(t.id).isDark, "\(t.id) is light even when macOS is dark") }
        for t in presets.filter({ !lightPresets.contains($0) }) + [.classicDark] { check(def(t.id).isDark, "\(t.id) is dark even when macOS is light") }
        check(!def("classic-light").isDark, "Classic Light is light")
        check(library.resolve(.system, systemIsDark: true).definition.id == "classic-dark" &&
              library.resolve(.system, systemIsDark: false).definition.id == "classic-light", "System draws Classic Dark or Classic Light")
        check(library.resolve(.system, systemIsDark: true).missing == nil, "System is never reported as missing")
        let gone = library.resolve(AppTheme("sunset"), systemIsDark: false)
        check(gone.definition.id == "classic-dark" && gone.missing == "sunset", "an id nobody has is shown as Classic Dark and named")
        check(library.resolve(.midnight, systemIsDark: false).definition.id == "midnight" && library.resolve(.midnight, systemIsDark: false).missing == nil,
              "a known theme resolves to itself")

        let rowsMidnight = library.choices(current: .midnight)
        check(rowsMidnight.map(\.theme) == [.system] + presets, "picker lists System and every preset: \(rowsMidnight.map(\.id))")
        let rowsClassic = library.choices(current: .classicDark)
        check(rowsClassic.first?.theme == .classicDark && rowsClassic.count == presets.count + 2, "Classic is listed while active")
        check(library.choices(current: .system).first?.theme == .system, "Classic is not listed while it is not active")
        check(rowsMidnight.first?.name == "System" && rowsMidnight.contains { $0.name == "Tokyo Night" }, "rows carry the names from the files")
        check(library.name(of: .tokyoNight) == "Tokyo Night" && library.name(of: .system) == "System" && library.name(of: AppTheme("x-y")) == "x-y",
              "the name of a theme, of System and of an unknown id")

        // MARK: every theme file gives a native palette and complete web tokens
        let tokenKeys: [String: Set<String>] = Dictionary(uniqueKeysWithValues: ThemeSchema.groups.map { ($0.key, Set($0.value)) })
        func checkPayload(_ theme: ThemeDefinition) {
            let id = theme.id
            let web = try! JSONSerialization.jsonObject(with: Data(theme.webPayload.utf8)) as! [String: Any]
            check(web["id"] as? String == id, "\(id): the payload names the theme")
            check(web["mode"] as? String == (theme.isDark ? "dark" : "light"), "\(id): the payload says dark or light")
            for (group, keys) in tokenKeys {
                let tokens = web[group] as? [String: String] ?? [:]
                // The terminal's background, foreground, cursor and selection follow the accent and are worked out by the page, unless a theme states them.
                let required = group == "term" ? keys.subtracting(["background", "foreground", "cursor", "selectionBackground"]) : keys
                check(Set(tokens.keys).isSubset(of: keys) && required.isSubset(of: Set(tokens.keys)),
                      "\(id): web.\(group) has its tokens (missing \(required.subtracting(tokens.keys).sorted()))")
                for (key, value) in tokens where ThemeColor(hex: value) == nil || value != value.lowercased() || value.count != 7 {
                    check(false, "\(id): web.\(group).\(key) is #rrggbb (\(value))")
                }
            }
            let base = web["base"] as? [String: String] ?? [:]
            let p = ThemePalette.make(theme)
            check(base["bg"] == p.bg.cssHex && base["panel"] == p.bgSidebar.cssHex && base["text"] == p.text.cssHex && base["accent"] == p.defaultAccent.cssHex,
                  "\(id): the web base colours are the native ones (one definition)")
            check(!theme.webPayload.contains("\n") && !theme.webPayload.contains("<"), "\(id): the payload is one line of JSON without markup")
        }
        for theme in library.themes { checkPayload(theme) }
        check(!def("classic-dark").web.vars.isEmpty && !def("classic-dark").web.ownAccentVars.isEmpty && def("classic-dark").web.mermaidBuiltIn &&
              def("classic-dark").web.chart?.count == 8, "Classic keeps its exact page values")
        check(presets.allSatisfy { def($0.id).web.vars.isEmpty && !def($0.id).web.mermaidBuiltIn }, "the presets state tokens only")

        // MARK: legibility of every preset (criterion 6) and Classic's own text
        for theme in everyBuiltIn {
            let p = palette(theme)
            let strict = !classics.contains(theme)
            for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar), ("input", p.bgInput), ("hover", p.bgHover), ("active", p.bgActive)] {
                check(ThemeColor.contrast(p.text, surface) >= 4.5, "\(theme.id) text on \(name) is \(ratio(p.text, surface))")
                check(ThemeColor.contrast(p.textBright, surface) >= 4.5, "\(theme.id) bright text on \(name) is \(ratio(p.textBright, surface))")
            }
            check(ThemeColor.contrast(p.text, p.selection) >= 4.5, "\(theme.id) text on selection is \(ratio(p.text, p.selection))")
            check(ThemeColor.contrast(p.onAccent, p.badge) >= 4.5, "\(theme.id) text on badge is \(ratio(p.onAccent, p.badge))")
            check(p.isDark == def(theme.id).isDark, "\(theme.id) palette dark flag matches")
            guard strict else { continue }
            for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar)] {
                check(ThemeColor.contrast(p.textDim, surface) >= 4.5, "\(theme.id) dim text on \(name) is \(ratio(p.textDim, surface))")
                for (cn, c) in [("accent", p.blue), ("green", p.green), ("orange", p.orange), ("yellow", p.yellow),
                                ("purple", p.purple), ("red", p.red), ("cyan", p.cyan)] {
                    check(ThemeColor.contrast(c, surface) >= 4.5, "\(theme.id) \(cn) on \(name) is \(ratio(c, surface))")
                }
            }
            check(ThemeColor.contrast(p.border, p.bg) >= 1.3, "\(theme.id) border is visible on the background (\(ratio(p.border, p.bg)))")
            check(ThemeColor.contrast(p.bgActive, p.bg) >= 1.15, "\(theme.id) the active row is distinguishable (\(ratio(p.bgActive, p.bg)))")
        }

        // Base colours approved in DEC-003.
        let approved: [(AppTheme, UInt32, UInt32, UInt32, UInt32)] = [
            (.darcula, 0x2B2B2B, 0x323232, 0xE0E0E0, 0xE6A15C), (.midnight, 0x151C2B, 0x1D2738, 0xE5EBF5, 0x79B8FF),
            (.graphite, 0x202124, 0x2A2C30, 0xE8EAED, 0xB39DDB), (.paper, 0xFFFCF5, 0xF2EDE3, 0x292724, 0x315E9B),
            (.nord, 0x2E3440, 0x353C4A, 0xE5E9F0, 0x88C0D0), (.forest, 0x1E2A22, 0x26352B, 0xDDD8C0, 0xA7C080),
            (.daylight, 0xF7F9FC, 0xE8EDF4, 0x1F2933, 0x0F766E)]
        for (theme, bg, panel, text, accent) in approved {
            let n = def(theme.id).native
            check(n.bg.rgb == bg && n.bgSidebar.rgb == panel && n.text.rgb == text && n.accent.rgb == accent, "\(theme.id) keeps its approved base colours")
            let p = palette(theme)
            check(p.bg.rgb == bg && p.bgSidebar.rgb == panel && p.text.rgb == text && p.accent.rgb == accent, "\(theme.id) palette uses them")
        }

        // MARK: Classic is the look before themes (DEC-004)
        let cd = palette(.classicDark), cl = palette(.classicLight)
        check(cd.bg.rgb == 0x1E1E1E && cd.bgSidebar.rgb == 0x252526 && cd.blue.rgb == 0x569CD6 && cd.badge.rgb == 0x007ACC && cd.selection.rgb == 0x264F78,
              "Classic Dark keeps the VS Code Dark+ colours")
        check(cl.bg.rgb == 0xFFFFFF && cl.bgSidebar.rgb == 0xF3F3F3 && cl.cyan.rgb == 0x0070C1 && cl.selection.rgb == 0xADD6FF,
              "Classic Light keeps the Light+ colours")

        // MARK: accent
        let plain = palette(.midnight)
        let pink = ThemeColor(0xFF4D9A)
        let custom = palette(.midnight, accent: pink)
        check(custom.accent == pink && custom.badge == pink, "the accent override is the accent and the badge fill")
        check(custom.selection != plain.selection, "the selection follows the accent")
        check(custom.defaultAccent.rgb == 0x79B8FF, "the default accent is still known")
        let dark = palette(.midnight, accent: ThemeColor(0x101828))
        check(ThemeColor.contrast(dark.blue, dark.bg) >= 4.5 && ThemeColor.contrast(dark.blue, dark.bgSidebar) >= 4.5,
              "an unreadable accent is lightened where it is text (\(ratio(dark.blue, dark.bg)))")
        let pale = palette(.paper, accent: ThemeColor(0xFFF2B0))
        check(ThemeColor.contrast(pale.blue, pale.bg) >= 4.5, "a pale accent on Paper is darkened where it is text (\(ratio(pale.blue, pale.bg)))")
        check(ThemeColor.contrast(pale.onAccent, pale.badge) >= 4.5, "text on a pale badge is readable")
        let paleDay = palette(.daylight, accent: ThemeColor(0xFFF2B0))
        check(ThemeColor.contrast(paleDay.blue, paleDay.bg) >= 4.5 && ThemeColor.contrast(paleDay.blue, paleDay.bgSidebar) >= 4.5,
              "a pale accent on Daylight is darkened where it is text (\(ratio(paleDay.blue, paleDay.bg)))")
        let darkForest = palette(.forest, accent: ThemeColor(0x14301C))
        check(ThemeColor.contrast(darkForest.blue, darkForest.bg) >= 4.5, "a dark accent on Forest is lightened where it is text (\(ratio(darkForest.blue, darkForest.bg)))")
        check(palette(.classicDark, accent: pink).blue != cd.blue, "Classic takes an accent too")

        // MARK: per-appearance accent memory (DEC-002)
        var s = WindowThemeSettings(theme: .midnight)
        s.setAccent(ThemeColor(0xFF0000))
        s.select(.paper)
        check(s.activeOverride == nil, "Paper starts with its default accent")
        s.setAccent(ThemeColor(0x00AA00))
        s.select(.midnight)
        check(s.activeOverride?.rgb == 0xFF0000, "returning to Midnight restores its accent")
        s.setAccent(nil)
        check(s.activeOverride == nil && s.accentOverride(for: .paper)?.rgb == 0x00AA00, "resetting clears only the active appearance")
        check(palette(.midnight, accent: s.activeOverride).accent.rgb == 0x79B8FF, "after a reset the default accent is in use")
        s.select(.system)
        check(ThemePalette.make(library.resolve(s.theme, systemIsDark: true).definition, accent: s.activeOverride).accent.rgb == 0x569CD6,
              "System uses the Classic accent")

        // MARK: stored names (every value an earlier version wrote still decodes)
        let oldNames: [(stored: String, id: String)] = [
            ("classicDark", "classic-dark"), ("classicLight", "classic-light"), ("darcula", "darcula"), ("midnight", "midnight"),
            ("graphite", "graphite"), ("tokyoNight", "tokyo-night"), ("carbonRed", "carbon-red"), ("nord", "nord"), ("forest", "forest"),
            ("paper", "paper"), ("daylight", "daylight"), ("system", "system")]
        func decode(_ json: String) -> WindowThemeSettings? { try? JSONDecoder().decode(WindowThemeSettings.self, from: Data(json.utf8)) }
        for (stored, id) in oldNames {
            let decoded = decode(##"{"theme":"\##(stored)","accents":{"\##(stored)":"#123456"}}"##)
            check(decoded?.theme.id == id, "the stored name \(stored) is the theme \(id)")
            check(decoded?.accentOverride(for: AppTheme(id)) == ThemeColor(0x123456), "the accent stored under \(stored) is kept")
            if id != "system" { check(library.definition(id) != nil, "\(stored) still names a shipped theme") }
            let encoded = try! JSONEncoder().encode(WindowThemeSettings(theme: AppTheme(id)))
            check(String(decoding: encoded, as: UTF8.self).contains("\"\(id)\""), "\(id) is stored under its id")
        }
        check(AppTheme(stored: "tokyoNight") == .tokyoNight && AppTheme(stored: "tokyo-night") == .tokyoNight, "both spellings give the same theme")
        for bad in ["", "Has Space", "a_b", "-lead", "trail-", "a--b", String(repeating: "a", count: 41), "ABC"] {
            check(AppTheme(stored: bad) == nil, "'\(bad)' cannot be a theme id")
        }
        check(decode(##"{"theme":"ocean","accents":{"ocean":"#0A0B0C"}}"##)?.theme.id == "ocean", "a well-formed id with no theme behind it is kept")

        // MARK: coding
        var full = WindowThemeSettings(theme: .graphite)
        full.setAccent(ThemeColor(0x123456))
        full.select(.paper)
        full.setAccent(ThemeColor(0xABCDEF))
        let data = try! JSONEncoder().encode(full)
        check((try? JSONDecoder().decode(WindowThemeSettings.self, from: data)) == full, "settings survive a round trip")
        for theme in [AppTheme.tokyoNight, .carbonRed, .nord, .forest, .daylight] {
            let settings = WindowThemeSettings(theme: theme, accents: [theme: pink])
            let encoded = try! JSONEncoder().encode(settings)
            check((try? JSONDecoder().decode(WindowThemeSettings.self, from: encoded)) == settings, "\(theme.id) and its custom accent survive a relaunch")
        }
        check(decode(#"{"theme":"nope!","accents":{}}"#)?.theme == .classicDark, "a name that cannot be an id becomes Classic Dark")
        check(decode(##"{"theme":"paper","accents":{"paper":"#12","midnight":"#0A0B0C","x y":"#ffffff"}}"##)?.accents == [.midnight: ThemeColor(0x0A0B0C)],
              "unreadable accents and names that cannot be ids are dropped")
        check(decode(#"{"theme":"paper"}"#)?.theme == .paper, "a missing accents map is empty")
        check(decode(#"{"theme":3,"accents":[1]}"#)?.theme == .classicDark, "wrong types give the fallback")

        // MARK: starting settings, upgrade and inheritance (criteria 4 and 5, DEC-004, DEC-005)
        func store() -> (ThemeSettingsStore, UserDefaults) {
            let name = "theme-model-tests-\(UUID().uuidString)"
            testDefaultsNames.append(name)
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            return (ThemeSettingsStore(defaults: d), d)
        }
        var (st, d) = store()
        check(st.startingSettings().theme == .classicDark, "nothing saved (today's default) starts as Classic Dark")
        d.set("light", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicLight, "a saved light setting stays light (Classic Light)")
        d.set("dark", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "a saved dark setting stays dark (Classic Dark)")
        d.set("system", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "a saved system setting keeps today's dark look")
        d.set("purple", forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "an unreadable legacy value falls back to Classic Dark")
        d.set(42, forKey: Setting.legacyTheme.name)
        check(st.startingSettings().theme == .classicDark, "a legacy value of the wrong type falls back to Classic Dark")

        d.set("light", forKey: Setting.legacyTheme.name)
        st.remember(full)
        check(st.startingSettings() == full, "the last change wins over the legacy setting and keeps every accent (DEC-005)")
        var newWindow = st.startingSettings()
        newWindow.select(.darcula)
        newWindow.setAccent(ThemeColor(0x010203))
        check(st.startingSettings() == full, "changing a window does not change the stored value until it is remembered")
        st.remember(newWindow)
        check(st.startingSettings().accentOverride(for: .paper)?.rgb == 0xABCDEF && st.startingSettings().theme == .darcula,
              "the next window gets the newest theme with the whole collection")

        d.set(Data("not json".utf8), forKey: Setting.themeLastChanged.name)
        check(st.startingSettings().theme == .classicLight, "an unreadable last-changed record falls back to the legacy setting")
        d.set(Data(##"{"theme":"bo gus","accents":{"paper":"#112233"}}"##.utf8), forKey: Setting.themeLastChanged.name)
        check(st.startingSettings().theme == .classicLight, "a record that names no possible theme is not used")
        d.set(42, forKey: Setting.themeLastChanged.name)
        check(st.startingSettings().theme == .classicLight, "a record of the wrong type is not used")

        // MARK: user themes, from a folder of the person's own files
        let workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("theme-model-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolder) }
        let userFolder = workFolder.appendingPathComponent("themes", isDirectory: true)
        try! FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        func write(_ name: String, _ text: String, in folder: URL? = nil) {
            try! Data(text.utf8).write(to: (folder ?? userFolder).appendingPathComponent(name))
        }
        func themeJSON(_ id: String, native: String, extra: String = "") -> String {
            #"{"schema":1,"id":"\#(id)","name":"\#(id.capitalized)","summary":"A test theme","native":{\#(native)}\#(extra)}"#
        }
        let oceanNative = ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##
        let sandNative = ##""bg":"#FBF6EC","bgSidebar":"#F0E8D8","text":"#2B2A28","accent":"#9A4F1B""##
        write("ocean.json", themeJSON("ocean", native: oceanNative))
        write("sand.json", themeJSON("sand", native: sandNative, extra: #","order":15,"picker":"listed""#))
        write("pinned.json", themeJSON("pinned", native: oceanNative, extra: ##","web":{"syn":{"keyword":"#FF00FF"},"t":{"codeBg":"#0A121A"}}"##))
        let withUser = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: userFolder)
        check(withUser.ignored.isEmpty, "valid user themes are not reported: \(withUser.ignored)")
        check(withUser.themes.count == everyBuiltIn.count + 3, "three user themes join the built-in ones")
        check(withUser.themes.map(\.order) == withUser.themes.map(\.order).sorted(), "the list is in order")
        check(withUser.themes.map(\.id).firstIndex(of: "sand") == 2, "order puts a user theme among the built-in ones (\(withUser.themes.map(\.id)))")
        check(withUser.themes.first { $0.id == "ocean" }?.source == .user(file: "ocean.json"), "a user theme knows its file")
        check(withUser.choices(current: .midnight).contains { $0.theme == AppTheme("ocean") && $0.name == "Ocean" }, "a user theme is a row of the picker")
        check(withUser.resolve(AppTheme("ocean"), systemIsDark: false).definition.id == "ocean", "a user theme resolves")
        for id in ["ocean", "sand", "pinned"] {
            let t = withUser.definition(id)!
            checkPayload(t)
            let p = ThemePalette.make(t)
            for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar), ("input", p.bgInput), ("hover", p.bgHover), ("active", p.bgActive)] {
                check(ThemeColor.contrast(p.text, surface) >= 4.5, "\(id): derived surface \(name) keeps the text readable (\(ratio(p.text, surface)))")
            }
            for (cn, c) in [("green", p.green), ("orange", p.orange), ("yellow", p.yellow), ("purple", p.purple), ("red", p.red), ("cyan", p.cyan), ("dim", p.textDim)] {
                check(ThemeColor.contrast(c, p.bg) >= 4.5 && ThemeColor.contrast(c, p.bgSidebar) >= 4.5, "\(id): derived \(cn) is readable on both backgrounds")
            }
            check(t.web.vars.isEmpty && t.web.ownAccentVars.isEmpty && t.web.chart == nil && !t.web.mermaidBuiltIn, "\(id): no exact page values")
            let codeBackgrounds = [t.web.t["codeBg"]!, t.web.t["preBg"]!]
            for group in [t.web.syn, t.web.structure] {
                for (key, value) in group where key != "count" {
                    for background in codeBackgrounds {
                        check(ThemeColor.contrast(value, background) >= 4.5, "\(id): token \(key) reads on the code background (\(ratio(value, background)))")
                    }
                }
            }
            for key in ["textSecondary", "textTertiary", "secondary", "danger", "success", "warning", "h2", "h3"] {
                check(ThemeColor.contrast(t.web.t[key]!, p.bg) >= 4.5, "\(id): t.\(key) reads on the page background (\(ratio(t.web.t[key]!, p.bg)))")
            }
        }
        check(withUser.definition("ocean")!.isDark && !withUser.definition("sand")!.isDark, "dark or light follows the background")
        let pinned = withUser.definition("pinned")!
        check(pinned.web.syn["keyword"]?.rgb == 0xFF00FF && pinned.web.t["codeBg"]?.rgb == 0x0A121A, "a token a file gives wins over derivation")
        check(pinned.web.syn["string"]?.rgb != 0xFF00FF && pinned.web.t["preBg"] == withUser.definition("ocean")!.web.t["preBg"],
              "the tokens it does not give are derived as for any other theme")
        check(withUser.definition("ocean")!.webPayload == ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: userFolder).definition("ocean")!.webPayload,
              "the same file gives the same payload")

        // MARK: files that cannot be used are reported with their reason, never skipped silently
        let problemFolder = workFolder.appendingPathComponent("problems", isDirectory: true)
        try! FileManager.default.createDirectory(at: problemFolder, withIntermediateDirectories: true)
        let good = oceanNative
        let problems: [(file: String, text: String, reason: String)] = [
            ("broken.json", "{ not json", "not a JSON object"),
            ("array.json", "[1, 2]", "not a JSON object"),
            ("noschema.json", #"{"id":"noschema","name":"X","native":{}}"#, "no schema version"),
            ("future.json", #"{"schema":2,"id":"future","name":"X","native":{}}"#, "newer"),
            ("zero.json", #"{"schema":0,"id":"zero","name":"X","native":{}}"#, "not a known version"),
            ("badid.json", themeJSON("Bad_Id", native: good), "lower-case letters"),
            ("mismatch.json", themeJSON("other", native: good), "named \"mismatch.json\""),
            ("noname.json", ##"{"schema":1,"id":"noname","native":{"bg":"#000000"}}"##, "\"name\""),
            ("nonative.json", #"{"schema":1,"id":"nonative","name":"X"}"#, "\"native\" is missing"),
            ("missingkey.json", themeJSON("missingkey", native: ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5""##), "native.accent"),
            ("badcolour.json", themeJSON("badcolour", native: ##""bg":"red","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##), "#RRGGBB"),
            ("shortcolour.json", themeJSON("shortcolour", native: ##""bg":"#000","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##), "#RRGGBB"),
            ("unknownnative.json", themeJSON("unknownnative", native: good + ##","glow":"#FFFFFF""##), "\"glow\""),
            ("unknowntop.json", themeJSON("unknowntop", native: good, extra: #","css":"body{display:none}""#), "unknown key \"css\""),
            ("lowtext.json", themeJSON("lowtext", native: ##""bg":"#202020","bgSidebar":"#242424","text":"#2A2A2A","accent":"#4FC3F7""##), "contrast"),
            ("lowaccent.json", themeJSON("lowaccent", native: ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#0C1722""##), "\"accent\""),
            ("cssvalue.json", themeJSON("cssvalue", native: good, extra: #","web":{"t":{"codeBg":"red; background:url(https://x.test/a)"}}"#), "#RRGGBB"),
            ("unknowntoken.json", themeJSON("unknowntoken", native: good, extra: ##","web":{"syn":{"glow":"#FFFFFF"}}"##), "\"glow\""),
            ("varsindata.json", themeJSON("varsindata", native: good, extra: ##","web":{"vars":{"--bg-primary":"#000000"}}"##), "only allowed in the themes that ship"),
            ("chartshort.json", themeJSON("chartshort", native: good, extra: ##","web":{"chart":["#000000"]}"##), "8 colours"),
            ("picker.json", themeJSON("picker", native: good, extra: #","picker":"hidden""#), "\"picker\""),
            ("order.json", themeJSON("order", native: good, extra: #","order":-1"#), "\"order\""),
            ("classic-dark.json", themeJSON("classic-dark", native: good), "built-in theme"),
            ("huge.json", themeJSON("huge", native: good, extra: #","summary":"\#(String(repeating: "x", count: 70_000))""#), "larger than"),
        ]
        for item in problems { write(item.file, item.text, in: problemFolder) }
        write("notes.txt", "this is not a theme file", in: problemFolder)
        write("fine.json", themeJSON("fine", native: good), in: problemFolder)
        write("unreadable.json", themeJSON("unreadable", native: good), in: problemFolder)
        chmod(problemFolder.appendingPathComponent("unreadable.json").path, 0o000)
        let before = Dictionary(uniqueKeysWithValues: problems.map { ($0.file, try! Data(contentsOf: problemFolder.appendingPathComponent($0.file))) })
        let checked = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: problemFolder)
        check(checked.themes.map(\.id).contains("fine"), "a good file next to bad ones is used")
        check(checked.themes.count == everyBuiltIn.count + 1, "no bad file becomes a theme (\(checked.themes.count - everyBuiltIn.count) user themes)")
        for item in problems {
            let found = checked.ignored.first { $0.file == item.file }
            check(found != nil, "\(item.file) is reported, not skipped")
            check(found?.reason.contains(item.reason) == true, "\(item.file): the reason names the problem (wanted \"\(item.reason)\", got \"\(found?.reason ?? "-")\")")
        }
        check(checked.ignored.first { $0.file == "unreadable.json" }?.reason.contains("cannot be read") == true, "an unreadable file is reported")
        check(!checked.ignored.contains { $0.file == "notes.txt" || $0.file == "fine.json" }, "a file that is not .json is not a theme file, and a good one is not reported")
        check(checked.ignored.count == problems.count + 1, "exactly the bad files are reported (\(checked.ignored.map(\.file)))")
        for item in problems { check((try? Data(contentsOf: problemFolder.appendingPathComponent(item.file))) == before[item.file], "\(item.file) is left exactly as it was") }
        chmod(problemFolder.appendingPathComponent("unreadable.json").path, 0o644)

        // MARK: limits and odd folders
        let crowdedFolder = workFolder.appendingPathComponent("crowded", isDirectory: true)
        try! FileManager.default.createDirectory(at: crowdedFolder, withIntermediateDirectories: true)
        for number in 0..<(ThemeLibrary.userFileLimit + 2) {
            write(String(format: "t%03d.json", number), themeJSON(String(format: "t%03d", number), native: good), in: crowdedFolder)
        }
        let crowded = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: crowdedFolder)
        check(crowded.themes.count == everyBuiltIn.count + ThemeLibrary.userFileLimit, "no more than \(ThemeLibrary.userFileLimit) user files are read")
        check(crowded.ignored.count == 2 && crowded.ignored.allSatisfy { $0.reason.contains("more than \(ThemeLibrary.userFileLimit)") }, "the files beyond the limit are reported")
        check(ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: workFolder.appendingPathComponent("absent")).ignored.isEmpty, "a missing themes folder is not a problem")
        check(ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: problemFolder.appendingPathComponent("fine.json")).ignored.count == 1,
              "a themes 'folder' that is a file is reported")
        let noBuiltIn = ThemeLibrary.load(builtInFolder: nil, userFolder: nil)
        check(noBuiltIn.themes.isEmpty && noBuiltIn.ignored.count == 1, "an app without its built-in folder says so")

        // MARK: adding a built-in theme is adding one file
        let extendedFolder = workFolder.appendingPathComponent("builtin", isDirectory: true)
        try! FileManager.default.copyItem(at: builtInFolder, to: extendedFolder)
        write("aurora.json", themeJSON("aurora", native: ##""bg":"#10201C","bgSidebar":"#162A25","text":"#E3F2EC","accent":"#5CE0B8""##, extra: ##","order":105"##), in: extendedFolder)
        let extended = ThemeLibrary.load(builtInFolder: extendedFolder, userFolder: nil)
        check(extended.themes.count == library.themes.count + 1 && extended.ignored.isEmpty, "one more file is one more theme")
        check(extended.themes.last?.id == "aurora", "it is listed in its place with nothing else edited")
        check(extended.choices(current: .midnight).map(\.theme.id).last == "aurora", "and it is a row of the picker")
        let aurora = ThemePalette.make(extended.definition("aurora")!)
        check(aurora.isDark && ThemeColor.contrast(aurora.text, aurora.bg) >= 4.5, "and it draws")

    }
}


private let windowStateTestModeKey = SettingsKey<String>("search.panelMode", default: "Project", scope: .window)

extension EditorHostTests {
    @MainActor func testWindowStateIsolation() throws {
        let editorDirectory = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        // The test's own keys: the registry's names with defaults a stored value can be told from.
        let modeKeyX = SettingsKey<String>("search.panelMode", default: "x", scope: .window)
        let infoKey = SettingsKey<Bool>("contents.infoExpanded", default: true, scope: .window)
        let countKey = SettingsKey<Int>("n", default: 0, scope: .window)
        let countKey7 = SettingsKey<Int>("n", default: 7, scope: .window)
        let countAsText = SettingsKey<String>("n", default: "", scope: .window)

        func freshDefaults() -> (UserDefaults, () -> Void) {
            let suite = "window-ui-state-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            return (defaults, { defaults.removePersistentDomain(forName: suite) })
        }

        // MARK: Two windows (WindowUIState belongs to the main actor, as the views that read it do)

        @MainActor func twoWindows() {
            let (defaults, cleanup) = freshDefaults()
            defer { cleanup() }
            let a = WindowUIState(defaults: defaults), b = WindowUIState(defaults: defaults)
            check(a.value(windowStateTestModeKey) == "Project", "a value nobody set is the fallback")
            check(b.value(windowStateTestModeKey) == "Project", "the second window starts the same")

            a.set("Documents", for: windowStateTestModeKey)
            check(a.value(windowStateTestModeKey) == "Documents", "the window that changed a value shows it")
            check(b.value(windowStateTestModeKey) == "Project", "another window that already shows it stays on its own value")

            b.set(false, for: infoKey)
            check(a.value(infoKey), "a flag set in one window leaves the other expanded, even one it shows only now")

            var changes = 0
            let watcher = b.objectWillChange.sink { changes += 1 }
            a.set("Project", for: windowStateTestModeKey)
            check(changes == 0, "a change in one window does not redraw another window")
            b.set(350.0, for: Setting.uiStudioInspectorWidth)
            check(changes == 1, "a change in the window redraws that window")
            b.set(350.0, for: Setting.uiStudioInspectorWidth)
            check(changes == 1, "setting the same value again redraws nothing")
            b.set(360.0, for: Setting.leftPanelWidth, publishing: false)
            check(changes == 1, "a divider position kept by an AppKit view redraws nothing")
            watcher.cancel()

            let later = WindowUIState(defaults: defaults)
            check(later.value(modeKeyX) == "Project", "a window opened later starts from the last value anywhere")
            check(later.value(Setting.leftPanelWidth) == 360.0, "the seed of a quiet value is kept too")
            a.set("Documents", for: windowStateTestModeKey)
            check(later.value(modeKeyX) == "Project", "and from then on follows nobody")
        }
        twoWindows()

        // MARK: The session

        @MainActor func theSession() {
            let (defaults, cleanup) = freshDefaults()
            let (emptyDefaults, emptyCleanup) = freshDefaults()
            defer { cleanup(); emptyCleanup() }
            let a = WindowUIState(defaults: defaults)
            a.set("Documents", for: windowStateTestModeKey)
            a.set(412.0, for: Setting.uiStudioInspectorWidth)
            a.set(false, for: infoKey)
            a.set(4, for: countKey)
            let data = try! JSONEncoder().encode(a.saved)
            let decoded = try! JSONDecoder().decode([String: WindowUIValue].self, from: data)
            check(decoded == a.saved, "the values survive the session file")

            let restored = WindowUIState(defaults: emptyDefaults)
            restored.restore(decoded)
            check(restored.value(windowStateTestModeKey) == "Documents" &&
                  restored.value(Setting.uiStudioInspectorWidth) == 412.0 &&
                  !restored.value(infoKey) && restored.value(countKey) == 4,
                  "a restored window has its own values, not the starting ones")

            let old = WindowUIState(defaults: emptyDefaults)
            old.restore(nil)
            check(old.saved.isEmpty && old.value(windowStateTestModeKey) == "Project", "a session saved before interface state has none")

            let wrongType = WindowUIState(defaults: emptyDefaults)
            wrongType.restore(["n": .string("not a number")])
            check(wrongType.value(countKey7) == 7, "a restored value of the wrong type falls back")
            check(wrongType.existing(countKey7) == 7 && wrongType.existing(countAsText) == nil, "the fallback replaces it, and existing() reads only the stored type")
        }
        theSession()

        // MARK: The editor page's own choices

        do {
            let keys = EditorWindowPrefs.keys
            check(keys.contains("markview-font-size") && keys.contains("markview-xray-details-width") && keys.contains("markview-code-notes-width")
                  && keys.contains("markview-xray-details-hidden"), "the text size, the panel widths and the X-Ray details are the window's")
            check(!keys.contains { $0.hasPrefix("mvMap:") }, "a map's view of a document is not the window's")
            check(EditorWindowPrefs.accepts(key: "markview-font-size", value: "13"), "the page may save its text size")
            check(!EditorWindowPrefs.accepts(key: "markview-other", value: "1"), "a key the window does not keep is refused")
            check(!EditorWindowPrefs.accepts(key: "markview-font-size", value: String(repeating: "9", count: 33)), "a long value is refused")
            check(Setting.editorPref("markview-font-size").name == "editor.markview-font-size", "the window files the value under its own name")

            let script = EditorWindowPrefs.script(values: ["markview-font-size": "16", "markview-other": "1", "markview-code-notes-width": "</script>"])
            check(script.contains("\"markview-font-size\":\"16\""), "the window's text size starts the page")
            check(!script.contains("markview-other\":"), "a value for a key the window does not keep is not passed to the page")
            check(!script.contains("</script>"), "nothing in the script can end the script element")
        }

        // MARK: Excluded folders belong to the project

        do {
            let (defaults, cleanup) = freshDefaults()
            defer { cleanup() }
            let one = URL(fileURLWithPath: "/work/one/app"), two = URL(fileURLWithPath: "/work/two/app")
            check(ExcludedFolders.key(for: one).name != ExcludedFolders.key(for: two).name, "two projects with the same folder name have different keys")
            let settings = Settings(defaults)
            check(ExcludedFolders.load(for: one, defaults: defaults).isEmpty, "a project with nothing excluded has none")
            ExcludedFolders.save(["build", "node_modules"], for: one, defaults: defaults)
            check(ExcludedFolders.load(for: one, defaults: defaults) == ["build", "node_modules"], "a project's list comes back")
            check(ExcludedFolders.load(for: two, defaults: defaults).isEmpty, "another project of the same folder name does not get it")

            settings.set(["dist"], for: Setting.excludedFoldersByName("legacy"))
            let legacy = URL(fileURLWithPath: "/work/legacy")
            check(ExcludedFolders.load(for: legacy, defaults: defaults) == ["dist"], "a list saved under the folder's name is not lost")
            ExcludedFolders.save(["dist", "out"], for: legacy, defaults: defaults)
            check(settings.stored(Setting.excludedFoldersByName("legacy")) == ["dist"], "and the project's own changes do not touch the old entry")
            check(ExcludedFolders.load(for: legacy, defaults: defaults) == ["dist", "out"], "the project then keeps its own list")
        }

        // MARK: Two hosted windows (@WindowStorage)

        /// What a hosted view last showed, and the binding it was given.
        final class Shown {
            var text = ""
            var renders = 0
            var binding: Binding<String>?
        }

        struct ModeView: View {
            @WindowStorage(windowStateTestModeKey) private var mode: String
            let shown: Shown
            var body: some View {
                shown.text = mode
                shown.renders += 1
                shown.binding = $mode
                return Text(mode)
            }
        }

        @MainActor func hostedChecks() {
            _ = NSApplication.shared
            let (defaults, cleanup) = freshDefaults()
            defer { cleanup() }
            var windows: [NSWindow] = []
            func host(_ state: WindowUIState, _ shown: Shown) {
                let hosting = NSHostingView(rootView: ModeView(shown: shown).environmentObject(state))
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 200, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                windows.append(window)
            }
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

            let stateA = WindowUIState(defaults: defaults), stateB = WindowUIState(defaults: defaults)
            let shownA = Shown(), shownB = Shown()
            host(stateA, shownA)
            host(stateB, shownB)
            settle()
            check(shownA.text == "Project" && shownB.text == "Project", "both hosted windows start on the same mode")

            let rendersB = shownB.renders
            shownA.binding?.wrappedValue = "Documents"
            settle()
            check(shownA.text == "Documents", "the window where the person changed the mode shows it")
            check(shownB.text == "Project", "the other window stays on its own mode")
            check(shownB.renders == rendersB, "and is not even redrawn")

            shownB.binding?.wrappedValue = "Project"
            shownB.binding?.wrappedValue = "Documents"
            settle()
            shownA.binding?.wrappedValue = "Project"
            settle()
            check(shownA.text == "Project" && shownB.text == "Documents", "each window goes its own way")
            check(stateA.saved["search.panelMode"] == .string("Project") && stateB.saved["search.panelMode"] == .string("Documents"),
                  "and each saves its own value with its session")
            windows.forEach { $0.close() }
        }
        hostedChecks()

        // MARK: The editor page, in two real web views that share one localStorage

        final class PageMessages: NSObject, WKScriptMessageHandler {
            var received: [[String: Any]] = []
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                if let body = message.body as? [String: Any] { received.append(body) }
            }
        }

        @MainActor func pageChecks() {
            _ = NSApplication.shared
            let editor = editorDirectory
            let contract = try! BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json"))
            let mvKit = (try! String(contentsOfFile: editor + "/js/mv-kit.js", encoding: .utf8)).replacingOccurrences(of: "</", with: "<\\/")
            var keep: [WKWebView] = []
            let isolatedWebsiteData = WKWebsiteDataStore.nonPersistent()
            func page(own: [String: String]) -> (WKWebView, PageMessages) {
                let messages = PageMessages()
                let config = WKWebViewConfiguration()
                config.websiteDataStore = isolatedWebsiteData
                config.userContentController.add(messages, name: "bridge")
                // The page sends through mvBridge (mv-kit.js) with the contract the app gives it, as the editor does (AR-28).
                config.userContentController.addUserScript(contract.userScript)
                let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
                web.loadHTMLString("<html><head><script>\(mvKit)</script><script>\(EditorWindowPrefs.script(values: own))</script></head><body>x</body></html>",
                                   baseURL: URL(string: "https://markview.test/"))
                let deadline = Date().addingTimeInterval(10)
                while web.isLoading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                keep.append(web)
                return (web, messages)
            }
            func run(_ web: WKWebView, _ js: String) -> String {
                var result = "no answer"
                var done = false
                web.evaluateJavaScript(js) { value, error in
                    result = (value as? String) ?? error.map { "ERR \($0)" } ?? "nil"
                    done = true
                }
                let deadline = Date().addingTimeInterval(5)
                while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
                return result
            }
            let size = "String(localStorage.getItem('markview-font-size'))"

            let (a, messagesA) = page(own: ["markview-font-size": "16"])
            check(run(a, "localStorage.clear(); 'cleared'") == "cleared", "the page's own localStorage still works")
            let (b, messagesB) = page(own: [:])
            check(run(a, size) == "16", "a page starts with its window's own text size")
            check(run(b, size) == "null", "a window with none starts from the shared store (empty here)")

            check(run(a, "localStorage.setItem('markview-font-size', 18); \(size)") == "18", "a save in the page is read back by the page")
            check(messagesA.received.count == 1 && messagesA.received[0]["type"] as? String == "editorWindowPref" &&
                  (messagesA.received[0]["payload"] as? [String: Any])?["key"] as? String == "markview-font-size" &&
                  (messagesA.received[0]["payload"] as? [String: Any])?["value"] as? String == "18",
                  "and reported to the app with its key and value")
            check(run(b, size) == "null", "the other window's page does not see it")
            check(messagesB.received.isEmpty, "and heard nothing")

            check(run(b, "localStorage.setItem('other-key', 'x'); String(localStorage.getItem('other-key'))") == "x", "any other key is the shared localStorage as before")
            check(messagesB.received.isEmpty, "and is not reported")

            let (c, _) = page(own: [:])
            check(run(c, size) == "18", "a window opened later starts from the last choice anywhere")
            check(run(a, "localStorage.setItem('markview-code-notes-width', 300); String(localStorage.getItem('markview-code-notes-width'))") == "300",
                  "the panel widths go the same way")
            check(run(c, "String(localStorage.getItem('markview-code-notes-width'))") == "300", "a page that has not read a width yet starts from the shared one")
            _ = keep
        }
        pageChecks()

    }
}


extension EditorHostTests {
    @MainActor func testImageAttachmentsOnIsolatedPasteboard() throws {
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(name): \(detail())", line: line)
        }
        func makeImage(_ width: Int, _ height: Int) -> NSImage {
            let image = NSImage(size: NSSize(width: width, height: height))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            image.unlockFocus()
            return image
        }
        /// An image of random pixels: its PNG is about as large as the raw pixels, so a big one is over the size limit.
        func noise(_ side: Int) -> NSImage {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            var generator = SystemRandomNumberGenerator()
            for offset in 0..<(rep.bytesPerRow * side) { rep.bitmapData![offset] = UInt8.random(in: 0...255, using: &generator) }
            let image = NSImage(size: NSSize(width: side, height: side))
            image.addRepresentation(rep)
            return image
        }
        func size(of png: Data) -> (Int, Int)? {
            guard let rep = NSBitmapImageRep(data: png) else { return nil }
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        func isPNG(_ data: Data) -> Bool { data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) }
        func isEightHex(_ name: String) -> Bool {
            let stem = name.dropLast(4)
            return name.hasSuffix(".png") && stem.count == 8 && stem.allSatisfy { "0123456789abcdef".contains($0) }
        }

        // Normalisation: PNG out, small images keep their size, large ones shrink to the longer side.
        let small = ImageAttachments.pngData(from: makeImage(200, 100))
        check(small.map(isPNG) == true, "converts to PNG")
        check(small.flatMap(size) ?? (0, 0) == (200, 100), "small image keeps its size")
        let big = ImageAttachments.pngData(from: makeImage(4000, 1000))
        check(big.flatMap(size) ?? (0, 0) == (1600, 400), "large image shrinks to 1600 on the long side")
        check(ImageAttachments.pngData(from: NSImage(size: .zero)) == nil, "empty image gives nothing")
        check(ImageAttachments.maxCount == 6 && ImageAttachments.maxBytes == 8 * 1_048_576 && ImageAttachments.maxSide == 1600, "the limits")

        // Pasteboard: an image, an image file, and text only.
        let board = NSPasteboard(name: NSPasteboard.Name("markview.attachments.test.\(UUID().uuidString)"))
        defer { board.clearContents(); board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([makeImage(120, 80)])
        check(ImageAttachments.images(on: board).count == 1, "reads an image from the pasteboard")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("image-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("shot.png")
        try small!.write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])
        let fromFile = ImageAttachments.images(on: board)
        check(fromFile.count == 1 && fromFile.first.flatMap(size) ?? (0, 0) == (200, 100), "reads an image file copied in Finder")

        let text = tmp.appendingPathComponent("note.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        board.clearContents()
        board.writeObjects([text as NSURL])
        check(ImageAttachments.images(on: board).isEmpty, "a copied text file is not an image")
        board.clearContents()
        board.setString("just text", forType: .string)
        check(ImageAttachments.images(on: board).isEmpty, "plain text gives no image, so the paste goes on as text")
        check(ImageAttachments.image(at: file) != nil, "an image file can be chosen")
        check(ImageAttachments.image(at: text) == nil, "a text file cannot")

        // File naming: <8 hex digits>.png in the folder given, made when missing; every file is new.
        let folder = tmp.appendingPathComponent("a/b/attachments")
        let first = try ImageAttachments.save(small!, into: folder)
        let second = try ImageAttachments.save(small!, into: folder)
        check(first.deletingLastPathComponent().path == folder.path && isEightHex(first.lastPathComponent), "saved as <8 hex digits>.png in the folder",
              first.path)
        let firstBytes = try Data(contentsOf: first), secondBytes = try Data(contentsOf: second)
        check(first != second && firstBytes == small! && secondBytes == small!, "every save is a new file with the PNG bytes")
        check(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count == 2, "nothing else is written")

        // The list: images are added up to the count, a refusal is named.
        var list = ImageAttachmentList()
        check(list.isEmpty && list.notice == nil, "a new list is empty")
        list.add([small!, small!, small!])
        check(list.items.count == 3 && list.notice == nil, "images within the limits are added without a notice")
        list.add([small!, small!, small!, small!, small!])
        check(list.items.count == 6, "no more than six images are kept", "\(list.items.count)")
        check(list.notice == "A request takes at most 6 images; 2 not added.", "the refusal by count is named", list.notice ?? "nil")
        list.add([small!])
        check(list.items.count == 6 && list.notice == "A request takes at most 6 images; 1 not added.", "a seventh image is refused with a notice", list.notice ?? "nil")
        let removed = list.items[0].id
        list.remove(removed)
        check(list.items.count == 5 && !list.items.contains { $0.id == removed } && list.notice == nil, "an image can be removed, which clears the notice")
        list.add([small!])
        check(list.items.count == 6 && list.notice == nil, "a removed place can be taken again")
        list.removeAll()
        check(list.isEmpty && list.notice == nil, "removeAll empties the list")

        // Size: a PNG over 8 MB after the 1600 px downscale is refused, with a notice; a smaller one is not.
        let heavy = ImageAttachments.pngData(from: noise(2400))
        check((heavy.flatMap(size) ?? (0, 0)) == (1600, 1600) && (heavy?.count ?? 0) > ImageAttachments.maxBytes, "a noisy screenshot is over 8 MB after the downscale",
              "\(heavy?.count ?? 0)")
        list.add([heavy!])
        check(list.isEmpty && list.notice == "An image is over 8 MB and not added.", "an image over 8 MB is refused with a notice", list.notice ?? "nil")
        list.add([heavy!, Data(count: ImageAttachments.maxBytes + 1), small!])
        check(list.items.count == 1 && list.notice == "2 images are over 8 MB and not added.",
              "the images that fit are kept next to the refused ones", list.notice ?? "nil")
        list.add([Data("not an image".utf8)])
        check(list.items.count == 1 && list.notice == "An image could not be read.", "data that is no image is named, not dropped silently", list.notice ?? "nil")
        list.add([heavy!, small!, Data("x".utf8)])
        check(list.items.count == 2 && list.notice == "An image is over 8 MB and not added. An image could not be read.", "several refusals share one line",
              list.notice ?? "nil")
        list.removeAll()

        // The pasteboard into the list: true when there were images (also when all were refused), false for text.
        board.clearContents()
        board.writeObjects([makeImage(90, 60)])
        check(list.addFromPasteboard(board) && list.items.count == 1, "an image on the clipboard is taken")
        board.clearContents()
        board.setString("just text", forType: .string)
        check(!list.addFromPasteboard(board) && list.items.count == 1 && list.notice == nil, "text on the clipboard is not taken")
        for _ in 0..<5 { list.add([small!]) }
        board.clearContents()
        board.writeObjects([makeImage(90, 60)])
        check(list.items.count == 6 && list.addFromPasteboard(board) && list.items.count == 6 && list.notice != nil,
              "a full list still takes the paste as an image: it is refused with a notice, not pasted as text")

        // A paste of text goes in at the caret, in place of the selection, and the text view's delegate hears of it.
        final class Listener: NSObject, NSTextViewDelegate {
            var changes = 0
            func textDidChange(_ notification: Notification) { changes += 1 }
        }
        let listener = Listener()
        func textView(_ string: String) -> NSTextView {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
            view.isEditable = true
            view.delegate = listener
            view.string = string
            return view
        }
        let middle = textView("Hello world")
        middle.setSelectedRange(NSRange(location: 5, length: 0))
        MainActor.assumeIsolated { ImageAttachments.insertAtCaret(", dear", in: middle) }
        check(middle.string == "Hello, dear world", "text is inserted at the caret, not at the end", middle.string)
        check(middle.selectedRange() == NSRange(location: 11, length: 0), "the caret ends after the inserted text", "\(middle.selectedRange())")
        check(listener.changes == 1, "the text view's delegate is told, so a binding follows", "\(listener.changes)")
        let replaced = textView("Hello world")
        replaced.setSelectedRange(NSRange(location: 6, length: 5))
        MainActor.assumeIsolated { ImageAttachments.insertAtCaret("there", in: replaced) }
        check(replaced.string == "Hello there", "the selection is replaced", replaced.string)
        let start = textView("world")
        start.setSelectedRange(NSRange(location: 0, length: 0))
        MainActor.assumeIsolated { ImageAttachments.insertAtCaret("Hello ", in: start) }
        check(start.string == "Hello world", "a paste at the start goes before the text", start.string)

        // Without a focused text view the text is appended to the draft; an empty clipboard pastes nothing.
        var appended: [String] = []
        board.clearContents()
        board.setString("tail", forType: .string)
        MainActor.assumeIsolated { ImageAttachments.pasteText(from: board) { appended.append($0) } }
        check(appended == ["tail"], "with no text view in focus the text is appended", "\(appended)")
        board.clearContents()
        MainActor.assumeIsolated { ImageAttachments.pasteText(from: board) { appended.append($0) } }
        check(appended == ["tail"], "an empty clipboard pastes nothing", "\(appended)")

        // Dropped items: a file of the Finder, a picture dragged from an app, other files, and text.
        final class Delivered: @unchecked Sendable {
            private let lock = NSLock()
            private var pngs: [Data] = []
            private var mainThread = true
            func add(_ data: Data) { lock.withLock { pngs.append(data); mainThread = mainThread && Thread.isMainThread } }
            var all: [Data] { lock.withLock { pngs } }
            var deliveredOnMain: Bool { lock.withLock { mainThread } }
        }
        func drop(_ providers: [NSItemProvider], expecting count: Int) -> (accepted: Bool, images: [Data], mainThread: Bool) {
            let delivered = Delivered()
            let accepted = MainActor.assumeIsolated { ImageAttachments.load(from: providers) { delivered.add($0) } }
            let deadline = Date().addingTimeInterval(count == 0 ? 1 : 5)
            while Date() < deadline, delivered.all.count < count { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            return (accepted, delivered.all, delivered.deliveredOnMain)
        }
        let droppedFile = drop([NSItemProvider(object: file as NSURL)], expecting: 1)
        check(droppedFile.accepted && droppedFile.images.count == 1 && droppedFile.images.first.flatMap(size) ?? (0, 0) == (200, 100), "a dropped image file is read")
        let droppedPicture = drop([NSItemProvider(object: makeImage(64, 48))], expecting: 1)
        check(droppedPicture.accepted && droppedPicture.images.count == 1 && droppedPicture.images.first.flatMap(size) ?? (0, 0) == (64, 48), "a dropped picture is read")
        let mixedProvider = NSItemProvider(object: text as NSURL)
        let fallbackImage = makeImage(40, 30)
        mixedProvider.registerObject(ofClass: NSImage.self, visibility: .all) { completion in
            completion(fallbackImage, nil)
            return nil
        }
        let fallbackPicture = drop([mixedProvider], expecting: 1)
        check(fallbackPicture.accepted && fallbackPicture.images.first.flatMap(size) ?? (0, 0) == (40, 30), "a non-image file falls back to the dropped picture")
        check(droppedFile.mainThread && droppedPicture.mainThread && fallbackPicture.mainThread, "dropped images are delivered on the main thread")
        let droppedText = drop([NSItemProvider(object: text as NSURL)], expecting: 0)
        check(droppedText.images.isEmpty, "a dropped text file gives no image")
        check(!MainActor.assumeIsolated { ImageAttachments.load(from: [NSItemProvider(object: "just words" as NSString)]) { _ in } }, "dropped text is refused")

    }
}


private extension WelcomeBackdrop {
    static let bugs = WelcomeBackdrop(rawValue: "bugs")!, blueprint = WelcomeBackdrop(rawValue: "blueprint")!, orbit = WelcomeBackdrop(rawValue: "orbit")!
    static let circuit = WelcomeBackdrop(rawValue: "circuit")!, launch = WelcomeBackdrop(rawValue: "launch")!, garden = WelcomeBackdrop(rawValue: "garden")!
}

extension EditorHostTests {
    func testProjectBackdropSelectionAndBoundedScan() async throws {
        func check(_ label: String, _ value: Bool, line: UInt = #line) {
            XCTAssertTrue(value, label, line: line)
        }
        var context = ProjectBackdropContext(identity: "/projects/mobile", signals: .init(platform: .ios, inspected: true), openBugs: 0, criticalBugs: 0, features: 4, completedFeatures: 1)
        check("iOS projects become a device blueprint", context.scene == .blueprint)
        context.openBugs = 9
        check("many open bugs override the platform", context.scene == .bugs && context.reason.contains("9 open bugs"))
        context.openBugs = 2; context.criticalBugs = 2
        check("multiple critical bugs surface even in a small backlog", context.scene == .bugs)
        context.criticalBugs = 0; context.openBugs = 0; context.signals.platform = .backend
        check("a backend has circuit flow", context.scene == .circuit)
        context.signals.platform = .web
        check("a web application has circuit flow", context.scene == .circuit)
        context.signals.sourceFiles = 220
        check("many moving parts form an orbital system", context.scene == .orbit)
        context.signals.platform = .ios
        check("a large mobile project keeps its device identity", context.scene == .blueprint)
        context.signals = .init(inspected: true); context.completedFeatures = 4
        check("completed work with no open bugs launches", context.scene == .launch)
        context.completedFeatures = 1
        check("a growing project has a code garden", context.scene == .garden)
        context.issuesKnown = false
        check("unloaded issues are not reported as zero bugs", !context.summary.contains("bugs"))
        let seed = context.seed
        context.openBugs = 10000; context.features = 20000
        check("project composition survives changing issue counts", context.seed == seed && context.detail == 4)
        context.identity = "/projects/other"
        check("another project has its own composition", context.seed != seed)
        check("By Project resolves to the current evidence", WelcomeBackdrop.project.scene(pick: 1, project: context) == context.scene)
        check("an empty window has a usable project-mode fallback", WelcomeBackdrop.project.scene(pick: 1) == .garden)
        check("all five new scenes can be restored", ["orbit", "blueprint", "circuit", "garden", "launch", "project"].allSatisfy { WelcomeBackdrop.stored($0).rawValue == $0 })

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("project.yml", "targets:\n  App:\n    platform: iOS\n")
        try write("App/Scene.swift", "import UIKit\n")
        try write("README.md", "# Project")
        var found = ProjectBackdropScanner.scan(root)
        check("scanner detects an iOS XcodeGen target", found.platform == .ios && found.sourceFiles == 1 && found.inspected)
        check("scanner counts languages and documentation", found.languages["Swift"] == 1 && found.documentationFiles == 1)
        try write("project.yml", "targets:\n  App:\n    platform: macOS\n")
        found = ProjectBackdropScanner.scan(root)
        check("macOS does not become iOS merely because Swift is present", found.platform == .macOS)
        try FileManager.default.removeItem(at: root.appendingPathComponent("project.yml"))
        try write("package.json", #"{"dependencies":{"react":"1"}}"#)
        check("web manifests are detected", ProjectBackdropScanner.scan(root).platform == .web)
        try write("package.json", #"{"dependencies":{"express":"1"}}"#)
        check("backend manifests are detected", ProjectBackdropScanner.scan(root).platform == .backend)
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        try write("node_modules/react-native/package.json", #"{"name":"react-native"}"#)
        try write("build/ios/Generated.swift", "")
        try write("Tests/Fixtures/ios/Scene.swift", "")
        let outside = root.appendingPathComponent("../outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("ios"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        found = ProjectBackdropScanner.scan(root)
        check("dependencies, generated output, tests and symlinks do not classify the project", found.platform == .unknown && found.sourceFiles == 1)
        try write("package.json", String(repeating: " ", count: 33000) + #"{"dependencies":{"react":"1"}}"#)
        check("manifest reads are bounded", ProjectBackdropScanner.scan(root).platform == .unknown)
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        for index in 0..<2700 { try write("Sources/f\(index).swift", "") }
        found = ProjectBackdropScanner.scan(root)
        check("large trees stop at the entry budget and disclose sampling", found.sampled && found.sourceFiles <= ProjectBackdropScanner.entryLimit && found.inspected)
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return ProjectBackdropScanner.scan(root)
        }.value
        check("cancelled scanning stops without publishing a completed inspection", !cancelled.inspected && cancelled.sourceFiles == 0)
    }
}


extension EditorHostTests {
    @MainActor func testDataViewersWithRealSchemeHandler() throws {
        let editor = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/tests/fixtures/data", isDirectory: true).standardizedFileURL.path
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, "\(message): \(detail.prefix(400))", line: line)
        }
        final class Bridge: NSObject, WKScriptMessageHandler {
            var messages: [[String: Any]] = []
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                if let body = message.body as? [String: Any] { messages.append(body) }
            }
        }
        final class Loaded: NSObject, WKNavigationDelegate {
            var done = false
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        }

        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        let handler = DataFileSchemeHandler()
        handler.isAllowed = { $0.standardizedFileURL.path.hasPrefix(fixtures + "/") }
        config.setURLSchemeHandler(handler, forURLScheme: "markview-data")
        let bridge = Bridge()
        config.userContentController.add(bridge, name: "bridge")
        config.userContentController.addUserScript(try BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = web
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "bridge"); window.close() }
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

        func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }

        /// Run `body` (an async function body) in the page and return its string result.
        func js(_ body: String, timeout: TimeInterval = 20) -> String {
            var out: String?
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): out = value as? String ?? "\(String(describing: value))"
                case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                }
            }
            spin(timeout) { out != nil }
            return out ?? "TIMEOUT"
        }

        /// Open a fixture in the data viewer and wait until its grid or log is shown.
        func open(_ name: String, _ kind: String) -> String {
            let src = "markview-data://" + fixtures + "/" + name
            return js("""
            window.setDataContent({ src: \(String(reflecting: src)), kind: '\(kind)', name: '\(name)', reload: false });
            const c = document.getElementById('data-container');
            for (let i = 0; i < 200; i++) {
              if (c.querySelector('.dv-grid tbody tr[data-row], .dv-log .ln[data-pos], .dv-msg.error:not(:empty)')) break;
              await new Promise(r => setTimeout(r, 50));
            }
            return c.innerText;
            """)
        }

        spin(15) { loaded.done }
        check(js("return typeof window.setDataContent") == "function", "the data viewers are on the page")

        var text = open("plants.csv", "table")
        check(text.contains("40 rows") && text.contains("height_cm") && text.contains("Basil"), "CSV: rows and header", text)
        text = js("""
        const c = document.getElementById('data-container');
        c.querySelector('.dv-sqlbtn').click();
        c.querySelector('.dv-sql textarea').value = 'SELECT plant, COUNT(*) AS n FROM data GROUP BY plant ORDER BY plant';
        c.querySelector('.dv-run').click();
        await new Promise(r => setTimeout(r, 300));
        return c.querySelector('.dv-grid').innerText;
        """)
        check(text.contains("Basil\t10") && text.contains("Tomato\t10"), "CSV: SQL with GROUP BY", text)
        _ = open("plants.csv", "table")
        text = js("""
        const c = document.getElementById('data-container');
        const input = c.querySelectorAll('thead input')[2]; input.value = '>45'; input.dispatchEvent(new Event('change'));
        await new Promise(r => setTimeout(r, 200));
        c.querySelectorAll('thead tr:first-child th[data-col]')[2].click(); await new Promise(r => setTimeout(r, 200));
        c.querySelectorAll('thead tr:first-child th[data-col]')[2].click(); await new Promise(r => setTimeout(r, 200));
        return c.querySelector('.dv-count').textContent + '|' + c.querySelector('tbody tr[data-row] td:nth-child(4)').textContent;
        """)
        check(text.hasPrefix("5 rows") && text.hasSuffix("|50"), "CSV: numeric filter >45 and descending sort", text)
        text = js("""
        const c = document.getElementById('data-container');
        c.querySelectorAll('thead tr:first-child th[data-col]')[2].click();
        await new Promise(r => setTimeout(r, 200));
        c.querySelector('.dv-stats').click();
        return c.querySelector('.dv-side').innerText;
        """)
        check(text.contains("Distinct") && text.contains("Max"), "CSV: column statistics", text)

        text = open("plants.tsv", "table")
        check(text.contains("5 rows") && text.contains("Mint"), "TSV", text)
        text = open("events.jsonl", "table")
        check(text.contains("meta.h") && text.contains("6 rows"), "JSON Lines: nested objects become dotted columns", text)
        text = open("plants.parquet", "parquet")
        check(text.contains("40 rows") && text.contains("Rosemary"), "Parquet (snappy)", text)
        text = open("plants-zstd.parquet", "parquet")
        check(text.contains("40 rows") && text.contains("Rosemary"), "Parquet (zstd)", text)
        text = open("garden.sqlite", "sqlite")
        check(text.contains("40 rows") && text.contains("height_cm"), "SQLite: first table", text)
        text = js("""
        const c = document.getElementById('data-container');
        const s = c.querySelector('.dv-table'); s.value = 'tall'; s.dispatchEvent(new Event('change'));
        await new Promise(r => setTimeout(r, 200));
        return c.querySelector('.dv-count').textContent;
        """)
        check(text.hasPrefix("10 rows"), "SQLite: a view from the table list", text)
        text = open("garden.xlsx", "table")
        check(text.contains("2026-03-01") && text.contains("Basil") && text.contains("2 sheets"), "Excel: first sheet, dates read", text)
        text = open("session.har", "table")
        check(text.contains("GET") && text.contains("https://garden.example/api/plants") && text.contains("200"), "HAR: one row per request", text)

        text = open("plants.feather", "table")
        check(text.contains("3 rows") && text.contains("Kale") && text.contains("71.2"), "Arrow IPC / Feather", text)
        text = open("plants.avro", "table")
        check(text.contains("3 rows") && text.contains("Mint") && text.contains("2026-03-02") && text.contains("VEG") && text.contains("-3"),
              "Avro (null codec): records, enum, union, negative long, date", text)
        text = open("plants-deflate.avro", "table")
        check(text.contains("3 rows") && text.contains("spreads") && text.contains("[\"shade\",\"wet\"]"), "Avro (deflate codec): arrays and unions", text)
        text = open("readings-snappy.avro", "table")
        check(text.contains("2 rows") && text.contains("labels.bed") && text.contains("north") && text.contains("12.34") && text.contains("-2.5")
              && text.contains("2026-10-05T00:01:00.000Z"), "Avro (snappy codec): map, decimal, timestamp", text)
        text = open("harvest.ods", "table")
        check(text.contains("3 rows") && text.contains("Tomato") && text.contains("2026-08-01") && text.contains("Pepper"),
              "OpenDocument spreadsheet: repeated rows expanded, a million empty rows ignored", text)

        text = open("app.log", "log")
        check(text.contains("Error3") && text.contains("Warn1"), "Log: levels counted (stack trace and JSON line are errors)", text)
        text = js("""
        const c = document.getElementById('data-container');
        const q = c.querySelector('.dv-q'); q.value = 'water'; q.dispatchEvent(new Event('input'));
        await new Promise(r => setTimeout(r, 400));
        c.querySelector('.dv-only').click();
        await new Promise(r => setTimeout(r, 100));
        return c.querySelector('.dv-mcount').textContent + '|' + c.querySelector('.dv-log').innerText;
        """)
        check(text.contains("failed to water") && !text.contains("slow disk"), "Log: search with only matching lines", text)

        // JSON / YAML editing in the tree
        let edit = """
        const nodes = () => [...DOM.rendered.querySelectorAll('.struct-node[data-path]')];
        const at = (p) => nodes().find(n => n.dataset.path === JSON.stringify(p));
        at(['version']).querySelector('.struct-value').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
        let input = DOM.rendered.querySelector('.struct-inline-input'); input.value = '2';
        input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        await new Promise(r => setTimeout(r, 400));
        at(['name']).querySelector('.struct-key').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
        input = DOM.rendered.querySelector('.struct-inline-input'); input.value = 'title';
        input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        await new Promise(r => setTimeout(r, 400));
        at(['plants', 0]).querySelector('.struct-act[data-act=delete]').click();
        await new Promise(r => setTimeout(r, 400));
        return DOM.editor.value;
        """
        func structured(_ name: String, _ type: String) {
            let content = try! String(contentsOfFile: fixtures + "/" + name, encoding: .utf8)
            let literal = String(data: try! JSONSerialization.data(withJSONObject: [content]), encoding: .utf8)!
            _ = js("window.setStructuredContent(\(literal)[0], '\(type)'); return 'ok';")
        }
        structured("config.json", "json")
        text = js(edit)
        check(text == "{\n    \"title\": \"garden\",\n    \"version\": 2,\n    \"plants\": [\n        \"mint\"\n    ]\n}\n",
              "JSON: edit a value, rename a key, delete an item; indentation kept", text)
        structured("config.yaml", "yaml")
        text = js(edit)
        check(text.hasPrefix("# Garden config\ntitle: garden") && text.contains("# the project") && text.contains("version: 2") && !text.contains("basil"),
              "YAML: the same edits keep the comments", text)
        structured("config.json", "json")
        text = js("""
        toggleStructMode();
        const ok = document.getElementById('struct-source-status').textContent;
        DOM.editor.value = '{ "broken": '; DOM.editor.dispatchEvent(new Event('input'));
        await new Promise(r => setTimeout(r, 400));
        return ok + '|' + document.getElementById('struct-source-status').className;
        """)
        check(text == "Valid JSON|struct-source-status bad", "JSON: the source view checks the syntax as you type", text)

        // All text-file viewers use the same Explain request and line-aligned notes.
        bridge.messages.removeAll()
        structured("config.yaml", "yaml")
        _ = js("document.querySelector('.doc-explain-btn').click(); return 'ok';")
        spin(0.2)
        var request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
        check(request?["action"] as? String == "notesView" && request?["show"] as? Bool == true && request?["explain"] as? Bool == true,
              "YAML: Explain requests its own source notes and starts AI")
        text = js("""
        window.setCodeContent('server:\\n  port: 8080\\ndatabase:\\n  pool: 5', 'yaml', 'config.yaml', 'Viewer');
        for (let i = 0; i < 100 && !document.querySelector('.code-main .cm-content'); i++) await new Promise(r => setTimeout(r, 30));
        window.setCodeNotes({ explanation: { summary: 'Service settings', sections: [
          { startLine: 1, endLine: 2, title: 'HTTP listener', explanation: 'Sets the server port.', importance: 'high' },
          { startLine: 3, endLine: 4, title: 'Database pool', explanation: 'Sets the connection pool size.', importance: 'normal' }
        ] }, filters: [] });
        await new Promise(r => setTimeout(r, 150));
        return [document.getElementById('status-mode').textContent, document.querySelector('.code-document-btn').textContent,
                document.querySelector('.code-edit-btn').hidden, document.querySelector('.code-notes-track').textContent,
                document.querySelectorAll('.code-main .cm-line').length].join('|');
        """)
        check(text.contains("YAML|← Viewer|true") && text.contains("HTTP listener") && text.contains("Database pool") && text.hasSuffix("|4"),
              "YAML: highlighted source, line-aligned section notes and return to viewer", text)
        text = js("""
        document.querySelector('.code-notes-close').click();
        const hiddenBefore = document.querySelector('.code-notes').hidden;
        window.explainCurrentFile();
        window.setCodeContent('server: 8080', 'yaml', 'reopened.yaml', 'Viewer');
        window.setCodeNotes({ explanation: { summary: 'Server settings', sections: [
          { startLine: 1, endLine: 1, title: 'Server', explanation: 'Port setting.', importance: 'normal' }
        ] }, filters: [] });
        return hiddenBefore + '|' + document.querySelector('.code-notes').hidden;
        """)
        check(text == "true|false", "Explain from source/data reopens notes after they were hidden", text)
        bridge.messages.removeAll()
        _ = js("document.querySelector('.code-document-btn').click(); return 'ok';")
        spin(0.1)
        request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
        check(request?["action"] as? String == "notesView" && request?["show"] as? Bool == false, "notes return to the dedicated viewer")
        text = js("""
        window.setCodeContent('# just text\\nkey=value', '', 'anything.mystery');
        await new Promise(r => setTimeout(r, 150));
        return [document.getElementById('status-mode').textContent, document.querySelector('.code-main .cm-content').textContent,
                document.querySelector('.code-edit-btn').hidden, document.querySelector('.code-document-btn').hidden].join('|');
        """)
        check(text.hasPrefix("TEXT|# just textkey=value|false|true"), "unknown files are plain editable text with Explain", text)
        bridge.messages.removeAll()
        _ = js("document.querySelector('.code-main .code-explain-btn').click(); return 'ok';")
        spin(0.1)
        request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
        check(request?["action"] as? String == "explain", "plain text Explain reaches the shared AI action")
        structured("config.json", "json")
        _ = js("toggleStructMode(); document.querySelector('#editor-pane .code-explain-btn').click(); return 'ok';")
        spin(0.1)
        request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
        check(request?["action"] as? String == "notesView" && request?["explain"] as? Bool == true, "structured source mode also exposes Explain")
        _ = open("plants.csv", "table")
        bridge.messages.removeAll()
        text = js("const b = document.querySelector('.dv-explain'); if (b) b.click(); return String(!!b);")
        spin(0.1)
        request = bridge.messages.last { $0["type"] as? String == "code" }?["payload"] as? [String: Any]
        check(text == "true" && request?["explain"] as? Bool == true, "CSV: Explain opens the original textual source")
        _ = open("app.log", "log")
        check(js("return String(!!document.querySelector('.dv-explain'))") == "true", "logs expose Explain")
        _ = open("plants.parquet", "parquet")
        check(js("return String(!!document.querySelector('.dv-explain'))") == "false", "binary data is not offered as textual source")

    }
}


extension EditorHostTests {
    func testEditorDocumentRouting() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition(), message, line: line)
        }
        let sirius = UUID(), myDataCenter = UUID(), daily = UUID()
        let tabs = [sirius, myDataCenter, daily]

        // The reported case: the page still holds the MyDataCenter document while the Sirius Art tab is selected.
        check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: tabs, activeIndex: 0) == 1,
              "a message naming a document goes to that document's tab, not to the selected one")
        check(EditorDocumentRouting.targetIndex(documentID: sirius, tabIDs: tabs, activeIndex: 2) == 0,
              "naming the first tab while the last is selected still reaches the first tab")

        // Reordering tabs changes indexes, never ids.
        let reordered = [daily, sirius, myDataCenter]
        check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: reordered, activeIndex: 1) == 2,
              "a reordered tab list is followed by id")

        // A closed tab must not hand its text to another tab.
        check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: [sirius, daily], activeIndex: 0) == nil,
              "a message for a closed tab is dropped instead of falling back to the selected tab")

        // Messages that name no document keep the earlier behaviour.
        check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: tabs, activeIndex: 1) == 1,
              "an unnamed message applies to the selected tab")
        check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: tabs, activeIndex: -1) == nil,
              "no selected tab: nothing to apply to")
        check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: tabs, activeIndex: 3) == nil,
              "selected index past the end: nothing to apply to")
        check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: [], activeIndex: 0) == nil,
              "no tabs: nothing to apply to")
        check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: [], activeIndex: 0) == nil,
              "no tabs: a named message is dropped")

        // BUG-043: text of a document the page was just switched away from must not pass for the shown document's text.
        check(EditorDocumentRouting.reportsShownDocument(documentID: myDataCenter, shown: myDataCenter),
              "text of the document on screen is remembered by the reload check")
        check(!EditorDocumentRouting.reportsShownDocument(documentID: sirius, shown: myDataCenter),
              "unsaved text of the document left behind is not remembered as the one on screen")
        check(!EditorDocumentRouting.reportsShownDocument(documentID: sirius, shown: nil),
              "a named message while no tab's document is shown is not remembered")
        check(EditorDocumentRouting.reportsShownDocument(documentID: nil, shown: myDataCenter),
              "an unnamed message is remembered, as before")
        check(EditorDocumentRouting.reportsShownDocument(documentID: nil, shown: nil),
              "an unnamed message with nothing shown is remembered, as before")

        // What the page sends.
        check(EditorDocumentRouting.documentID(from: sirius.uuidString) == sirius, "a valid id is parsed")
        check(EditorDocumentRouting.documentID(from: sirius.uuidString.lowercased()) == sirius, "a lowercase id is parsed")
        check(EditorDocumentRouting.documentID(from: "") == nil, "an empty id means not named")
        check(EditorDocumentRouting.documentID(from: "not-a-uuid") == nil, "a malformed id means not named")
        check(EditorDocumentRouting.documentID(from: nil) == nil, "a missing id means not named")
        check(EditorDocumentRouting.documentID(from: 42) == nil, "a non-string id means not named")

    }

    @MainActor func testEditorMessagesCarryDocumentIdentity() throws {
        let editor = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, "\(message): \(detail.prefix(600))", line: line)
        }
        struct Message { let type: String; let doc: String; let payload: [String: Any] }
        final class Bridge: NSObject, WKScriptMessageHandler {
            var messages: [Message] = []
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
                guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
                messages.append(Message(type: type, doc: body["doc"] as? String ?? "<missing>", payload: body["payload"] as? [String: Any] ?? [:]))
            }
        }
        final class Loaded: NSObject, WKNavigationDelegate {
            var done = false
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        }

        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        let bridge = Bridge()
        config.userContentController.add(bridge, name: "bridge")
        config.userContentController.addUserScript(try BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = web
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "bridge"); window.close() }
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

        func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }

        func js(_ body: String, timeout: TimeInterval = 20) -> String {
            var out: String?
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): out = value as? String ?? "\(String(describing: value))"
                case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                }
            }
            spin(timeout) { out != nil }
            return out ?? "TIMEOUT"
        }

        /// Messages of `type` that arrived since `mark`, after giving the page a moment to send them.
        func messages(_ type: String, since mark: Int, wait: TimeInterval = 3) -> [Message] {
            spin(wait) { bridge.messages[mark...].contains { $0.type == type } }
            spin(0.2)
            return bridge.messages[mark...].filter { $0.type == type }
        }

        let tabA = UUID().uuidString, tabB = UUID().uuidString

        spin(30) { loaded.done }
        check(loaded.done, "shipping editor loaded")
        spin(2)

        // The app loads a document and names its tab in the same script (WebViewBridge.documentIDScript: mvSetDocument, then the load).
        var mark = bridge.messages.count
        var result = js("window.mvSetDocument(\"\(tabA)\"); window.setContent('# Alpha\\n\\nfirst document'); return 'ok';")
        check(result == "ok", "document A loads", result)
        var sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabA }, "text reported after loading A names tab A", sent.map { $0.doc }.joined(separator: ","))
        check(sent.contains { ($0.payload["markdown"] as? String)?.contains("Alpha") == true }, "that text is document A's")

        mark = bridge.messages.count
        result = js("window.mvSetDocument(\"\(tabB)\"); window.setContent('# Beta\\n\\nsecond document'); return 'ok';")
        sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabB }, "after switching to B, text names tab B", sent.map { $0.doc }.joined(separator: ","))

        // The reported failure: the page still shows B, typed into, while the app believes another tab is selected.
        // Cmd+S must send B's text and name B, so the app can write B's file and leave the selected tab alone.
        mark = bridge.messages.count
        result = js("""
        const rendered = document.getElementById('editor-rendered');
        rendered.querySelector('h1').textContent = 'Beta edited';
        rendered.dispatchEvent(new Event('input', {bubbles: true}));
        rendered.dispatchEvent(new KeyboardEvent('keydown', {key: 's', metaKey: true, bubbles: true, cancelable: true}));
        return 'ok';
        """)
        check(result == "ok", "Cmd+S is sent from the WYSIWYG view", result)
        let content = messages("contentChanged", since: mark)
        let saves = messages("saveRequested", since: mark)
        check(content.last.map { $0.doc == tabB && (($0.payload["markdown"] as? String) ?? "").contains("Beta edited") } == true,
              "Cmd+S sends the edited text of the shown document and names it", content.map { "\($0.doc):\($0.payload["markdown"] ?? "")" }.joined(separator: " | "))
        check(saves.count == 1 && saves[0].doc == tabB, "the save request names the shown document", saves.map { $0.doc }.joined(separator: ","))
        if let a = bridge.messages[mark...].firstIndex(where: { $0.type == "contentChanged" }),
           let b = bridge.messages[mark...].firstIndex(where: { $0.type == "saveRequested" }) {
            check(a < b, "the text arrives before the save request")
        }

        // No tab's document (the app clears the id for an insight or the X-Ray): messages carry an empty id.
        mark = bridge.messages.count
        result = js("window.mvSetDocument(''); window.setContent('# Loose'); return 'ok';")
        sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == "" }, "with the id cleared, messages name no document", sent.map { $0.doc }.joined(separator: ","))

        // BUG-043: unsaved WYSIWYG edits survive a switch to another document.
        let tabC = UUID().uuidString
        func load(_ id: String, _ markdown: String) {
            let result = js("window.mvSetDocument(\"\(id)\"); window.setContent('\(markdown)'); return 'ok';")
            check(result == "ok", "document \(markdown.prefix(12)) loads", result)
        }
        func typeInWysiwyg(_ text: String) {
            let result = js("""
            const rendered = document.getElementById('editor-rendered');
            rendered.querySelector('h1').textContent = '\(text)';
            rendered.dispatchEvent(new Event('input', {bubbles: true}));
            return 'ok';
            """)
            check(result == "ok", "typing in the WYSIWYG view", result)
        }
        func markdown(_ message: Message) -> String { (message.payload["markdown"] as? String) ?? "" }

        load(tabA, "# Alpha\\n\\nfirst document")
        typeInWysiwyg("Alpha typed, not saved")
        mark = bridge.messages.count
        load(tabB, "# Beta\\n\\nsecond document")
        sent = messages("contentChanged", since: mark)
        check(sent.first.map { $0.doc == tabA && markdown($0).contains("Alpha typed, not saved") } == true,
              "switching documents first hands over the unsaved edits, under the old id", sent.map { "\($0.doc.prefix(4)):\(markdown($0).prefix(30))" }.joined(separator: " | "))
        check(sent.dropFirst().allSatisfy { $0.doc == tabB && !markdown($0).contains("typed, not saved") },
              "what follows is the new document's own text, under the new id")
        check(sent.contains { $0.doc == tabB && markdown($0).contains("Beta") }, "the new document is reported")

        // Nothing was typed: no hand-over, the first message already belongs to the new document.
        mark = bridge.messages.count
        load(tabC, "# Gamma\\n\\nthird document")
        sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabC }, "without edits nothing is handed over for the old document", sent.map { $0.doc.prefix(4) }.joined(separator: ","))

        // The same document loading again (a refresh from disk) keeps replacing the edits.
        typeInWysiwyg("Gamma typed, then refreshed")
        mark = bridge.messages.count
        load(tabC, "# Gamma\\n\\nfresh from disk")
        sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabC && !markdown($0).contains("then refreshed") },
              "reloading the same document does not hand its edits over", sent.map { markdown($0).prefix(30) }.joined(separator: " | "))

        // The edits were synced into the Source view and never sent: they still must not be lost.
        load(tabA, "# Alpha\\n\\nfirst document")
        typeInWysiwyg("Alpha typed, then Source")
        _ = js("switchToSource(); return 'ok';")
        mark = bridge.messages.count
        load(tabB, "# Beta\\n\\nsecond document")
        sent = messages("contentChanged", since: mark)
        check(sent.first.map { $0.doc == tabA && markdown($0).contains("Alpha typed, then Source") } == true,
              "edits seen in the Source view are handed over too", sent.map { "\($0.doc.prefix(4)):\(markdown($0).prefix(30))" }.joined(separator: " | "))

        // Edits are handed over once: coming back and leaving again without typing sends nothing for that document.
        _ = js("switchToPreview(); return 'ok';")
        mark = bridge.messages.count
        load(tabC, "# Gamma\\n\\nthird document")
        sent = messages("contentChanged", since: mark)
        check(!sent.isEmpty && sent.allSatisfy { $0.doc == tabC }, "a second switch hands nothing over again", sent.map { $0.doc.prefix(4) }.joined(separator: ","))

    }
}


@MainActor
private final class DocumentFilesTestLoader: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done?.resume()
        done = nil
    }
}

extension EditorHostTests {
    func testDocumentFilePolicy() throws {
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(name): \(detail())", line: line)
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("document-files-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        for folder in [project.appendingPathComponent("docs/images"), project.appendingPathComponent("sub"), outside] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: base) }
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        for path in ["docs/images/shot.png", "docs/images/file tree.PNG", "docs/images/logo.svg", "docs/notes.md", "sub/up.jpg"] {
            try bytes.write(to: project.appendingPathComponent(path))
        }
        try bytes.write(to: outside.appendingPathComponent("secret.png"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("docs/escape.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("docs/linked"), withDestinationURL: outside)

        func request(_ path: String) -> URL {
            var components = URLComponents()
            components.scheme = DocumentFiles.scheme
            components.host = ""
            components.path = path
            return components.url!
        }
        func resolve(_ path: String, roots: [URL]? = nil) -> DocumentFiles.Resolution {
            DocumentFiles.resolve(request(path), roots: roots ?? [project])
        }
        let real = project.resolvingSymlinksInPath().standardizedFileURL

        // A picture inside the project is served with its content type.
        if case .file(let url, let type) = resolve(project.path + "/docs/images/shot.png") {
            check("a picture inside the project is served", url.path == real.appendingPathComponent("docs/images/shot.png").path, url.path)
            check("png gets image/png", type == "image/png", type)
        } else { check("a picture inside the project is served", false) }

        if case .file(_, let type) = resolve(project.path + "/docs/images/logo.svg") {
            check("svg is declared as svg so an img can draw it", type == "image/svg+xml", type)
        } else { check("svg is served", false) }

        if case .file(let url, let type) = resolve(project.path + "/docs/images/file tree.PNG") {
            check("a name with a space and a capital extension is served", url.lastPathComponent == "file tree.PNG" && type == "image/png", url.path)
        } else { check("a name with a space and a capital extension is served", false) }

        // The address the page builds for a path with a space is percent-encoded; the request decodes it back.
        let encoded = URL(string: "markview-doc://" + project.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "/docs/images/file%20tree.PNG")!
        if case .file(let url, _) = DocumentFiles.resolve(encoded, roots: [project]) {
            check("a percent-encoded request is decoded", url.lastPathComponent == "file tree.PNG", url.path)
        } else { check("a percent-encoded request is decoded", false) }

        // Only pictures.
        check("a Markdown file is refused", resolve(project.path + "/docs/notes.md") == .forbidden)
        check("a path without a file type is refused", resolve(project.path + "/docs/images") == .forbidden)

        // Only inside the folders the person works in.
        check("a picture outside every root is refused", resolve(outside.path + "/secret.png") == .forbidden)
        check("a .. that leaves the root is refused", resolve(project.path + "/docs/../../outside/secret.png") == .forbidden)
        check("a symbolic link to a picture outside is refused", resolve(project.path + "/docs/escape.png") == .forbidden)
        check("a symbolic link to a folder outside is refused", resolve(project.path + "/docs/linked/secret.png") == .forbidden)
        check("a sibling folder with the root's name as a prefix is refused",
              resolve(base.path + "/project-other/x.png") == .forbidden)

        // .. that stays inside is fine.
        if case .file(let url, _) = resolve(project.path + "/sub/../docs/images/shot.png") {
            check("a .. that stays inside the root is served", url.lastPathComponent == "shot.png")
        } else { check("a .. that stays inside the root is served", false) }

        // Several roots: the folder of a document outside the project.
        check("a picture next to a document outside the project is served with that folder as a root",
              resolve(outside.path + "/secret.png", roots: [project, outside]) != .forbidden)

        // Requests that are not for this scheme or not absolute.
        check("another scheme is refused", DocumentFiles.resolve(URL(string: "https://example.com/a.png")!, roots: [project]) == .forbidden)
        check("no roots, nothing is served", resolve(project.path + "/docs/images/shot.png", roots: []) == .forbidden)

        // The roots: the project and the folder of each open document, without repeats.
        let docs = [project.appendingPathComponent("README.md"), project.appendingPathComponent("docs/notes.md"), outside.appendingPathComponent("a.md")]
        let roots = DocumentFiles.roots(project: project, documents: docs)
        check("roots are the project and the folders of the documents", roots.map(\.path) == [project.path, project.appendingPathComponent("docs").path, outside.path], roots.map(\.path).joined(separator: ", "))
        check("roots without a project are the folders of the documents",
              DocumentFiles.roots(project: nil, documents: [outside.appendingPathComponent("a.md")]).map(\.path) == [outside.path])

    }

    @MainActor func testDocumentFilePagePaths() async throws {
        func check(_ name: String, _ ok: Bool, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(name): \(detail)", line: line)
        }
        _ = NSApplication.shared
        let scriptURL = try XCTUnwrap(Bundle.main.url(forResource: "markview-document-files", withExtension: "js", subdirectory: "Editor/js"))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        defer { web.stopLoading() }
        let loader = DocumentFilesTestLoader()
        web.navigationDelegate = loader
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loader.done = continuation
            web.loadHTMLString("<html><body><div id=\"r\"></div></body></html>", baseURL: nil)
        }
        let test = script + """
        ;
        const base = 'file:///P/my%20q/';
        const r = document.getElementById('r');
        r.innerHTML = '<p><img src="a b.png" width="10"> <img src="https://x.test/w.png"> <img src="data:image/png;base64,AAAA">'
            + '<a href="notes/x.md">link</a>'
            + '<picture><source srcset="a.png 1x, b.png 2x"><img src="../up.png"></picture></p>';
        // what the renderer does to links
        r.querySelectorAll('a').forEach(function (a) { a.setAttribute('data-mv-href', a.getAttribute('href')); a.setAttribute('href', new URL(a.getAttribute('href'), base).href); });
        MarkViewDocumentFiles.resolvePictures(r, base);
        const shown = r.innerHTML;
        const restored = MarkViewDocumentFiles.withOriginalPaths(shown);
        return JSON.stringify({ shown: shown, restored: restored, original: '<p><img src="a b.png" width="10"> <img src="https://x.test/w.png"> <img src="data:image/png;base64,AAAA"><a href="notes/x.md">link</a><picture><source srcset="a.png 1x, b.png 2x"><img src="../up.png"></picture></p>' });
        """
        let raw = try? await web.callAsyncJavaScript(test, contentWorld: .page) as? String
        guard let raw, let data = raw.data(using: .utf8), let result = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let shown = result["shown"], let restored = result["restored"], let original = result["original"] else {
            XCTFail("The document-files script did not return its results"); return
        }
        check("a local picture is shown at its markview-doc address", shown.contains("src=\"markview-doc:///P/my%20q/a%20b.png\""), shown)
        check("a parent-relative picture is shown at its address", shown.contains("src=\"markview-doc:///P/up.png\""), shown)
        check("a srcset is rewritten with its descriptors", shown.contains("markview-doc:///P/my%20q/a.png 1x, markview-doc:///P/my%20q/b.png 2x"), shown)
        check("a web picture and inline data stay as written", shown.contains("src=\"https://x.test/w.png\"") && shown.contains("src=\"data:image/png;base64,AAAA\""), shown)
        check("the width the author wrote is kept", shown.contains("width=\"10\""))
        check("the author's paths come back exactly", restored == original, "\n  got  \(restored)\n  want \(original)")
        check("no helper attribute is left after restoring", !restored.contains("data-mv-"), restored)
    }

    @MainActor func testDocumentFileSchemeHandler() async throws {
        func check(_ name: String, _ ok: Bool, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(name): \(detail)", line: line)
        }
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("document-handler-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: project.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func png() -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: .png, properties: [:])!
        }
        try png().write(to: project.appendingPathComponent("docs/a b.png"))
        try png().write(to: outside.appendingPathComponent("secret.png"))
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><rect width='20' height='10' fill='red'/></svg>".utf8)
            .write(to: project.appendingPathComponent("docs/logo.svg"))

        func address(_ path: String) -> String {
            var components = URLComponents()
            components.scheme = DocumentFiles.scheme
            components.host = ""
            components.path = path
            return components.string!
        }

        let handler = DocumentFileSchemeHandler()
        handler.allowedRoots = { [project] }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: DocumentFileSchemeHandler.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        defer { web.stopLoading() }
        let loader = DocumentFilesTestLoader()
        web.navigationDelegate = loader
        let page = """
        <html><body>
        <img id="ok" src="\(address(project.path + "/docs/a b.png"))">
        <img id="svg" src="\(address(project.path + "/docs/logo.svg"))">
        <img id="outside" src="\(address(outside.path + "/secret.png"))">
        <img id="missing" src="\(address(project.path + "/docs/none.png"))">
        </body></html>
        """
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loader.done = continuation
            web.loadHTMLString(page, baseURL: URL(fileURLWithPath: "/"))
        }
        // The load event waits for the pictures; a short extra wait covers a slow answer.
        try await Task.sleep(nanoseconds: 700_000_000)
        let raw = try await web.callAsyncJavaScript("""
        return JSON.stringify(Array.from(document.images).map(function (i) { return [i.id, i.complete && i.naturalWidth, i.naturalHeight]; }));
        """, contentWorld: .page) as? String
        let rows = (try? JSONSerialization.jsonObject(with: Data((raw ?? "[]").utf8))) as? [[Any]] ?? []
        var sizes: [String: [Int]] = [:]
        for row in rows { if let id = row[0] as? String { sizes[id] = [(row[1] as? Int) ?? 0, (row[2] as? Int) ?? 0] } }

        check("an allowed picture with a space in its name loads at its size", sizes["ok"] == [12, 8], "\(sizes)")
        check("an SVG loads (declared as image/svg+xml)", sizes["svg"] == [20, 10], "\(sizes)")
        check("a picture outside the folders is refused", sizes["outside"] == [0, 0], "\(sizes)")
        check("a missing picture does not load", sizes["missing"] == [0, 0], "\(sizes)")
    }
}


extension EditorHostTests {
    @MainActor func testMermaidSVGRenderingAndSanitization() throws {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor"))
            .deletingLastPathComponent().path
        let editor = ProcessInfo.processInfo.environment["MARKVIEW_MERMAID_EDITOR"] ?? bundled
        let testDeadline = Date().addingTimeInterval(240)
        func check(_ ok: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(ok, "\(message): \(detail.prefix(900))", line: line)
        }
        final class Bridge: NSObject, WKScriptMessageHandler {
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
        }
        final class Loaded: NSObject, WKNavigationDelegate {
            var done = false
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
        }

        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(Bridge(), name: "bridge")
        config.userContentController.addUserScript(try BridgeContract(contentsOf: URL(fileURLWithPath: editor + "/js/bridge-contract.json")).userScript)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = web
        defer { web.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "bridge"); window.close() }
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadFileURL(URL(fileURLWithPath: editor + "/index.html"), allowingReadAccessTo: URL(fileURLWithPath: editor))

        func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = min(Date().addingTimeInterval(seconds), testDeadline)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }

        func js(_ body: String, timeout: TimeInterval = 120) -> String {
            var out: String?
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): out = value as? String ?? "\(String(describing: value))"
                case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                }
            }
            spin(timeout) { out != nil }
            return out ?? "TIMEOUT"
        }

        /// Runs one block of page script that returns a JSON array of {name, ok, detail} and prints every entry as a check.
        func runChecks(_ title: String, _ body: String) {
            let answer = js(body)
            guard let data = answer.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
                check(false, "\(title) returned results", answer)
                return
            }
            for entry in list { check(entry["ok"] as? Bool == true, entry["name"] as? String ?? title, entry["detail"] as? String ?? "") }
        }

        spin(30) { loaded.done }
        check(loaded.done, "shipping editor page loaded")
        spin(2)
        let ready = js("return String(typeof window.setContent === 'function' && typeof window.mvKit === 'object' && typeof window.mermaid === 'object');")
        check(ready == "true", "the page has setContent, mvKit and Mermaid", ready)

        // 1. A real diagram, drawn and inserted by the page itself.
        runChecks("the real diagram", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            const source = 'graph TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[Done]\n  B -->|no| D[Retry]';
            window.mvSetDocument('mermaid-svg-test');
            window.setContent('# Diagram\n\n```mermaid\n' + source + '\n```\n');
            for (let i = 0; i < 100 && !document.querySelector('#editor-rendered .mermaid svg'); i++) await new Promise(r => setTimeout(r, 100));
            const shown = document.querySelector('#editor-rendered .mermaid svg');
            note('the page draws the diagram', !!shown);
            if (!shown) return JSON.stringify(results);
            function probe(svg) {
                const rect = svg.querySelector('.node rect, .node polygon');
                const label = svg.querySelector('.nodeLabel');
                const edge = svg.querySelector('.flowchart-link');
                return {
                    fill: rect ? getComputedStyle(rect).fill : 'none',
                    stroke: rect ? getComputedStyle(rect).stroke : 'none',
                    labelColor: label ? getComputedStyle(label).color : 'none',
                    edgeStroke: edge ? getComputedStyle(edge).stroke : 'none',
                    labels: Array.from(svg.querySelectorAll('.nodeLabel')).map(e => e.textContent.trim()).filter(Boolean)
                };
            }
            // The same source drawn by Mermaid and inserted with no sanitiser: this is what the theme looks like.
            const drawn = await mermaid.render('mermaid-svg-expected', source);
            const scratch = document.createElement('div');
            scratch.innerHTML = drawn.svg;
            document.body.appendChild(scratch);
            const expected = probe(scratch.querySelector('svg'));
            const actual = probe(shown);
            scratch.remove();
            note('Mermaid theme fill is not the default black', expected.fill !== 'rgb(0, 0, 0)' && expected.fill !== 'none', JSON.stringify(expected));
            note('the node fill on the page is the fill Mermaid drew', actual.fill === expected.fill, 'page ' + actual.fill + ' expected ' + expected.fill);
            note('the node outline on the page is the outline Mermaid drew', actual.stroke === expected.stroke && actual.stroke !== 'none', 'page ' + actual.stroke + ' expected ' + expected.stroke);
            note('the label colour on the page is the one Mermaid drew', actual.labelColor === expected.labelColor, 'page ' + actual.labelColor + ' expected ' + expected.labelColor);
            note('the edge colour on the page is the one Mermaid drew', actual.edgeStroke === expected.edgeStroke && actual.edgeStroke !== 'none', 'page ' + actual.edgeStroke + ' expected ' + expected.edgeStroke);
            note('every label of the diagram is on the page', expected.labels.length >= 4 && JSON.stringify(actual.labels) === JSON.stringify(expected.labels), 'page ' + JSON.stringify(actual.labels) + ' expected ' + JSON.stringify(expected.labels));
            const style = shown.querySelector('style');
            const id = shown.getAttribute('id');
            const sheet = style ? Array.from(document.styleSheets).find(s => s.ownerNode === style) : null;
            const rules = sheet ? Array.from(sheet.cssRules) : [];
            note('the diagram keeps its own stylesheet', rules.length > 10, 'rules: ' + rules.length);
            note('every rule of that stylesheet starts at the diagram id', rules.length > 0 && rules.every(r => r.type === 1 && r.selectorText.split(',').every(s => s.trim().indexOf('#' + id) === 0)), id);
            return JSON.stringify(results);
            """#)

        // 2. Sixteen kinds of diagram: nothing Mermaid draws is lost.
        runChecks("diagram kinds", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            const kinds = {
              flowchart: 'graph TD\n A[Start]-->B{Choice}\n B-->|yes|C[Done]\n classDef big fill:#f9f,stroke:#333,stroke-width:4px\n class A big\n style C fill:#bbf,stroke:#f66,stroke-dasharray: 5 5',
              sequence: 'sequenceDiagram\n participant Alice\n Alice->>Bob: Hello\n Bob-->>Alice: Hi\n Note over Alice,Bob: note\n loop L\n Alice->>Bob: x\n end',
              class: 'classDiagram\n class Animal{+int age\n +eat()}\n Animal <|-- Dog\n Animal : +String name',
              state: 'stateDiagram-v2\n [*] --> Still\n Still --> Moving\n Moving --> [*]\n state Moving {\n  [*] --> A\n }',
              er: 'erDiagram\n CUSTOMER ||--o{ ORDER : places\n CUSTOMER { string name }',
              gantt: 'gantt\n title T\n dateFormat YYYY-MM-DD\n section S\n A :a1, 2024-01-01, 3d\n B :after a1, 2d',
              pie: 'pie title Pets\n "Dogs" : 386\n "Cats" : 85',
              mindmap: 'mindmap\n root((mind))\n  A\n  B',
              journey: 'journey\n title J\n section S\n  Task: 5: Me',
              git: 'gitGraph\n commit\n branch dev\n commit\n checkout main\n merge dev',
              timeline: 'timeline\n title T\n 2002 : A',
              quadrant: 'quadrantChart\n title Q\n x-axis Low --> High\n y-axis Low --> High\n quadrant-1 A\n Campaign A: [0.3, 0.6]',
              xy: 'xychart-beta\n title "S"\n x-axis [a, b]\n bar [1, 2]',
              c4: 'C4Context\n title T\n Person(a, "A")',
              sankey: 'sankey-beta\n a,b,1',
              requirement: 'requirementDiagram\n requirement test_req {\n id: 1\n text: the test text.\n risk: high\n verifymethod: test\n }'
            };
            const parser = document.implementation.createHTMLDocument('');
            function declarations(svgMarkup) {
                const doc = new DOMParser().parseFromString(svgMarkup, 'text/html');
                const list = [];
                doc.querySelectorAll('style').forEach(el => {
                    const s = parser.createElement('style');
                    s.textContent = el.textContent;
                    parser.head.appendChild(s);
                    Array.from(s.sheet.cssRules).forEach(rule => {
                        for (const property of rule.style) list.push(rule.selectorText.replace(/#[A-Za-z0-9_-]+/, '#ID') + '|' + property + ':' + rule.style.getPropertyValue(property));
                    });
                    s.remove();
                });
                return list;
            }
            function text(svgMarkup) {
                const doc = new DOMParser().parseFromString(svgMarkup, 'text/html');
                doc.querySelectorAll('style').forEach(s => s.remove());
                return doc.body.textContent.replace(/\s+/g, ' ').trim();
            }
            let serial = 0;
            for (const [kind, source] of Object.entries(kinds)) {
                let drawn;
                try { drawn = await mermaid.render('kind-' + (++serial), source); } catch (e) { note(kind + ': Mermaid draws the sample', false, e); continue; }
                const clean = window.mvKit.sanitizeMermaidSvg(drawn.svg);
                const before = declarations(drawn.svg), after = new Set(declarations(clean));
                // The two declarations the filter refuses on purpose: z-index, and position:absolute on the HTML overlays Mermaid adds
                // to the page body for click callbacks (tooltip, sequence-diagram popup menu), which never sit inside the returned SVG.
                const overlay = /\.(?:mermaidTooltip|actorPopupMenu|actorPopupMenuPanel)\|position:absolute$/;
                const lost = before.filter(d => !after.has(d)).filter(d => d.indexOf('|z-index:') < 0 && !overlay.test(d));
                note(kind + ': every label is kept', text(drawn.svg) === text(clean), text(drawn.svg).slice(0, 80) + ' / ' + text(clean).slice(0, 80));
                note(kind + ': every style declaration is kept', before.length > 0 && lost.length === 0, 'declarations ' + before.length + ', lost: ' + lost.slice(0, 3).join(' ; '));
            }
            return JSON.stringify(results);
            """#)

        // 3. Hostile SVG.
        runChecks("hostile SVG", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            window.__pwn = 0;
            const corpus = {
              'a script element': '<svg id="a1"><script>window.__pwn = 1</script><rect/></svg>',
              'event handlers': '<svg id="a2" onload="window.__pwn = 2"><rect onclick="window.__pwn = 2" onmouseover="window.__pwn = 2"/></svg>',
              'a script and a handler in foreignObject': '<svg id="a3"><foreignObject><script>window.__pwn = 3</script><div onclick="window.__pwn = 3">x</div></foreignObject></svg>',
              'an iframe, a form, an object and an embed in foreignObject': '<svg id="a4"><foreignObject><iframe srcdoc="<script>parent.__pwn = 4</script>"></iframe><form action="https://evil.invalid"></form><object data="x"></object><embed src="x"></foreignObject></svg>',
              'javascript: links': '<svg id="a5"><a href="javascript:window.__pwn = 5"><text>x</text></a><a xlink:href="javascript:window.__pwn = 5"><text>y</text></a></svg>',
              'an @import': '<svg id="a6"><style>@import url(https://evil.invalid/x.css); @import "https://evil.invalid/y.css";</style><rect/></svg>',
              'rules outside the diagram': '<svg id="a7"><style>body{display:none} p{color:red} #a7 rect{fill:red} #a7 ~ p{color:blue} #a7 + p{color:blue}</style><rect/></svg>',
              'remote loads from CSS': '<svg id="a8"><style>#a8 rect{background:url(https://evil.invalid/p.png);list-style-image:url(https://evil.invalid/q.png);cursor:url(https://evil.invalid/c.png),auto;filter:url(https://evil.invalid/f.svg#x)}</style><rect/></svg>',
              'CSS escapes and comments': '<svg id="a9"><style>#a9 rect{position:f\\69xed;background:\\75rl(https://evil.invalid/p.png);z-index:9;color:/**/red;-moz-binding:url(x);behavior:url(x)}</style><rect/></svg>',
              'a CSS expression': '<svg id="b1"><style>#b1 rect{width:expression(window.__pwn = 6);fill:red}</style><rect/></svg>',
              'markup in a CSS string': '<svg id="b2"><style>#b2 a{content:"</style><img src=x onerror=window.__pwn=7>"}</style></svg>',
              'a mutation payload with </p>': '<svg></p><style><a id="</style><img src=1 onerror=window.__pwn=8>">',
              'a mutation payload with mglyph': '<math><mtext><table><mglyph><style><!--</style><img title="--&gt;&lt;img src=1 onerror=window.__pwn=9&gt;">',
              'a mutation payload in foreignObject': '<svg id="b3"><foreignObject><p><svg><desc><style><a id="</style><img src=1 onerror=window.__pwn=10>"></style></desc></svg></p></foreignObject></svg>',
              'a style in foreignObject': '<svg id="b4"><foreignObject><style>body{display:none}</style><style><img src=x onerror=window.__pwn=11></style><div>y</div></foreignObject></svg>',
              'a comment that closes a style': '<svg id="b5"><style><!--</style><img src=x onerror=window.__pwn=12>--></style></svg>',
              'nested foreignObject': '<svg id="b6"><foreignObject><svg><foreignObject><img src=x onerror=window.__pwn=13></foreignObject></svg></foreignObject></svg>',
              'a hostile style attribute': '<svg id="b7"><rect style="position:fixed;background:url(https://evil.invalid/p.png);fill:blue" width="5" height="5"/></svg>'
            };
            const host = document.createElement('div');
            document.body.appendChild(host);
            const bodyBefore = getComputedStyle(document.body).display;
            for (const [name, raw] of Object.entries(corpus)) {
                const clean = window.mvKit.sanitizeMermaidSvg(raw);
                host.innerHTML = clean;
                const once = host.innerHTML;
                host.innerHTML = once;
                await new Promise(r => setTimeout(r, 40));
                const all = Array.from(host.querySelectorAll('*'));
                const handlers = all.filter(e => Array.from(e.attributes).some(a => /^on/i.test(a.name))).length;
                const jsLinks = all.filter(e => Array.from(e.attributes).some(a => /javascript:/i.test(a.value))).length;
                const imports = Array.from(document.styleSheets).filter(s => s.ownerNode && host.contains(s.ownerNode)).flatMap(s => Array.from(s.cssRules)).filter(r => r.type === 3).length;
                const outside = Array.from(document.styleSheets).filter(s => s.ownerNode && host.contains(s.ownerNode)).flatMap(s => Array.from(s.cssRules))
                    .filter(r => r.type === 1 && !r.selectorText.split(',').every(sel => /^#(a\d|b\d)(?![\w-])/.test(sel.trim()))).length;
                const loads = all.filter(e => /url\(\s*["']?https?:/i.test(e.getAttribute('style') || '')).length +
                    Array.from(document.styleSheets).filter(s => s.ownerNode && host.contains(s.ownerNode)).flatMap(s => Array.from(s.cssRules)).filter(r => /url\(\s*["']?https?:/i.test(r.cssText)).length;
                const fixed = all.filter(e => getComputedStyle(e).position === 'fixed').length;
                const rect = host.querySelector('rect');
                const background = rect ? getComputedStyle(rect).backgroundImage : 'none';
                note('hostile SVG neutralised: ' + name,
                     host.querySelectorAll('script').length === 0 && handlers === 0 && jsLinks === 0 && imports === 0 && outside === 0 && loads === 0 &&
                     fixed === 0 && background === 'none' && once === host.innerHTML && window.__pwn === 0 && getComputedStyle(document.body).display === bodyBefore,
                     JSON.stringify({ clean: clean.slice(0, 200), handlers, jsLinks, imports, outside, loads, fixed, background, pwn: window.__pwn }));
                host.innerHTML = '';
            }
            await new Promise(r => setTimeout(r, 300));
            note('nothing the hostile SVG carried ran', window.__pwn === 0, window.__pwn);
            host.remove();
            return JSON.stringify(results);
            """#)

        // 4. <style> stays forbidden everywhere else.
        runChecks("other profiles", #"""
            const results = [];
            const note = (name, ok, detail) => results.push({ name, ok: !!ok, detail: detail === undefined ? '' : String(detail) });
            for (const profile of ['markdown', 'book', 'discussion', 'insight']) {
                const clean = window.mvKit.sanitizeHtml('<p>kept</p><style>body{display:none}</style><svg id="x"><style>#x rect{fill:red}</style><rect/></svg>', profile);
                note('the ' + profile + ' profile still drops <style>', clean.indexOf('kept') >= 0 && clean.toLowerCase().indexOf('<style') < 0, clean);
            }
            return JSON.stringify(results);
            """#)

    }
}
