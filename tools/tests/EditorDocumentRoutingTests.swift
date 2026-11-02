import Foundation

// Standalone checks for MarkView/Models/EditorDocumentRouting.swift (BUG-031).
// Run through tools/tests/editor-document-routing-tests.sh.

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

let sirius = UUID(), myDataCenter = UUID(), daily = UUID()
let tabs = [sirius, myDataCenter, daily]

// The reported case: the page still holds the MyDataCenter document while the Sirius Art tab is selected.
check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: tabs, activeIndex: 0) == 1,
      "a message naming a document goes to that document's tab, not to the selected one")
check(EditorDocumentRouting.targetIndex(documentID: sirius, tabIDs: tabs, activeIndex: 2) == 0,
      "naming the first tab while the last is selected still reaches the first tab")

// Reordering tabs changes indexes, never ids.
let reordered = [daily, sirius, myDataCenter]
check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: reordered, activeIndex: 1) == 2,
      "a reordered tab list is followed by id")

// A closed tab must not hand its text to another tab.
check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: [sirius, daily], activeIndex: 0) == nil,
      "a message for a closed tab is dropped instead of falling back to the selected tab")

// Messages that name no document keep the earlier behaviour.
check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: tabs, activeIndex: 1) == 1,
      "an unnamed message applies to the selected tab")
check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: tabs, activeIndex: -1) == nil,
      "no selected tab: nothing to apply to")
check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: tabs, activeIndex: 3) == nil,
      "selected index past the end: nothing to apply to")
check(EditorDocumentRouting.targetIndex(documentID: nil, tabIDs: [], activeIndex: 0) == nil,
      "no tabs: nothing to apply to")
check(EditorDocumentRouting.targetIndex(documentID: myDataCenter, tabIDs: [], activeIndex: 0) == nil,
      "no tabs: a named message is dropped")

// BUG-043: text of a document the page was just switched away from must not pass for the shown document's text.
check(EditorDocumentRouting.reportsShownDocument(documentID: myDataCenter, shown: myDataCenter),
      "text of the document on screen is remembered by the reload check")
check(!EditorDocumentRouting.reportsShownDocument(documentID: sirius, shown: myDataCenter),
      "unsaved text of the document left behind is not remembered as the one on screen")
check(!EditorDocumentRouting.reportsShownDocument(documentID: sirius, shown: nil),
      "a named message while no tab's document is shown is not remembered")
check(EditorDocumentRouting.reportsShownDocument(documentID: nil, shown: myDataCenter),
      "an unnamed message is remembered, as before")
check(EditorDocumentRouting.reportsShownDocument(documentID: nil, shown: nil),
      "an unnamed message with nothing shown is remembered, as before")

// What the page sends.
check(EditorDocumentRouting.documentID(from: sirius.uuidString) == sirius, "a valid id is parsed")
check(EditorDocumentRouting.documentID(from: sirius.uuidString.lowercased()) == sirius, "a lowercase id is parsed")
check(EditorDocumentRouting.documentID(from: "") == nil, "an empty id means not named")
check(EditorDocumentRouting.documentID(from: "not-a-uuid") == nil, "a malformed id means not named")
check(EditorDocumentRouting.documentID(from: nil) == nil, "a missing id means not named")
check(EditorDocumentRouting.documentID(from: 42) == nil, "a non-string id means not named")

if failures == 0 {
    print("editor document routing: all checks passed")
} else {
    print("editor document routing: \(failures) check(s) failed")
    exit(1)
}
