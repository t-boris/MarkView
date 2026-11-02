---
type: bug
id: BUG-031
title: Saving in the editor can overwrite another tab's file
status: fixed
branch: fix/bug-031-editor-save-wrong-tab
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-02
---

# Saving in the editor can overwrite another tab's file

## Summary

On 2026-11-02 two tabs of one window were named `questions.md`: `Back Burner/MyDataCenter/_researcher/questions.md`
and `Back Burner/Sirius Art/_researcher/questions.md`. Boris typed an answer to a MyDataCenter question and saved.
The Sirius Art file on disk then held the whole MyDataCenter document plus that answer (rewritten by the editor's
WYSIWYG-to-Markdown conversion: front matter turned into a `Metadata` HTML table, list markers re-spaced), and the
MyDataCenter file was untouched. Sirius Art's own two open questions were gone from the file.

## Cause

The editor page and the app disagreed about which document was current, and the app trusted its own idea of it.

- `sendToSwift` (`markview-bridge.js`) posted `contentChanged` and `saveRequested` with no information about the
  document they described.
- `EditorView.Coordinator.didUpdateContent` called `WorkspaceManager.updateActiveTabContent`, and
  `bridgeSaveRequested` called `saveActiveFile`. Both act on the tab that is selected when the message is handled.
- Cmd+S in the page (`markview-edit.js` `saveFile`) converts the WYSIWYG DOM to Markdown, sends `contentChanged`
  (the page's text) and then `saveRequested`. If the page still showed document A while the selected tab was B, A's
  text became B's `content` and was written to B's `url`.

The file name played no part: the same thing could happen to any two tabs. The two `questions.md` tabs made the
damage easy to see.

How the page and the selected tab came apart on that day was not reproduced live. The debug log has no entry for
the save. The change below does not depend on the trigger: whatever separates them, the text can only reach the
tab it was typed in.

## Resolution

The page now says which tab it shows, and the app applies a message to that tab only.

- `window.mvDocumentId` holds the id of the tab whose document the page shows. Swift sets it in the same script
  that loads the document (`loadContent`, `loadCodeContent`, `loadStructuredContent`, `loadDataContent`), so no
  message can pair a new id with the old document. `sendToSwift` adds it to every message as `doc`.
- `EditorDocumentRouting` (new, pure) maps that id to a tab index. A message for a tab that was closed is dropped;
  it never falls back to the selected tab. A message that names no document (insight, X-Ray, nothing loaded) keeps
  the earlier behaviour and applies to the selected tab.
- `WorkspaceManager.updateTabContent(_:documentID:)` and `saveEditorDocument(documentID:)` replace
  `updateActiveTabContent` and the save call in `bridgeSaveRequested`. When the page's document is not the
  selected tab, a `[Editor]` line goes to the debug log (file names only), so the next occurrence leaves a trace.
- A tab that replaces another with the same file and text (closed and reopened) used to skip the reload, which
  would have left the page naming the closed tab. The reload guard now includes the tab id.
- Insight and X-Ray routes clear the id.

Unchanged: the Save menu item and the command palette still save the selected tab's own text and path
(`saveActiveFile`), which cannot mix documents.

## Not changed

Edits typed in the WYSIWYG view stay in the page until Cmd+S or a switch to Source; switching tabs loads the next
document over them (`setContent` resets `wysiwygDirty`). This is existing behaviour, deliberate in the code comments
(the Markdown conversion rewrites formatting), and is a separate question.

## Verification

- `bash tools/tests/editor-document-routing-tests.sh`, two parts:
  - The routing rule: a message naming a document reaches that tab even when another tab is selected, follows
    reordering, is dropped for a closed tab, and unnamed messages keep the old behaviour. The same checks fail
    against the previous "always the selected tab" rule (4 failures).
  - The shipped editor page in headless WebKit: after a load, the text it reports names the tab; Cmd+S in the
    WYSIWYG view sends the edited text and then a save request that both name the shown tab; a cleared id names
    nothing. The same checks fail against the previous `sendToSwift` (5 failures).
- Debug build with `xcodebuild` (see CLAUDE.md) passes.
- Not exercised by a run: the real app's tab bar and Cmd+S by hand. The Swift side (`WebViewBridge`,
  `EditorView`, `WorkspaceManager`) is covered by the build and by reading the call path.
