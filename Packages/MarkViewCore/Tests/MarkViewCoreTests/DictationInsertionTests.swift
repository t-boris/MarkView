import AppKit
import XCTest
@testable import MarkViewCore

@MainActor
final class DictationInsertionTests: XCTestCase {
    func testSelectionAndBinding() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        window.makeFirstResponder(view)
        func check(_ name: String, _ got: String, _ want: String, line: UInt = #line) {
            XCTAssertEqual(got, want, name, line: line)
        }
        func insert(_ original: String, _ range: NSRange, _ transcript: String) -> String {
            view.string = original
            view.setSelectedRange(range)
            var binding = original
            DictationInsertion.insert(transcript, window: window, fieldFocused: true, text: &binding)
            check("binding owns the edit", view.string, original)
            return binding
        }
        check("middle", insert("Hello world.", NSRange(location: 5, length: 0), "big"), "Hello big world.")
        check("before punctuation", insert("Hello world.", NSRange(location: 11, length: 0), "again"), "Hello world again.")
        check("selection", insert("one two three", NSRange(location: 4, length: 3), "два"), "one два three")
        check("empty", insert("", NSRange(location: 0, length: 0), "Привет"), "Привет")
        check("unicode selection", insert("🙂 привет мир", NSRange(location: 3, length: 6), "hello"), "🙂 hello мир")
        var text = "Existing text"
        DictationInsertion.insert("more", window: window, fieldFocused: false, text: &text)
        check("unfocused append", text, "Existing text more")
        var multiline = "Line\n"
        DictationInsertion.insert("next", window: window, fieldFocused: false, text: &multiline)
        check("append after newline", multiline, "Line\nnext")
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let otherView = NSTextView(frame: .zero)
        other.contentView!.addSubview(otherView)
        other.makeFirstResponder(otherView)
        otherView.string = "another window"
        check("own window selection", insert("abc", NSRange(location: 3, length: 0), "def"), "abc def")
        check("other window preserved", otherView.string, "another window")
        view.string = "stale editor"
        var current = "Current binding"
        DictationInsertion.insert("spoken", window: window, fieldFocused: true, text: &current)
        check("stale selection appends safely", current, "Current binding spoken")
        var noWindow = "Field"
        DictationInsertion.insert("spoken", window: nil, fieldFocused: true, text: &noWindow)
        check("missing window appends", noWindow, "Field spoken")
    }
}
