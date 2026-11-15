import Combine
import Foundation

/// Behaviour of the shipping `TabsController` on real temporary files: opening, editing, saving, closing with the questions answered by a
/// script, Close Documents, the reload of files that changed on disk, the follow of moved files, and what redraws what (`AR-14` step 5,
/// `AR-15`). Nothing here shows a dialog or a window.
@main
enum TabsControllerChecks {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        }
    }

    /// A folder of its own for one check, removed afterwards.
    static func folder(_ body: (URL) async throws -> Void) async rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-controller-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        try await body(url)
    }

    @MainActor
    final class Script {
        var answers: [UnsavedChangesAnswer] = []
        var asked: [String] = []
        var failedSaves: [String] = []
        var offered: [URL] = []
        lazy var dialogs = TabDialogs(
            askToSave: { [unowned self] message, _ in
                asked.append(message)
                return answers.isEmpty ? .cancel : answers.removeFirst()
            },
            reportFailedSave: { [unowned self] name in failedSaves.append(name) },
            offerDefaultApp: { [unowned self] url, _ in offered.append(url); return false })
    }

    static func main() async {
        await openEditSaveReload()
        await closeAsksAboutUnsavedChanges()
        await closeDocuments()
        await closeFolderQuestionAndFailedSave()
        await followMovedFiles()
        await reloadFilesChangedOnDisk()
        await sideTableFollowsTheTabs()
        await whatRedrawsWhat()
        await closeTabsUnderTrashedFolder()
        await tabKindsOpenWithoutTextLoad()
        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) check(s) failed\n".utf8))
            exit(1)
        }
        print("TabsController: open, edit, save, reload, close prompts, Close Documents, disk changes, moves, scroll table and redraws passed")
    }

    @MainActor
    static func openEditSaveReload() async {
        await folder { dir in
            let file = dir.appendingPathComponent("note.md")
            try? "# Title\n\n## Part\n".write(to: file, atomically: true, encoding: .utf8)
            let tabs = TabsController(dialogs: Script().dialogs)
            var events: [String] = []
            let subscription = tabs.events.sink { event in
                switch event {
                case .saved(let url): events.append("saved:" + url.lastPathComponent)
                case .reloadedFromDisk: events.append("reloaded")
                case .terminalClosed: events.append("terminal")
                }
            }

            tabs.openDocument(file)
            for _ in 0..<200 where tabs.openTabs.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
            check(tabs.openTabs.count == 1 && tabs.activeTabIndex == 0, "a text file opens in a tab that becomes active")
            check(tabs.openTabs.first?.content == "# Title\n\n## Part\n", "the tab holds the text of the file")
            check(tabs.openTabs.first?.headings.map(\.text) == ["Title", "Part"], "a Markdown tab lists its headings")
            check(tabs.openTabs.first?.isModified == false, "a fresh tab is not modified")

            tabs.openDocument(file)
            check(tabs.openTabs.count == 1, "opening a file that is open selects its tab instead of adding one")

            let id = tabs.openTabs[0].id
            tabs.updateTabContent("# Title\n\nedited\n", documentID: id)
            check(tabs.openTabs[0].isModified, "typing makes the tab modified")
            check((try? String(contentsOf: file)) == "# Title\n\n## Part\n", "typing does not touch the file")
            tabs.updateTabContent("# Title\n\n## Part\n", documentID: id)
            check(!tabs.openTabs[0].isModified, "typing the original text back makes the tab clean again")

            tabs.updateTabContent("# Title\n\nsaved text\n", documentID: id)
            tabs.saveEditorDocument(documentID: id)
            check((try? String(contentsOf: file)) == "# Title\n\nsaved text\n", "saving writes the text to the file")
            check(!tabs.openTabs[0].isModified && tabs.openTabs[0].originalContent == "# Title\n\nsaved text\n", "saving makes the text the new baseline")
            check(events == ["saved:note.md"], "saving says so once (\(events))")

            // A message that names a closed tab must not land on the selected one (BUG-031).
            tabs.updateTabContent("never", documentID: UUID())
            check(tabs.openTabs[0].content == "# Title\n\nsaved text\n", "a message for a tab that is gone is dropped")

            try? "# Title\n\nfrom elsewhere\n".write(to: file, atomically: true, encoding: .utf8)
            let reloaded = tabs.reloadActiveTabFromDisk()
            check(reloaded == "# Title\n\nfrom elsewhere\n" && !tabs.openTabs[0].isModified, "reloading shows what the disk holds")
            subscription.cancel()
            tabs.shutdown()
        }
    }

    @MainActor
    static func closeAsksAboutUnsavedChanges() async {
        await folder { dir in
            let file = dir.appendingPathComponent("a.md")
            try? "one\n".write(to: file, atomically: true, encoding: .utf8)
            let script = Script()
            let tabs = TabsController(dialogs: script.dialogs)
            await tabs.openTextFile(file)
            let id = tabs.openTabs[0].id
            tabs.updateTabContent("two\n", documentID: id)

            script.answers = [.cancel]
            tabs.closeTab(at: 0)
            check(tabs.openTabs.count == 1 && script.asked.count == 1, "Cancel keeps a modified tab open")

            script.answers = [.discard]
            tabs.closeTab(at: 0)
            check(tabs.openTabs.isEmpty && tabs.activeTabIndex == -1, "Don't Save closes the tab and returns to the Welcome tab")
            check((try? String(contentsOf: file)) == "one\n", "Don't Save leaves the file as it was")

            await tabs.openTextFile(file)
            tabs.updateTabContent("three\n", documentID: tabs.openTabs[0].id)
            script.answers = [.save]
            tabs.closeTab(at: 0)
            check(tabs.openTabs.isEmpty, "Save closes the tab")
            check((try? String(contentsOf: file)) == "three\n", "Save writes the text before the tab closes")

            await tabs.openTextFile(file)
            tabs.closeTab(at: 0)
            check(tabs.openTabs.isEmpty && script.asked.count == 3, "a tab without changes closes without a question")
        }
    }

    @MainActor
    static func closeDocuments() async {
        await folder { dir in
            let a = dir.appendingPathComponent("a.md"), b = dir.appendingPathComponent("b.md")
            try? "a\n".write(to: a, atomically: true, encoding: .utf8)
            try? "b\n".write(to: b, atomically: true, encoding: .utf8)
            let script = Script()
            let tabs = TabsController(dialogs: script.dialogs)
            await tabs.openTextFile(a)
            var git = OpenTab(url: dir.appendingPathComponent(".markview-tool-git"), content: "", originalContent: "")
            git.kind = .tool(.git)
            tabs.appendTab(git)
            await tabs.openTextFile(b)
            tabs.updateTabContent("b edited\n", documentID: tabs.openTabs[2].id)
            check(tabs.openTabs.map(\.isDocument) == [true, false, true], "two documents and a tool tab are open")

            script.answers = [.cancel]
            tabs.closeDocuments()
            check(tabs.openTabs.count == 3 && script.asked.count == 1, "Cancel closes nothing")

            script.answers = [.discard]
            tabs.closeDocuments()
            check(tabs.openTabs.count == 1 && tabs.openTabs[0].id == git.id, "Close Documents keeps the tool tab")
            check(tabs.activeTabIndex == 0, "the tool tab becomes the active one")
            check((try? String(contentsOf: b)) == "b\n", "Don't Save leaves the document as it was")
            check(script.asked.count == 2 && script.asked[1].contains("b.md"), "one question names the modified document (\(script.asked))")
        }
    }

    @MainActor
    static func closeFolderQuestionAndFailedSave() async {
        await folder { dir in
            let file = dir.appendingPathComponent("locked.md")
            try? "x\n".write(to: file, atomically: true, encoding: .utf8)
            let script = Script()
            let tabs = TabsController(dialogs: script.dialogs)
            await tabs.openTextFile(file)
            tabs.updateTabContent("y\n", documentID: tabs.openTabs[0].id)

            check(tabs.resolveUnsavedChanges(at: [0], before: "closing the folder") == false && script.asked.count == 1, "no answer means nothing closes")
            script.answers = [.discard]
            check(tabs.resolveUnsavedChanges(at: [0], before: "closing the folder"), "Don't Save lets the folder close")

            // A folder nobody can write into: the save fails, the person is told, and nothing closes over unsaved work.
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            script.answers = [.save]
            let closed = tabs.resolveUnsavedChanges(at: [0], before: "closing the folder")
            check(!closed && script.failedSaves == ["locked.md"], "a failed save stops the close and says which file (\(script.failedSaves))")
            check(tabs.lastSaveError != nil, "a failed save leaves the banner text")
            check(tabs.openTabs[0].isModified, "the tab stays modified after a failed save")
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            tabs.saveFile(at: 0)
            check(tabs.lastSaveError == nil && !tabs.openTabs[0].isModified, "a later successful save clears the banner text")
        }
    }

    @MainActor
    static func followMovedFiles() async {
        await folder { dir in
            let sub = dir.appendingPathComponent("sub"), moved = dir.appendingPathComponent("moved")
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let file = sub.appendingPathComponent("n.md")
            try? "n\n".write(to: file, atomically: true, encoding: .utf8)
            let tabs = TabsController(dialogs: Script().dialogs)
            await tabs.openTextFile(file)
            tabs.follow(moved: [(sub, moved)])
            check(tabs.openTabs[0].url.path == moved.appendingPathComponent("n.md").path, "a tab of a file inside a moved folder follows it")
            tabs.follow(moved: [(dir.appendingPathComponent("other"), dir.appendingPathComponent("elsewhere"))])
            check(tabs.openTabs[0].url.path == moved.appendingPathComponent("n.md").path, "a move of something else changes nothing")
        }
    }

    @MainActor
    static func reloadFilesChangedOnDisk() async {
        await folder { dir in
            let clean = dir.appendingPathComponent("clean.md"), dirty = dir.appendingPathComponent("dirty.md")
            try? "clean 1\n".write(to: clean, atomically: true, encoding: .utf8)
            try? "dirty 1\n".write(to: dirty, atomically: true, encoding: .utf8)
            let tabs = TabsController(dialogs: Script().dialogs)
            var reloads = 0
            let subscription = tabs.events.sink { if case .reloadedFromDisk = $0 { reloads += 1 } }
            await tabs.openTextFile(clean)
            await tabs.openTextFile(dirty)
            tabs.updateTabContent("dirty typed\n", documentID: tabs.openTabs[1].id)

            try? "clean 2\n".write(to: clean, atomically: true, encoding: .utf8)
            try? "dirty 2\n".write(to: dirty, atomically: true, encoding: .utf8)
            await tabs.reloadChangedOpenFiles(all: true)
            check(tabs.openTabs[0].content == "clean 2\n" && !tabs.openTabs[0].isModified, "a tab without edits takes the text an assistant wrote")
            check(tabs.openTabs[1].content == "dirty typed\n" && tabs.openTabs[1].isModified, "a tab with unsaved edits keeps what was typed")
            check(reloads == 1, "the window is told once that tabs were reloaded (\(reloads))")

            await tabs.reloadChangedOpenFiles(all: true)
            check(reloads == 1, "nothing changed, so nobody is told again")

            // A document whose file is gone is not a failure of the check.
            try? FileManager.default.removeItem(at: clean)
            await tabs.reloadChangedOpenFiles(all: true)
            check(tabs.openTabs[0].content == "clean 2\n", "a file that vanished leaves its tab as it was")
            subscription.cancel()
        }
    }

    @MainActor
    static func sideTableFollowsTheTabs() async {
        await folder { dir in
            let tabs = TabsController(dialogs: Script().dialogs)
            var ids: [UUID] = []
            for name in ["a.md", "b.md", "c.md"] {
                let file = dir.appendingPathComponent(name)
                try? "# \(name)\n".write(to: file, atomically: true, encoding: .utf8)
                await tabs.openTextFile(file)
                ids.append(tabs.openTabs.last!.id)
            }
            for id in ids { tabs.scroll.setScrollPosition(120, for: id); tabs.scroll.setActiveHeading("h-" + id.uuidString, for: id) }
            tabs.closeTab(at: 0)
            check(tabs.scroll.scrollPosition(for: ids[0]) == 0 && tabs.scroll.activeHeading(for: ids[0]) == nil, "a closed tab leaves nothing in the scroll table (FU-11)")
            check(tabs.scroll.scrollPosition(for: ids[1]) == 120, "the other tabs keep their scroll position")
            tabs.closeOtherTabs(except: 0)
            check(tabs.scroll.scrollPosition(for: ids[2]) == 0, "Close Others prunes the tabs that closed")
            tabs.closeAllTabs()
            check(tabs.scroll.scrollPosition(for: ids[1]) == 0 && tabs.openTabs.isEmpty, "Close All empties the table")
        }
    }

    @MainActor
    static func whatRedrawsWhat() async {
        await folder { dir in
            let file = dir.appendingPathComponent("typing.md")
            try? "# T\n".write(to: file, atomically: true, encoding: .utf8)
            let tabs = TabsController(dialogs: Script().dialogs)
            await tabs.openTextFile(file)
            let id = tabs.openTabs[0].id
            var tabsEmissions = 0, scrollEmissions = 0
            let a = tabs.objectWillChange.sink { _ in tabsEmissions += 1 }
            let b = tabs.scroll.objectWillChange.sink { _ in scrollEmissions += 1 }

            for index in 0..<20 { tabs.updateTabContent("# T\nline \(index)\n", documentID: id) }
            check(tabsEmissions == 20 && scrollEmissions == 0, "typing redraws what shows the tabs, once per change (tabs \(tabsEmissions), scroll \(scrollEmissions))")

            tabsEmissions = 0; scrollEmissions = 0
            for index in 0..<20 { tabs.scroll.setScrollPosition(CGFloat(index * 10), for: id) }
            check(tabsEmissions == 0 && scrollEmissions == 0, "scrolling redraws nothing (tabs \(tabsEmissions), scroll \(scrollEmissions))")

            tabsEmissions = 0; scrollEmissions = 0
            for index in 0..<20 { tabs.updateActiveHeading("heading \(index)") }
            check(tabsEmissions == 0 && scrollEmissions == 20, "the active heading redraws only the Contents panel (tabs \(tabsEmissions), scroll \(scrollEmissions))")
            check(tabs.scroll.activeHeading(for: id) == "heading 19", "the active heading is kept per tab")
            _ = (a, b)
        }
    }

    @MainActor
    static func closeTabsUnderTrashedFolder() async {
        await folder { dir in
            let sub = dir.appendingPathComponent("trash"), keep = dir.appendingPathComponent("keep.md")
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let inside = sub.appendingPathComponent("in.md")
            try? "in\n".write(to: inside, atomically: true, encoding: .utf8)
            try? "keep\n".write(to: keep, atomically: true, encoding: .utf8)
            let script = Script()
            let tabs = TabsController(dialogs: script.dialogs)
            await tabs.openTextFile(keep)
            await tabs.openTextFile(inside)
            tabs.updateTabContent("edited\n", documentID: tabs.openTabs[1].id)
            tabs.closeTabs(under: sub)
            check(tabs.openTabs.map(\.url.lastPathComponent) == ["keep.md"], "tabs of a folder moved to the Trash close")
            check(script.asked.isEmpty, "nothing is asked: the person chose to let the folder go")
        }
    }

    @MainActor
    static func tabKindsOpenWithoutTextLoad() async {
        await folder { dir in
            let tabs = TabsController(dialogs: Script().dialogs)
            let pdf = dir.appendingPathComponent("Read only.PDF"), image = dir.appendingPathComponent("p.png"), data = dir.appendingPathComponent("rows.csv")
            for url in [pdf, image, data] { try? Data("x".utf8).write(to: url) }
            tabs.openDocument(pdf)
            tabs.openDocument(image)
            tabs.openDocument(data)
            check(tabs.openTabs.count == 3, "a PDF, an image and a data file open at once")
            if case .pdf = tabs.openTabs[0].kind {} else { check(false, "a PDF opens in the reader") }
            if case .image = tabs.openTabs[1].kind {} else { check(false, "an image opens in the viewer") }
            if case .data = tabs.openTabs[2].kind {} else { check(false, "a data file opens in its viewer") }
            check(tabs.openTabs.allSatisfy { !$0.isFileBacked || $0.content.isEmpty }, "these tabs hold no text of their own")
            let before = try? Data(contentsOf: pdf)
            tabs.activeTabIndex = 0
            tabs.saveActiveFile()
            check((try? Data(contentsOf: pdf)) == before && tabs.lastSaveError == nil, "saving a PDF tab writes nothing")
            tabs.shutdown()
        }
    }
}
