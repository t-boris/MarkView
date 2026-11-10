import Foundation
import SwiftUI
import AppKit
import WebKit

// Checks the rules that keep one window's interface state away from every other window (BUG-120 and the audit that followed it):
// `WindowUIState` (what `@WindowStorage` reads), the editor page's own choices (`EditorWindowPrefs`) and the excluded folders of a
// project (`ExcludedFolders`).

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print(condition ? "ok   \(message)" : "FAIL \(message)")
    if !condition { failures += 1 }
}
func freshDefaults() -> (UserDefaults, () -> Void) {
    let suite = "window-ui-state-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (defaults, { defaults.removePersistentDomain(forName: suite) })
}

// MARK: Two windows

do {
    let (defaults, cleanup) = freshDefaults()
    defer { cleanup() }
    let a = WindowUIState(defaults: defaults), b = WindowUIState(defaults: defaults)
    check(a.value("search.panelMode", fallback: "Project") == "Project", "a value nobody set is the fallback")
    check(b.value("search.panelMode", fallback: "Project") == "Project", "the second window starts the same")

    a.set("Documents", for: "search.panelMode")
    check(a.value("search.panelMode", fallback: "Project") == "Documents", "the window that changed a value shows it")
    check(b.value("search.panelMode", fallback: "Project") == "Project", "another window that already shows it stays on its own value")

    b.set(false, for: "contents.infoExpanded")
    check(a.value("contents.infoExpanded", fallback: true), "a flag set in one window leaves the other expanded, even one it shows only now")

    var changes = 0
    let watcher = b.objectWillChange.sink { changes += 1 }
    a.set("Project", for: "search.panelMode")
    check(changes == 0, "a change in one window does not redraw another window")
    b.set(350.0, for: "uiStudioInspectorWidth")
    check(changes == 1, "a change in the window redraws that window")
    b.set(350.0, for: "uiStudioInspectorWidth")
    check(changes == 1, "setting the same value again redraws nothing")
    b.set(360.0, for: "layout.leftPanelWidth", publishing: false)
    check(changes == 1, "a divider position kept by an AppKit view redraws nothing")
    watcher.cancel()

    let later = WindowUIState(defaults: defaults)
    check(later.value("search.panelMode", fallback: "x") == "Project", "a window opened later starts from the last value anywhere")
    check(later.value("layout.leftPanelWidth", fallback: 0.0) == 360.0, "the seed of a quiet value is kept too")
    a.set("Documents", for: "search.panelMode")
    check(later.value("search.panelMode", fallback: "x") == "Project", "and from then on follows nobody")
}

// MARK: The session

do {
    let (defaults, cleanup) = freshDefaults()
    let (emptyDefaults, emptyCleanup) = freshDefaults()
    defer { cleanup(); emptyCleanup() }
    let a = WindowUIState(defaults: defaults)
    a.set("Documents", for: "search.panelMode")
    a.set(412.0, for: "uiStudioInspectorWidth")
    a.set(false, for: "contents.infoExpanded")
    a.set(4, for: "n")
    let data = try! JSONEncoder().encode(a.saved)
    let decoded = try! JSONDecoder().decode([String: WindowUIValue].self, from: data)
    check(decoded == a.saved, "the values survive the session file")

    let restored = WindowUIState(defaults: emptyDefaults)
    restored.restore(decoded)
    check(restored.value("search.panelMode", fallback: "Project") == "Documents" &&
          restored.value("uiStudioInspectorWidth", fallback: 0.0) == 412.0 &&
          !restored.value("contents.infoExpanded", fallback: true) && restored.value("n", fallback: 0) == 4,
          "a restored window has its own values, not the starting ones")

    let old = WindowUIState(defaults: emptyDefaults)
    old.restore(nil)
    check(old.saved.isEmpty && old.value("search.panelMode", fallback: "Project") == "Project", "a session saved before interface state has none")

    let wrongType = WindowUIState(defaults: emptyDefaults)
    wrongType.restore(["n": .string("not a number")])
    check(wrongType.value("n", fallback: 7) == 7, "a restored value of the wrong type falls back")
    check(wrongType.existing("n") as Int? == 7 && wrongType.existing("n") as String? == nil, "the fallback replaces it, and existing() reads only the stored type")

    enum Mode: String, WindowUIStorable { case list, tree }
    let modes = WindowUIState(defaults: emptyDefaults)
    check(modes.value("mode", fallback: Mode.list) == .list, "an enum starts at its fallback")
    modes.set(Mode.tree, for: "mode")
    check(modes.saved["mode"] == .string("tree") && modes.value("mode", fallback: Mode.list) == .tree, "a String enum is stored by its raw value")
    emptyDefaults.set("nonsense", forKey: "other")
    check(WindowUIState(defaults: emptyDefaults).value("other", fallback: Mode.tree) == .tree, "an unknown stored raw value is the fallback")
}

// MARK: The editor page's own choices

do {
    let keys = EditorWindowPrefs.keys
    check(keys.contains("markview-font-size") && keys.contains("markview-xray-details-width") && keys.contains("markview-code-notes-width")
          && keys.contains("markview-xray-details-hidden"), "the text size, the panel widths and the X-Ray details are the window's")
    check(!keys.contains { $0.hasPrefix("mvMap:") }, "a map's view of a document is not the window's")
    check(EditorWindowPrefs.accepts(key: "markview-font-size", value: "13"), "the page may save its text size")
    check(!EditorWindowPrefs.accepts(key: "markview-other", value: "1"), "a key the window does not keep is refused")
    check(!EditorWindowPrefs.accepts(key: "markview-font-size", value: String(repeating: "9", count: 33)), "a long value is refused")
    check(EditorWindowPrefs.stateKey("markview-font-size") == "editor.markview-font-size", "the window files the value under its own name")

    let script = EditorWindowPrefs.script(values: ["markview-font-size": "16", "markview-other": "1", "markview-code-notes-width": "</script>"])
    check(script.contains("\"markview-font-size\":\"16\""), "the window's text size starts the page")
    check(!script.contains("markview-other\":"), "a value for a key the window does not keep is not passed to the page")
    check(!script.contains("</script>"), "nothing in the script can end the script element")
    check(script.contains("type: 'editorWindowPref'"), "the page tells the app when it saves one of the choices")
}

// MARK: Excluded folders belong to the project

do {
    let (defaults, cleanup) = freshDefaults()
    defer { cleanup() }
    let one = URL(fileURLWithPath: "/work/one/app"), two = URL(fileURLWithPath: "/work/two/app")
    check(ExcludedFolders.key(for: one) != ExcludedFolders.key(for: two), "two projects with the same folder name have different keys")
    check(ExcludedFolders.load(for: one, defaults: defaults).isEmpty, "a project with nothing excluded has none")
    ExcludedFolders.save(["build", "node_modules"], for: one, defaults: defaults)
    check(ExcludedFolders.load(for: one, defaults: defaults) == ["build", "node_modules"], "a project's list comes back")
    check(ExcludedFolders.load(for: two, defaults: defaults).isEmpty, "another project of the same folder name does not get it")

    defaults.set(["dist"], forKey: "excludedFolders.legacy")
    let legacy = URL(fileURLWithPath: "/work/legacy")
    check(ExcludedFolders.load(for: legacy, defaults: defaults) == ["dist"], "a list saved under the folder's name is not lost")
    ExcludedFolders.save(["dist", "out"], for: legacy, defaults: defaults)
    check(defaults.stringArray(forKey: "excludedFolders.legacy") == ["dist"], "and the project's own changes do not touch the old entry")
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
    @WindowStorage("search.panelMode") private var mode = "Project"
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
MainActor.assumeIsolated { hostedChecks() }

// MARK: The editor page, in two real web views that share one localStorage

final class PageMessages: NSObject, WKScriptMessageHandler {
    var received: [[String: Any]] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { received.append(body) }
    }
}

@MainActor func pageChecks() {
    _ = NSApplication.shared
    var keep: [WKWebView] = []
    func page(own: [String: String]) -> (WKWebView, PageMessages) {
        let messages = PageMessages()
        let config = WKWebViewConfiguration()
        config.userContentController.add(messages, name: "bridge")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
        web.loadHTMLString("<html><head><script>\(EditorWindowPrefs.script(values: own))</script></head><body>x</body></html>",
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
MainActor.assumeIsolated { pageChecks() }

print(failures == 0 ? "\nAll window-state checks passed." : "\n\(failures) window-state check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
