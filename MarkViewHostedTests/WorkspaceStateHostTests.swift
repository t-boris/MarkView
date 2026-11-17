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


extension EditorHostTests {
    func testDeploymentLogPlansOffline() {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        var server = DeploymentEnvironment(id: "p", name: "Prod", kind: .ssh, host: "web-1.example.com")
        server.checks = [DeploymentCheck(id: "n", title: "nginx", kind: .systemd, target: "nginx"), DeploymentCheck(id: "d", title: "db", kind: .docker, target: "db")]
        let before = DeploymentLogs.suggestions(for: server, snapshot: nil)
        check(before.map(\.title) == ["System journal", "Errors only", "Service nginx", "Container db"], "before the first look: the journal, errors, and what the checks name: \(before.map(\.title))")
        check(before.allSatisfy { CommandPolicy.classify($0.command).isReadOnly }, "every suggested command is read-only: \(before.filter { !CommandPolicy.classify($0.command).isReadOnly }.map(\.command))")

        var snap = SystemSnapshot()
        snap.os = "Linux"
        snap.containers = [.init(name: "web", status: "Up", image: "nginx"), .init(name: "db", status: "Up", image: "postgres")]
        snap.failedUnits = ["backup.service"]
        let after = DeploymentLogs.suggestions(for: server, snapshot: snap)
        check(after.map(\.title).contains("Container web") && after.map(\.title).contains("Service backup.service") && after.filter { $0.title == "Container db" }.count == 1, "after a look: containers and failed services are added once: \(after.map(\.title))")

        server.logSources = [LogSource(id: "mine", title: "App", command: "journalctl -u nginx -n 200 --no-pager")]
        let merged = DeploymentLogs.all(for: server, snapshot: snap)
        check(merged.first?.id == "mine" && merged.filter { $0.command == "journalctl -u nginx -n 200 --no-pager" }.count == 1, "own sources come first and are not repeated")

        let mac = DeploymentEnvironment(id: "m", name: "Mac", kind: .local)
        let macLogs = DeploymentLogs.suggestions(for: mac, snapshot: nil)
        check(macLogs.first?.command.hasPrefix("log show") == true && !macLogs.contains { $0.command.contains("journalctl") }, "this Mac gets the unified log, not the journal")
        check(DeploymentLogs.suggestions(for: DeploymentEnvironment(id: "c", name: "C", kind: .cloud, provider: "fly"), snapshot: nil).isEmpty, "a cloud service has none (its commands show logs)")
        var hostile = DeploymentEnvironment(id: "h", name: "H", kind: .ssh, host: "h.example.com")
        hostile.checks = [DeploymentCheck(id: "x", title: "x", kind: .systemd, target: "a; reboot"), DeploymentCheck(id: "y", title: "y", kind: .docker, target: "$(id)")]
        check(!DeploymentLogs.suggestions(for: hostile, snapshot: nil).contains { $0.command.contains("reboot") || $0.command.contains("$(") }, "a hostile name never reaches a command")

        // What is read before answering a question.
        var box = DeploymentEnvironment(id: "b", name: "Box", kind: .ssh, host: "b.example.com")
        box.logSources = [LogSource(id: "mine", title: "App", command: "tail -n 200 /var/log/app.log")]
        var seen = SystemSnapshot(); seen.os = "Linux"
        seen.containers = [.init(name: "web", status: "Up 3 days", image: "nginx"), .init(name: "pg", status: "Up 3 days", image: "postgres:16"), .init(name: "worker", status: "Restarting (1) 5 seconds ago", image: "app"), .init(name: "cache", status: "Up 2 days", image: "redis:7")]
        seen.failedUnits = ["backup.service"]
        let plan = DeploymentLogs.evidencePlan(question: "Is it healthy?", env: box, snapshot: seen).map(\.title)
        check(plan.first == "Errors only" && plan.contains("Service backup.service") && plan.contains("Container worker"), "errors, failed services and containers that are not up come first: \(plan)")
        check(plan.count <= 6 && Set(plan).count == plan.count, "no more than six, none twice")
        let dbPlan = DeploymentLogs.evidencePlan(question: "Is the database fine?", env: box, snapshot: seen).map(\.title)
        check(dbPlan.contains("Container pg") && !dbPlan.contains("Container cache") || dbPlan.count == 6, "a question about the database reads the database container: \(dbPlan)")
        check(DeploymentLogs.evidencePlan(question: "?", env: box, snapshot: seen).contains { $0.title == "App" }, "the person's own log is read too")
        check(DeploymentLogs.evidencePlan(question: "?", env: DeploymentEnvironment(id: "q", name: "Q", kind: .ssh, host: "q.example.com"), snapshot: nil).count >= 2, "before a first look it still reads the journal")
        check(DeploymentLogs.evidencePlan(question: "?", env: DeploymentEnvironment(id: "c", name: "C", kind: .cloud, provider: "fly"), snapshot: nil).isEmpty, "a cloud service has nothing to read this way")
        check(DeploymentLogs.evidencePlan(question: "x", env: box, snapshot: seen).allSatisfy { CommandPolicy.classify($0.command).isReadOnly }, "everything read is read-only")

    }
}


extension EditorHostTests {
    func testDeploymentDiscoveryOnTemporaryFixtures() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let config = """
        Host prod
            HostName 203.0.113.10
            User deploy
            Port 2222
            IdentityFile ~/.ssh/prod_ed25519
        Host staging stage
          HostName staging.example.net
          User ubuntu
        Host *
          ServerAliveInterval 30
        Host unrelated
          HostName 198.51.100.7
        """
        let hosts = DeploymentDiscovery.parseSSHConfig(config)
        check(hosts.map(\.alias) == ["prod", "staging", "stage", "unrelated"], "ssh config hosts, wildcards left out: \(hosts.map(\.alias))")
        check(hosts[0].hostName == "203.0.113.10" && hosts[0].user == "deploy" && hosts[0].port == 2222 && hosts[0].identityFile == "~/.ssh/prod_ed25519", "ssh config fields")
        check(hosts[1].hostName == "staging.example.net" && hosts[2].user == "ubuntu", "one block, several aliases")

        // ssh mentions in docs
        let docs = """
        Deploy with `ssh deploy@203.0.113.10 'cd /srv/app && git pull'`.
        Then `scp build.tar.gz deploy@staging.example.net:/srv/` and rsync -av out/ deploy@staging.example.net:/srv/app.
        Clone with git@github.com:me/app.git (ssh git@github.com).
        Use ssh user@host as a template, and ssh keys are in 1Password. Connect via ssh into the box.
        """
        let targets = DeploymentDiscovery.sshTargets(in: docs)
        check(targets.map(\.host).contains("203.0.113.10") && targets.map(\.host).contains("staging.example.net"), "real hosts are found: \(targets.map(\.host))")
        let prose = DeploymentDiscovery.sshTargets(in: "Then ssh git@github to test. Run `ssh apt-get install x`. After 109 steps ssh 109 is a number. Real: ssh deploy@10.0.0.5 and ssh root@db-1")
        check(prose.map(\.host) == ["10.0.0.5", "db-1"], "prose words and bare numbers are not machines: \(prose.map(\.host))")
        check(!targets.map(\.host).contains("github.com") && !targets.map(\.host).contains("host") && !targets.map(\.host).contains("keys") && !targets.map(\.host).contains("into"), "code hosts, placeholders and prose are not: \(targets.map(\.host))")
        check(targets.first { $0.host == "203.0.113.10" }?.user == "deploy", "the user is read")

        // compose
        let composeText = """
        version: "3"
        services:
          web:
            image: nginx
          db:
            image: postgres:16
            volumes:
              - data:/var/lib/postgresql/data
        volumes:
          data:
        """
        check(DeploymentDiscovery.composeServices(composeText) == ["web", "db"], "compose services: \(DeploymentDiscovery.composeServices(composeText))")

        // a project
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(".github/workflows/deploy.yml", """
        name: Deploy
        on: push
        jobs:
          prod:
            runs-on: ubuntu-latest
            environment: production
            steps:
              - uses: appleboy/ssh-action@v1
                with:
                  host: ${{ secrets.PROD_HOST }}
                  username: deploy
          stage:
            environment: staging
            steps:
              - run: rsync -av . ${{ secrets.STAGING_HOST }}:/srv
        """)
        try write("fly.toml", "app = \"my-api\"\n[http_service]\n")
        try write("vercel.json", "{}")
        try write("firebase.json", #"{"hosting":{"public":"web/dist"},"functions":[{"source":"functions"}],"firestore":{"rules":"firestore.rules"}}"#)
        try write(".firebaserc", #"{"projects":{"default":"demo-dev","prod":"demo-prod"}}"#)
        try write(".github/workflows/firebase-deploy.yml", """
        name: Deploy to Firebase
        on: { push: { branches: [main] } }
        jobs:
          deploy:
            steps:
              - run: npx -y firebase-tools deploy --non-interactive
                env:
                  FIREBASE_TOKEN: ${{ secrets.FIREBASE_TOKEN }}
                  STRIPE_SECRET_KEY: ${{ secrets.STRIPE_SECRET_KEY }}
        """)
        try write("docker-compose.yml", composeText)
        try write("README.md", docs)
        try write("node_modules/x/README.md", "ssh deploy@evil.example.org")
        try write("src/main.swift", "print(1)")

        let found = DeploymentDiscovery.scan(root: root, sshConfig: config)
        let byId = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        check(byId["production"]?.kind == .ssh && byId["production"]?.missing.joined().contains("PROD_HOST") == true, "workflow: production, host is a secret: \(found.map(\.id))")
        check(byId["staging"]?.kind == .ssh, "workflow: staging")
        check(byId["fly"]?.provider == "fly" && byId["fly"]?.cloudCommands.first?.command == "fly status -a my-api", "fly.toml: app and commands")
        check(byId["fly"]?.cloudCommands.allSatisfy { CommandPolicy.classify($0.command).isReadOnly } == true, "every suggested fly command is read-only")
        check(byId["vercel"]?.provider == "vercel" && byId["vercel"]?.cloudCommands.allSatisfy { CommandPolicy.classify($0.command).isReadOnly } == true, "vercel.json: read-only commands")
        let dev = byId["firebase-demo-dev"], prod = byId["firebase-demo-prod"]
        check(dev?.provider == "firebase" && prod?.provider == "firebase", "firebase.json + .firebaserc: one place per project: \(found.map(\.id))")
        check(dev?.cloudCommands.contains { $0.command == "firebase functions:list --project demo-dev" } == true && dev?.checks.first?.target == "https://demo-dev.web.app", "firebase: commands and hosting check name the project")
        check([dev, prod].compactMap { $0 }.allSatisfy { $0.cloudCommands.allSatisfy { $0.command.contains("--project demo-") && !$0.command.contains("projects:list") } }, "firebase: every command is scoped to its project, none lists the whole account")
        check(dev?.logSources.first?.command == "firebase functions:log --project demo-dev --lines 100", "firebase: functions log")
        check(dev?.evidence.contains { $0.contains("firebase-deploy.yml") } == true && byId["firebase"] == nil, "firebase: the workflow's evidence joins the projects, no bare duplicate")
        check(([dev, prod].compactMap { $0 }.flatMap { $0.cloudCommands.map(\.command) + $0.logSources.map(\.command) }).allSatisfy { CommandPolicy.classify($0).isReadOnly }, "every suggested firebase command is read-only")
        check(!CommandPolicy.classify("firebase deploy --project demo-dev").isReadOnly && !CommandPolicy.classify("firebase functions:log --follow").isReadOnly && !CommandPolicy.classify("firebase use prod").isReadOnly, "firebase deploy, following logs and use are not")
        check(ProviderHints.advice(command: "firebase projects:list", stderr: "Error: Failed to authenticate, have you run firebase login?", status: 1)?.contains("firebase login") == true, "a signed-out firebase says how to sign in")
        check(!found.contains { $0.id.contains("stripe") }, "a secret that merely contains the letters IP (STRIPE_SECRET_KEY) is not a host")
        let server = found.first { $0.host == "203.0.113.10" }
        check(server?.user == "deploy" && server?.port == 2222 && server?.identityFile == "~/.ssh/prod_ed25519", "the docs' host picks up its ssh config entry")
        for f in found { print("   found", f.id, f.kind, f.host, f.confidence, f.checks.map(\.id)) }
        check(server?.checks.contains { $0.kind == .docker && $0.target == "web" } == true || found.contains { $0.id == "docker-host" && $0.checks.contains { $0.target == "web" } }, "compose services become container checks (on the only server, or on their own entry)")
        check(found.first { $0.host == "staging.example.net" } != nil, "a second host from the docs")
        check(!found.contains { $0.host.contains("evil") }, "node_modules is not read")
        check(!found.contains { $0.host == "198.51.100.7" }, "an unrelated ssh config host is left out")
        check(found.sorted { $0.confidence > $1.confidence } == found, "sorted by confidence")
        let env = byId["fly"]!.makeEnvironment(existing: ["fly-io-my-api"])
        check(env.id == "fly-io-my-api-2" && env.kind == .cloud && env.problems.isEmpty, "a suggestion becomes an environment with a free id")
        check(DeploymentEnvironment(id: "a", name: "a", kind: .ssh, host: "-oProxyCommand=evil").problems.contains { $0.contains("characters") }, "an option-like host is refused")
        check(DeploymentEnvironment(id: "a", name: "a", kind: .ssh, host: "web-1.example.com", user: "deploy").problems.isEmpty, "a normal ssh environment is fine")
        check(DeploymentEnvironment(id: "a", name: "a", kind: .ssh, host: "::1").problems.isEmpty && DeploymentEnvironment.isSafeToken("fe80::1%en0"), "ipv6 fits")


        // A project that keeps its database in a managed service (as docs write it down) and its servers at a hosting vendor.
        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("discovery2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root2) }
        func write2(_ path: String, _ text: String) throws {
            let url = root2.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write2("docs/deployment/environments.md", """
        # Environments

        | | local | dev | production |
        |---|---|---|---|
        | Business DB | local postgres | **Neon** branch `dev` | **Neon** branch `production` |

        > Neon provisioned: project `flat-dawn-39185109`, region aws-eu-central-1. Host (pooled): `ep-billowing-paper-as15eck5-pooler.c-4.eu-central-1.aws.neon.tech`.
        | production | `production` | `br-frosty-queen-aswnplte` | `ep-billowing-paper-as15eck5-pooler.c-4.eu-central-1.aws.neon.tech` |
        | dev | `dev` | `br-mute-sun-asvtz0qs` | `ep-bitter-bird-as7ypdhk-pooler.c-4.eu-central-1.aws.neon.tech` |
        Variant A: dev and production each run on a single Contabo box with docker-compose.app.yml.
        The full connection string goes only in infrastructure/.env, never commit it.
        """)
        try write2("package.json", "{\"dependencies\": {\"@neondatabase/serverless\": \"^0.9\", \"next\": \"15\"}}")
        try write2(".env", "DATABASE_URL=postgres://neondb_owner:SuperSecretPassw0rd@ep-secret-host-123456.us-east-2.aws.neon.tech/db")
        let managed = DeploymentDiscovery.scan(root: root2)
        let neon = managed.first { $0.id == "neon" }
        check(neon?.kind == .cloud && neon?.provider == "neon", "a Neon database is found: \(managed.map(\.id))")
        check(neon?.checks.map(\.target).sorted() == ["ep-billowing-paper-as15eck5-pooler.c-4.eu-central-1.aws.neon.tech:5432", "ep-bitter-bird-as7ypdhk-pooler.c-4.eu-central-1.aws.neon.tech:5432"], "its two endpoints become reachability checks: \(neon?.checks.map(\.target) ?? [])")
        check(neon?.checks.contains { $0.title.contains("(production)") } == true && neon?.checks.contains { $0.title.contains("(dev)") } == true, "labelled production and dev from the docs' lines")
        check(neon?.cloudCommands.contains { $0.command == "neonctl branches list --project-id flat-dawn-39185109" } == true, "the project id gives neonctl commands: \(neon?.cloudCommands.map(\.command) ?? [])")
        check(neon?.cloudCommands.allSatisfy { CommandPolicy.classify($0.command).isReadOnly } == true, "every Neon command is read-only")
        check(neon?.missing.joined().contains("never shows or saves it") == true, "it says the connection URL is never shown or saved")
        check(!managed.flatMap { $0.evidence + $0.missing + $0.checks.map(\.target) }.joined().contains("SuperSecret") && !managed.contains { $0.evidence.joined().contains("ep-secret-host") }, ".env is never read")
        let servers = managed.filter { $0.kind == .ssh }
        check(servers.map(\.name).contains("Dev (Contabo)") && servers.map(\.name).contains("Production (Contabo)") && servers.allSatisfy { $0.host.isEmpty && !$0.missing.isEmpty }, "the hosting vendor and environments from the docs become servers still missing a host: \(servers.map(\.name))")
        let packageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("discovery3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: packageRoot) }
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try "{\"dependencies\":{\"@supabase/supabase-js\":\"2\"}}".write(to: packageRoot.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let onlyPackage = DeploymentDiscovery.scan(root: packageRoot)
        check(onlyPackage.first?.provider == "supabase" && onlyPackage.first?.name.contains("library found") == true && onlyPackage.first?.checks.isEmpty == true && onlyPackage.first?.cloudCommands.first?.command == "supabase projects list", "a dependency alone suggests the service, without inventing a host")

        // A project that runs locally: console script + port named in the README.
        let localRoot = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localRoot) }
        try? FileManager.default.createDirectory(at: localRoot.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try? "[project]\nname = \"app\"\n[project.scripts]\ntitanium-platform = \"app.cli:main\"\ntitanium-research-mcp = \"app.mcp:main\"\n[tool.pytest]\n".write(to: localRoot.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        try? "Run `.venv/bin/titanium-platform`, then open http://127.0.0.1:8765/#/research. Postgres on localhost:5432.\n".write(to: localRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let local = DeploymentDiscovery.scan(root: localRoot).first { $0.id == "this-mac" }
        check(local?.kind == .local && local?.checks.contains { $0.kind == .http && $0.target == "http://127.0.0.1:8765/" } == true, "a localhost port in the README becomes a local http check: \(String(describing: local?.checks.map(\.target)))")
        check(local?.checks.allSatisfy { !$0.target.contains("5432") } == true, "a database port is not the app")
        check(local?.missing.first?.contains("`.venv/bin/titanium-platform`") == true && local?.missing.first?.contains("mcp") == false, "start command from console scripts, the MCP server left out: \(String(describing: local?.missing))")

        let nodeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-node-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: nodeRoot, withIntermediateDirectories: true)
        try? "{\"scripts\":{\"dev\":\"vite --port 4321\",\"build\":\"vite build\"}}".write(to: nodeRoot.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let node = DeploymentDiscovery.scan(root: nodeRoot).first { $0.id == "this-mac" }
        check(node?.missing.first?.contains("npm run dev") == true && node?.checks.first?.target == "http://127.0.0.1:4321/", "package.json dev script and its --port")
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-plain-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        check(DeploymentDiscovery.scan(root: plain).first { $0.id == "this-mac" } == nil, "nothing to run, nothing suggested")

        // Hints for a missing CLI.
        check(ProviderHints.tool(of: "sudo -n neonctl projects list") == "neonctl", "the tool of a command")
        check(ProviderHints.advice(command: "neonctl projects list", stderr: "sh: neonctl: command not found", status: 127)?.contains("brew install neonctl") == true, "a missing CLI says how to install it")
        check(ProviderHints.advice(command: "vercel ls", stderr: "Error: No existing credentials found. Please log in", status: 1)?.contains("vercel login") == true, "a signed-out CLI says how to sign in")
        check(ProviderHints.hints["neonctl"]?.installCommand == "brew install neonctl" && ProviderHints.hints["vercel"]?.installCommand == "npm i -g vercel", "the install command is the one the hint names")
        check(ProviderHints.hints.values.allSatisfy { $0.tool == "docker" || !CommandPolicy.classify($0.installCommand).isReadOnly }, "an install always asks first")
        check(ProviderHints.problem(command: "fly status", stderr: "sh: fly: command not found", status: 127)?.problem == .missing && ProviderHints.problem(command: "vercel ls", stderr: "Please log in", status: 1)?.problem == .signedOut, "missing or signed out")
        check(ProviderHints.advice(command: "uptime", stderr: "command not found", status: 127) == nil && ProviderHints.advice(command: "fly status", stderr: "app not found", status: 1) == nil, "other failures get no advice")

    }
}


extension EditorHostTests {
    func testDefinitionOfDoneStorageAndPrompt() throws {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        let standard = DefinitionOfDone.standard
        check("standard has the built-in items", standard.items.count == DefinitionOfDone.builtIn.count && standard.items.count >= 10)
        check("ids are unique", Set(standard.items.map(\.id)).count == standard.items.count)
        let text = standard.goalText()
        check("goal text is one line", !text.contains("\n"))
        check("required items are numbered", text.contains("(1) ") && text.contains("(2) "))
        check("branch from origin/main is required", text.contains("origin/main"))
        check("CI green is required", text.contains("CI checks"))
        check("issues are in step", text.contains("GitHub issues"))
        check("merge is asked, not required", text.contains("Ask me before you do any of these") && text.contains("Merge the pull request once"))
        check("skipped items are named as not part of the goal", text.contains("Not part of this goal") && text.contains("Build and deploy"))
        check("skipped wording is not given as an instruction", !text.contains("deploy it the way this project does"))
        check("a checklist with evidence is asked for at the end", text.contains("checklist") && text.contains("evidence"))

        // Switching items.
        var custom = standard
        for i in custom.items.indices where custom.items[i].id == "deploy" { custom.items[i].mode = .require }
        for i in custom.items.indices where custom.items[i].id == "ci" { custom.items[i].mode = .skip }
        let t2 = custom.goalText()
        check("deploy now required", t2.contains("deploy it the way this project does"))
        check("ci skipped", !t2.contains("Wait for the pull request's CI checks") && t2.contains("CI is green"))

        // Custom items and empty ones.
        var withCustom = standard
        withCustom.items.append(DoneItem(id: "x1", title: "Changelog", instruction: "Add an entry to CHANGELOG.md", mode: .require, custom: true))
        withCustom.items.append(DoneItem(id: "x2", title: "Empty", instruction: "   ", mode: .require, custom: true))
        withCustom.items.append(DoneItem(id: "x3", title: "Skipped custom", instruction: "Do something odd", mode: .skip, custom: true))
        let t3 = withCustom.goalText()
        check("custom required item is added with a full stop", t3.contains("Add an entry to CHANGELOG.md."))
        check("empty custom item is ignored", !t3.contains("Empty"))
        check("skipped custom item is dropped silently", !t3.contains("Do something odd") && !t3.contains("Skipped custom"))
        check("nothing set gives no text", DefinitionOfDone(items: []).goalText().isEmpty)
        check("all skipped gives only the not-part list", {
            var d = standard
            for i in d.items.indices { d.items[i].mode = .skip }
            let g = d.goalText()
            return g.hasPrefix("Not part of this goal") && !g.contains("Definition of done")
        }())

        // Storage in a throwaway folder.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dod-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        check("no file: standard", DefinitionOfDone.load(root: root) == .standard)
        check("no project: standard", DefinitionOfDone.load(root: nil) == .standard)
        do { try withCustom.save(root: root) } catch { check("save: \(error)", false) }
        let loaded = DefinitionOfDone.load(root: root)
        check("round trip keeps the custom item", loaded.items.contains { $0.id == "x1" && $0.custom && $0.mode == .require })
        check("round trip keeps a changed mode", loaded.items.first { $0.id == "merge" }?.mode == .ask)
        check("file is where the app looks", FileManager.default.fileExists(atPath: root.appendingPathComponent(".dde/definition-of-done.json").path))

        // An older file lacks a newer built-in item and has outdated wording.
        let old = DefinitionOfDone(items: [DoneItem(id: "branch", title: "old title", instruction: "old words", mode: .skip),
                                           DoneItem(id: "gone", title: "Removed built-in", instruction: "x", mode: .require)])
        let merged = DefinitionOfDone.merged(old)
        check("old file: the choice is kept", merged.items.first { $0.id == "branch" }?.mode == .skip)
        check("old file: wording follows the app", merged.items.first { $0.id == "branch" }?.instruction.contains("origin/main") == true)
        check("old file: new built-ins appear", merged.items.count == DefinitionOfDone.builtIn.count)
        check("old file: a removed built-in does not linger", !merged.items.contains { $0.id == "gone" })
        try? Data("not json".utf8).write(to: root.appendingPathComponent(".dde/definition-of-done.json"))
        check("a broken file falls back to standard", DefinitionOfDone.load(root: root) == .standard)

        // The file is a schema-versioned store (AR-36): a saved checklist is in an envelope; a file written before it still loads; a file
        // that cannot be read is never replaced without a backup; a newer file is never replaced.
        let dod = root.appendingPathComponent(".dde/definition-of-done.json")
        let legacyFixture = """
        {
          "items" : [
            { "custom" : false, "id" : "branch", "instruction" : "old words", "mode" : "skip", "title" : "old title" },
            { "custom" : false, "id" : "merge", "instruction" : "old merge words", "mode" : "ask", "title" : "Merge" },
            { "custom" : true, "id" : "x9", "instruction" : "Add an entry to CHANGELOG.md", "mode" : "require", "title" : "Changelog" }
          ]
        }
        """
        StoreFixture.write(legacyFixture, to: dod)
        let upgraded = DefinitionOfDone.load(root: root)
        check("legacy file: the person's choices and custom item survive the upgrade",
              upgraded.items.first { $0.id == "branch" }?.mode == .skip && upgraded.items.first { $0.id == "merge" }?.mode == .ask
              && upgraded.items.contains { $0.id == "x9" && $0.custom && $0.mode == .require })
        check("legacy file: it is left as written until a save", StoreFixture.envelope(dod) == nil)
        try upgraded.save(root: root)
        check("legacy file: the next save writes the envelope", StoreFixture.envelope(dod)?.schema == 1)
        check("legacy file: the envelope reloads to the same checklist", DefinitionOfDone.load(root: root) == upgraded)
        check("legacy file: nothing was damaged, so no backup", StoreFixture.backups(of: dod).isEmpty)

        let damaged = "{ \"items\": [ truncated"
        StoreFixture.write(damaged, to: dod)
        check("damaged file: the standard checklist is used in memory", DefinitionOfDone.load(root: root) == .standard)
        check("damaged file: loading does not touch it", StoreFixture.bytes(dod) == Data(damaged.utf8) && StoreFixture.backups(of: dod).isEmpty)
        try withCustom.save(root: root)
        check("damaged file: a save keeps the old bytes in a dated backup",
              StoreFixture.backups(of: dod).count == 1 && StoreFixture.bytes(StoreFixture.backups(of: dod)[0]) == Data(damaged.utf8))
        check("damaged file: and writes the new checklist", DefinitionOfDone.load(root: root).items.contains { $0.id == "x1" })

        let newer = StoreFixture.newerFile(payload: #"{"items":[],"somethingNew":true}"#)
        StoreFixture.write(newer, to: dod)
        check("newer file: it is not used", DefinitionOfDone.loadIfPresent(root: root) == nil)
        var refused = false
        do { try withCustom.save(root: root) } catch SchemaStoreError.newerSchemaVersion { refused = true } catch {}
        check("newer file: a save is refused and the file stays as it is", refused && StoreFixture.bytes(dod) == Data(newer.utf8))
        check("newer file: the policy readers see a declared checklist with no item set", DefinitionOfDone.policyData(root: root) == Data("{}".utf8))

        // The prompt.
        let prompt = HandoffPrompt.feature("docs/features/x", tool: CLITool(rawValue: "claude")!, done: standard)
        check("prompt keeps the objective and adds the checklist", prompt.hasPrefix("/goal Implement what docs/features/x") && prompt.contains("Definition of done"))
        check("prompt stays on one line", !prompt.contains("\n"))
        check("prompt without a checklist is unchanged", HandoffPrompt.feature("docs/features/x", tool: CLITool(rawValue: "claude")!) == HandoffPrompt.feature("docs/features/x", tool: CLITool(rawValue: "claude")!, done: DefinitionOfDone(items: [])))
    }
}

extension EditorHostTests {
    func testHandoffPromptsRespectRecordedAnswers() {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        let path = "docs/features/csv-export"
        for backend in ["claude", "codex", "cline", "copilot"].map { CLITool(rawValue: $0)! } {
            let p = HandoffPrompt.feature(path, tool: backend)
            let who = backend.rawValue
            check("\(who): feature prompt names the folder", p.contains(path))
            check("\(who): feature prompt is one line (pasted and submitted at once)", !p.contains("\n"))
            for record in ["questions/", "decisions/", "findings/", "discussion.md"] {
                check("\(who): feature prompt names \(record)", p.contains(record))
            }
            check("\(who): answers are binding and not asked again", p.contains("binding") && p.contains("do not ask them again"))
            check("\(who): new answers are written back", p.contains("back into the specification"))
            check("\(who): no open invitation to ask anything", !p.contains("ask any question if you are in doubt"))
            let b = HandoffPrompt.bug("docs/bugs/BUG-011-x.md", tool: backend)
            check("\(who): bug prompt names the report", b.contains("docs/bugs/BUG-011-x.md"))
            check("\(who): bug prompt keeps reproduce / root cause / verify", b.contains("reproduce") && b.contains("root cause") && b.contains("verify"))
            check("\(who): bug clarifications are binding", b.contains("## Clarifications") && b.contains("do not ask them again"))
            check("\(who): bug prompt is one line", !b.contains("\n"))
        }
        check("claude feature prompt is a /goal", HandoffPrompt.feature(path, tool: CLITool(rawValue: "claude")!).hasPrefix("/goal "))
        check("codex feature prompt is a /goal", HandoffPrompt.feature(path, tool: CLITool(rawValue: "codex")!).hasPrefix("/goal "))
        check("copilot feature prompt is an autopilot objective", HandoffPrompt.feature(path, tool: CLITool(rawValue: "copilot")!).hasPrefix("/autopilot "))
        check("cline feature prompt sets a task goal", HandoffPrompt.feature(path, tool: CLITool(rawValue: "cline")!).hasPrefix("Goal for this Cline task:"))
        check("claude bug prompt is a /goal", HandoffPrompt.bug("x.md", tool: CLITool(rawValue: "claude")!).hasPrefix("/goal fix the bug"))
        // A goal of the person's own words, for markview_agent_send.
        check("claude goal is /goal <text>", HandoffPrompt.goal("tests pass", tool: CLITool(rawValue: "claude")!) == "/goal tests pass")
        check("codex goal is /goal <text>", HandoffPrompt.goal("tests pass", tool: CLITool(rawValue: "codex")!) == "/goal tests pass")
        check("copilot goal is /autopilot <text>", HandoffPrompt.goal("tests pass", tool: CLITool(rawValue: "copilot")!) == "/autopilot tests pass")
        check("antigravity goal is the text, asked to continue", HandoffPrompt.goal("tests pass", tool: CLITool(rawValue: "antigravity")!).hasPrefix("tests pass ") && !HandoffPrompt.goal("tests pass", tool: CLITool(rawValue: "antigravity")!).hasPrefix("/"))
        check("cline goal is a task goal", HandoffPrompt.goal("tests pass", tool: CLITool(rawValue: "cline")!).hasPrefix("Goal for this Cline task: tests pass"))
    }
}

extension EditorHostTests {
    func testPrototypeHandoffDraftAndDiff() {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let entries = [PrototypeFiles.Entry(version: 5, instruction: "Bigger trade button", summary: "The button is larger.", date: Date()),
                       PrototypeFiles.Entry(version: 6, instruction: "Show strikes in a column", summary: "", date: Date())]
        let trade = PrototypeHandoff.Item(id: "trade", name: "Trade", kind: .screen, files: ["screens/trade.js"], components: ["src/Trade.tsx"], alsoChangedInCode: ["src/Trade.tsx"])
        let shell = PrototypeHandoff.Item(id: "shell", name: "Shell", kind: .foundation, files: ["styles.css"], components: [], alsoChangedInCode: [])
        let badge = PrototypeHandoff.Item(id: "src/ui/Badge.tsx", name: "Badge", kind: .component, files: ["components/badge.html"], components: [], alsoChangedInCode: [])
        let changes = PrototypeHandoff.Changes(baselineVersion: 3, items: [trade, shell, badge], history: entries, codeChanged: ["src/Trade.tsx"])

        // The draft: one unit per change, the fallback text, nothing without a baseline or changes.
        let draft = PrototypeHandoff.draft(prototypeTitle: "Shop", slug: "shop", version: 7, changes: changes)!
        check(draft.units.map(\.id) == ["trade", "shell", "src/ui/Badge.tsx"] && draft.baselineVersion == 3 && draft.version == 7, "a unit per changed screen, component and the shell")
        check(draft.units.allSatisfy { !$0.described && $0.before == .pending && $0.after == .pending }, "nothing is described or photographed yet")
        check(draft.units[0].changes.count == 3 && draft.units[0].changes[0].contains("screens/trade.js")
              && draft.units[0].changes[1] == "Requested in the prototype (v5): Bigger trade button Result: The button is larger."
              && draft.units[0].changes[2] == "Requested in the prototype (v6): Show strikes in a column", "the fallback names the files and every request since the baseline")
        check(PrototypeHandoff.draft(prototypeTitle: "Shop", slug: "shop", version: 7, changes: .init(baselineVersion: nil, items: [trade], history: [], codeChanged: [])) == nil, "no baseline, no draft")
        check(PrototypeHandoff.draft(prototypeTitle: "Shop", slug: "shop", version: 7, changes: .init(baselineVersion: 3, items: [], history: [], codeChanged: [])) == nil, "nothing changed, no draft")

        // What to render and what to call the file.
        check(PrototypeHandoff.shotTarget(of: draft.units[0], componentPage: nil) == (screen: "trade", page: nil), "a screen is shown by its id")
        check(PrototypeHandoff.shotTarget(of: draft.units[1], componentPage: nil) == (screen: nil, page: nil), "the shell shows the first screen")
        check(PrototypeHandoff.shotTarget(of: draft.units[2], componentPage: "components/badge.html") == (screen: nil, page: "components/badge.html"), "a component is shown by its page")
        check(PrototypeHandoff.shotFileName(unitID: draft.units[2].id, side: "before") == "src-ui-badge-tsx-before.png" && PrototypeHandoff.shotFileName(unitID: draft.units[0].id, side: "after") == "trade-after.png", "file names are safe and apart")
        var odd = draft.units[0]; odd.id = "../../Ünï/ ??"
        check(PrototypeHandoff.shotFileName(unitID: odd.id, side: "after") == "ünï-after.png" || PrototypeHandoff.shotFileName(unitID: odd.id, side: "after") == "n-after.png", "an unsafe id stays inside the folder: \(PrototypeHandoff.shotFileName(unitID: odd.id, side: "after"))")
        odd.id = "///"
        check(PrototypeHandoff.shotFileName(unitID: odd.id, side: "before") == "unit-before.png", "an id with no letters still gets a name")

        // The feature text.
        let idea = PrototypeHandoff.featureIdea(draft)
        check(idea.contains("\"Shop\" prototype (v7)") && idea.contains("(v3)") && idea.contains("do not copy the prototype's markup") && idea.contains("Sync from code")
              && idea.contains("v5 \"Bigger trade button\"; v6 \"Show strikes in a column\""), "the idea says where it comes from, how to build and the way back")
        check(PrototypeHandoff.requirementTitle(draft.units[0]) == "Trade matches the prototype" && PrototypeHandoff.requirementTitle(draft.units[1]) == "The application shell matches the prototype"
              && PrototypeHandoff.requirementTitle(draft.units[2]) == "Badge component matches the prototype", "a title per kind of unit")
        check(PrototypeHandoff.requirementStatement(draft.units[0], draft: draft) == "The application shall show Trade as the \"Shop\" prototype v7 does, in the source component `src/Trade.tsx`.", "the statement names the component")
        check(PrototypeHandoff.requirementStatement(draft.units[1], draft: draft) == "The application shall show its shell as the \"Shop\" prototype v7 does.", "the shell statement has no component")

        // Criteria: the changes, the picture check when there is a picture, the conflict.
        var unit = draft.units[0]
        unit.changes = ["  Strikes: show them in a column. Check: five rows.  ", "", "Button: larger."]
        unit.after = .taken("docs/features/x/references/SRC-001-trade-after.png")
        let criteria = PrototypeHandoff.requirementCriteria(unit)
        check(criteria.count == 4 && criteria[0] == "Strikes: show them in a column. Check: five rows." && criteria[1] == "Button: larger."
              && criteria[2].contains("\"after\" picture of Trade") && criteria[3].contains("`src/Trade.tsx`") && criteria[3].contains("reconcile"), "criteria: trimmed changes, picture check, conflict: \(criteria)")
        unit.after = .skipped("no screen"); unit.alsoChangedInCode = []
        check(PrototypeHandoff.requirementCriteria(unit).count == 2, "no picture and no conflict: only the changes")
        unit.changes = []
        check(PrototypeHandoff.requirementCriteria(unit).isEmpty, "a unit with nothing to say has no criteria (the writer must handle that)")

        // The brief carries the draft.
        var drawn = draft
        drawn.units[0].changes = ["Strikes: show them in a column."]
        drawn.units[0].before = .taken("docs/f/before.png"); drawn.units[0].after = .taken("docs/f/after.png")
        let plain = PrototypeHandoff.brief(title: "Shop", reference: "mv://prototype/shop", version: 7, siteRelative: "docs/prototypes/shop/site", changes: changes)
        let rich = PrototypeHandoff.brief(title: "Shop", reference: "mv://prototype/shop", version: 7, siteRelative: "docs/prototypes/shop/site", changes: changes, draft: drawn)
        check(rich.contains("  - Strikes: show them in a column.\n") && rich.contains("  - Pictures: before: `docs/f/before.png`, after: `docs/f/after.png`\n"), "the brief lists what to change and the pictures")
        check(plain == PrototypeHandoff.brief(title: "Shop", reference: "mv://prototype/shop", version: 7, siteRelative: "docs/prototypes/shop/site", changes: changes, draft: nil)
              && rich.count > plain.count, "no draft: the brief is as before")

        // The description: schema, prompt, parser.
        check((PrototypeHandoff.describeSchema["required"] as? [String]) == ["changes"], "the schema asks for the changes")
        let prompt = PrototypeHandoff.describePrompt(unit: drawn.units[0], draft: drawn, beforeFiles: ["docs/p/versions/v3/screens/trade.js"], afterFiles: ["docs/p/site/screens/trade.js"], diff: "- a\n+ b\n")
        check(prompt.contains("Trade") && prompt.contains("v3") && prompt.contains("v7") && prompt.contains("src/Trade.tsx") && prompt.contains("v5: Bigger trade button")
              && prompt.contains("`docs/p/versions/v3/screens/trade.js`") && prompt.contains("Picture before: `docs/f/before.png`") && prompt.contains("```diff\n- a\n+ b\n\n```"), "the prompt names the unit, versions, requests, files, pictures and the difference")
        let fresh = PrototypeHandoff.describePrompt(unit: drawn.units[1], draft: drawn, beforeFiles: [], afterFiles: ["docs/p/site/styles.css"], diff: "")
        check(fresh.contains("none (the unit is new)") && fresh.contains("(no textual difference)") && fresh.contains("The shell"), "a new unit and an empty difference are said")
        let answer: [String: Any] = ["changes": [["where": "Chain header", "what": "Add a Strike column between the sides.", "check": "The strike is in the middle."],
                                                 ["where": "", "what": "Rename GO to Trade.", "check": ""], ["where": "x", "what": "  ", "check": "y"]]]
        check(PrototypeHandoff.parseDescription(answer) == ["Chain header: Add a Strike column between the sides. Check: The strike is in the middle.", "Rename GO to Trade."],
              "an answer becomes lines; an entry with no change is dropped: \(String(describing: PrototypeHandoff.parseDescription(answer)))")
        check(PrototypeHandoff.parseDescription(["changes": []]) == [] && PrototypeHandoff.parseDescription(["nope": 1]) == nil && PrototypeHandoff.parseDescription(nil) == nil, "empty is empty, a wrong shape is nil")

        // The line difference.
        check(PrototypeHandoff.lineDiff(before: "a\nb\nc", after: "a\nb\nc").isEmpty, "equal texts: no difference")
        let diff = PrototypeHandoff.lineDiff(before: "1\n2\n3\n4\n5\n6\n7\n8\n9\n10", after: "1\n2\n3\n4\nFIVE\n6\n7\n8\n9\n10", context: 1)
        check(diff == "…\n  4\n- 5\n+ FIVE\n  6\n", "one changed line with one line of context each side: \(diff.debugDescription)")
        let added = PrototypeHandoff.lineDiff(before: "a", after: "a\nb\nc", context: 0)
        check(added == "+ b\n+ c\n" || added == "…\n+ b\n+ c\n", "added lines: \(added.debugDescription)")
        let big = PrototypeHandoff.lineDiff(before: "", after: (0..<5000).map { "line \($0)" }.joined(separator: "\n"), limit: 500)
        check(big.count < 600 && big.hasSuffix("… (cut)"), "a long difference is cut")

        // The plan for the feature.
        var planned = drawn
        planned.units[1].changes = []
        let plan = PrototypeHandoff.featurePlan(planned)
        check(plan.title == "Match the code to the Shop prototype" && plan.provenance == "Created from prototype shop v7" && plan.requirements.count == 3, "the plan: title, provenance, a requirement per unit")
        check(plan.requirements[0].criteria.count == 3 && plan.requirements[1].criteria == ["The application shell in the application matches the prototype (v7)."]
              && !plan.requirements[2].criteria.isEmpty, "a requirement always has a criterion, even when nothing was described: \(plan.requirements[1].criteria)")
        check(plan.pictures.count == 2 && plan.pictures[0] == .init(unitID: "trade", side: "before", title: "Trade before (prototype v3)", file: "docs/f/before.png")
              && plan.pictures[1].title == "Trade after (prototype v7)", "a picture per taken shot, titled with the prototype version it shows")
        check(plan.overview.hasPrefix("# Match the code to the Shop prototype\n\n## Idea\n\n") && plan.overview.contains("- Trade (screen): also changed in the code since the sync, reconcile\n")
              && plan.overview.contains("- Shell (shell)\n") && plan.overview.contains("- Badge (component)\n"), "the overview lists the units and the conflict")
        check(PrototypeHandoff.screenshotsSection([]) == "" && PrototypeHandoff.screenshotsSection([(title: "T before", link: "../references/SRC-001-t.png")]) == "\n## Screenshots\n\n**T before**\n\n![T before](../references/SRC-001-t.png)\n", "the screenshots section")

        // The files of a unit.
        let files = ["a.js": ("1\n2", "1\nTWO"), "gone.js": ("x", nil as String?), "same.js": ("s", "s")]
        let fileDiff = PrototypeHandoff.unitDiff(files: ["same.js", "a.js", "gone.js", "new.js", "nothing.js"],
                                                 before: { files[$0]?.0 ?? ($0 == "new.js" ? nil : nil) },
                                                 after: { $0 == "new.js" ? "n" : ($0 == "same.js" ? "s" : files[$0]?.1 ?? nil) })
        check(fileDiff == "--- a.js\n  1\n- 2\n+ TWO\n--- gone.js\n(removed)\n- x\n--- new.js\n(new file)\n+ n\n", "a changed, a removed and a new file are told apart; an equal and a missing one are skipped: \(fileDiff.debugDescription)")
    }
}

extension EditorHostTests {
    func testProjectOperationPrimaryOrder() {
        func check(_ name: String, _ got: [String], _ want: [String], line: UInt = #line) {
            XCTAssertEqual(got, want, name, line: line)
        }
        func operation(_ id: String, _ kind: String, _ label: String? = nil) -> ProjectOperation {
            let json = """
            {"id":"\(id)","label":"\(label ?? id)","kind":"\(kind)","nodes":[],"command":"echo \(id)","cwd":".",
             "origin":"discovered","provenance":[],"prerequisites":[],"remoteTrigger":false}
            """
            return try! JSONDecoder().decode(ProjectOperation.self, from: Data(json.utf8))
        }

        let many = [operation("docs", "other"), operation("clean", "clean"), operation("build-web", "build"),
                    operation("build-app", "build"), operation("install", "install"), operation("restart", "restart"),
                    operation("deploy-prod", "deploy"), operation("deploy-stage", "deploy"), operation("migrate", "other")]
        let ids = { (list: [ProjectOperation]) in list.map(\.id) }

        check("five at most, by kind then label",
              ids(ProjectOperation.primary(many, running: [], lastStarted: [:])),
              ["deploy-prod", "deploy-stage", "build-app", "build-web", "install"])
        check("running comes first",
              ids(ProjectOperation.primary(many, running: ["migrate"], lastStarted: [:])).prefix(1).map { $0 }, ["migrate"])
        let now = Date()
        check("recently started before unused",
              ids(ProjectOperation.primary(many, running: [], lastStarted: ["clean": now, "docs": now.addingTimeInterval(-60)])),
              ["clean", "docs", "deploy-prod", "deploy-stage", "build-app"])
        check("fewer than five: all of them", ids(ProjectOperation.primary(Array(many.prefix(2)), running: [], lastStarted: [:])),
              ["clean", "docs"])
        check("test and run precede install and clean",
              ids(ProjectOperation.primary([operation("clean", "clean"), operation("run", "run"),
                                            operation("test", "test"), operation("install", "install")], running: [], lastStarted: [:])),
              ["test", "run", "install", "clean"])
        check("unknown kind ranks last", ids(ProjectOperation.primary([operation("x", "weird"), operation("y", "other")],
                                                                      running: [], lastStarted: [:])), ["y", "x"])
    }
}

extension EditorHostTests {
    @MainActor func testIntakeClipboardAttachments() throws {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("intake-paste-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("ordinary text", forType: .string)
        check("plain text stays with the editor", try IntakeClipboard.attachments(from: board, folder: folder) == nil)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let blue = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)
        for x in 0..<32 { for y in 0..<32 { bitmap.setColor(blue, atX: x, y: y) } }
        let png = bitmap.representation(using: .png, properties: [:])!
        board.clearContents(); board.setData(png, forType: .png)
        let first = try IntakeClipboard.attachments(from: board, folder: folder)!
        let second = try IntakeClipboard.attachments(from: board, folder: folder)!
        check("PNG clipboard becomes a readable image attachment", first.count == 1 && NSImage(contentsOf: first[0]) != nil)
        check("repeated image paste never overwrites", first != second && FileManager.default.fileExists(atPath: first[0].path))
        board.clearContents(); board.setData(bitmap.tiffRepresentation!, forType: .tiff)
        let tiff = try IntakeClipboard.attachments(from: board, folder: folder)!
        check("TIFF screenshot paste converts to PNG", tiff[0].pathExtension == "png" && NSImage(contentsOf: tiff[0]) != nil)
        board.clearContents(); board.writeObjects([first[0] as NSURL])
        check("Finder file paste attaches the file", try IntakeClipboard.attachments(from: board, folder: folder) == first)
        board.clearContents(); board.setString("<p>text only</p>", forType: .html)
        check("HTML without an image remains text paste", try IntakeClipboard.attachments(from: board, folder: folder) == nil)
        do {
            board.clearContents(); board.setData(png, forType: .png)
            _ = try IntakeClipboard.attachments(from: board, folder: first[0])
            check("image write failure is reported", false)
        } catch { check("image write failure is reported", true) }
        // Also supply an image for native Preview → Copy → intake paste verification.
        if let output = ProcessInfo.processInfo.environment["MARKVIEW_INTAKE_IMAGE_OUTPUT"], !output.isEmpty {
            try png.write(to: URL(fileURLWithPath: output))
        }
    }
}

extension EditorHostTests {
    @MainActor func testProjectColorSelectionAndMigration() {
        func check(_ name: String, _ got: String, _ want: String, line: UInt = #line) {
            XCTAssertEqual(got, want, name, line: line)
        }
        check("eight colors", String(ProjectColor.palette.count), "8")
        check("distinct ids", String(Set(ProjectColor.palette.map(\.id)).count), "8")
        check("distinct values", String(Set(ProjectColor.palette.map { "\($0.red) \($0.green) \($0.blue)" }).count), "8")

        // Project key: standardized path after resolving symbolic links.
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("pc-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("a/my-project", isDirectory: true)
        let other = base.appendingPathComponent("b/my-project", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try! FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }
        let key = ProjectColor.projectKey(for: real)
        check("key is the path", key, real.path)
        check("symlink resolves to the same project", ProjectColor.projectKey(for: link), key)
        check("dot segments are standardized", ProjectColor.projectKey(for: real.appendingPathComponent("../my-project")), key)
        check("trailing slash is the same project", ProjectColor.projectKey(for: URL(fileURLWithPath: real.path + "/")), key)
        check("same name, other path is another project", String(ProjectColor.projectKey(for: other) == key), "false")

        // Automatic color (DEC-014): a fixed value per folder name, ignoring case, identical in every
        // process (not Swift's seeded hash).
        check("stable across calls", ProjectColor.automatic(forKey: key).id, ProjectColor.automatic(forKey: key).id)
        check("same name, other path, same color", ProjectColor.automatic(forKey: ProjectColor.projectKey(for: other)).id,
              ProjectColor.automatic(forKey: key).id)
        check("worktree clone of the same name", ProjectColor.automatic(forKey: "/private/tmp/broker-fabric").id,
              ProjectColor.automatic(forKey: "/Users/boris/github.com/broker-fabric").id)
        check("case is ignored", ProjectColor.automatic(forKey: "/a/MarkView").id, ProjectColor.automatic(forKey: "/b/markview").id)
        check("known name, known color", ProjectColor.automatic(forKey: "/Users/boris/github.com/MarkView").id,
              ProjectColor.palette[Int(fnv("markview") % 8)].id)
        // Pinned: changing the hash or the palette order would recolor every project without a choice.
        check("pinned color 1", ProjectColor.automatic(forKey: "/Users/boris/github.com/MarkView").id, "orange")
        check("pinned color 2", ProjectColor.automatic(forKey: "/Users/boris/github.com/broker-fabric").id, "yellow")
        let spread = Set((0..<200).map { ProjectColor.automatic(forKey: "/projects/p\($0)").id })
        check("uses the whole palette", String(spread.count), "8")
        func fnv(_ s: String) -> UInt64 {
            var h: UInt64 = 14695981039346656037
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            return h
        }

        // Store: only chosen colors persist; one shared value for every window.
        let suite = "ProjectColorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        MainActor.assumeIsolated {
            // Colors saved before DEC-014 (automatic and chosen alike) are dropped once.
            defaults.set([key: "teal"], forKey: Setting.projectColors.name)
            let migrated = ProjectColorStore(defaults: defaults)
            check("old saved colors are dropped", String(migrated.assignments.isEmpty), "true")
            check("migration runs once", String(Settings(defaults).value(Setting.projectColorsByName)), "true")

            let store = ProjectColorStore(defaults: defaults)
            check("reading does not persist", String(store.assignments.isEmpty), "true")
            check("no choice shows the automatic color", store.color(forKey: key).id, ProjectColor.automatic(forKey: key).id)
            let chosen = ProjectColor.palette.first { $0 != store.color(forKey: key) }!
            store.set(chosen, forKey: key)
            check("a choice is saved", store.assignments[key] ?? "", chosen.id)
            check("a choice stays with its folder", store.color(forKey: ProjectColor.projectKey(for: other)).id,
                  ProjectColor.automatic(forKey: key).id)
            let relaunched = ProjectColorStore(defaults: defaults)
            check("choice survives a relaunch", relaunched.color(forKey: key).id, chosen.id)
            relaunched.set(ProjectColor.automatic(forKey: key), forKey: key)
            check("choosing the automatic color clears the choice", String(relaunched.assignments[key] == nil), "true")
            defaults.set([key: "no-such-color"], forKey: Setting.projectColors.name)
            let damaged = ProjectColorStore(defaults: defaults)
            check("unknown stored id falls back to automatic", damaged.color(forKey: key).id, ProjectColor.automatic(forKey: key).id)
        }
    }
}

extension EditorHostTests {
    @MainActor func testAllFilesAndExplainRouting() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func file(_ name: String) -> URL { root.appendingPathComponent(name) }
        func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: file(name)) }
        for name in [".env", ".env.local", ".custom", "settings.mystery", "NO_EXTENSION", "notes.txt", ".gitignore"] {
            try write(name, "SERVICE_PORT=8080\n")
            check(FileType.isOpenable(file(name)), "\(name) can open")
            check(FileType.from(url: file(name)) == .code, "\(name) uses text/code instead of Markdown")
        }
        check(FileType.codeLanguage(for: file(".env.local")) == "properties", "environment variants have known highlighting")
        check(FileType.codeLanguage(for: file(".custom")) == nil, "unknown dotfiles have no guessed highlighting")
        check(FileType.sourceLanguage(for: file("settings.mystery")) == "", "unknown extensions stay plain text")
        check(FileType.sourceLanguage(for: file("NO_EXTENSION")) == "", "unknown extensionless names stay plain text")
        check(FileType.sourceLanguage(for: file("main.swift")) == "swift", "known source retains highlighting")
        for (name, language) in [("config.yaml", "yaml"), ("config.json", "json"), ("config.xml", "xml"), ("README.md", "markdown"), ("board.canvas", "json")] {
            check(FileType.sourceLanguage(for: file(name)) == language, "\(name) has highlighted Explain source")
            check(FileType.from(url: file(name)) != .code, "\(name) retains its dedicated viewer")
        }
        try fm.createDirectory(at: file(".private"), withIntermediateDirectories: true)
        try fm.createDirectory(at: file(".git"), withIntermediateDirectories: true)
        try write(".private/hidden.unknown", "hidden text")
        try fm.createSymbolicLink(at: file("linked.unknown"), withDestinationURL: file("notes.txt"))
        // FileNode belongs to the main actor (the tree the views observe); the checks run there, as the window's own code does.
        @MainActor func checkTree(of root: URL) {
            let node = FileNode.buildTree(from: root)
            let names = Set((node.children ?? []).map(\.name))
            check(names.contains(".env") && names.contains(".env.local") && names.contains("settings.mystery"), "tree includes hidden and unknown files")
            check(names.contains(".private") && names.contains(".git") && names.contains("linked.unknown"), "tree includes hidden folders and file symlinks")
            let hidden = node.children!.first { $0.name == ".private" }!
            hidden.loadChildren()
            check(hidden.children?.first?.name == "hidden.unknown", "hidden folders can be browsed")
        }
        MainActor.assumeIsolated { checkTree(of: root) }
        check(try FileType.readText(at: file("linked.unknown")) == "SERVICE_PORT=8080\n", "file symlinks decode their target")
        for encoding in [String.Encoding.utf8, .utf16, .utf32] {
            try "port: 8080\r\nname: café 🌱\n".data(using: encoding)!.write(to: file("unicode"))
            check(try FileType.readText(at: file("unicode")) == "port: 8080\r\nname: café 🌱\n", "Unicode \(encoding.rawValue) decoded without changing lines")
        }
        try Data([0xEF, 0xBB, 0xBF] + Array("plain".utf8)).write(to: file("bom"))
        check(try FileType.readText(at: file("bom")) == "plain", "UTF-8 BOM is removed")
        try Data([0, 1, 2, 0xFF]).write(to: file("binary.unknown"))
        check(FileType.isOpenable(file("binary.unknown")), "binary files remain visible")
        do { _ = try FileType.readText(at: file("binary.unknown")); check(false, "binary bytes rejected") }
        catch FileType.TextReadError.binary { print("ok   binary bytes rejected") }
        try Data().write(to: file("empty"))
        check(try FileType.readText(at: file("empty")) == "", "empty files open as text")
        let large = file("large")
        fm.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 33 * 1024 * 1024)
        try handle.close()
        do { _ = try FileType.readText(at: large); check(false, "oversized generic text is bounded") }
        catch FileType.TextReadError.tooLarge { print("ok   oversized generic text is bounded") }
        for name in ["config.yaml", "config.json", "config.xml", ".env.local", "settings.toml"] {
            let prompt = FileExplanationPrompt.instructions(path: name)
            check(prompt.contains("what it is responsible for") && prompt.contains("effect of changing") && prompt.contains("without repeating their values"), "\(name) explains configuration responsibilities without echoing secrets")
        }
        check(FileExplanationPrompt.instructions(path: "unusual.xyz").contains("actual contents"), "unknown text explanation follows contents")
        check(FileExplanationPrompt.instructions(path: "README.md").contains("documentation file"), "Markdown keeps document explanation")
        check(FileExplanationPrompt.instructions(path: "main.swift").contains("source code"), "source keeps code explanation")
        check(FileType.hasTextSource(file("data.csv")) && FileType.hasTextSource(file("app.log")), "text data has Explain source")
        check(!FileType.hasTextSource(file("data.parquet")) && !FileType.hasTextSource(file("book.xlsx")), "binary data is never sent as text")
    }
}

extension EditorHostTests {
    func testGitHubActivityWindowAndPrompts() {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func date(_ value: String) -> Date { formatter.date(from: value)! }

        func weekdays(_ count: Int, end: String, start: String, _ message: String) {
            let window = GitHubActivityWindow.make(period: .weekdays, count: count, now: date(end), calendar: calendar)
            check(window?.start == date(start) && window?.end == date(end), message)
        }

        weekdays(2, end: "2026-10-26 09:00:00", start: "2026-10-22 09:00:00", "Monday morning reaches Thursday morning")
        weekdays(2, end: "2026-10-27 09:00:00", start: "2026-10-23 09:00:00", "Tuesday morning reaches Friday morning")
        weekdays(2, end: "2026-10-30 16:23:45", start: "2026-10-28 16:23:45", "ordinary weekdays preserve time to the second")
        weekdays(2, end: "2026-10-26 00:00:00", start: "2026-10-22 00:00:00", "midnight skips the entire weekend")
        weekdays(2, end: "2026-10-31 12:00:00", start: "2026-10-29 00:00:00", "Saturday consumes no weekday hours")
        weekdays(2, end: "2026-11-01 12:00:00", start: "2026-10-29 00:00:00", "Sunday consumes no weekday hours")
        weekdays(2, end: "2026-11-02 09:00:00", start: "2026-10-29 09:00:00", "fall DST weekend preserves local weekday bounds")
        weekdays(2, end: "2026-03-09 09:00:00", start: "2026-03-05 09:00:00", "spring DST weekend preserves local weekday bounds")
        weekdays(1, end: "2026-10-26 09:00:00", start: "2026-10-23 09:00:00", "one weekday is configurable")
        weekdays(5, end: "2026-10-26 09:00:00", start: "2026-10-19 09:00:00", "five weekdays span a calendar week")
        weekdays(2, end: "2026-12-28 09:00:00", start: "2026-12-24 09:00:00", "holidays count as weekdays")

        let now = date("2026-10-26 09:00:00")
        let elapsed = GitHubActivityWindow.make(period: .hours, count: 48, now: now, calendar: calendar)!
        check(elapsed.start == date("2026-10-24 09:00:00"), "calendar hours do not skip weekends")
        let custom = GitHubActivityWindow.make(period: .custom, customStart: date("2026-10-01 12:00:00"),
                                               customEnd: date("2026-10-25 18:30:00"), now: now)!
        check(custom.end == date("2026-10-25 18:30:00"), "custom historical end is preserved")
        check(GitHubActivityWindow.make(period: .custom, customStart: now, customEnd: now, now: now) == nil,
              "empty custom range is rejected")
        check(GitHubActivityWindow.make(period: .custom, customStart: now, customEnd: elapsed.start, now: now) == nil,
              "reversed custom range is rejected")
        check(GitHubActivityWindow.make(period: .custom, customStart: elapsed.start,
                                        customEnd: now.addingTimeInterval(60), now: now) == nil, "future end is rejected")
        for period in [GitHubActivityPeriod.weekdays, .hours] {
            check(GitHubActivityWindow.make(period: period, count: 0) == nil, "zero \(period) is rejected")
            check(GitHubActivityWindow.make(period: period, count: Int.max) == nil, "unbounded \(period) is rejected")
        }

        // Use a volatile defaults domain so checks never persist or alter app settings.
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        UserDefaults.standard.setVolatileDomain([Setting.outputLanguage.name: "Russian"], forName: UserDefaults.argumentDomain)
        let prompt = TerminalPrompt.all.first { $0.id == "github-activity" }!
        let rendered = prompt.text(file: nil, pullRequest: nil, activityWindow: custom)
        check(prompt.input == .githubActivity, "button asks for its activity period")
        check(rendered.contains("2026-10-01T17:00:00.000Z") && rendered.contains("2026-10-25T23:30:00.000Z"),
              "prompt contains exact UTC bounds, including the custom end")
        check(!rendered.contains("{window}"), "no unresolved window placeholder")
        check(rendered.contains("updated AFTER the window") && rendered.contains("complete\npagination"),
              "historical scans retain candidates updated later and require pagination")
        check(rendered.contains("including weekend activity"), "weekend events remain inside the scan")
        check(rendered.contains("ALL existing local features and bugs"), "matching covers older local records")
        check(rendered.contains("not application implementation or GitHub\nmutations"), "scope is local reconciliation")
        check(rendered.contains("Write the final report in Russian."), "selected report language is used")
        UserDefaults.standard.setVolatileDomain([Setting.outputLanguage.name: ActionOutputLanguage.documentLanguage], forName: UserDefaults.argumentDomain)
        check(prompt.text(file: nil, pullRequest: nil, activityWindow: custom).contains("Write the final report in Russian."),
              "report defaults to Russian without changing repository language rules")
        UserDefaults.standard.setVolatileDomain([Setting.outputLanguage.name: "English"], forName: UserDefaults.argumentDomain)
        check(prompt.text(file: nil, pullRequest: nil, activityWindow: custom).contains("Write the final report in English."),
              "explicit output language overrides the report default")
        UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)

        let review = TerminalPrompt.all.first { $0.id == "review-pr" }!
        check(review.text(file: nil, pullRequest: "#123").contains("Review #123"), "existing PR substitution still works")
        check(TerminalPrompt.all.first { $0.id == "explain-file" }!.text(file: "src/demo.swift", pullRequest: nil)
                .contains("Explain src/demo.swift"), "existing file substitution still works")
    }
}

private struct StorageSecuritySample: Codable, Equatable {
    var recentPaths: [String]
    var maxItems: Int
}

extension EditorHostTests {
    @MainActor func testVersionedStorageAndSecurityConfiguration() {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mv-phase6-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. AR-36, AR-39 & FU-04: SchemaVersionedStore, non-clobbering corrupt backups, and downgrade refusal
        let store = SchemaVersionedStore<StorageSecuritySample>(currentSchemaVersion: 2)
        let fileURL = tempDir.appendingPathComponent("prefs.json")

        let missingResult = store.load(from: fileURL)
        if case .missing = missingResult {
            check(true, "AR-36: StoreLoadResult returns .missing when file does not exist")
        } else {
            check(false, "AR-36: StoreLoadResult returns .missing when file does not exist")
        }

        // Legacy unversioned JSON upgrades transparently with schemaVersion == 0
        let legacyData = try! JSONEncoder().encode(StorageSecuritySample(recentPaths: ["/tmp/a"], maxItems: 10))
        try! legacyData.write(to: fileURL)
        let legacyResult = store.load(from: fileURL)
        if case .loaded(let val, let version) = legacyResult {
            check(val == StorageSecuritySample(recentPaths: ["/tmp/a"], maxItems: 10) && version == 0,
                  "AR-36: SchemaVersionedStore transparently loads legacy unversioned JSON as schemaVersion 0")
        } else {
            check(false, "AR-36: SchemaVersionedStore transparently loads legacy unversioned JSON")
        }

        // Corrupted file detection & multiple non-clobbering .corrupt-<timestamp>-<suffix> backups
        let updatedRecord = StorageSecuritySample(recentPaths: ["/tmp/a", "/tmp/b"], maxItems: 25)
        try! Data("{broken json 1".utf8).write(to: fileURL)
        let corruptResult = store.load(from: fileURL)
        check(corruptResult.isCorrupted, "AR-36: StoreLoadResult distinguishes .corrupted from .missing")
        try! store.save(updatedRecord, to: fileURL, permissions: 0o600)

        try! Data("{broken json 2".utf8).write(to: fileURL)
        try! store.save(updatedRecord, to: fileURL, permissions: 0o600)
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? [])
            .filter { $0.hasPrefix("prefs.json.corrupt-") }
        check(backups.count == 2,
              "FU-04: SchemaVersionedStore preserves non-clobbering timestamped .corrupt backups across repeated failures")

        let perms = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        check(perms == 0o600, "AR-39/FU-04: SchemaVersionedStore writes private files atomically with 0o600 permissions")

        let savedResult = store.load(from: fileURL)
        if case .loaded(let val, let version) = savedResult {
            check(val == updatedRecord && version == 2, "AR-36: SchemaVersionedStore writes and reloads schemaVersion 2 envelope atomically")
        } else {
            check(false, "AR-36: SchemaVersionedStore writes and reloads schemaVersion 2 envelope")
        }

        // Newer-schema downgrade protection (`FU-04`)
        let futureURL = tempDir.appendingPathComponent("future-prefs.json")
        let futurePayload = Data(#"{"schema":99,"updatedAt":"2026-11-15T00:00:00Z","data":{"recentPaths":[],"maxItems":1}}"#.utf8)
        try! futurePayload.write(to: futureURL)
        let newerLoad = store.load(from: futureURL)
        check(newerLoad.isNewerSchema, "FU-04: SchemaVersionedStore returns .newerSchema when on-disk schema exceeds currentSchemaVersion")
        var threwNewer = false
        do {
            try store.save(updatedRecord, to: futureURL)
        } catch let err as SchemaStoreError {
            if case .newerSchemaVersion(_, let found, let supported) = err, found == 99, supported == 2 {
                threwNewer = true
            }
        } catch {}
        let preservedFutureData = try? Data(contentsOf: futureURL)
        check(threwNewer && preservedFutureData == futurePayload,
              "FU-04: SchemaVersionedStore.save throws SchemaStoreError.newerSchemaVersion and leaves newer file untouched")

        struct LegacyRecordWithVersionField: Codable, Equatable {
            var recentPaths: [String]
            var maxItems: Int
            var version: Int
        }
        let legacyVersionFieldURL = tempDir.appendingPathComponent("legacy-version-field.json")
        let legacyVersionFieldData = try! JSONEncoder().encode(
            LegacyRecordWithVersionField(recentPaths: ["/tmp/legacy"], maxItems: 5, version: 99)
        )
        try! legacyVersionFieldData.write(to: legacyVersionFieldURL)
        let legacyVersionLoad = store.load(from: legacyVersionFieldURL)
        if case .loaded(let val, let schemaVer) = legacyVersionLoad {
            check(val == StorageSecuritySample(recentPaths: ["/tmp/legacy"], maxItems: 5) && schemaVer == 0,
                  "FU-04/FU-14: SchemaVersionedStore ignores legacy payload version field instead of mistaking it for envelope schema")
        } else {
            check(false, "FU-04/FU-14: SchemaVersionedStore loads legacy payload with version field as schemaVersion 0")
        }

        // The contract every store of AR-36/AR-39 relies on, beyond the legacy upgrade above.
        // An envelope whose payload cannot be read is damage, never an empty legacy payload: a payload of optional fields would
        // otherwise load as empty and the next save would replace the real content.
        struct AllOptional: Codable, Equatable { var a: String?; var b: Int? }
        let optionalStore = SchemaVersionedStore<AllOptional>()
        let wrongEnvelope = tempDir.appendingPathComponent("wrong-envelope.json")
        let wrongBytes = Data(#"{"schema":1,"updatedAt":"2026-11-15T00:00:00Z","data":{"a":["not","a","string"]}}"#.utf8)
        try! wrongBytes.write(to: wrongEnvelope)
        check(optionalStore.load(from: wrongEnvelope).isCorrupted, "AR-36: an envelope with an unreadable payload is corrupted, not an empty legacy payload")
        // A legacy document that is not an envelope still loads when every field is optional.
        let bareOptional = tempDir.appendingPathComponent("bare-optional.json")
        try! Data(#"{"a":"x"}"#.utf8).write(to: bareOptional)
        check(optionalStore.load(from: bareOptional).value == AllOptional(a: "x", b: nil), "AR-36: a bare payload of optional fields loads as schema 0")

        // Dates: a store whose old files used the default numeric dates reads them, and the same store reads ISO 8601 ones.
        struct Stamped: Codable, Equatable { var at: Date }
        let numeric = SchemaVersionedStore<Stamped>(dates: .referenceDate)
        let numericURL = tempDir.appendingPathComponent("numeric.json")
        try! JSONEncoder().encode(Stamped(at: Date(timeIntervalSinceReferenceDate: 800_000_000))).write(to: numericURL)
        check(numeric.load(from: numericURL).value == Stamped(at: Date(timeIntervalSinceReferenceDate: 800_000_000)), "AR-36: a legacy file with numeric dates loads")
        try! numeric.save(Stamped(at: Date(timeIntervalSinceReferenceDate: 800_000_000)), to: numericURL)
        check(numeric.load(from: numericURL).value == Stamped(at: Date(timeIntervalSinceReferenceDate: 800_000_000)) && StoreFixture.envelope(numericURL)?.schema == 1,
              "AR-36: the envelope keeps numeric dates exact")
        let isoURL = tempDir.appendingPathComponent("iso.json")
        try! Data(#"{"at":"2026-11-01T10:00:00Z"}"#.utf8).write(to: isoURL)
        check(numeric.load(from: isoURL).value != nil, "AR-36: a legacy file with ISO 8601 dates loads in a numeric-dates store")

        // recentFiles.json: the previous version wrote a bare JSON array of paths.
        let recents = SchemaVersionedStore<[String]>()
        let recentsURL = tempDir.appendingPathComponent("recentFiles.json")
        try! Data(#"["/Users/me/a.md","/Users/me/b.md"]"#.utf8).write(to: recentsURL)
        check(recents.load(from: recentsURL).value == ["/Users/me/a.md", "/Users/me/b.md"], "AR-36: a legacy recent-files array loads intact")
        try! recents.save(["/Users/me/c.md", "/Users/me/a.md"], to: recentsURL)
        check(StoreFixture.envelope(recentsURL)?.schema == 1 && recents.load(from: recentsURL).value == ["/Users/me/c.md", "/Users/me/a.md"],
              "AR-36: the recent-files list is written in the envelope and reloads")

        // A file is written with the mode it already had; a new file is not made private unless the caller asks.
        let modeURL = tempDir.appendingPathComponent("mode.json")
        try! optionalStore.save(AllOptional(a: "1", b: nil), to: modeURL)
        check(((try? FileManager.default.attributesOfItem(atPath: modeURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) == 0o644, "AR-39: a new store file gets the ordinary mode")
        try! FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: modeURL.path)
        try! optionalStore.save(AllOptional(a: "2", b: nil), to: modeURL)
        check(((try? FileManager.default.attributesOfItem(atPath: modeURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) == 0o640, "AR-39: a save keeps the mode the file already had")

        // 2. AR-40: the control socket token, its file, the peer check and the shared server protection are checked over real
        //    sockets by the MarkViewCore PrivateSocketTests (and, per server, remote-browser-, remote-workspace- and cockpit-host-bridge-tests).
        let ancestors = BrowserAgentTools.ancestorPIDs(startingAt: getpid())
        check(ancestors.first == getpid(), "AR-40: ancestorPIDs(startingAt:) starts from kernel-verified peer PID")

        // 3. AR-41: Info.plist App Transport Security configuration parsed structurally
        if let plistData = try? Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MarkView/Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
            let principal = plist["NSPrincipalClass"] as? String
            let ats = plist["NSAppTransportSecurity"] as? [String: Any]
            let arbitrary = ats?["NSAllowsArbitraryLoads"] as? Bool
            let webContent = ats?["NSAllowsArbitraryLoadsInWebContent"] as? Bool
            let localNet = ats?["NSAllowsLocalNetworking"] as? Bool
            check(principal == "NSApplication" && arbitrary == false && webContent == true && localNet == true,
                  "AR-41: Info.plist PropertyList enforces NSAllowsArbitraryLoads=false while allowing web content and local networking")
        } else {
            check(false, "AR-41: MarkView/Info.plist parses cleanly as a PropertyList dictionary")
        }
    }
}

extension EditorHostTests {
    func testDeploymentExecutorLocalProcessesAndSSHValidation() async throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let local = LocalExecutor(directory: nil)
        let hello = await local.run("echo hello; echo oops 1>&2", stdin: nil, timeout: 10)
        check(hello.succeeded && hello.stdout == "hello\n" && hello.stderr == "oops\n", "stdout and stderr are kept apart")
        let failing = await local.run("exit 3", stdin: nil, timeout: 10)
        check(failing.status == 3 && !failing.succeeded, "the exit status is kept")
        let cat = await local.run("cat", stdin: "from stdin\n", timeout: 10)
        check(cat.stdout == "from stdin\n", "stdin reaches the command")
        let started = Date()
        let slow = await local.run("sleep 20", stdin: nil, timeout: 1)
        check(slow.timedOut && Date().timeIntervalSince(started) < 8, "a slow command is stopped at the timeout (\(Date().timeIntervalSince(started)) s)")
        let big = await local.run("head -c 3000000 /dev/zero | tr '\\0' 'a'", stdin: nil, timeout: 20)
        check(big.truncated && big.stdout.utf8.count == CommandResult.outputCap, "output is cut at the cap")
        let both = await local.run("yes x | head -n 300000 1>&2; echo done", stdin: nil, timeout: 20)
        check(both.stdout == "done\n", "a noisy stderr cannot stall the command")
        let path = await local.run("command -v ls", stdin: nil, timeout: 10)
        check(path.succeeded, "the PATH of a shell is set")

        // The ssh command line.
        var env = DeploymentEnvironment(id: "prod", name: "Prod", kind: .ssh, host: "web-1.example.com", user: "deploy", port: 2222)
        let args = SSHExecutor.arguments(for: env) ?? []
        check(args.contains("BatchMode=yes") && args.contains("2222") && args.last == "deploy@web-1.example.com", "ssh: batch mode, port, destination last: \(args)")
        check(!args.contains("-i"), "ssh: no key option without a key file")
        env.identityFile = "~/.ssh/prod"
        let withKey = SSHExecutor.arguments(for: env) ?? []
        check(withKey.contains("-i") && withKey.contains(NSHomeDirectory() + "/.ssh/prod") && withKey.contains("IdentitiesOnly=yes"), "ssh: the key file is expanded and the only one used")
        env.host = "-oProxyCommand=touch /tmp/pwned"
        check(SSHExecutor.arguments(for: env) == nil, "ssh: a host that looks like an option is refused")
        let refused = await SSHExecutor(environment: env).run("uptime", stdin: nil, timeout: 5)
        check(refused.status == 255 && refused.stderr.contains("not valid"), "and nothing runs")

        // What ssh said.
        func result(_ text: String, status: Int32 = 255) -> CommandResult { CommandResult(status: status, stdout: "", stderr: text) }
        check(ConnectionProblem.from(result("Host key verification failed.")) == .hostKeyUnknown, "unknown host key")
        check(ConnectionProblem.from(result("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@")) == .hostKeyChanged, "changed host key")
        check(ConnectionProblem.from(result("deploy@h: Permission denied (publickey).")) == .authFailed, "refused key")
        if case .unreachable(let line)? = ConnectionProblem.from(result("ssh: connect to host h port 22: Connection refused")) { check(line.contains("refused"), "refused connection") } else { check(false, "refused connection") }
        check(ConnectionProblem.from(CommandResult(status: -1, stdout: "", stderr: "", timedOut: true)) == .timedOut, "timeout")
        check(ConnectionProblem.from(CommandResult(status: 1, stdout: "", stderr: "grep: no match")) == nil, "a failing remote command is not a connection problem")
        check(ConnectionProblem.from(CommandResult(status: 0, stdout: "x", stderr: "")) == nil, "success is not a problem")
        check(ConnectionProblem.hostKeyChanged.message.contains("will not continue"), "a changed key is never trusted")
        check(await HostKeys.scan(host: "-oProxyCommand=x", port: 22) == nil, "host key scan refuses an unsafe host")

        // The person's own Node comes first on the PATH (nvm default alias).
        let fakeHome = NSTemporaryDirectory() + "mv-home-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: fakeHome) }
        for version in ["v20.20.2", "v22.22.3", "v22.9.0", "v24.21.0"] {
            try FileManager.default.createDirectory(atPath: fakeHome + "/.nvm/versions/node/\(version)/bin", withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(atPath: fakeHome + "/.nvm/alias", withIntermediateDirectories: true)
        func nvmDefault(_ text: String) throws { try text.write(toFile: fakeHome + "/.nvm/alias/default", atomically: true, encoding: .utf8) }
        try nvmDefault("22\n")
        check(LocalExecutor.nodeBinDirectories(home: fakeHome) == [fakeHome + "/.nvm/versions/node/v22.22.3/bin"], "nvm default 22 is the newest installed 22.x (not 22.9.0)")
        try nvmDefault("v20.20.2")
        check(LocalExecutor.nodeBinDirectories(home: fakeHome) == [fakeHome + "/.nvm/versions/node/v20.20.2/bin"], "an exact nvm default")
        try nvmDefault("lts/*")
        check(LocalExecutor.nodeBinDirectories(home: fakeHome) == [fakeHome + "/.nvm/versions/node/v24.21.0/bin"], "a named alias falls back to the newest installed")
        try nvmDefault("26")
        check(LocalExecutor.nodeBinDirectories(home: fakeHome).isEmpty, "a version that is not installed adds nothing")
        try nvmDefault("22")
        let searchPath = LocalExecutor.searchPath(home: fakeHome).split(separator: ":").map(String.init)
        check(searchPath.first == fakeHome + "/.nvm/versions/node/v22.22.3/bin" && searchPath.firstIndex(of: "/opt/homebrew/bin")! > 0, "the nvm Node precedes Homebrew's")
        check(LocalExecutor.nodeBinDirectories(home: fakeHome + "/nowhere").isEmpty, "no nvm, no change")
    }
}
