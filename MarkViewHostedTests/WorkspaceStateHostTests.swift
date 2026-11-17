import AppKit
import Combine
import MarkViewCore
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
