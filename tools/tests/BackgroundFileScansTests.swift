import Foundation

// The file-system scans a window runs off the main thread (AR-42), on real folders in a temporary directory:
// the Markdown probe behind the "Recursive Insight" menu, the diagram sheet's document list, the by-name lookup of a
// search result, and the open-files watcher's read of dates and text. Compiled by tools/tests/background-file-scans-tests.sh.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appendingPathComponent("mv-scans-" + UUID().uuidString.prefix(8), isDirectory: true)
try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: sandbox) }

func folder(_ name: String) throws -> URL {
    let url = sandbox.appendingPathComponent(name, isDirectory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func write(_ text: String, _ relative: String, in root: URL) throws {
    let url = root.appendingPathComponent(relative)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}
func setDate(_ date: Date, _ url: URL) throws { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }

// MARK: - containsMarkdown

do {
    let empty = try folder("empty")
    check(!BackgroundFileScans.containsMarkdown(in: empty), "an empty folder holds no Markdown")

    let hidden = try folder("hidden-only")
    try write("x", ".dde/notes.md", in: hidden)
    try write("x", ".git/README.md", in: hidden)
    try write("x", "src/main.swift", in: hidden)
    check(!BackgroundFileScans.containsMarkdown(in: hidden), "hidden folders, .dde and other file types do not count")

    let package = try folder("package")
    try write("x", "Thing.app/Contents/Help.md", in: package)
    check(!BackgroundFileScans.containsMarkdown(in: package), "the inside of a package does not count")

    let nested = try folder("nested")
    try write("x", "a/b/c/Guide.MD", in: nested)
    check(BackgroundFileScans.containsMarkdown(in: nested), "a Markdown file deep in the tree is found, whatever the case of its extension")

    let outside = try folder("outside")
    try write("secret", "secret.md", in: outside)
    let linked = try folder("linked-out")
    try fm.createSymbolicLink(at: linked.appendingPathComponent("link.md"), withDestinationURL: outside.appendingPathComponent("secret.md"))
    check(!BackgroundFileScans.containsMarkdown(in: linked), "a link that leads outside the folder does not count")

    let inside = try folder("linked-in")
    try write("x", "real/doc.md", in: inside)
    try fm.createSymbolicLink(at: inside.appendingPathComponent("alias.md"), withDestinationURL: inside.appendingPathComponent("real/doc.md"))
    check(BackgroundFileScans.containsMarkdown(in: inside), "a link inside the folder is fine")

    // A cancelled task stops at once and reports nothing, even though the folder holds Markdown.
    let task = Task.detached { () -> Bool in
        while !Task.isCancelled { await Task.yield() }
        return BackgroundFileScans.containsMarkdown(in: nested)
    }
    task.cancel()
    check(await task.value == false, "a cancelled walk ends without an answer")
}

// MARK: - markdownPaths

do {
    let root = try folder("paths")
    try write("x", "b.md", in: root)
    try write("x", "docs/a.md", in: root)
    try write("x", "docs/Deep/Z.MD", in: root)
    try write("x", "docs/notes.txt", in: root)
    try write("x", ".hidden/h.md", in: root)
    check(BackgroundFileScans.markdownPaths(in: root) == ["b.md", "docs/Deep/Z.MD", "docs/a.md"],
          "the Markdown files come back as sorted paths relative to the root, hidden and other files left out")
    check(BackgroundFileScans.markdownPaths(in: sandbox.appendingPathComponent("missing")).isEmpty, "a missing folder gives an empty list")
}

// MARK: - firstFile

do {
    let root = try folder("lookup")
    try write("x", "one/two/Target.md", in: root)
    try write("x", ".hidden/Secret.md", in: root)
    check(BackgroundFileScans.firstFile(named: "Target.md", in: root)?.lastPathComponent == "Target.md", "a file is found by name deep in the tree")
    check(BackgroundFileScans.firstFile(named: "Nope.md", in: root) == nil, "an absent name gives nil")
    check(BackgroundFileScans.firstFile(named: "Secret.md", in: root) == nil, "hidden folders are not searched")
}

// MARK: - Open files

do {
    let root = try folder("open-files")
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let now = Date(timeIntervalSince1970: 1_700_000_500)
    try write("log line 1", "data.log", in: root)
    try write("fresh text", "doc.md", in: root)
    try write("same text", "same.md", in: root)
    let data = root.appendingPathComponent("data.log"), doc = root.appendingPathComponent("doc.md"), same = root.appendingPathComponent("same.md")
    try setDate(now, data); try setDate(now, doc); try setDate(now, same)
    typealias File = BackgroundFileScans.OpenFile

    // A data tab: only its date matters.
    var readings = BackgroundFileScans.read([File(url: data, kind: .data, seen: old, loaded: "")], all: false)
    check(readings.count == 1 && readings[0].isNewer && readings[0].changedText == nil && readings[0].date == now,
          "a data file newer than the last check is reported, without reading its content")
    readings = BackgroundFileScans.read([File(url: data, kind: .data, seen: now, loaded: "")], all: false)
    check(readings.count == 1 && !readings[0].isNewer, "a data file with the same date is not newer")
    readings = BackgroundFileScans.read([File(url: data, kind: .data, seen: nil, loaded: "")], all: false)
    check(readings.count == 1 && !readings[0].isNewer && readings[0].date == now, "the first check only records the date")

    // A text tab: newer and different.
    readings = BackgroundFileScans.read([File(url: doc, kind: .text, seen: old, loaded: "old text")], all: false)
    check(readings.count == 1 && readings[0].changedText == "fresh text", "a newer text file with other text is read")
    readings = BackgroundFileScans.read([File(url: same, kind: .text, seen: old, loaded: "same text")], all: false)
    check(readings.count == 1 && readings[0].isNewer && readings[0].changedText == nil, "a newer file with the tab's own text is not a change")
    readings = BackgroundFileScans.read([File(url: doc, kind: .text, seen: now, loaded: "old text")], all: false)
    check(readings.count == 1 && readings[0].changedText == nil && readings[0].date == now, "an unchanged date is not read (the date is still reported)")
    readings = BackgroundFileScans.read([File(url: doc, kind: .text, seen: nil, loaded: "old text")], all: false)
    check(readings.count == 1 && readings[0].changedText == nil, "a text tab never checked before only records its date")

    // A full check (after a branch switch) reads whatever the dates say.
    readings = BackgroundFileScans.read([File(url: doc, kind: .text, seen: now, loaded: "old text")], all: true)
    check(readings.count == 1 && readings[0].changedText == "fresh text", "a full check reads a file whose date did not move")
    readings = BackgroundFileScans.read([File(url: doc, kind: .text, seen: nil, loaded: "old text")], all: true)
    check(readings.count == 1 && readings[0].changedText == "fresh text", "a full check reads a file that was never checked")
    readings = BackgroundFileScans.read([File(url: same, kind: .text, seen: now, loaded: "same text")], all: true)
    check(readings.count == 1 && readings[0].changedText == nil, "a full check still ignores identical text")

    // Files that cannot be read.
    let gone = root.appendingPathComponent("gone.md")
    try Data([0xFF, 0xFE, 0xFD, 0x80]).write(to: root.appendingPathComponent("binary.md"))
    try setDate(now, root.appendingPathComponent("binary.md"))
    readings = BackgroundFileScans.read([File(url: gone, kind: .text, seen: old, loaded: "x"),
                                         File(url: root.appendingPathComponent("binary.md"), kind: .text, seen: old, loaded: "x"),
                                         File(url: doc, kind: .text, seen: old, loaded: "old text")], all: false)
    check(readings.map(\.file.url.lastPathComponent) == ["binary.md", "doc.md"], "a missing file is left out and the others are still read")
    check(readings[0].changedText == nil && readings[1].changedText == "fresh text", "a file that is not UTF-8 text reports no change")
}

print("\(failures) failures")
exit(failures == 0 ? 0 : 1)
