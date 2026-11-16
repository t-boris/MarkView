import AppKit
import Foundation

// The model of an archive tab (MarkView/Models/Workspace/ArchiveModel.swift) on a real zip made by the real `Archive.compress`: the entries
// load, a click unpacks one file for a look, "Extract" unpacks everything next to the archive, and the work the model started belongs to it
// (`AR-19`): a second request while one runs is not started twice, and a model that is let go (the tab closed) calls nobody back.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

/// Waits (at most five seconds) until `condition` holds, letting the model's tasks run.
@MainActor func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor func run() async throws {
    let work = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("archive-model-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let src = work.appendingPathComponent("pack")
    try FileManager.default.createDirectory(at: src.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try "hello\n".write(to: src.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
    try "deep\n".write(to: src.appendingPathComponent("docs/note.md"), atomically: true, encoding: .utf8)
    let zip = try Archive.compress([src])

    let model = ArchiveModel(url: zip)
    check(model.phase == .loading && model.rows.isEmpty, "a new model is loading and shows nothing")
    await model.load()
    check(model.phase == .loaded && model.files == 2 && model.folders >= 1, "the entries of the zip are read: \(model.files) files, \(model.folders) folders")
    check(!model.rows.isEmpty && model.rows.first?.isDirectory == true, "the tree starts with the top folder")
    model.filter = "note"
    check(model.rows.map(\.title) == ["pack/docs/note.md"], "a search lists the matching files by path: \(model.rows.map(\.title))")
    model.filter = ""

    // A click unpacks one file for a look; a second click while it is on its way is not started.
    let entry = model.entries.first { $0.path.hasSuffix("readme.md") }!
    var opened: [URL] = []
    model.open(entry) { opened.append($0) }
    check(model.opening == entry.path, "the entry being unpacked is named while it is on its way")
    model.open(entry) { opened.append($0) }
    check(await eventually { model.opening == nil && opened.count == 1 }, "the unpacked copy is handed to the viewer, once")
    check((try? String(contentsOf: opened[0], encoding: .utf8)) == "hello\n", "the copy has the content of the entry")
    try? FileManager.default.removeItem(at: opened[0].deletingLastPathComponent())

    // Extract all: next to the archive, in a new folder named after it.
    var folders: [URL] = []
    model.extract(into: nil) { folders.append($0) }
    check(model.busy != nil, "an unpacking says what it is doing")
    model.extract(into: nil) { folders.append($0) }
    check(await eventually { model.busy == nil && folders.count == 1 }, "everything is unpacked, once")
    let folder = folders.first
    check(folder?.lastPathComponent == "pack 2" && folder?.deletingLastPathComponent() == zip.deletingLastPathComponent()
          && FileManager.default.fileExists(atPath: folder!.appendingPathComponent("pack/docs/note.md").path),
          "the folder is next to the archive (\"pack\" is taken, so it is numbered) and holds the tree: \(String(describing: folder?.lastPathComponent))")
    check(model.extractedTo == folder && model.notice?.contains("Extracted 2 files") == true, "the model remembers where it unpacked and says so")

    // A model that is let go (the tab closed) does not call back: its task is cancelled with it.
    var closing: ArchiveModel? = ArchiveModel(url: zip)
    await closing!.load()
    weak let gone = closing
    var called = false
    closing!.extract(into: nil) { _ in called = true }
    closing = nil
    try await Task.sleep(nanoseconds: 800_000_000)
    check(gone == nil, "a closed archive tab is not kept alive by its unpacking")
    check(!called, "an unpacking of a closed tab reports to nobody")
}

try await run()
print(failures == 0 ? "\nAll archive model checks passed" : "\n\(failures) check(s) FAILED")
if failures > 0 { exit(1) }
