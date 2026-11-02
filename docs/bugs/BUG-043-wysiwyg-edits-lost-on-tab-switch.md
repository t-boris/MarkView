---
type: bug
id: BUG-043
title: Switching tabs discards text typed in the WYSIWYG view
status: fixed
branch: fix/bug-043-wysiwyg-edits-lost-on-tab-switch
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-02
---

# Switching tabs discards text typed in the WYSIWYG view

## Summary

Text typed in the WYSIWYG view of a Markdown tab stays in the editor page only. The tab (`content`, `isModified`) learns
about it when the user presses Cmd+S in the page or switches the page to Source. If the user selects another tab first, the
page loads the other document over the typed text and nothing remembers it: the tab shows no modified mark, closing it does
not ask about saving, and coming back shows the old text. Found while fixing BUG-031.

## Cause

`window.setContent` (`markview-bridge.js`) replaces the page's document and resets `wysiwygDirty`. The editor deliberately
does not convert WYSIWYG edits to Markdown while the user types (`markview-edit.js`: the conversion rewrites formatting), so
until a save or a mode switch the only copy of the edits is the page's DOM. Nothing converted them when the app replaced the
document.

## Resolution

When the page is about to show a different document, it first hands its unsaved edits to the app as the text of the document
they were typed in.

- `window.mvSetDocument(id)` (`markview-edit.js`) replaces setting `window.mvDocumentId` directly. If the id changes and edits
  are pending (`wysiwygDirty`, Markdown file), it converts them (WYSIWYG view only; the Source view's text is already the
  truth) and sends `contentChanged` while the old id is still set. BUG-031's routing then applies the text to the old tab,
  which becomes modified, is kept in the window's draft, and asks about saving when closed.
- `WebViewBridge.documentIDScript` calls `mvSetDocument` in the same script as every document load (and when an insight or the
  X-Ray replaces the document), so the hand-over precedes the new id and the new text. A page without the function just takes
  the id.
- The same document loading again (a refresh from disk) does not hand anything over: it keeps replacing the edits.
- `saveFile` clears `wysiwygDirty` after it has sent the text, so a save followed by a tab switch does not send it twice.
- `EditorView` remembered every reported text as "what the page holds" for its reload check. The hand-over arrives after the next
  document was loaded and would have made the selected tab reload a second time; `EditorDocumentRouting.reportsShownDocument`
  keeps the reload check to the shown document's text.

## Not changed

Edits stay in the page, and are still lost, in these cases. They need a decision: either the page keeps the tab in step while the
user types (the conversion then runs often, and rewrites formatting in the tab's text) or the app asks the page before it acts.

- Closing the tab that holds pending WYSIWYG edits: the tab is gone before the hand-over arrives, so no "Save changes?" appears.
- Quitting the app with pending edits: the window's saved drafts are made from the tabs' text, which does not have them.
- The Save menu item and the command palette save the tab's own text (`saveActiveFile`); with pending WYSIWYG edits that text
  is the one from before they were typed. Cmd+S inside the page is not affected.

## Verification

- `bash tools/tests/editor-document-routing-tests.sh`:
  - `reportsShownDocument` rule (unit checks).
  - The shipped editor page in headless WebKit: after typing in the WYSIWYG view, loading another document first sends the typed
    text under the old tab's id and then the new document's text under the new id; with nothing typed nothing is sent for the old
    document; reloading the same document sends no edits; edits already synced into the Source view are handed over; a second
    switch sends nothing again. With the hand-over removed from `mvSetDocument` the two hand-over checks fail (2 failures).
- Debug build with `xcodebuild` (see CLAUDE.md) passes.
- Not exercised by a run: the real app's tab bar (type in one tab, select another, come back). The Swift side
  (`documentIDScript`, `didUpdateContent`) is covered by the build and by reading the call path.
