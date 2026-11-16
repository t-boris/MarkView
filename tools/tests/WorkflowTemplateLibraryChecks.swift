import Foundation

// WorkflowTemplateLibrary (AR-19): the changes the Flow popover and Settings start. The library is the shipping one over a real store in a
// temporary folder; the answers are what the views show.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor
func makeLibrary() -> (WorkflowTemplateLibrary, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mv-template-library-\(UUID().uuidString)", isDirectory: true)
    return (WorkflowTemplateLibrary(store: WorkflowTemplateStore(folder: folder)), folder)
}

@MainActor
func changes() async {
    print("-- save, choose, delete")
    let (library, folder) = makeLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let workflow = WorkflowFlow.kanban.applied(to: .standard)

    var saved: [String] = []
    library.startSave(name: "Kanban", note: "n", workflow: workflow, replacing: nil) { result in
        if case .success(let template) = result { saved.append(template.id) }
    }
    check(library.templates.isEmpty, "a save returns at once, before the folder is written")
    check(await waitUntil { saved == ["kanban"] }, "the answer comes with the template")
    check(library.templates.map(\.id) == ["kanban"] && library.loaded, "and the list was read again before it came")

    var chosen: [String?] = []
    library.startSetDefault("kanban") { chosen.append($0) }
    check(await waitUntil { chosen.count == 1 } && chosen == [nil] && library.listing.defaultID == "kanban", "the template for new projects is chosen and the list shows it")
    library.startSetDefault("nothing-here") { chosen.append($0) }
    check(await waitUntil { chosen.count == 2 } && chosen[1] != nil && library.listing.defaultID == "kanban", "a template that is not there is refused with a reason that a person reads")

    var deleted: [String?] = []
    library.startDelete("kanban") { deleted.append($0) }
    check(await waitUntil { deleted.count == 1 } && deleted == [nil] && library.templates.isEmpty && library.listing.defaultID == nil,
          "a deleted template leaves the list, and the choice for new projects goes with it")
    library.startDelete("kanban") { deleted.append($0) }
    check(await waitUntil { deleted.count == 2 } && deleted[1] != nil, "deleting what is gone says why")
}

@MainActor
func replacing() async {
    print("-- a change asked for while one is under way")
    let (library, folder) = makeLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let workflow = WorkflowFlow.kanban.applied(to: .standard)
    var answers: [String] = []
    library.startSave(name: "First", note: "", workflow: workflow, replacing: nil) { result in
        if case .success(let template) = result { answers.append(template.name) }
    }
    library.startSave(name: "Second", note: "", workflow: workflow, replacing: nil) { result in
        if case .success(let template) = result { answers.append(template.name) }
    }
    check(await waitUntil { !answers.isEmpty }, "the later save is answered")
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(answers == ["Second"], "the answer of the replaced save is dropped: it is not shown after the newer one")
    check(await waitUntil { Set(library.templates.map(\.name)) == ["First", "Second"] }, "the file the replaced save had started still lands whole, and the list shows both")
}

@MainActor
func closing() async {
    print("-- the library goes away")
    var answers = 0
    do {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        library.startSave(name: "Late", note: "", workflow: WorkflowFlow.kanban.applied(to: .standard), replacing: nil) { _ in answers += 1 }
    }
    try? await Task.sleep(nanoseconds: 400_000_000)
    check(answers == 0, "a library that was released answers nobody")
}

@main
@MainActor
enum WorkflowTemplateLibraryChecks {
    static func main() async {
        await changes()
        await replacing()
        await closing()
        print("Workflow template library summary: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
