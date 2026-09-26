// Checks DictationInsertion (MarkView/Views/DictationViews.swift) against a real NSTextView:
// transcript at the cursor, selection replaced, spacing, undo, append when the field is not focused.
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
let tv = NSTextView(frame: window.contentView!.bounds); tv.allowsUndo = true
window.contentView!.addSubview(tv)
var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want { print("ok  \(name)") } else { failures += 1; print("FAIL \(name): got \(got.debugDescription) want \(want.debugDescription)") }
}
DispatchQueue.main.async {
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        window.makeFirstResponder(tv)
        var unused = ""
        // cursor in the middle of a word boundary
        tv.string = "Hello world."
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        DictationInsertion.insert("big", fieldFocused: true, text: &unused)
        check("middle", tv.string, "Hello big world.")
        // cursor before punctuation
        tv.string = "Hello world."
        tv.setSelectedRange(NSRange(location: 11, length: 0))
        DictationInsertion.insert("again", fieldFocused: true, text: &unused)
        check("before period", tv.string, "Hello world again.")
        // selection replaced, rest intact
        tv.string = "one two three"
        tv.setSelectedRange(NSRange(location: 4, length: 3))
        DictationInsertion.insert("два", fieldFocused: true, text: &unused)
        check("selection", tv.string, "one два three")
        // start of empty field
        tv.string = ""
        DictationInsertion.insert("Привет", fieldFocused: true, text: &unused)
        check("empty focused", tv.string, "Привет")
        check("binding untouched when focused", unused, "")
        // undoable
        check("undo registered", String(tv.undoManager?.canUndo ?? false), "true")
        // not focused -> append
        var text = "Existing text"
        DictationInsertion.insert("more", fieldFocused: false, text: &text)
        check("append", text, "Existing text more")
        var text2 = "Line\n"
        DictationInsertion.insert("next", fieldFocused: false, text: &text2)
        check("append after newline", text2, "Line\nnext")
        print(NSApp.keyWindow === window ? "keyWindow ok" : "WARNING: window not key")
        exit(failures == 0 ? 0 : 1)
    }
}
app.run()
