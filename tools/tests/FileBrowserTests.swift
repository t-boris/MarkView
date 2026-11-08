// Compiled with the production FileType, Archive, FileTreeSortOrder and FileBrowser by file-browser-tests.sh.
import Foundation

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("ok   \(label)") } else { failures += 1; print("FAIL \(label)") }
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

let suite = "file-browser-tests-\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(FileBrowserPreferences.load(from: defaults) == FileBrowserPreferences(), "defaults: list, hidden off, ignored shown, all")
check(FileBrowserPreferences().mode == .list && !FileBrowserPreferences().showHidden, "hidden items are excluded by default")
var stored = FileBrowserPreferences(mode: .tree, showHidden: true, hideIgnored: true, category: .openable)
stored.save(to: defaults)
check(FileBrowserPreferences.load(from: defaults) == stored, "view, hidden, ignored and category survive a restart")
defaults.set("nonsense", forKey: "fileBrowser.viewMode")
defaults.set("nonsense", forKey: "fileBrowser.category")
check(FileBrowserPreferences.load(from: defaults).mode == .list && FileBrowserPreferences.load(from: defaults).category == .all,
      "unknown stored values fall back to the defaults")
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

print(failures == 0 ? "\nAll file browser checks passed." : "\n\(failures) file browser check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
