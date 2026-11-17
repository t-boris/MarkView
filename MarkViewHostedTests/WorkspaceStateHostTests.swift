import AppKit
import Combine
import MarkViewCore
import os
import SwiftUI
import WebKit
import XCTest
@testable import MarkView

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
    func testIssueListingFiltersAndSort() {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        func ids(_ items: [IssueFacts]) -> [String] { items.map(\.id) }

        func feature(_ id: String, _ status: String, priority: String = "", updated: String = "", created: String = "",
                     modified: Date? = nil, title: String? = nil) -> IssueFacts {
            IssueFacts(kind: .feature, id: id, title: title ?? id, status: status, priority: priority,
                       updated: updated, created: created, modified: modified)
        }
        func bug(_ id: String, _ status: String, severity: String = "", updated: String = "", created: String = "",
                 modified: Date? = nil, title: String? = nil) -> IssueFacts {
            IssueFacts(kind: .bug, id: id, title: title ?? id, status: status, priority: severity,
                       updated: updated, created: created, modified: modified)
        }
        func filter(_ toggles: IssueFilterToggle...) -> IssueFilter { IssueFilter(Set(toggles)) }
        func shown(_ f: IssueFilter, _ items: [IssueFacts]) -> [String] { ids(items.filter(f.matches)) }

        // MARK: Status mapping (REQ-001, DEC-002, DEC-005, user decision on verified/archived)

        check("bug fixed is Closed", IssueStatus.isClosed(bug("b", "fixed")))
        check("bug closed is Closed", IssueStatus.isClosed(bug("b", "closed")))
        check("bug fixed not under Open", !filter(.open).matches(bug("b", "fixed")))
        check("bug fixed under Closed", filter(.closed).matches(bug("b", "fixed")))
        check("bug fixing is Open", !IssueStatus.isClosed(bug("b", "fixing")))
        check("feature done: Closed + Implemented", filter(.closed).matches(feature("f", "done")) && filter(.implemented).matches(feature("f", "done")))
        check("feature rejected: Closed + Not Implemented",
              filter(.closed).matches(feature("f", "rejected")) && filter(.notImplemented).matches(feature("f", "rejected")))
        check("feature verified: Closed + Implemented", IssueStatus.isClosed(feature("f", "verified")) && IssueStatus.isImplemented(feature("f", "verified")))
        check("feature archived: Closed, not Implemented", IssueStatus.isClosed(feature("f", "archived")) && !IssueStatus.isImplemented(feature("f", "archived")))
        check("feature implementing: Open", !IssueStatus.isClosed(feature("f", "implementing")))
        check("missing feature status: Open", filter(.open).matches(feature("f", "")))
        check("missing bug status: Open", filter(.open).matches(bug("b", "")))
        check("unknown status: Open", filter(.open).matches(feature("f", "weird")) && filter(.open).matches(bug("b", "weird")))
        check("case-insensitive", IssueStatus.isClosed(bug("b", "FIXED")) && IssueStatus.isImplemented(feature("f", "Implemented")))
        check("whitespace and separators", IssueStatus.normalize("  In Progress ") == "in-progress" && IssueStatus.normalize("in_progress") == "in-progress")
        check("bug closed is not Implemented", !IssueStatus.isImplemented(bug("b", "closed")))

        // MARK: Combination (DEC-006, DEC-009)

        let all = [feature("f-open", "draft"), feature("f-done", "implemented"), feature("f-rej", "rejected"),
                   bug("b-open", "open"), bug("b-fixed", "fixed")]
        check("default shows everything", shown(IssueFilter(), all) == ids(all))
        check("Open+Closed shows all", shown(filter(.open, .closed), all) == ids(all))
        check("Bugs+Features shows all", shown(filter(.bugs, .features), all) == ids(all))
        check("Bugs+Open = open bugs", shown(filter(.bugs, .open), all) == ["b-open"])
        check("Features+NotImplemented+Open", shown(filter(.features, .notImplemented, .open), all) == ["f-open"])
        check("Bugs+Implemented is empty", shown(filter(.bugs, .implemented), all).isEmpty)
        check("Implemented never shows bugs", !shown(filter(.implemented), all).contains { $0.hasPrefix("b-") })
        check("Not Implemented never shows bugs", !shown(filter(.notImplemented), all).contains { $0.hasPrefix("b-") })
        check("Implemented+NotImplemented = all features", shown(filter(.implemented, .notImplemented), all) == ["f-open", "f-done", "f-rej"])
        check("Closed+Implemented = implemented features", shown(filter(.closed, .implemented), all) == ["f-done"])
        check("summary", filter(.bugs, .open).summary == "Open · Bugs")
        check("summary groups", filter(.open, .closed, .features, .notImplemented).summary == "Open, Closed · Features · Not Implemented")
        check("default is default", IssueFilter().isDefault && !filter(.open).isDefault)
        var toggled = IssueFilter(); toggled.toggle(.open); toggled.toggle(.bugs); toggled.toggle(.open)
        check("toggle", toggled == filter(.bugs))

        // MARK: Persisted values (REQ-005, DEC-015)

        check("filter round trip", IssueFilter(stored: filter(.bugs, .open).storedValue) == filter(.bugs, .open))
        check("filter stored in menu order", filter(.bugs, .open).storedValue == ["open", "bugs"])
        check("unknown filter ids dropped", IssueFilter(stored: ["open", "gone", "bugs"]) == filter(.open, .bugs))
        check("no stored filter = default", IssueFilter(stored: nil).isDefault)
        check("sort round trip", IssueSort(stored: IssueSort(field: .priority, descending: false).storedValue) == IssueSort(field: .priority, descending: false))
        check("sort stored format", IssueSort().storedValue == "date:desc")
        check("unknown sort = default", IssueSort(stored: "size:desc") == .default && IssueSort(stored: "date:up") == .default && IssueSort(stored: "garbage") == .default)
        check("no stored sort = date desc", IssueSort(stored: nil) == IssueSort(field: .date, descending: true))

        // MARK: Dates (REQ-002, DEC-011)

        let day = { (s: String) in IssueSort.parseDate(s)! }
        check("YYYY-MM-DD parses", IssueSort.parseDate("2026-09-27") != nil)
        check("ISO date-time parses", IssueSort.parseDate("2026-09-27T10:00:00Z") != nil)
        check("ISO fractional parses", IssueSort.parseDate("2026-09-27T10:00:00.123+02:00") != nil)
        check("quoted date parses", IssueSort.parseDate("\"2026-09-27\"") != nil)
        let isoValues = ["2026-09-27T10:00:00Z", "2026-09-27T10:00:00.123+02:00"]
        let expectedDates = isoValues.map { IssueSort.parseDate($0)! }
        let dateMismatches = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if IssueSort.parseDate(isoValues[index % 2]) != expectedDates[index % 2] {
                dateMismatches.withLock { $0 += 1 }
            }
        }
        check("concurrent ISO date parsing remains stable", dateMismatches.withLock { $0 == 0 })
        check("invalid day rejected", IssueSort.parseDate("2026-02-31") == nil)
        check("garbage rejected", IssueSort.parseDate("yesterday") == nil && IssueSort.parseDate("") == nil)
        let mtime = day("2020-01-01")
        check("updated wins", IssueSort.date(feature("f", "", updated: "2026-09-27", created: "2026-01-01", modified: mtime)) == day("2026-09-27"))
        check("created next", IssueSort.date(feature("f", "", created: "2026-01-01", modified: mtime)) == day("2026-01-01"))
        check("invalid updated falls through", IssueSort.date(feature("f", "", updated: "soon", created: "2026-01-01")) == day("2026-01-01"))
        check("mtime last", IssueSort.date(feature("f", "", modified: mtime)) == mtime)

        let dated = [feature("a", "", updated: "2026-03-01"), feature("b", "", created: "2026-05-01"),
                     feature("c", "", modified: day("2026-04-01")), feature("none", "")]
        check("date desc (default)", ids(IssueSort().sorted(dated) { $0 }) == ["b", "c", "a", "none"])
        check("date asc, missing last", ids(IssueSort(field: .date, descending: false).sorted(dated) { $0 }) == ["a", "c", "b", "none"])
        // BUG-017: a day's bugs tie on `created`; they keep their filing order, not their titles' order.
        let sameDay = [bug("BUG-9", "", created: "2026-01-01", title: "Zeta"), bug("BUG-21", "", created: "2026-01-01", title: "Alpha"),
                       bug("BUG-10", "", created: "2026-01-01", modified: day("2026-02-01"), title: "Beta")]
        check("same day: newest id first", ids(IssueSort().sorted(sameDay) { $0 }) == ["BUG-21", "BUG-10", "BUG-9"])
        check("same day, oldest first: oldest id first", ids(IssueSort(field: .date, descending: false).sorted(sameDay) { $0 }) == ["BUG-9", "BUG-10", "BUG-21"])
        check("same day ties ignore titles", ids(IssueSort().sorted([feature("a", "", created: "2026-01-01", title: "zzz"),
                                                                    feature("b", "", created: "2026-01-01", title: "aaa")]) { $0 }) == ["b", "a"])

        // MARK: Priority (REQ-002, DEC-007)

        check("bug scale", IssueSort.priorityRank(bug("b", "", severity: "Blocker")) == 4 && IssueSort.priorityRank(bug("b", "", severity: "normal")) == 2
              && IssueSort.priorityRank(bug("b", "", severity: "trivial")) == 1)
        check("feature scale", IssueSort.priorityRank(feature("f", "", priority: "P0")) == 4 && IssueSort.priorityRank(feature("f", "", priority: " High ")) == 3)
        check("unknown priority empty", IssueSort.priorityRank(feature("f", "", priority: "urgent-ish")) == nil && IssueSort.priorityRank(bug("b", "")) == nil)
        let prioritized = [bug("low", "", severity: "low"), feature("none", ""), feature("crit", "", priority: "p0"),
                           bug("high", "", severity: "high"), bug("unknown", "", severity: "whatever")]
        let desc = ids(IssueSort(field: .priority, descending: true).sorted(prioritized) { $0 })
        let asc = ids(IssueSort(field: .priority, descending: false).sorted(prioritized) { $0 })
        check("priority desc", Array(desc.prefix(3)) == ["crit", "high", "low"])
        check("priority asc reverses valued items", Array(asc.prefix(3)) == ["low", "high", "crit"])
        check("empty priority last both ways", Set(desc.suffix(2)) == ["none", "unknown"] && Set(asc.suffix(2)) == ["none", "unknown"])
        let samePriority = [bug("old", "", severity: "high", created: "2026-01-01"), bug("new", "", severity: "high", created: "2026-06-01")]
        check("priority ties: newest first", ids(IssueSort(field: .priority, descending: false).sorted(samePriority) { $0 }) == ["new", "old"])
        let samePriorityDay = [bug("BUG-2", "", severity: "high", created: "2026-01-01"), bug("BUG-11", "", severity: "high", created: "2026-01-01")]
        check("priority and date ties: newest id first", ids(IssueSort(field: .priority, descending: false).sorted(samePriorityDay) { $0 }) == ["BUG-11", "BUG-2"])

        // MARK: Badge tone

        check("tone done", IssueStatus.tone(bug("b", "fixed")) == .done && IssueStatus.tone(feature("f", "verified")) == .done)
        check("tone dropped", IssueStatus.tone(feature("f", "rejected")) == .dropped)
        check("tone active", IssueStatus.tone(feature("f", "implementing")) == .active && IssueStatus.tone(bug("b", "fixing")) == .active)
        check("tone open", IssueStatus.tone(bug("b", "")) == .open)

        // A status of the project's workflow is read by its role, whatever it is called (feature-3).
        func roled(_ kind: IssueFacts.Kind, _ status: String, _ role: LifecycleRole) -> IssueFacts {
            var facts = kind == .feature ? feature("f", status) : bug("b", status)
            facts.role = role
            return facts
        }
        check("a completed role is closed and implemented under any name", IssueStatus.isClosed(roled(.feature, "shipped", .completed)) && IssueStatus.isImplemented(roled(.feature, "shipped", .completed)))
        check("a cancelled role is closed but not implemented", IssueStatus.isClosed(roled(.feature, "dropped", .cancelled)) && !IssueStatus.isImplemented(roled(.feature, "dropped", .cancelled)))
        check("an active role is open and active under any name", !IssueStatus.isClosed(roled(.bug, "in-review", .active)) && IssueStatus.tone(roled(.bug, "in-review", .active)) == .active)
        check("a not-started role is open even when the name sounds finished", !IssueStatus.isClosed(roled(.bug, "closed", .notStarted)) && IssueStatus.tone(roled(.bug, "closed", .notStarted)) == .open)
        check("the role beats the old name for active work too", IssueStatus.tone(roled(.feature, "implementing", .notStarted)) == .open)
        check("a completed bug and a completed feature are done, a cancelled feature is dropped",
              IssueStatus.tone(roled(.bug, "done", .completed)) == .done && IssueStatus.tone(roled(.feature, "live", .completed)) == .done && IssueStatus.tone(roled(.feature, "shelved", .cancelled)) == .dropped)
        check("a bug is never implemented", !IssueStatus.isImplemented(roled(.bug, "done", .completed)))
        check("a status without a role is still read by name", IssueStatus.isClosed(feature("f", "rejected")))

    }
}


extension EditorHostTests {
    func testIssueReferenceAndOutcomeParsingOffline() {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        let origin = "t-boris/MarkView"
        func t(_ number: Int, _ repo: String? = nil) -> IssueSyncTarget { IssueSyncTarget(repo: repo ?? origin, number: number) }
        func feature(_ id: String, _ status: String, fields: [String] = [], texts: [String] = []) -> IssueSyncItem {
            IssueSyncItem(kind: .feature, id: id, title: id, status: status, fieldValues: fields, texts: texts)
        }
        func bug(_ id: String, _ status: String, fields: [String] = [], texts: [String] = []) -> IssueSyncItem {
            IssueSyncItem(kind: .bug, id: id, title: id, status: status, fieldValues: fields, texts: texts)
        }
        func targets(_ item: IssueSyncItem) -> [IssueSyncTarget] { IssueSyncLinks.references(of: item, origin: origin).map(\.target) }

        // MARK: Explicit references (REQ-002, DEC-001, DEC-006)

        check("field #n resolves to origin", targets(feature("f", "", fields: ["#36"])) == [t(36)])
        check("field bare number resolves to origin", targets(feature("f", "", fields: ["12"])) == [t(12)])
        check("field owner/repo#n", targets(feature("f", "", fields: ["t-boris/MarkView#7"])) == [t(7)])
        check("field full issue URL", targets(feature("f", "", fields: ["https://github.com/t-boris/MarkView/issues/9"])) == [t(9)])
        check("field several values in one string", targets(feature("f", "", fields: ["#1, #2"])) == [t(1), t(2)])
        check("repository compared without case", t(5, "T-Boris/markview") == t(5))
        check("text issue URL resolves", targets(feature("f", "", texts: ["See https://github.com/t-boris/MarkView/issues/40 here"])) == [t(40)])
        check("text URL with comment anchor", targets(feature("f", "", texts: ["https://github.com/t-boris/MarkView/issues/41#issuecomment-1"])) == [t(41)])
        check("text 'issue #n' is not a link", targets(feature("f", "", texts: ["Fixes issue #12 and #13"])).isEmpty)
        check("text PR URL is not an issue reference", targets(feature("f", "", texts: ["https://github.com/t-boris/MarkView/pull/51"])).isEmpty)
        check("duplicates across fields and text kept once",
              targets(feature("f", "", fields: ["#3", "3"], texts: ["https://github.com/t-boris/MarkView/issues/3"])) == [t(3)])
        check("item linked to several issues keeps each",
              targets(feature("f", "", fields: ["#1", "#2"], texts: ["https://github.com/t-boris/MarkView/issues/4"])) == [t(1), t(2), t(4)])
        let pullField = IssueSyncLinks.fieldReferences(["https://github.com/t-boris/MarkView/pull/8"], origin: origin)
        check("field PR URL is a pull link", pullField.count == 1 && pullField[0].isPullLink && pullField[0].target == t(8))

        // MARK: Explicit fields hold references, not prose (BUG-033, REQ-002)
        // Sync closes issues without a preview, so a number inside an anchor, a version or a sentence must
        // never become a link. A field value is either a list of references or prose; in prose only full
        // issue and pull request URLs count.

        func fieldTargets(_ value: String) -> [IssueSyncTarget] { targets(feature("f", "", fields: [value])) }
        let home = "https://github.com/t-boris/MarkView"
        check("field URL with comment anchor links only its issue", fieldTargets("\(home)/issues/41#issuecomment-1234") == [t(41)])
        check("field URL with query links only its issue", fieldTargets("\(home)/issues/9?notification_referrer_id=77") == [t(9)])
        check("field URL with trailing slash", fieldTargets("\(home)/issues/9/") == [t(9)])
        check("field URL without scheme", fieldTargets("github.com/t-boris/MarkView/issues/9") == [t(9)])
        let anchoredPull = IssueSyncLinks.fieldReferences(["\(home)/pull/8#issuecomment-5"], origin: origin)
        check("field PR URL with anchor is one pull link", anchoredPull.count == 1 && anchoredPull[0].isPullLink && anchoredPull[0].target == t(8))
        check("field URL followed by letters is not a link", fieldTargets("\(home)/issues/41abc").isEmpty)
        check("field sentence with a bare number is not a link", fieldTargets("see issue 12 in v2.3").isEmpty)
        check("field version is not a link", fieldTargets("v2.3").isEmpty && fieldTargets("2.3").isEmpty && fieldTargets("1.0.4").isEmpty)
        check("field sentence with #n is not a link", fieldTargets("see #12 for details").isEmpty)
        check("field #n with a note is not a link", fieldTargets("#36 (main)").isEmpty)
        check("field words between references make it prose", fieldTargets("#1 and #2").isEmpty)
        check("field owner/repo#n inside prose is not a link", fieldTargets("part of t-boris/MarkView#7").isEmpty)
        check("field owner/repo#n with a suffix is not a link", fieldTargets("t-boris/MarkView#7.1").isEmpty)
        check("field number with a suffix is not a link", fieldTargets("12abc").isEmpty && fieldTargets("#12abc").isEmpty && fieldTargets("12.").isEmpty)
        check("field URL inside prose still links", fieldTargets("fixed in \(home)/issues/41, released in v2.3") == [t(41)])
        check("field list separators", fieldTargets("#1; #2") == [t(1), t(2)] && fieldTargets("1 2") == [t(1), t(2)]
              && fieldTargets("1, 2,") == [t(1), t(2)] && fieldTargets("t-boris/MarkView#3, 4") == [t(3), t(4)])
        check("field mixed list keeps its order", fieldTargets("#1, \(home)/issues/2#issuecomment-5, 3") == [t(1), t(2), t(3)])
        check("separate field values are judged apart", targets(feature("f", "", fields: ["#5", "see issue 12", "#6"])) == [t(5), t(6)])
        check("field with prose only leaves the item unlinked",
              IssueSyncPlan(items: [feature("f", "implemented", fields: ["see issue 12 in v2.3"])], origin: origin).pairs.map(\.target) == [nil])

        // MARK: Plan: other repositories, pull links, unlinked (DEC-006, DEC-010)

        let plan = IssueSyncPlan(items: [
            feature("done-a", "implemented", fields: ["#10"]),
            feature("wip", "implementing", fields: ["#10", "#11"]),
            bug("BUG-001", "fixed", fields: ["#12"]),
            bug("BUG-002", "closed", fields: ["upstream/MarkView#5"]),
            feature("text-only", "verified", texts: ["issue #99"]),
            feature("pr-link", "archived", fields: ["https://github.com/t-boris/MarkView/pull/20"]),
            feature("fork", "implemented", texts: ["https://github.com/someone/MarkView/issues/3"]),
        ], origin: origin)
        check("lookups are unique origin issues in order", plan.lookups == [t(10), t(11), t(12)])
        check("other repository skipped", plan.known[t(5, "upstream/MarkView")] == .otherRepository)
        check("fork is another repository", plan.known[t(3, "someone/MarkView")] == .otherRepository)
        check("PR link skipped as pull request", plan.known[t(20)] == .pullRequest)
        let unlinkedPairs = plan.pairs.filter { $0.target == nil }.map { plan.items[$0.item].id }
        check("text-only item is the only unlinked one", unlinkedPairs == ["text-only"])
        check("rejected-only items get no unlinked row", !unlinkedPairs.contains("BUG-002") && !unlinkedPairs.contains("pr-link"))

        // MARK: Eligibility (REQ-003, DEC-005, owner answer on bugs)

        check("feature statuses done", ["implemented", "verified", "archived", "done", " Implemented ", " Done "].allSatisfy { feature("f", $0).isDone })
        check("feature earlier statuses not done", ["", "idea", "ready", "implementing"].allSatisfy { !feature("f", $0).isDone })
        check("bug fixed/closed done", bug("b", "fixed").isDone && bug("b", "closed").isDone)
        check("bug open/fixing not done", !bug("b", "open").isDone && !bug("b", "fixing").isDone)
        check("a number that is a PR settles as a pull request", IssueSyncRemote.pullRequest.settledOutcome == .pullRequest)
        check("a missing issue settles as not found", IssueSyncRemote.notFound.settledOutcome == .notFound)
        check("a lookup failure settles as failed with its message", IssueSyncRemote.failed("HTTP 403").settledOutcome == IssueSyncOutcome(kind: .failed, detail: "HTTP 403"))
        check("an answer about a real issue settles nothing: the lifecycle decides", IssueSyncRemote.issue(open: true).settledOutcome == nil && IssueSyncRemote.issue(open: false).settledOutcome == nil)

        // MARK: GitHub answers

        check("open issue parsed", IssueSyncRemote.parse(json: #"{"number":1,"state":"open"}"#) == .issue(open: true))
        check("closed issue parsed", IssueSyncRemote.parse(json: #"{"number":1,"state":"closed","state_reason":"completed"}"#) == .issue(open: false))
        check("pull request parsed", IssueSyncRemote.parse(json: #"{"number":1,"state":"open","pull_request":{"url":"x"}}"#) == .pullRequest)
        check("garbage is a failure", { if case .failed = IssueSyncRemote.parse(json: "<html>") { return true }; return false }())
        check("404 is not found", IssueSyncRemote.failure(message: "gh: Not Found (HTTP 404)") == .notFound)
        check("410 is not found", IssueSyncRemote.failure(message: "gh: This issue was deleted (HTTP 410)") == .notFound)
        check("403 is a failure, not 'not found'",
              IssueSyncRemote.failure(message: "gh: Resource not accessible by integration (HTTP 403)") != .notFound)
        check("403 message kept", IssueSyncRemote.failure(message: "HTTP 403: Forbidden") == .failed("HTTP 403: Forbidden"))
        check("write access allows closing", IssueSyncPreflight.permissionProblem(json: #"{"viewerPermission":"WRITE"}"#, repo: origin) == nil)
        check("triage access allows closing", IssueSyncPreflight.permissionProblem(json: #"{"viewerPermission":"TRIAGE"}"#, repo: origin) == nil)
        check("read access blocks the run", IssueSyncPreflight.permissionProblem(json: #"{"viewerPermission":"READ"}"#, repo: origin) != nil)

        // MARK: Report (REQ-004, DEC-008, DEC-010)

        var outcomes = plan.known
        outcomes[t(10)] = IssueSyncOutcome(kind: .skipped, detail: "not done yet: wip (implementing)")
        outcomes[t(11)] = .alreadyClosed
        outcomes[t(12)] = .closed
        let report = IssueSyncReport(plan: plan, outcomes: outcomes)
        check("one row per item–issue pair plus unlinked", report.rows.count == plan.pairs.count && report.rows.count == 8)
        check("shared issue counted once", report.count(.skipped) == 4)  // #10, #20, upstream#5, someone#3
        check("closed counted", report.count(.updated) == 1)
        check("unchanged counted", report.count(.unchanged) == 1)
        check("unlinked counted apart", report.unlinkedCount == 1)
        check("both items of a shared issue have rows", report.rows.filter { $0.target == t(10) }.map(\.item.id) == ["done-a", "wip"])
        check("closed rows come first after failures", report.linkedRows.first?.outcome == .closed)
        check("summary", report.summary == "1 closed · 1 unchanged · 4 skipped · 1 unlinked")
        check("preflight error report has no rows", IssueSyncReport(origin: origin, error: "Not signed in").rows.isEmpty)
        check("label in origin is #n", t(12).label(origin: origin) == "#12")
        check("label elsewhere names the repo", t(5, "upstream/MarkView").label(origin: origin) == "upstream/markview#5")

        // The role of the status in the project's workflow decides whether an item is done (feature-3).
        func roled(_ item: IssueSyncItem, _ role: LifecycleRole) -> IssueSyncItem { var copy = item; copy.role = role; return copy }
        check("a completed role is done under any name", roled(feature("f", "shipped"), .completed).isDone && roled(bug("b", "accepted"), .completed).isDone)
        check("a cancelled role is done", roled(feature("f", "shelved"), .cancelled).isDone)
        check("an active or not-started role is not done, even under a finished-sounding name", !roled(feature("f", "implemented"), .active).isDone && !roled(bug("b", "closed"), .notStarted).isDone)
        check("a status without a role is read by name", feature("f", "verified").isDone && bug("b", "fixed").isDone && !bug("b", "fixing").isDone)

    }
}


extension EditorHostTests {
    func testCloudServiceParsingOffline() {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let now = CloudServices.date("2026-10-12T12:00:00Z")!

        // MARK: scope and queries
        let commands = [CloudCommand(id: "a", title: "", command: "firebase hosting:sites:list --project demo-dev"), CloudCommand(id: "b", title: "", command: "fly status -a my-api")]
        let scope = CloudServices.scope(of: commands)
        check(scope.project == "demo-dev" && scope.app == "my-api", "the project and the app are read from the commands")
        check(CloudServices.scope(of: [CloudCommand(id: "x", title: "", command: "firebase x --project a;rm")]).project == nil, "a project name with shell characters is refused")
        check(CloudServices.queries(provider: "firebase", scope: scope).map(\.id) == ["hosting", "functions"], "firebase: hosting and functions")
        check(CloudServices.queries(provider: "firebase", scope: CloudScope()).isEmpty, "firebase without a project asks nothing")
        check(CloudServices.queries(provider: "fly", scope: scope).map(\.command) == ["fly status -a my-api --json", "fly machines list -a my-api --json"], "fly: app and machines")
        check(CloudServices.queries(provider: "vercel", scope: CloudScope()).map(\.id) == ["deployments"], "vercel: deployments")
        check(CloudServices.queries(provider: "aws", scope: scope).isEmpty, "other providers: none yet")
        let all = CloudServices.queries(provider: "firebase", scope: scope) + CloudServices.queries(provider: "fly", scope: scope) + CloudServices.queries(provider: "vercel", scope: scope)
        check(all.allSatisfy { CommandPolicy.classify($0.command).isReadOnly }, "every query is read-only: \(all.filter { !CommandPolicy.classify($0.command).isReadOnly }.map(\.command))")

        // MARK: firebase
        let functionsJSON = """
        Warning: something printed before the JSON
        {"status":"success","result":[
         {"id":"zeta","region":"us-central1","runtime":"nodejs22","availableMemoryMb":256,"callableTrigger":{},"environmentVariables":{"STRIPE_KEY":"sk_live_SECRET"},"uri":"https://zeta-x.a.run.app"},
         {"id":"alpha","region":"europe-west1","runtime":"nodejs22","availableMemoryMb":512,"httpsTrigger":{},"uri":"https://alpha-x.a.run.app"},
         {"id":"nightly","region":"us-central1","runtime":"nodejs22","scheduleTrigger":{"schedule":"every 24 hours"}},
         {"id":"bad name; rm -rf","region":"us-central1","callableTrigger":{}}
        ]}
        """
        let functionsQuery = CloudQuery(id: "functions", group: "Functions", command: "")
        let functions = CloudServices.parse(functionsQuery, provider: "firebase", scope: CloudScope(project: "demo-dev", app: nil), output: functionsJSON, now: now)
        check(functions.map(\.name) == ["alpha", "bad name; rm -rf", "nightly", "zeta"], "functions are listed by name: \(functions.map(\.name))")
        let alpha = functions.first { $0.name == "alpha" }!, zeta = functions.first { $0.name == "zeta" }!
        check(alpha.details == ["https", "nodejs22", "europe-west1", "512 MB"], "details: trigger, runtime, region, memory")
        check(alpha.openURL == "https://alpha-x.a.run.app" && zeta.openURL == nil, "an https function can be opened, a callable one cannot")
        check(alpha.logCommand == "firebase functions:log --project demo-dev --only alpha --lines 100" && CommandPolicy.classify(alpha.logCommand!).isReadOnly, "the log command is the function's own and read-only")
        check(functions.first { $0.name.hasPrefix("bad") }?.logCommand == nil, "a function name with shell characters gets no command")
        check(functions.first { $0.name == "nightly" }?.details.first == "scheduled", "a scheduled trigger")
        let dump = functions.map { "\($0)" }.joined()
        check(!dump.contains("SECRET") && !dump.contains("STRIPE"), "environment variables are never read")
        check(zeta.consoleURL == "https://console.firebase.google.com/project/demo-dev/functions", "console page of the functions")

        let channelsJSON = """
        {"status":"success","result":{"channels":[
         {"name":"projects/demo-dev/sites/demo-dev/channels/live","url":"https://demo-dev.web.app","updateTime":"2026-10-09T12:00:00.123Z"},
         {"name":"projects/demo-dev/sites/demo-dev/channels/pr-7","url":"https://demo-dev--pr-7-abc.web.app","updateTime":"2026-10-12T11:00:00Z","expireTime":"2026-10-14T12:00:00Z"}
        ]}}
        """
        let channels = CloudServices.parse(CloudQuery(id: "hosting", group: "Hosting", command: ""), provider: "firebase", scope: CloudScope(project: "demo-dev", app: nil), output: channelsJSON, now: now)
        check(channels.count == 2 && channels[0].name == "demo-dev · live" && channels[0].probe && channels[0].openURL == "https://demo-dev.web.app", "hosting: a channel per row, to open and to probe")
        check(channels[0].details == ["updated 3 d ago", "never expires"], "hosting: age and expiry: \(channels[0].details)")
        check(channels[1].details == ["updated 1 h ago", "expires in 2 d"], "hosting: a preview channel expires: \(channels[1].details)")
        check(channels[0].consoleURL == "https://console.firebase.google.com/project/demo-dev/hosting/sites/demo-dev", "hosting: console page")

        // MARK: fly
        let appJSON = #"{"Name":"my-api","Status":"suspended","Hostname":"my-api.fly.dev","Version":7,"Secrets":[{"Name":"DATABASE_URL"}]}"#
        let flyApp = CloudServices.parse(CloudQuery(id: "app", group: "App", command: ""), provider: "fly", scope: CloudScope(project: nil, app: "my-api"), output: appJSON, now: now)
        check(flyApp.count == 1 && flyApp[0].state == "suspended" && flyApp[0].level == .warn && flyApp[0].openURL == "https://my-api.fly.dev" && !flyApp[0].probe, "fly app: state, address, never probed (a call would wake it)")
        check(flyApp[0].logCommand == "fly logs -a my-api --no-tail" && CommandPolicy.classify(flyApp[0].logCommand!).isReadOnly && !"\(flyApp)".contains("DATABASE_URL"), "fly app: read-only log command, secrets untouched")
        let machinesJSON = #"""
        [{"id":"148e1","name":"a-machine","state":"started","region":"fra","updated_at":"2026-10-12T11:30:00Z","image_ref":{"repository":"my-org/my-api","tag":"deployment-1"},"config":{"env":{"TOKEN":"SECRETVALUE"}},"checks":[{"name":"http","status":"passing"}]},
         {"id":"287f2","name":"b-machine","state":"started","region":"ams","checks":[{"name":"http","status":"critical"}]},
         {"id":"391a3","name":"c-machine","state":"stopped","region":"fra"}]
        """#
        let machines = CloudServices.parse(CloudQuery(id: "machines", group: "Machines", command: ""), provider: "fly", scope: CloudScope(project: nil, app: "my-api"), output: machinesJSON, now: now)
        check(machines.map(\.name) == ["b-machine", "a-machine", "c-machine"], "fly machines: problems first: \(machines.map(\.name))")
        check(machines[0].level == .bad && machines[1].level == .ok && machines[2].level == .unknown, "fly machines: a critical check is bad, started is ok, stopped is quiet")
        check(machines[1].details == ["fra", "my-api", "updated 30 min ago"], "fly machines: details: \(machines[1].details)")
        check(machines[1].logCommand == "fly logs -a my-api --machine 148e1 --no-tail" && CommandPolicy.classify(machines[1].logCommand!).isReadOnly, "fly machines: the machine's own log")
        check(!"\(machines)".contains("SECRETVALUE"), "fly machines: environment is never read")

        // MARK: vercel
        let vercelJSON = #"""
        {"contextName":"team","deployments":[
         {"name":"web","url":"web-abc123.vercel.app","state":"READY","target":"production","createdAt":1791806400000},
         {"name":"web","url":"web-def456.vercel.app","state":"ERROR","createdAt":1791802800000},
         {"name":"web","url":"web-ghi789.vercel.app","state":"BUILDING","target":null,"createdAt":1791806100000}],"pagination":{}}
        """#
        let deployments = CloudServices.parse(CloudQuery(id: "deployments", group: "Deployments", command: ""), provider: "vercel", scope: CloudScope(), output: vercelJSON, now: now)
        check(deployments.map(\.state) == ["ready", "error", "building"], "vercel: states: \(deployments.map { $0.state ?? "-" })")
        check(deployments.map(\.level) == [.ok, .bad, .warn], "vercel: ready is ok, error bad, building warn")
        check(deployments[0].details.first == "production" && deployments[1].details.first == "preview", "vercel: production or preview")
        check(deployments[0].openURL == "https://web-abc123.vercel.app" && deployments[0].logCommand == "vercel inspect web-abc123.vercel.app --logs" && CommandPolicy.classify(deployments[0].logCommand!).isReadOnly, "vercel: open and a read-only build log")

        // MARK: totals, probe, junk
        let totals = CloudServices.totals(machines + deployments)
        check(totals.map(\.group) == ["Machines", "Deployments"] && totals[0].bad == 1 && totals[0].ok == 1 && totals[0].count == 3 && totals[1].warn == 1, "totals per group: \(totals)")
        check(CloudServices.probeResult(code: 200, seconds: 0.4).level == .ok && CloudServices.probeResult(code: 200, seconds: 5).level == .warn, "probe: 200 is ok, slow is a warning")
        check(CloudServices.probeResult(code: 404, seconds: 0.2).level == .warn && CloudServices.probeResult(code: 503, seconds: 0.2).level == .bad && CloudServices.probeResult(code: nil, seconds: 8).state == "unreachable", "probe: 404 warns, 5xx and no answer are bad")
        check(CloudServices.parse(functionsQuery, provider: "firebase", scope: CloudScope(project: "p", app: nil), output: "Error: Failed to authenticate", now: now).isEmpty, "output that is not JSON gives nothing")
        check(CloudServices.parse(functionsQuery, provider: "firebase", scope: CloudScope(project: "p", app: nil), output: "{\"status\":\"success\",\"result\":{}}", now: now).isEmpty, "an unexpected shape gives nothing")

    }
}
