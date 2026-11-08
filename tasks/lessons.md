# Lessons

## A report's "Original description" is the request; the validity check's summary is not (BUG-108 follow-up, 5.45.0)

- BUG-108 said "починить обрезку", and ALSO, in the same original text, that project configuration must live inside the project, not in the
  general settings (which are only for templates), in a project file shown visually, with processes per type (feature, quick feature, bug,
  custom) from templates or from scratch. The validity check had summarised that second half as "a separate feature request, not an
  established cause of clipping". I fixed only the clipping, shipped 5.44.1, called the bug fixed and, when Boris asked, offered to file the
  rest as a feature. He answered: "if it should have been done and is not, it is a bug; do it in this bug, immediately".
- Rule: before planning a bug fix, read the whole `## Original description` and list every request in it (the dictated text mixes several)
  next to the summary; each is in scope unless Boris says otherwise. A machine summary or a "not a cause" note narrows nothing: do not
  decide that part of what he wrote is out of scope, and never answer "that is a feature" for something he wrote in the report. If it is
  truly unclear, ask before building the narrow fix, not after the release.
- A bug closed on the clipping alone is not done: when the report names more than one outcome, the final checklist has one line per outcome.
- Pace: after the code is verified by the suites that cover the change, do not run every harness in the repo and do not wait on long
  checks Boris did not ask for ("мне не нужны все эти проверки, ты просто тратишь мои токены", 2026-11-08). Run the focused suites, build, open
  the PR, merge, release.

## A fixed sheet width centres whatever overflows it: one `fixedSize` label can cut both edges (BUG-108, 5.44.1)

- The Project Workflow sheet is `.frame(width: 760)`. One rule's "From:" menu (nine statuses, 91 characters, `.fixedSize()`) made the
  scroll area 881 pt wide, and the frame centred the overflow, so the left edge (title, Name field, tabs) was cut off on every open. It looked
  like a window-size problem (settings window 640 pt, sheet 760 pt, a 400 pt scroll height); none of those was the cause. The report's
  hypotheses were all about the container; the cause was one child's ideal width.
- Reproduce a layout bug before touching the view: host the shipping view in a borderless `NSWindow` far outside the display (never shown),
  switch tabs through the `NSSegmentedControl` (`sendAction`), and read the frames of the AppKit-backed pieces (`HostingScrollView`,
  `DocumentView`, text fields). `bitmapImageRepForCachingDisplay` + `cacheDisplay` writes a PNG that shows the same cut text as the screenshot
  (it leaves out pickers and buttons). The splice list for such a harness grows through the model files a view uses
  (`IssueLifecycleDisplay`, `IssueLifecycleEvidence`, `IssueTransitionLog`, `FeatureVocabulary`): add them one compile error at a time.
- Test with the data at its widest, not only the shipped default: every status in every From, every condition for every actor, long ids. A
  label built from user data must be bounded (`frame(maxWidth:)`, `lineLimit(1)`, `truncationMode`) and carry the full text in `.help`.
- `fixedSize()` on a menu or text whose content comes from data is a latent overflow; keep it only for fixed labels.

## "Filters" means the visibility filters too, and a goal's CI step does not override a standing rule (Files views, 5.44.0)

Boris, mid-turn: "Когда я говорил про фильтры, я еще имел ввиду, чтобы, например, отфильтровать gitignore ... или может быть hidden не показывать."
- The spec's AC-3 listed hidden items, a name query and a category, but Boris's idea of "filters" also covered Git-ignored items. Before
  building a filter set, list every way an item can be "noise" in a file browser (hidden, Git-ignored, build output, excluded folders,
  unsupported types) and put the whole list into the plan so one answer settles it; record the extension as a requirement at once (REQ-001).
- The goal template said "wait for CI" while the memory said "never wait for CI". When a template step and a standing rule conflict, ask once
  and write the answer into the plan's header, not just into the chat.
- A spec premise can be wrong about the code (F-001 assumed the list hid unopenable files; `FileType.isOpenable` is true for every regular
  file). Grep the predicate before building on a spec sentence, then ask about the real behaviour.
- `ViewThatFits` in an `HStack` next to a `Spacer`: prove the narrow-width behaviour with a mock of the container (`ImageRenderer` or an
  offscreen `NSHostingView`, never a shown window) instead of reasoning about proposals; the mock showed the form degrading full, percent,
  minimal, gauge with the neighbours' gap kept at 6pt.

## Every push starts a round of CI: batch pushes and add no workflow without asking (Boris, 2026-11-08, PR #313)

Boris: "Почему так много CI запущено? ... Я же заплачу за каждый билд."
- A push to a PR starts nine workflows (eight macOS, one ubuntu, about 38 runner minutes); a push to `main` (even docs) starts Build &
  Release on two architectures plus the path-filtered ones. I pushed twice (the second only to fix one flaky new check) and added a tenth
  workflow whose build step duplicated the others. The repository is public, so hosted runners should not be billed, but the volume is
  still mine to keep small.
- Before the first push: run a new web/WebKit check the way CI does (clean checkout, nothing cached) and avoid clock-derived assertions.
  Push once. Batch docs commits into one push to `main`. Do not add a workflow or a build step without asking; propose
  `concurrency: cancel-in-progress` and path filters instead (proposed in `tasks/todo.md`, not approved).

## A palette that reads global state cannot differ per window; a mechanical migration needs the compiler as its oracle (per-window themes, 5.41.0)

- `VSDark` read `NSApp.effectiveAppearance` on every call, so no two windows could ever look different, and `ThemeManager` forced
  `darkAqua` on every window. A per-window setting needs the value in the view environment (`@Environment(\.palette)`, published by the
  window's root) and `NSWindow.appearance` per window; look for the *source* of the value (a static, a global observer) before adding
  a picker. Nothing static may remain: a leftover `VSDark.x` or `.primary`/`.secondary` quietly follows the macOS appearance instead of
  the window's theme.
- Moving ~1500 references was done with a script that masks strings and comments, rewrites `VSDark.x` to `palette.x`, adds the
  environment property where a type needs it, and reports every use outside a view body (free functions, `static let`, extensions, view
  builders in models). The build lists exactly those; each became a view struct or a parameter. Run the script as a dry run first and
  read its report; do not hand-edit 50 files.
- A standalone harness that compiles view files (`pdf-reader-tests.sh`, `intake-clipboard-tests.sh`) breaks the moment a file depends on
  a new type. Add the real model files to its compile line rather than stubbing the palette in the test: a stub drifts from the app.
  Keep helpers that need app-only types (here `DiagnosticSeverity`) next to their users, not in the shared palette file.
- `"${1:-}"` passes an *empty string*, not nothing: a test that treats "argument present" as "write pictures here" wrote five PNGs into
  the repository root. Treat an empty argument as absent, and `git status` after running a new harness.
- `ImageRenderer` needs `@MainActor` helpers; read its pixels through an sRGB `CGContext` (the image's own colour space shifts
  values by a few units). That gives a window-isolation check with no window on screen.
- Do not prove "the page did not reload" with `performance.timeOrigin`: on the CI image WebKit reported it with a jitter, so the check
  failed while the marker on `window` was intact. Use a marker on `window` plus the identity of a DOM node (`r === window.__node`);
  the same check fails when the node is replaced, which was verified with a deliberate mutation.
- `prototype-runtime-tests.sh` fails two checks on pristine origin/main as well. Before chasing a red harness, run it from a
  `git worktree add --detach <dir> origin/main`; remove the worktree after.

## Cleanup that compares with the state it just cleared, hidden-page geometry, and a picture is checked by its bytes (REQ-015…REQ-017, 5.34.0)

- A drag helper reset `target = ''` and then called the cleanup, whose `mark('')` returns early when the id equals the current target:
  after Esc the drop highlight stayed. The web test that counts `.connect-ok, .connect-no, .connect-from` after Esc found it. Do not
  clear the value a cleanup function compares against; let the cleanup clear it, and read what you need into a constant before.
- In the hidden WebKit page a node can lie under the properties panel or outside the 1280 px viewport, and `document.elementFromPoint`
  then returns the panel or null. Before a pointer test: Expand all, Centre, pan the map clear of the panel. The page code uses
  `elementFromPoint(...) || event.target` for the drop target (a touch pointer keeps its first target, so `event.target` alone is wrong).
- A new file kind that the page may send (a picture) is checked in Swift by its first bytes, never by the name or the type the page gives;
  SVG is refused because it can carry scripts. The stored value is one relative path (no `..`, no scheme), validated before anything else
  in `update`, so a refused value changes nothing.
- `balanced` used to alternate by index, so folding a branch never moved a side. Choosing sides from the visible weight needs a slack:
  with no slack the sides flip whenever a title wraps into a second line.

## A resizable field in a flex column needs `flex: none`, and the editable preview cannot write a map file back (BUG-096, REQ-010, 5.33.0)

- A textarea with `resize: vertical` inside a column-flex panel did not resize: `flex: 1 1 180px` has a non-auto flex-basis, which wins
  over the inline `height` the grip sets. Give a field the user can resize `flex: none` and a plain `height` (and `box-sizing:
  border-box`). The regression check sets `style.height` the way the grip does and reads the box back; it failed (140 px for 360 and
  170) before the CSS change, so it does prove the fix.
- Before promising an "editable ordinary Markdown view" of a structured Markdown file, measure the round trip: switch to the preview,
  fire `input` on `#editor-rendered` (that sets the page's dirty flag; without it nothing is converted back), switch to Source and diff.
  On a real 1327-line research map the converter replaced the front matter by an HTML table (the file stopped being a map), re-indented
  the outline and escaped `[Project fact]`. A spike harness is a copy of the first 118 lines of `ResearchMapWebTests.swift` plus a few
  `js(...)` calls. Boris chose a read-only View after seeing the numbers.
- The top bar (`#wysiwyg-toolbar`) is hidden while the map is shown, so anything that must be visible in every view needs a second
  instance in the map toolbar; build it once as a function and style it with the application's tokens (the `--rm-*` tokens exist only
  inside `.rm-root`).

## A node card is built from parts: never replace its children, and test every edit path with all parts present (BUG-095, 5.32.0)

Found while adding shape and size to the research map card: typing in the panel's title field set `btn.textContent`, which wiped
the badge, the icon and the label that 5.31.0 had put inside the card; they never came back until the map was reloaded.
- Update the one element that holds the changed value (`entry.label.textContent`), never the container that owns other parts.
  Grep for `textContent =` and `innerHTML =` on any element that gained children when a feature added parts to it.
- When a feature adds parts to an existing element, the old edit paths (typing, undo, snapshot echo) must be exercised in a test
  with every new part present. The 5.31.0 icon and number tests only delivered snapshots; none typed a title.
- To prove a regression test catches the bug, run the compiled test against the page that ships in the installed app
  (`research-map-web-tests` takes the editor folder as its argument; `/Applications/MarkView.app/Contents/Resources/Editor`).
- In the hidden-WebKit tests a field the test typed in keeps focus, and the page rightly refuses to overwrite a focused field
  with a snapshot: blur it before checking what a snapshot shows. A `deliver()` replaces the whole snapshot, so every node the
  next step needs must be in it (a helper that builds the look of all the nodes in play avoids half-reset state).
- Shapes that do not fill their box (ellipse, diamond) need three things the rectangle did not: the title measured and the shape
  sized around it (inscribed rectangle: x0.71 for an ellipse, x0.5 for a diamond), controls placed on the outline instead of the
  box corner, and a thin frame so the resize handles on the box corners visibly belong to the shape.

## A new view uses the app's own design tokens and is looked at in the real app before release (research map, 5.29.0)

Boris's first look at the map (2026-11-04) found five problems: the UI does not follow the application's design, no collapse/expand,
"Move to another branch" is useless, no way to expand a description or a topic, correct a node or research it, and (a request)
no Markdown/PDF export.
- Causes: the page copied the prototype's palette (`--rm-*`: purple/navy/green hex values, glow on nodes) and used none of the
  app's tokens (`--bg-*`, `--text-*`, `--border-color`, `--accent-*` in `index.html` `:root`); nobody opened the map in the running
  app (only hidden-WebKit tests with a stubbed bridge); the node actions are an icon-only bar behind a small ▼ that reads as a fold
  toggle, with tooltips as the only labels; the prototype only simulated AI, so only "develop" (children from a typed direction)
  was built.
- An approved prototype fixes layout and behaviour, not colours: map its look onto the app's tokens (read `:root` first).
- Before release render the view offscreen with the app's real CSS next to a neighbouring view (canvas, data) and look at the image;
  a green test suite does not show that a screen looks like the app.
- Primary actions need visible labels. ▼ means "fold", so a node menu uses "⋯". A title field must wrap, not cut a long title.
- When a prototype simulates something (AI), list in the requirements what the real feature needs beyond the simulation
  (here: describe, expand, correct and research a node) and ask, instead of building only the simulated part.

## A field's height is measured last, and a hidden page does not animate (research map, 5.31.0)

- The map's title field (a textarea that grows with its text) was fitted to its content before the properties panel had its final
  content. The panel then got a vertical scrollbar, the field became 17 px narrower and the text wrapped to a second line that was
  cut off. A test with the node already selected passed, a screenshot of a fresh selection showed it. Fit such fields **at the end**
  of the panel update (twice, so the second pass sees the final width) and again from a `ResizeObserver` for width changes.
- A hidden WebKit window never runs CSS transitions: a theme switch screenshot showed half-faded toolbar buttons. Add
  `* { transition: none !important }` to the page before such a screenshot.
- A text field's height must include its border when it is border-box: `scrollHeight` alone is 2 px short.
- A screenshot run on the real page found two defects (the cut title, the cramped "Expand description" button) that 228 passing
  DOM checks had not. Keep rendering the real page after a UI change, in both themes, and look at the picture.
- A SwiftUI view that depends on a big session object cannot be rendered alone. Pass it the one function it needs (here: capture →
  file URL) and it can be drawn offscreen with generated captures.
- Boris adds requests while a change is under way (here: enlarge the comparison, icons and numbers). Record each as a requirement as
  it arrives, ask only the questions that change the file format or the look, then continue.

## Real streams, real machines: check what the CLI sends and what a slow runner does (research map, 2026-11-04)

Building the research map, an independent review and the first CI run found what the local unit tests could not.
- The CLI hands over the next text block with nothing between it and the previous one: "First line." + "NODE {…}" arrives as
  `First line.NODE {…}`, so a protocol that wants a node on its own line loses it. Checked on the real `stream-json`.
  Rule: a line protocol over a model's stream gets its line breaks from the events that end a text block (tool calls,
  thinking), never from the model's habits, and is tried on the real stream of every backend before it ships.
- A status written at the start of a long run ("researching") needs a path back when the run dies with the app: the next
  time the map is shown with no job running it is settled to "incomplete", and Stop works even without a job.
- A change applied over a tab's text can overwrite a newer disk version (the watcher polls every 2 s): re-read the disk when the
  tab has no unsaved edits, and never recreate a deleted file.
- A page test that marks "messages since now" must mark before the action that sends them: a debounce fires after 300 ms,
  which on a slow CI runner is before the next line of the test has run (the first CI run of the page suite failed on it).
- The full sweep of `tools/tests/*.sh` has ten suites that already fail on a clean checkout (checked on `4187f60`); compare
  with a clean worktree before blaming a change.

## Do not make a model find what the code already says, and never make the page wait for it (BUG-088, BUG-089, BUG-090, 2026-11-04)

In vivaa-platform's Studio log the admin-panel had 63 route handlers and 56 of them had no rule: the list of the API was one
assistant call with a 420 s limit, it timed out, and the map stayed empty. Each unknown request then held the page for up
to 90 s while an agent searched the project for the handler, and every scenario switch cancelled that work and signed the
application out.
- Rule: what folder names and exports tell (Next.js `app/**/route.ts`, `pages/api`) is read by code, in milliseconds and
  completely; the model only gives that list meaning (the shape of an answer). A model's list is completed by the scan, and
  is replaced by it when the model fails.
- Rule: a request that waits for a model gets an answer within a few seconds (503 "preparing"), and the page is loaded
  again when the real rule is ready. A wait bounded by the model's own deadline is longer than any application's.
- Rule: hand the model the file it would otherwise search for (the handler of the request); the minute is the search.
- Rule: cancel only what depends on what changed. Rules belong to the environment, not to the scenario, so a scenario switch
  must not cancel a preparation; and a switch to the same test user keeps its sign-in cookies (in memory, not on disk).
- A test that switches scenarios puts the original one back, or a later check reads the wrong one (AC-19 did).

## Data the person asked for must outlive the next reopen and the next change (BUG-087, 2026-11-04)

Boris asked the Studio assistant for 16 strikes above and below SPX several times in broker-fabric and thought nothing was
saved. The files were: two identical 33-strike scenarios. Two separate faults made the data look lost.
- UI Studio always opened on the built-in "Populated" scenario, so a saved scenario waited in a menu nobody looked in.
  Rule: whatever state the person built, the next session opens on it (kept per project in `.dde/studio/`, never committed).
- A context change told the assistant "the new scenario has exactly the overrides you return", so a 27 KB option chain
  had to be copied back every time; the next change ("click Review & Send") dropped it and the page fell back to five
  strikes. Rule: the app carries what does not change; the model returns only what it adds or replaces
  (`dropOverrides` removes one). Never make a model copy bulky data to keep it.
- When a person says "it is not saved", read the stored files and the history first (the saved scenarios were there),
  then the state a new session starts in; the answer is rarely "the file is missing".
- Hiding a test window with `alphaValue = 0` or 0.01 stops the page from rendering and fails the session checks that
  depend on it (select, edit flows); the harness's plain window passes, so check a hiding trick against the baseline.

## A layout fixed on a clean sample is checked on the person's real snapshot before it ships (BUG-085, 2026-11-04)

Opening a part in the Code X-Ray broke the layered order. The fix passed seven new checks on a made-up four-layer
project, but the real vivaa-platform snapshot widened the opened layer by 7.6 px: file labels are paths without spaces,
Cytoscape wraps only at spaces, and a label wider than its cell widens every container around it (compound sizing
includes child labels).
- Rule: a fixture with short names proves the geometry, not the text: take the person's stored snapshot (`.dde/state.db`,
  `readArchitecture` copied into a probe, `CodeArchitecture.view`, hidden off-screen WKWebView) and open parts in every
  layer, measuring bounding boxes after each step.
- Rule: a long unbreakable label gets `text-overflow-wrap: anywhere` where the layout assumes it wraps, and the fixture then
  carries long paths so a regression fails.

## A hidden "Script error." is a bug in our own script until proven otherwise (BUG-086, 2026-11-04)

UI Studio's Select showed webpack's "Uncaught runtime errors: Script error." overlay as soon as the pointer moved. The
cause was in the injected runtime, not in the application: `var place` (the scenario's browser location, REQ-008) and
`function place(div, el)` (the selection boxes) shared one scope, the assignment at start replaced the function with
`null`, and the first redraw threw. The message was hidden because the throwing script has no address, and the
harness's select checks passed because they read only the pick result, never the redraw that runs a frame later.
- Rule: when WebKit reports a bare "Script error." with no file, line or error object, suspect our own injected script first,
  wrap its handlers in try/catch that records `String(e) + e.stack`, and reproduce against the real page.
- Rule: scan a big IIFE for one name declared as both variable and function (`^  var X` against `^  function X`); function
  hoisting makes the later assignment win silently.
- Rule: a check for UI that draws after an event must wait a frame and assert that no `error` event and no reported
  `runtimeError` arrived, not only that the call returned.
- Rule: a probe that opens a window on the person's screen, above all one that loads their own application, runs a few
  times and hidden, never in loops of dozens (Boris: "прекрати создавать strike desk").

## A layout bug is reproduced on the person's own data, measured, then fixed at the data and the layout (BUG-066, 2026-11-04)

The Code X-Ray overview of vivaa-platform had a column running through External and empty bands. The layout code alone
explained only half of it: the other half was the data (files the code model did not own were hung from the root, one part
each, so 317 migrations closed the Data band). Both causes showed only on the real snapshot.
- Rule: extract the stored snapshot (`.dde/state.db` → JSON with `python3 -I`), run the shipping `CodeArchitecture.view`
  with the harness's compile set, render with the shipping editor in WKWebView (`CodeArchitectureWebTests.swift` pattern),
  and print bounding boxes. Count parts per layer before deciding what is "layout".
- Rule: a model path and a draft path that build the same view must agree on structure (folders kept in both).
- Rule: a placement routine that returns a size must have that size used by whatever sits below it; a fixed cell width is
  never a grid rule for a container whose width is fixed.
- Rule: run a harness on `main` before trusting a failure of it: `"nodes":4` had been failing since the layered overview.

## A dev overlay is not a build failure until its label says so (BUG-067, 2026-11-04)

UI Studio called a working Next.js page a failed build: Next 16 shows console, runtime and recoverable errors in the same
`[data-nextjs-dialog]` as a build error and names the kind only in `#nextjs__container_errors_label`. A second path did the
same from the dev-server log (`\berror\b[: ]` matched a handled `console.error`). The banner then never cleared.
- Rule: classify framework signals by the framework's own label, verified in the project's installed version
  (`node_modules/next/dist/compiled/next-devtools`), never by the presence of a container element.
- Rule: a log scan that decides "the build failed" matches compile and bundle failures only, and is a pure function checked
  against real lines of an application that built (the person's own log line first).
- Rule: a state the page sets must have a way back: report the overlay going away, watch where it really lives (a shadow
  root), and do not deduplicate a signal that can repeat.

## A repair path must not be allowed to decline silently (BUG-062, 2026-11-03)

The preview check found five problems in the strikedesk prototype and the fix round "fixed" none of them. The fix round used the revision
prompt, which tells the assistant to make no change and list files in `remaining` when a request needs more than three files, and then called
the revision with `sweep: false`, which ignores `remaining`. The decline was printed as a chat message; the header looked normal.
- Rule: when a prompt lets the assistant decline into a field, the caller must act on that field or the prompt must forbid it. Read the prompt
  and the caller together; a flag that disables the follow-up is a contradiction.
- Rule: split work by what the problem names (each problem line carries its file) instead of asking one answer to cover everything.
- Rule: a repair that leaves problems behind must say so where the reviewer looks (the header), not only in the chat.
- Rule: a defect the page cannot report as an error (a loader that removes its own container shows nothing and throws nothing) needs a check
  that reads the file; run it over the real files of the failing prototype to see its false positives before trusting it.

## A document's text is never rewritten to make it displayable (BUG-061, 2026-11-03)

README.md showed empty picture boxes. The editor inlined Markdown images as base64 into the text it held, which also made every file
with a picture look modified and, on save, wrote the base64 into the file (BUG-007's record was corrupted that way), while HTML `<img>`
tags were never handled at all. Boris: "We have a huge bug. Pictures are not shown. This is terrible. Fix it urgently."
- Rule: a resource the page cannot read is served by the app at a URL (`markview-doc:`, like `markview-data:`); the text the editor
  holds stays byte-for-byte what is on disk. A fix that changes the text to carry a resource is not a fix.
- Rule: when a page rewrites an address for display, it keeps the author's own value in a data attribute and puts it back when the
  rendered page is turned into text again.
- Rule: reproduce with the real thing first (an isolated debug copy on a throwaway project with every form of the input: `%20`,
  `<…>`, `./`, `../`, `srcset`, `picture`), then look at what else the same mechanism does (here: the "modified" marker and the save).
- Rule: after finding corruption of this kind, search the person's own repositories for it and repair what the bug wrote.

## A contract that never varies belongs to MarkView, not to the model (BUG-060, 2026-11-03)

The StrikeDesk prototype showed only the toolbar of its main widget. The shell's `app.js` documented the page structure that every
screen needs (a definite height for html, body and #app, a column layout for the dock) and asked the model that writes `styles.css`
to provide it. The model wrote the header rules and left the structural ones out; the preview audit saw the collapse, and the repair
round declined because the fix spanned more than three files. Boris, after the first idea of appending the rules to the model's file:
"don't give me any quick fixes, hard fixes, shortcuts, nothing. It must always be clean architecture only."
- Rule: a rule that is the same for every prototype is code MarkView owns, written by MarkView, in a folder the assistant cannot see or
  write (`markview/structure.css`, zero-specificity `:where()` rules so the model's own styles still win). It is never a sentence in a
  prompt that the model may or may not follow, and never a patch appended to a file the model owns.
- Rule: such a layer must be baseline-neutral (the fingerprint ignores it, so applying it is not a "Studio edit"), applied wherever a
  site is built, accepted, synced or opened (an existing prototype repairs itself), and covered by a standalone check.
- Rule: measure before deciding. The empty chain was found by measuring the boxes in the prototype's own files in a browser, then the
  real `ensure()` was run on a copy of the real prototype and the same measurement repeated. Never edit the person's prototype by hand.

## Check a second instance of the app without touching the running one (2026-11-03)

To look at a new sheet I started a debug build next to Boris's running MarkView. Three things went wrong at once: `HOME=` does not
isolate the preferences of a non-sandboxed app, so the copy restored one of his projects and began indexing it; System Events
addresses processes by name, so with two processes called "MarkView" a window list and a click reached his windows; and a click by
screen coordinates lands in whichever window is on top.
- Rule: build the check copy with its own `PRODUCT_BUNDLE_IDENTIFIER` (fresh preferences) and its own `PRODUCT_NAME` (a unique process
  name), open only a throwaway project, and quit it by its own pid when done.
- Rule: drive it only through Accessibility elements of `process "<unique name>"`; never by screen coordinates, never by the name
  "MarkView".
- Rule: before any `kill`, list the pids with their executable paths; mine is the one under `/tmp/` or the scratchpad.

## Documentation goes straight to main (2026-11-03)

I opened a pull request for a README and presentation change, following the branch + PR rule. Boris corrected it:
"Commit all the documentation, always commit straight to main."
- Rule: documentation-only changes (README, `docs/`, `tasks/`, presentations, bug and feature records) are committed and
  pushed directly to `main`. No branch, no PR, no version bump, no DMG.
- Rule: features and bug fixes keep the branch + PR flow.
- Rule: "all the documentation" includes records other sessions left uncommitted in the working tree: compare them with
  `origin/main` first and commit only the files that really differ.
- Rule: in a shared tree, do it from a throwaway worktree of `origin/main` instead of switching branches, and remove it afterwards.

## Truncated prototype files need a bounded output protocol (2026-11-03)

The BUG-056 runtime change covered requirements mode, not code reconstruction. A code sync could still fail on a large
escaped file answer. The restart parser also recognized only `{"`, missing the usual pretty-printed `{\n  "summary"`.
- Rule: test restarted JSON with real formatting and nested records, not only compact synthetic objects.
- Rule: when raw JSON continuation cannot recover a file, regenerate it through small, independently valid fragment
  objects; concatenate decoded content, enforce the existing file-size cap, and save only after completion.
- Check the rollback through the full sync call, including failure and cancellation halfway through a generated file.

## Copilot over ACP streams its internal continuations as one answer (BUG-056, 2026-11-03)

When the model hits its 32K output cap, Copilot CLI continues by itself inside the same `session/prompt` and streams every internal
turn's text as `agent_message_chunk` with no boundary, then reports `end_turn`. Its session log (`~/.copilot/session-state/<id>/
events.jsonl`) shows the turns (`assistant.turn_start`) and the real texts (`assistant.message`). That is the fastest way to see what
the model actually wrote versus what MarkView received.
- Rule: never trust "the JSON never closed" to mean "ask for more". Check whether a complete answer already parses, and stop when the
  model only says it is finished.
- Rule: do not make the model emit large fixed code (a runtime, a framework) as an escaped JSON string in every run. Ship it, and
  let the model write only what is specific. That removes the slowest and most fragile answers.

## "Script error." is WebKit muting a cross-origin script, not an error message (BUG-047, 2026-11-03)

The Prototype Studio preview loaded `site/index.html` with `loadFileURL`, where every `file:` URL is its own origin. An error thrown in
a sibling `<script src>` (`app.js`, `screens/*.js`) reaches `window.onerror` as the bare text "Script error." with no file and line, so
the automatic fix round at the end of a generation was told to fix an error nobody could read. A harness with one throwing screen
showed the difference in a minute: `file://` gave "Script error.", a custom URL scheme gave `ReferenceError … (screens/broken.js:2)`.
- Rule: a page that loads its own scripts and reports their errors is served from one origin (a `WKURLSchemeHandler`), never from
  per-file `file:` URLs. When an error report has no text, first check how the page was loaded before asking the assistant to fix it.
- Test the error path with the shipping listener: the harness extracts it from `PrototypeStudioView.swift` instead of copying it, and
  keeps a `file://` baseline that shows the old behaviour.
- A background scratch copy can be checked without Boris's app: own bundle id and executable name, open a fixture project with
  `open -g -a`, press the toolbar menu through System Events by title, then read the web area's `AXURL`, its text and the badge's `AXHelp`
  with a small `AXUIElementCreateApplication(pid)` walk (`entire contents` in System Events returns only 2 elements for SwiftUI).
  Remove the copy's `Application Support/MarkView-<id>`, `Caches/<id>` and `WebKit/<id>` afterwards.

## 2026-10-29 — Long prototype runs need explicit cancellation, not stage stopwatches

**Context:** BUG-030. Prototype Studio terminated foundation work after 20 minutes, including Copilot
ACP calls. Stage deadlines discarded productive work whose duration depended on the requirements.

**Rule:** Make request deadlines explicit and optional. User-controlled prototype runs continue
until completion, Stop or a provider error; short app features retain their existing deadlines.
Verify the policy at every prototype stage and test both ACP and native process transports for
unbounded completion, bounded calls and cancellation. A check through one provider is insufficient.

## 2026-10-29 — Process completion and pipe EOF have different owners

**Context:** BUG-029. GitHub workers were still reading stdout after gh exited because terminal
children retained pipe descriptors. A timeout guarded by process.isRunning could not release them.

**Rule:** Collect process stacks and pipe owners before blaming the network. Close unrelated file
descriptors in forked terminal children. A bounded command runner must observe the requested process
exit independently of EOF, drain both streams without blocking, and escalate an ignored termination.
Test a successful child whose descendant keeps stdout open as well as a genuinely hung child.

## 2026-10-28 — Verify remote edits in both fresh and resumed conversations

**Context:** BUG-028. Codex's HOME CLI sandbox was read-only while its WORK MCP tools could write.
The model refused a natural file-edit request without attempting a tool. Clearer developer context
fixed new threads, but a resumed thread retained the earlier developer messages and refusal.

**Rule:** Distinguish the process host from the tool execution host and report each host's actual
permissions. Verify a natural read-then-edit request by inspecting the saved file, including a thread
that previously refused. Refresh saved context through the provider's supported API; command-line
configuration changes alone do not prove the old model-visible history has changed. Preserve the
native sandbox rather than widening it to solve a remote-routing misunderstanding.

## 2026-10-07 — A diagram is useful when it answers one question and can be checked

**Context:** AI diagrams (Graph Creator, code map, audit) were produced by pasting a prompt into the
interactive terminal: "include ALL components", no example, no schema, no check. The app never saw the
answer, so a broken or hairball diagram was only found by eye; the report was "diagrams are useless".

**Rule:** Run AI tools in a headless agent (`CLICompletion`) and make the app own the result. For a
diagram: the agent returns a graph as JSON by schema (one question, 8-20 nodes, verb-labelled edges,
`source`/`evidence` file:line from files it read); Swift validates it against the project (ids, edges,
node budget, paths that exist), asks again with the problems listed, and writes the file itself. A
smaller true diagram beats a bigger guessed one; say what was left out. Test prompt changes end to end
on this repository, not only the validator (`tools/tests/diagram-tests.sh` covers the validator).

## 2026-09-30 — A stateless AI loop needs the answers in its context, not a checklist

**Context:** Review of New Feature / New Project discovery. Every AI call was a cold CLI run; the
context carried the AI's own paraphrase of the idea, questions by title only, and a fixed list of 11
understanding dimensions that had to reach "known". Real specs showed the same question asked twice
(Q-001 ≈ Q-004), a contradiction the AI created from its two answers, questions the code already
answered, and about 3 minutes per question round.

**Rule:** In a loop of stateless calls, put the primary sources (the user's own words, every recorded
answer, the transcript) into every call's context, and let the questions come from the feature's own
open decisions rather than from a generic checklist. Ask in rounds with a recommended answer per
question, so the owner confirms instead of dictating. Log each call (label, seconds, tokens) so the
loop can be measured before and after a change. Cheap calls at low effort are not cheap when they
multiply into ten rounds.

## 2026-09-29 — Optional AI detail must not hold up a structural analysis

**Context:** BUG-015. A file without a successful cached outline was selected again on
every analysis. Long HTML went to a per-file AI request with a 300-second limit, even
though the project structure was already available. Timeout was mislabelled as a read
failure after the file had loaded.

**Rule:** Build a useful local outline first and cache it by file signature. Let an
explicit action request deeper AI detail with a bounded wait; preserve the local
result if that request fails. Distinguish file I/O errors from assistant errors.

## 2026-09-28 — Normalize cached outlines when building diagram nodes

**Context:** BUG-014. X-Ray stored full local and AI outlines, then rendered every named part and
group even when it contained only one or two items. A prompt change would only affect future AI
answers, leaving cached outlines and locally built declarations with the same extra clicks.

**Rule:** Enforce presentation thresholds at the shared node builder for every outline source.
Preserve item IDs and source positions when removing a container, and check both sparse and useful
branches with a deterministic fixture.

## 2026-09-26 — Write to a PTY: EAGAIN means "later", not "stop"

**Context:** BUG-002. `TerminalSession.write()` wrote to a non-blocking PTY master and stopped at the
first `write` ≤ 0. macOS takes only about 1 KB of input at a time, so every prompt over 1 KB was cut
at 1022 bytes. The closing `ESC[201~` was lost, and Enter was swallowed by the unclosed paste.
Every AI Tools item then "did nothing". The code looked fine for short keystrokes.

**Rule:** Every write to a non-blocking descriptor has an owner for the unsent part: keep it in order
and finish on a write source (retry EINTR, wait on EAGAIN), never on the main thread by blocking. To
reproduce terminal input bugs, use a standalone forkpty harness with the exact write code and a
slow reader or the real CLI. Count the bytes accepted instead of guessing from the screen.

## 2026-09-26 — Автоматическая фиксация: проверять на реальных данных и реальном процессе

**Контекст:** Lifecycle log: «spec ready» ждал статус `ready`, который приложение никогда не
ставит (Create issues переводит review → implementing). «Implement with AI» не писал событие.
Слежение за merge строилось на PR, а в этом репозитории коммитят прямо в main без PR.

**Правило:** Для каждого автоматического триггера найти код, который реально производит этот
переход (grep по значению статуса/действию), и проверить на живых данных (лог событий, `git log`,
`gh`), что событие появилось бы. Действие пользователя, запускающее этап (кнопка), само пишет
событие; модель брать из того, что CLI фактически использовал, а не из настроек.

## 2026-09-26 — Прогресс не виден, если вид не наблюдает объект с состоянием

**Контекст:** Карточки Feature читали `store.assistant.isRunning` через вычисляемое свойство, но
наблюдали только `FeatureStore`. SwiftUI не перерисовывал их при изменении `running` в
`FeatureAssistant` — спиннер не появлялся, карточка менялась только с готовым результатом.
Прошлая правка («помечать шаг сразу») ничего не дала по той же причине.

**Правило:** Вид, который показывает состояние объекта, наблюдает именно его
(`@ObservedObject` / `@EnvironmentObject`). Любое нажатие дольше ~0.5 с — сразу видимый
прогресс (что именно происходит), без ожидания подготовки запроса или сети.

## 2026-09-26 — Долгоживущие вещи не держать в @StateObject вида, который пропадает

**Контекст:** Голосовая запись (WhisperClient) жила в `@StateObject` кнопки микрофона.
Переключение вкладки уничтожало вид (терминал под редактором, вкладки правой панели) → запись
обрывалась, текст терялся. Все записи писали в один временный файл.

**Правило:** Запись, стрим, процесс — во владении модели (сессия терминала, движок), вид только
наблюдает (`@ObservedObject`). Временные файлы — уникальные, удалять после использования.

## 2026-09-26 — Файлы, которые правит и пользователь, и приложение: читать с диска перед записью

**Контекст:** Ревью Feature workspaces: `update()` писал закэшированную копию (правка
пользователя в редакторе терялась), фоновая перезагрузка приносила устаревший список и новый
объект получал уже занятый номер — `write(atomically:)` молча перезаписывал файл; перезапись
front matter теряла комментарии и блочные значения.

**Правило:** Read-modify-write всегда с диска в момент изменения; новые файлы — только
`.withoutOverwriting` и номер выше всех имён на диске; фоновые чтения со счётчиком поколений;
YAML, который нельзя переписать без потерь, не переписывать (сообщить).

## 2026-09-26 — Содержимое .toolbar не получает environmentObject окна

**Контекст:** 2.0.1 падал при запуске: `AIToolsMenu` в `.toolbar` читал
`@EnvironmentObject WorkspaceManager`, а `WorkspaceManager` — `@StateObject` в `ContentView`, в
окружение панели инструментов он не попадает (EnvironmentObject.error → SIGTRAP).

**Правило:** Виды внутри `.toolbar` получают объекты параметром (`@ObservedObject`), как
`AssistantToolbarMenu` работает только с `@AppStorage`. После изменений панели инструментов —
запустить собранное приложение, сборка этого не ловит.

## 2026-09-26 — Файл вне папки проекта переключает рабочее пространство

**Контекст:** `openFile` для `.md` вне корня папки вызывает `initSingleFileWorkspace`: закрывает
базу, останавливает терминалы, Git смотрит в другую папку. Копии файлов PR лежат в кэше вне
проекта — открытие такого `.md` из PR X-Ray давало «Initialize Git Repo» в репозитории с git.

**Правило:** Любой файл, который приложение само кладёт вне проекта (кэш PR, временные копии),
должен распознаваться как часть открытого проекта (`isFileInCurrentWorkspace`). Проверять
открытие `.md` из таких мест.

## 2026-09-26 — PR X-Ray: файл — лист; изменения внутри видны только в открытом файле

**Контекст:** PR X-Ray рисовал внутри файлов узлы изменений (конкретные строки). Пользователь:
это не то — в X-Ray нужны файлы/структура; клик по файлу открывает файл, и уже там видно каждое
изменение с объяснением «почему». Удалённые файлы тоже должны открываться.

**Правило:** В X-Ray (включая PR) не рисовать содержимое файла; детали изменения — в
просмотрщике файла (линза Pull request). В PR X-Ray клик по файлу сразу открывает его.

## 2026-09-26 — Интеграции опциональны: MarkView может быть просто Markdown-viewer

**Контекст:** Во время реализации GitHub-интеграции пользователь напомнил: приложение можно
открыть на одном файле без папки, и оно должно оставаться обычным Markdown-viewer.

**Правило:** Любая интеграция (GitHub и т.п.) — opt-in переключатель в Settings (по умолчанию
выключен) и работает только при открытой папке. Выключена → ни одного вызова `gh`, никакого
опроса, существующий UI не меняется.

## 2026-09-25 — Новую возможность встраивать в существующий инструмент, а не строить рядом

**Контекст:** Пользователь просил «custom filter» — искать по теме и видеть подсвеченным только
нужный код. Я сделал отдельную панель «Topic / AI Search» слева, кнопку в тулбаре и отдельную линзу
в коде. Пользователь: «Ты неправильно сделал. Я хотел внутри X-Ray сделать search… это не более
того, как обычный фильтр… убери весь этот UI».

**Ошибка:** Слово «фильтр» в запросе указывало на уже существующий механизм (фильтры X-Ray с
⚡ Quick AI filter). Я не сверил, какой существующий UI имеется в виду, и изобрёл новый.

**Правило на будущее:**
- Если в запросе звучит название существующей вещи («фильтр», «панель», «линза»), сначала найди
  её в коде и предложи расширить именно её. Новая панель/кнопка — только после явного согласия.
- Перед реализацией UI-фичи коротко опиши, *где* она появится («в X-Ray, в поле ⚡ фильтра»), и
  получи подтверждение, если есть хоть малейшая неоднозначность.
- Результат поиска показывать так, как пользователь описал визуально (здесь: «подсвечивает красным
  только важное»), а не своей схемой шагов/цветов.

## 2026-05-31 — Зависший UI: снимай sample стека, не гадай

**Контекст:** Пользователь повторял «висит». Я последовательно гадал: индексация →
WebView (mermaid 2.9MB) → миграция БД. Каждый раз тратил циклы на неверную гипотезу.
Реальная причина нашлась за один `sample <pid>`: главный поток на 100% стоял в
`GitClient.refresh() → run() → Process.waitUntilExit()` — git выполнялся СИНХРОННО на
главном потоке при открытии папки, плюс чтение pipe ПОСЛЕ `waitUntilExit` → дедлок при
выводе git > 64KB (`git status` на 1200+ файлах).

**Правило на будущее:**
- «Висит/beachball» → СРАЗУ `/usr/bin/sample <pid> 3` (или spindump) и смотри thread 0.
  Стек точно покажет блокирующий вызов. Не гадай по коду.
- `ps -o %cpu,state`: 0% CPU + state S = заблокирован на ожидании (lock/IPC/waitUntilExit),
  а не крутит цикл. Высокий CPU = busy-loop/тяжёлые вычисления. Это сужает поиск.
- НИКОГДА не вызывай `Process.waitUntilExit()` на главном потоке. И всегда читай pipe ДО
  (или конкурентно с) waitUntilExit — иначе переполнение 64KB-буфера = вечный дедлок.
- Утилиты `log`, `sample` перехвачены функцией/обёрткой miniconda в zsh-профиле —
  использовать полный путь `/usr/bin/log`, `/usr/bin/sample`.


## 2026-05-30 — Диагностика перформанса: сначала факты, потом гипотезы

**Контекст:** Жалоба «MarkView очень долго грузится при старте». Я сразу полез читать
`index.html`, нашёл mermaid.min.js 2.9 MB и CDN-скрипты, и предложил lazy-load JS.
Пользователь дважды поправил: «дело не в парсинге» и «больше 5 минут грузится».

**Ошибка:** Построил гипотезу (парсинг JS) из чтения кода, не сверив с **масштабом
симптома**. 2.9 MB JS парсится ~1–2 с — это физически не может давать 5 минут. >5 минут =
зависание/блокировка, а не стоимость вычисления.

**Правило на будущее:**
- При жалобе на перформанс СНАЧАЛА получить число/масштаб (секунды? минуты?) и **прочитать
  логи с таймстампами**, и только потом строить гипотезу. Здесь логи (`~/markview_debug.log`)
  сразу показали бы провал во времени после `structural index started`.
- Сверять порядок величины: предполагаемая причина должна объяснять НАБЛЮДАЕМЫЙ масштаб.
  Парсинг → секунды; сетевой таймаут/блокировка main-потока/per-item sync → минуты.
- Реальная причина: `StructuralIndexer` делал 3 обхода дерева + `DispatchQueue.main.sync`
  на каждый из 1222 файлов на занятом main-потоке.

## 2026-05-30 — Process.terminationHandler требует удержания Process

**Контекст:** Вынес индексацию в отдельный процесс. `Process` создавался как локальная
переменная; после выхода из функции объект освобождался → `terminationHandler` не срабатывал
(ОС-процесс при этом нормально отрабатывал). Сначала удержал в instance-property, но в
приложении создаётся НЕСКОЛЬКО `WorkspaceManager` (несколько окон/ghost windows), и property
умирал вместе с временным экземпляром.

**Правило:** Для fire-and-collect дочерних процессов удерживать `Process` в **процесс-wide
(static)** коллекции до вызова terminationHandler, не в instance-state короткоживущего объекта.
Логировать на входе в handler через nonisolated-путь (handler выполняется вне `@MainActor`),
чтобы отличать «handler не вызвался» от «self уже nil».

## 2026-09-03 — Хардкод абсолютных путей к внешним CLI

**Контекст:** Пользователь сообщил, что Codex перестал работать. Причина: в
`AIConsoleEngine` путь был константой `"/opt/homebrew/bin/codex"`, а реальный бинарник
стоял через npm/nvm — `~/.nvm/versions/node/v22.22.3/bin/codex`. При этом `PATH` для
подпроцессов тоже был литералом без nvm-путей. Ошибка выглядела как «ничего не
происходит»: `process.run()` кидал непрозрачный NSError, и в UI не было ни причины,
ни способа исправить.

**Правила:**
- Никогда не хардкодить абсолютный путь к стороннему бинарнику. Порядок разрешения:
  явный override из настроек → скан кандидатов (включая **все** `~/.nvm/versions/node/*/bin`)
  → `command -v` через login-shell. Путь к node-CLI меняется при каждом обновлении Node.
- Любая интеграция с внешним инструментом должна быть **перенастраиваемой из UI**.
  Если пользователь не может починить её сам — это дефект дизайна, а не «конфиг».
- Ошибка «не найдено» обязана называть: что искали, где искали и куда идти чинить.
  Молчаливый отказ хуже, чем краш.
- У CLI обычно есть дешёвая неинтерактивная проверка авторизации — использовать её,
  а не тратить токены пробным запросом: `claude auth status` (JSON, поле `loggedIn`),
  `codex login status`.
- Логин в CLI требует TTY/браузер. Открывать Terminal через исполняемый `.command`-файл
  и `NSWorkspace.open`, а не через `NSAppleScript` — иначе нужны Apple Events
  и `NSAppleEventsUsageDescription`.

**Сопутствующее:** там же нашёлся лог первых 20 символов API-ключа в
`~/markview_debug.log` (`DDESettingsView.onAppear`). Логировать только факт наличия
и длину — никогда никакую часть ключа.

## 2026-09-17 — Fire-and-forget notifications lose requests during startup

**Context:** Finder "Open With" never opened anything. `application(_:open:)` posted a
NotificationCenter message; the receiving `ContentView` filtered by `hostWindow`,
which `WindowAccessor` sets on the *next* run-loop turn. On delivery every window
rejected it and the request vanished. The fallback only covered "no visible window",
but SwiftUI shows the window before delivering the open event.

**Rules:**
- An external request (open URL, deep link) must be stored in a durable queue and
  drained by the receiver; the notification is only a "check the queue" signal.
- Drain at every moment the receiver may become eligible (signal, window attached,
  window becomes key), not just once.
- Don't branch on "is a window visible" at open time — SwiftUI's ordering of
  window creation vs. `application(_:open:)` is not something to rely on.
- Verify with `open -n -a <DerivedData app> <path>` and the debug log; one grep for
  "was it ever handled" (count = 0) proved the bug in seconds.

## 2026-09-24 — Don't drive UI in the user's live app instance

**Context:** To verify "Close Folder" I ran `install.sh` (which relaunches
/Applications/MarkView.app) and clicked the menu item via System Events. On relaunch
the app had reopened the user's own workspace (`vivaa-platform/docs`) in the key
window, so the scripted click closed the user's real folder and tabs instead of the
test fixture.

**Rules:**
- UI automation runs against the Debug build in /tmp/MarkViewDerivedData, never the
  installed app the user is working in.
- Before a scripted action, confirm which window/folder is key (debug log or window
  title); abort if it is not the fixture I opened.
- Destructive UI actions (close, delete, discard) are for the user to try, not me.

## 2026-09-24 — Menu commands don't observe objects behind @FocusedValue

**Context:** "Close Folder" used `.disabled(activeWorkspace?.rootNode == nil)`, where
`activeWorkspace` is `@FocusedValue(\.workspaceManager)`. The user reported it
permanently disabled. `Commands` re-evaluate only when a focused *value* changes; the
WorkspaceManager reference is the same object before and after the folder loads
asynchronously, so the item froze in whatever state it had when the window took focus.
I had even seen the reverse symptom (still enabled after close) and wrote it off as
cosmetic.

**Rules:**
- Menu enabled/checked state must come from a value-typed focused value
  (`.focusedSceneValue(\.someBool, ...)`), not from properties of a focused object.
- A stale menu state in either direction is the same bug — fix it, don't document it.

## 2026-09-24 — Range deletes by marker: list what's inside first

**Context:** Removing `analyzeAllFiles` I cut from its doc comment to the next known
marker (`/// Load ALL entities…`). Eight live functions (diagram prompts,
`refreshSemanticViews`, `navigateToText`) sat in between; the build broke and I had to
restore them from HEAD.

**Rule:** before deleting a span between two markers, print the `func`/`struct`
declarations inside it and confirm every one is meant to go. Prefer brace-matched
deletion of a single declaration over marker-to-marker cuts.
The same holds for deleting a whole file: `EntityGraphView.swift` also held
`MarkdownContentView`, which the AI console renders with. List every top-level
declaration in a file and grep each one before `git rm`.

## `defer` in a Task does not release a flag before chained work
- `scan()` used `defer { busy = false }` and called `analyze()` at the end of the same Task. The defer had not run yet, so `analyze()` hit `guard !busy` and silently did nothing: the first automatic AI analysis never started.
- Rule: when a job chains into another job guarded by the same flag, clear the flag explicitly right before the chained call. Don't rely on `defer`, and never let a later `defer` clear a flag the chained job has set.

## New columns need a migration, not just CREATE TABLE
- `arch_nodes` gained columns while databases created by an earlier build already had the table. `CREATE TABLE IF NOT EXISTS` skipped it, so INSERT/SELECT failed with "no column named component".
- Rule: whenever a column is added to an existing table, also call `addMissingColumns` (ALTER TABLE ADD COLUMN) in `createTables`, and test on a copy of an old database.

## Codex "error" events are not always fatal
- `codex exec --json` reports warnings (e.g. "Model metadata … not found") as `{"type":"error"}` and API failures as raw JSON inside `message`. Only `turn.failed` ends a run.
- Rule: record `error` events and use them only to explain an empty answer; unwrap the nested `error.message` before showing it. Test model choices with a real `codex exec` call, since the catalog can list models the account cannot use.

## Verify editor UI in WebKit, and never let `display` override `hidden`
- The notes panel could not be collapsed: `.code-notes { display: flex }` beats the UA `[hidden] { display: none }`, so ✕ did nothing. Chrome checks missed it because ✕ was never exercised, and the app runs WKWebView, not Chrome.
- Rule: every element toggled with `hidden` whose CSS sets `display` needs an explicit `[hidden] { display: none }`. When a library styles the element with `!important` (CodeMirror's `.cm-editor` is `display: flex !important`), the `[hidden]` rule needs `!important` too — otherwise two viewers show at once. Check interactions (drag, close, reopen) in real WebKit: a small Swift program with an off-screen WKWebView that loads the editor from a local server and dispatches the events, not only in Chrome.

## Confirm which panel the user means before fixing it
- "The explanation panel doesn't resize" meant the X-Ray details panel (descriptions, Component list), but I fixed the code-notes panel. The user had to repeat it several times.
- Rule: when a report names a UI element loosely ("the panel", "explanations"), match it to the screen the user is on (X-Ray, code, docs) and name the element back ("the X-Ray details panel on the right"). If two readings are plausible, fix both or ask.
- Also: a flex item holding a canvas needs `min-width: 0` (or `overflow: hidden`), or it grows to the canvas width and pushes side panels off-screen.

## Never use `git stash` to compare before/after
- I ran `git stash push <file>; …; git stash pop` to time an old version. The file was untracked, so nothing was stashed — and `pop` would have applied someone else's older stash to a working tree with 70+ uncommitted files.
- Rule: to compare versions, build the old code from a copy (`git show HEAD:path > /tmp/...`) or a separate worktree; never stash in the user's working tree.

## New files in Resources/Editor are not bundled automatically
- The "Build Web Editor" pre-build script copies only listed files (`index.html`, `terminal.html`, `vendor/`). A new top-level page must be added to that script in both `project.yml` and `project.pbxproj`, or `Bundle.main.url(...)` returns nil and the web view stays blank with no error.
- Check with `ls <App>/Contents/Resources/Editor/` after building.

## Never restart the user's running MarkView
- `install.sh` and `release.sh --install` quit and kill the running app; Boris works in it (live terminal sessions). Build into /tmp/MarkViewDerivedData or `./release.sh` (no `--install`) and let him install when he chooses.

## Nodes inside files break "leaf = file" assumptions in the X-Ray JS
- Overlays, PR highlighting and tag hiding collect `descendantsFiles` (leaves). Once files got children (contents, PR changes) a file stopped being a leaf and was dimmed/uncounted. A file is the aggregation boundary: stop at `kind === 'file'`; inner kinds inherit their file's overlay.

## A loaded diff goes stale while the user keeps working
- The PR X-Ray showed a diff taken before a later commit, so lines no longer matched the file. Any view that overlays a diff on a file must either show the diff's own version of the file or map lines by content, and local changes must be re-read when they move on.

## JSONSerialization numbers 0 and 1 are also Bool
- The usage parser skipped Bool values with `value is Bool`; `NSNumber` 0 and 1 match that, so
  "0%" and "1%" windows vanished. Only the tests on real response shapes caught it.
- Rule: tell booleans from numbers with `CFGetTypeID(number) == CFBooleanGetTypeID()`, never `is Bool`.

## Scanning large files: read in chunks and drain the autorelease pool
- The first scan of ~650 MB of agent logs peaked at 1.18 GB: whole files were read at once and
  every `JSONSerialization`/`FileHandle` object stayed in the thread's autorelease pool until the
  scan ended. Chunks of 8 MB, each inside `autoreleasepool {}`, brought it to 92 MB.
- Rule: any loop over many files or lines that creates Foundation objects runs its body in
  `autoreleasepool`; measure peak memory with `/usr/bin/time -l` on real data.


## Launch tests must never touch the user's MarkView (2026-09-26)
- Mistake: the launch test compared against a PID remembered from an earlier turn (48496); the user had restarted MarkView meanwhile (71011), so the test killed the user's app.
- Rule: collect the running PIDs in the same command, immediately before `open -n`, and kill only a process whose executable path is `build/release/MarkView.app` (check `ps -o command=`), never by "not in an old list".

## 2026-09-26 — Cancel must reach async callbacks; insert only into the field's own window

**Context:** Review of the intake dictation: the microphone permission callback started recording
after the user had cancelled (the mic stayed on, the WAV leaked); the transcript was inserted
into whatever text view was first responder in the key window, including another window's
API-key field.

**Rule:** Anything started behind a prompt or callback captures a generation and does nothing if
it changed. Text produced later is inserted only into the originating window's first responder
(captured when the action started), otherwise appended to the field's own binding.


## 2026-09-26 — Terminal OSC 8 and plain URLs have different activation paths

WebLinksAddon handles regex URLs; xterm's OSC 8 provider uses Terminal.options.linkHandler.
Without that handler it calls browser confirm/window.open, which WKWebView without a
WKUIDelegate cannot display. Test both paths in native WebKit. Link activation on xterm's
screen can also bubble into PTY mouse reporting in a TUI: reserve Cmd+click at the screen
bubble phase after the linkifier, retaining ordinary TUI mouse events. Resolve relative file
links against the live foreground/shell cwd, not only the folder where the terminal started.

## Terminal escape-sequence tests must use the emitter's real encoding (2026-09-26)

BUG-001 tests covered only ST-terminated OSC 8 (`ESC \`). Claude Code (Ink/ansi-escapes)
ends OSC 8 with BEL and other tools add `id=` params. When reproducing a terminal bug reported
against a specific program, replay that program's exact byte shape (terminator, params, SGR styling,
alternate screen, mouse mode). Also run the new check against the pre-fix page to prove it catches the bug.

## Never edit a text view and its `inout` binding in the same call (BUG-003, 2026-09-26)
- Dictation inserted the transcript through `NSTextView.insertText` inside a function that took the
  field's text as `inout String`. The view updated the `@State`, then the `inout` write-back restored
  the old text: the text flashed in and vanished, with no error. It was misread for hours as a
  microphone/recording problem, because the logs had no public messages (NSLog shows `<private>`).
- Rule: an edit goes to exactly one owner, the binding. Read the cursor from the view if needed, but
  never mutate the view. To reproduce a UI bug without Accessibility access, run a Developer ID-signed
  copy from a worktree with stderr tracing next to the user's app and have the user click. Trace
  every step through to the final state, not just the part you suspect.

## HSplitView ignores idealWidth; don't run xcodegen on this project (2026-09-26)
- A pane given `idealWidth: savedWidth` opened at 199 or 600 px, depending on the window: SwiftUI `HSplitView`
  divides the space itself. Restoring a width needs the underlying `NSSplitView.setPosition(_:ofDividerAt:)`
  after the first layout (`LeftPanelWidthKeeper`). Don't save widths from before that restore, because they come from layout passes.
- `xcodegen generate` rewrote every ID in `project.pbxproj` (870 lines). Add new files by hand, as was done for
  PTYWriter.swift, and keep `project.yml` aligned.
- A UI can be checked without touching the user's app: build with `PRODUCT_BUNDLE_IDENTIFIER=<other>` (separate
  defaults), seed its defaults, and read rows via `osascript` System Events (`help` of row buttons).

## @AppStorage is app-wide: per-window UI state must not use it (BUG-004, 2026-09-27)
- The right panel tab, left panel mode, open issue, Git section and feature stage were `@AppStorage`. That is one
  UserDefaults value observed by every window, so a tab switched in one window switched in all of them.
- Rule: state that describes what one window shows lives in that window's model (`WorkspaceManager.layout`,
  `PanelLayout`). UserDefaults is only its seed for the next window and relaunch. Keep `@AppStorage` for preferences
  that all windows should share (theme, model, API settings).
- Driving a test copy through AppleScript: `process whose unix id is N` resolves back to
  `application process "MarkView"` by NAME, so it reaches the user's installed app, not the copy. Use the AX API
  directly (`AXUIElementCreateApplication(pid)`, small swiftc helpers) to address the copy by PID only.
## Headless `claude -p` refuses web tools unless pre-approved (New Research, 2026-09-27)
- `--tools WebSearch,WebFetch` only makes the tools available. In `-p` mode nothing can approve them, so every
  WebSearch was denied (listed in the result's `permission_denials`), and WebFetch worked only for Claude Code's
  built-in allowlisted domains. The model then wrote "search not permitted" into the report, with no error.
- Rule: `allowWeb` also passes `--allowedTools WebSearch,WebFetch`; read `permission_denials` and treat refused
  web calls as lost web access. Reproduce with the exact CLI flags before blaming the prompt.

## Text selected in the rendered editor is not the Markdown source (2026-09-27)
- The rendered view shows `doesn’t` for `doesn't`, drops `**`, `[` `](url)` and list markers. Matching a selection
  back to the source needs normalisation (`ResearchDocument.plain`), found only by a real selection, not by tests
  written from the source.

## Driving a background test copy through Accessibility (2026-09-27)
- Toolbar `Menu`: `AXPress` on the AXMenuButton opens it and its AXMenuItems can be pressed; `AXShowMenu` does not.
- SwiftUI tap gestures (file tree rows) ignore `CGEvent.postToPid` clicks while the app is in the background; open
  files through a pressable path instead (Search tab results). Web content: select with
  `AXTextMarkerRangeForUIElement` → set `AXSelectedTextMarkerRange` on the AXWebArea (fires `selectionchange`).

## Prompts that make the AI check git state must exclude the app's own files (batch Fix with AI, 2026-09-27)
- The batch prompt told the AI to ask before continuing when the tree is dirty. The app had just marked the batch's reports
  `fixing`, and MarkView keeps its index in an untracked `.dde/`, so every real run would have stopped on the question.
- Rule: when a prompt conditions on "uncommitted changes", list what the app itself changed or owns (its own edits, `.dde/`)
  as expected and never committed. Verify such prompts with a headless `claude -p` run in a fixture repo, not only by reading.


## 2026-09-27 — Understand answers and image paste

- Plain `NSTextView` disables Paste for an image-only clipboard. A paste override also needs PNG/TIFF/file URL `readablePasteboardTypes`; verify Preview → Copy → ⌘V, not only conversion helpers.
- Keep dedicated answer state independent of X-Ray's first snapshot. Merge its transient evidence into new snapshots, and guard deferred stream callbacks with a generation token so completed/retried questions cannot be overwritten.
- Collect git log/blame for actual discovered evidence files and exact valid ranges. Keyword-only history misses introducing documents; blame 1–120 fails on short files. Supply bounded PR bodies as well as metadata.
- Pasted question attachments belong in transient workspace storage until explicit RES save; copy saved assets so closing the filter cannot break the saved document.

## Optional-success closures and nested ObservableObjects (Start a Project from Scratch, 2026-09-27)
- `await manager?.activate() ?? "error"` where `activate()` returns `String?` with nil meaning success turns every
  success into the error. Unwrap the owner first (`guard let manager else { return "error" }; return await …`).
- A sheet observing only its flow object does not re-render when the flow's nested `FeatureStore`/`FeatureAssistant`
  change: a button's `disabled` stayed stale. Forward nested `objectWillChange` into the flow, and check the button in
  a real run — `AXPress` on a disabled SwiftUI button still reports success.
- A background test copy (`open -n -g`) opens no window: `newWindowForTab:` needs an active app. Press File › New
  Window through the AX menu bar, and open folders with `open -g -a <copy.app> <folder>` (its own bundle ID).
- The "document language" default has no documents to go by in a new project; name the source of the language.

## A lifecycle event that waits for something can be lost (BUG-008, 2026-09-27)
- "Implement with AI" wrote `implementation_started` only after the CLI's first reply (polling up to 15 min), because
  the append-only log cannot be amended with the model later. It showed up late, was lost if the app quit (reinstall),
  and the status was never set at all, since only Create issues set `implementing`.
- Rule: record a user-triggered event at the action itself with what is known then; never make its existence depend
  on a later, in-memory wait. Every entry point into a state (buttons, menus, AI actions) applies the same status rule:
  share it (`Feature.beforeImplementation`, `markImplementing`) instead of repeating it inline.

## Never show an API response body as an error (BUG-009, 2026-09-27)
- Whisper failures pasted the first 300 characters of OpenAI's JSON error body into the UI, including the masked
  key fragment OpenAI echoes. Users saw JSON and no next step.
- Rule: map HTTP status + the provider's machine-readable error code to a sentence, a next step and a short
  `(HTTP n · code)` tag; accept only identifier-shaped codes; never display or log the body. Get a real error body
  with a fake key (`curl … -H 'Authorization: Bearer sk-fake'`) and test the mapping against it.

## A launch from an agent shell leaks its environment into the terminal (2026-09-27)
- MarkView was relaunched with `nohup` from Claude Code's Bash, which sets `NO_COLOR=1`. `TerminalSession` copies
  the app's environment into every shell, so Claude, Codex, git and ls in all terminals turned black and white.
  No code had changed; `ps -E -ww -o command= -p <pid>` showed `NO_COLOR=1` on the app process.
- Rule: the terminal drops the launching tool's markers (`CLAUDECODE*`, `NO_COLOR`, `FORCE_COLOR`); the user's rc
  files set their own values again. Relaunch the app with `env -u NO_COLOR -u FORCE_COLOR open -a …`, never by
  running the binary from an agent shell. When output "suddenly" changes, check the running process's env first.

## A spec's `implemented` status is a claim, not evidence (Issues Sync, 2026-09-27)
- `sync-github-issues-with-feature-bug-status-from` was `status: implemented`, yet no Sync code existed anywhere;
  a second spec for the same issue #36 had been written on top of it with conflicting decisions.
- Rule: before implementing (or skipping) a feature, grep the code for its behaviour; when two specs share an
  issue, pick one canonical spec and archive the other in the same PR. Dry-run anything that mutates GitHub
  against the real repository (lookups only) before the first live run, and show the owner what it would change.

## A guard fixed for one entry point must be checked for all of them (BUG-011, 2026-09-27)
- "Implementation agent repeats answered questions" was blamed on the handoff prompt. Six headless runs (Claude,
  Codex) of the old prompt on a fixture used every recorded answer; 24 real transcripts showed 4 repeats in total.
  The real repeats came from guided discovery: after the intake's open questions, `answer(next: true)` generated
  new questions that duplicated them (13 specs, e.g. new-research Q-001 = Q-004 with different answers). 2.24.0 had
  already fixed exactly this, but only for new projects (`projectDiscovery &&`).
- Rule: when a report names a suspect, measure it (headless runs on a fixture, real transcripts, the spec files'
  order in discussion.md) before fixing it. When a fix is scoped to one flow, grep for the sibling flows that
  share the mechanism and ask whether the scope is intended.

## Layout bugs: replay the stored graph headlessly and measure (BUG-012, 2026-09-28)
- The X-Ray snapshot is in `<project>/.dde/state.db` (`arch_nodes`, `arch_edges`, per view). Cytoscape runs
  headless in Node with `cytoscape-elk` and the vendored `elk.bundled.js` (give it `node_modules/elkjs/lib/`);
  mirror `buildElements` (drawn nodes, representatives, sizes) and the `layout()` options, then measure fill
  (node area / box area), overlaps and mean linked-node distance. ELK's worker keeps Node alive: exit after
  `layoutstop`, with a timeout.
- A screenshot's scatter was not the folder the report's suspect pointed at (a Go folder with no inner links packs
  fine); sweeping every large box across projects found the branch that scatters and proved the fix everywhere.

## Keeping one installed copy: check Gatekeeper first (2026-09-29)
- Releases up to 3.4.2 were Developer ID signed but not notarized (`NOTARY_PROFILE` was unset). A copy
  installed from a browser-downloaded DMG carries `com.apple.quarantine`, and `spctl` rejects it as
  "Unnotarized Developer ID". Local builds have no quarantine, so they masked this.
- Rule: before deleting other copies of the app, run `spctl -a -vvv -t exec` on the copy that stays and check
  `xattr` for quarantine. Since PR #76, `release.sh` notarizes with the `markview-notary` keychain profile.

## AI answers: an empty answer is a failure, not a result (BUG-020, 2026-09-29)
- Codex once answered X-Ray's deployment request with `{"nodes":[],"edges":[]}`. It was stored as the map,
  its config signature was saved, and the answer cache kept it, so every later Analyze reused the emptiness.
- Rule: when an AI step's result gates future runs (signatures, caches), validate the answer's substance
  (e.g. at least one node) before caching or storing it; on failure keep the previous result and say so.
- Live-check an X-Ray fix on an APFS clone (`cp -cR`) of the affected project with a QA copy of the Debug
  build (own bundle id); do not click through it while Boris is using the machine.

## A bug without a repro pair: try the project's own data (BUG-017, 2026-09-30)
- The first attempt reviewed the comparator against its spec, found them consistent, and stopped for lack of an
  example. The spec itself was the bug: front matter dates name a day, so a day's issues tie, and the "deterministic"
  title tie-breaker listed them alphabetically — nothing like the filing order the user expected.
- Rule: when the user says the order or result "is not what I did", run the code over the real data at hand
  (this repository's `docs/bugs` reproduced it in one pass) before asking for examples; and judge a tie-breaker
  by what the user would expect, not only by whether it is stable.

## A "fixed" bug reported again: find the path the user actually used (BUG-022, 2026-09-30)
- BUG-021 made the toolbar's assistant choice per project, and the code for that path was correct. Boris
  reported the same symptom again. The stored settings showed it: `project.ai` held two projects' choices,
  while the defaults (`settings.cli.*Model`) had been edited several times — he changed the model in DDE
  Settings, whose picker still bound the default keys, and the single Settings window stayed bound to the
  first window that opened it.
- Rule: when a fixed bug comes back, do not re-verify the fixed path; list every UI that edits the same
  state (grep the keys and the `@AppStorage` bindings) and read the stored data to see which one wrote it.
  A shared singleton window must be rebound to the workspace that opens it, not to the first caller.
- Standalone harnesses drift: `CLICompletion.swift` gained `LinkedFolders` and `AICallLog` after
  `project-ai-choice-tests.sh` was written, so the harness no longer compiled. Run the relevant
  `tools/tests/*.sh` before committing and add the new files or stubs to the script.

## Harness checks must not pin facts that drift with unrelated edits (2026-09-30)
- `xray-content-tests.sh` asserted that `arch-container` sits on line 1430 of `index.html`; four unrelated
  edits later it was on 1434 and the check failed on `main` for everyone. Nobody noticed because the harness
  is run only when its module changes.
- Rule: derive such expectations from the fixture at run time (find the line in the file) or pin a copy
  of the fixture under `tools/tests/`; and run every harness touching a changed module before committing.
- The Book X-Ray builder was checked by replaying it over this repository's `docs/` (821 chapters in 0.7 s)
  before any UI existed — the same "run it over the real data" rule as BUG-017.

## The first picture decides whether a map is readable (Book X-Ray, 2026-09-30)
- The Book opened with every part expanded and all AI-found links drawn: 43 chapters in 8.5 px type under
  233 dashed arrows. Boris: "вообще не понятно, о чём книга" — although every box carried its text.
- Rule: size the default view to what a reader can take in (a handful of containers with their blurbs), draw
  the dense AI-inferred relations only around the selected box, and check the result on a real folder of the
  user's size before shipping, not on a 5-document fixture.

## Scripted edits: never open a file for writing before reading it (2026-10-01)
- A Python edit ended with `open(p,'w').write(open(p).read())`: `'w'` truncates before the read runs, so
  `WorkspaceManager.swift` (4,500 lines) became empty. It was restored from `HEAD` and the edits replayed.
- Rule: read into a variable, edit it, write once; one script per file, with `assert old in s` per replacement,
  and check `git diff --stat` after any scripted edit of a large file.

## Live checks without disturbing Boris: a QA copy driven through Accessibility (2026-10-01)
- A QA copy (own bundle id and executable name, e.g. `MarkViewQA`) opened with `open -g -a <app> <folder>` stays
  behind Boris's windows. Menu commands that target the focused window do nothing in a background app; press
  the window's own controls via System Events (`perform action "AXPress"`, then `click menu item`).
- Capture only that window: `screencapture -o -l<id>` with the id from `CGWindowListCopyWindowInfo` filtered by
  owner and window title. A region capture grabbed whatever was on top (private data) — never use `-R` for this.
- WebKit does not paint a page in an occluded window until something forces a redraw; a blank web area in such a
  capture is not a bug by itself — confirm with a standalone WKWebView `takeSnapshot`.

## Proving "never starts X": make X impossible to start (2026-10-01)
- electron-vite's `dev --rendererOnly` reads like "renderer only", but its source still calls `startElectron`.
  `vite-plugin-electron/simple` returns a promise of plugins, so a name filter over the plain array missed it and
  Vite rebuilt main and tried to launch Electron.
- Rule: read the tool's source for flags that promise "only X"; test with Electron's binary absent
  (`ELECTRON_SKIP_BINARY_DOWNLOAD=1`) so any start fails loudly, and flatten nested arrays *and promises* when
  filtering Vite plugins.

## An AI loop must write its outcome back into what it reviews (BUG-023, 2026-10-04)
- Review → resolve → review never converged: each resolution added a decision next to the requirement but left
  the requirement text unchanged, so the next review reported the pair as a contradiction. Resolved findings
  were also visible to the reviewer only by title, so the same concern came back reworded.
- Rule: when an AI step settles something, write the settlement into the artifact the next AI step reads
  (here: rewrite the requirement), and give the reviewer the settled items with how they were settled plus an
  explicit "empty is the expected result". Check convergence on real data: count what each round produced and
  read the new findings' titles — "X contradicts Y" findings mean the loop is feeding itself.

## "Skip if already running" is wrong when the caller needs the result (BUG-024, 2026-10-04)
- `applyDecisions` returned when another apply was running; that suited a second resolution but not a review,
  which then read requirements mid-rewrite and filed a false finding. Rule: a step whose caller depends on its
  outcome must wait for the running one (serialize), never skip it. Check the AI call log timestamps
  (`ai-calls.jsonl`) when a finding contradicts the file as it is now.
- Never reuse an id that something may still reference: derive the next number from existing files and every
  mention in the feature.
- A reviewer that may ask for any missing detail never runs dry, because every answer adds detail; give it the
  same "the implementer decides" boundary the question round already has.

## Don't tie a feature to how a third-party client spawns processes (BUG-027, 2026-10-05)
- MCP-server discovery relied on MarkView being an ancestor of the server. Cline on this Mac spawned servers from
  the terminal process; on the work computer the same Cline ran them in a background hub under launchd, and the
  tools vanished. The check here passed only because this machine's client behaved one way.
- Rule: when a feature depends on a client's process model, add a path that does not (here: the app's socket +
  the agent's working folder), and give the user a one-command diagnosis to run on the machine you cannot see.

## Never take a full-screen screenshot while checking a second app instance (2026-10-11)
- To find out why clicks did not reach the test instance I ran `screencapture` of the whole screen; it captured the
  person's other windows (calls, project documents, another browser's password page). I deleted it at once and did not
  use it, but it should not have been taken.
- Rule: capture only the test instance's window (`screencapture -l<window id>`); list windows by owner name and number
  only (no screenshots) when something else may be in front.

## A status must say what and why, and sit on the thing it describes (2026-10-12)
- The AI-activity chip (4.38.0) showed "Thinking" and appeared once in the toolbar for a window with several agent tabs. Boris: "Thinking" means nothing; each tab needs its own status; show the task and what is being done.
- Rule: a status text names the task and the concrete step (the agent's own last sentence, else the tool and its target); a bare state word ("Thinking", "Working") is never enough. A status for several items (tabs, files, jobs) belongs on each item, with the toolbar only summarising.
- Check a new indicator against the multi-item case (two tabs, two windows) before calling it done, not only the single-item one.

## A new control in a view must be clicked once in the running app
`ImageViewerView` used `@EnvironmentObject` that its parent never injected; it built and rendered, and only crashed on the first click. A build and a screenshot do not exercise actions: click every new control in a second instance, and check that the view's parent supplies every environment object it reads.

## A server's working folder is not the agent's when a shared daemon starts it (Cline hub, 2026-10-14)
BUG-027 routed agent tools by the MCP server's cwd. Cline starts every session's servers from one hub daemon whose cwd is the first project's, so all Cline sessions landed in one window, and project tools could write into the wrong project. Check `ps -o ppid`/`lsof -d cwd` of the live server before trusting its cwd; when the process cannot know, make the agent say it (a tool argument) and refuse to guess between windows.

## Discussion was built as "question -> Insight page", but Boris meant a conversation (2026-10-23)

- Boris: "this is Insight, it is nonsense; a discussion is a talk with the AI (voice too) about a file, folder or the whole
  project; the answer takes the form the question needs: only text, or an architecture picture, or a pros/cons table, drawn
  inline while it answers. A visualization of the conversation."
- Cause: I reused the nearest existing feature (Insight) for a new concept after one short description, and offered a plan
  that named it ("answers as Insight pages") without checking that the picture in his head matched.
- Rule: when a request is a new concept built from words like "formalize", "UI-ize", describe the experience in one concrete
  scene (what he types, what he sees) and confirm it before choosing which existing feature to reuse.

## An empty array passes every `as? [T]` cast (Discussion crash, 2026-10-24)
A helper taking `Any` and testing `value as? [DiscussionTurn]` matched the empty `[[String:String]]` it had just built, so it recursed until the stack overflowed (4.52.0 crashed on a discussion with no turns). Never dispatch on `Any` downcasts of collections; give each shape its own typed call.

## A Unix socket path over 104 bytes binds nothing, and HOME does not move the app's data (control server live test, 2026-10-25)
The scratch MarkView launched with `MARKVIEW_SOCKET_DIR` under the session scratchpad listened on nothing: `sun_path` holds 104 bytes and `bind` failed quietly (`listen(at:)` returned false). Use a short directory (`/tmp/mvctl`) for the socket folder. `HOME=…` is also ignored — `NSHomeDirectory()` and the Application Support folder stay the real ones — so a second instance shares `windowSessions.json` and `markview_debug.log` with the running app.
- Rule: run a test instance with its own bundle id, a short `MARKVIEW_SOCKET_DIR`, and `sandbox-exec -f profile.sb` denying writes to `~/Library/Application Support/MarkView`, `~/Library/Caches/MarkView` and `~/markview_debug.log`; never rely on `HOME`. Kill it only after `ps -o command=` shows the scratch path.

## "Unable to read project" after a hand edit is the edit, not the machine (2026-10-25)
After adding files to `project.pbxproj`, `xcodebuild` printed "CoreSimulator is out of date" followed by "Unable to read project". I took the CoreSimulator text for the cause, "confirmed" it on the clean tree by looking at `xcodebuild -list | head -8` (which cut off the verdict), and wrote it up as a broken machine, even in a PR description. The warning appears on every run and is harmless; the project was unreadable because of my edit (see the lint lesson). The clean tree was fine all along.
- Rule: never conclude "the environment is broken" from truncated output. Look at the last lines of the real run (`tail`, or the exit code) for the clean tree and for mine before blaming either, and lint a hand-edited project file first.
- A scratch build without xcodebuild also works when needed: `swiftc -Onone -parse-as-library -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos13.0 $(find MarkView -name '*.swift') -o X.app/Contents/MacOS/MarkView` with an Info.plist (variables substituted), `Resources/Editor` and an ad-hoc `codesign --entitlements MarkView/MarkViewDebug.entitlements`.

## A status heuristic must give a screen redraw time to settle before refusing (agent_send, 2026-10-25)
`markview_agent_send` refused a Claude that had just come up ("working (printing)"): pressing Enter on its trust prompt redrew the screen, which counted as work for the next 3 s. A refusal based on "printed in the last N seconds" waits for quiet (up to a few seconds) before it says no.

## A file added to project.pbxproj by hand must lint, and a lint failure is not noise (4.56.0, 2026-10-25)
I added four files to `project.pbxproj` and `plutil -lint` printed "Unexpected character / at line 1". I put it down to the `// !$*UTF8*$!` header without linting the file from before my edit, which says OK. The real cause: `path = ControlToolRunner+Agents.swift;` — a name with `+` must be quoted (`path = "…";`, as `ProjectToolRunner+Edit.swift` is). CI then failed with "Unable to read project". The 4.56.0 merge had to be repaired by 4.56.1.
- Rule: after editing the project file by hand run `plutil -lint MarkView.xcodeproj/project.pbxproj` (must say OK) and compare any failure with `git show HEAD:MarkView.xcodeproj/project.pbxproj`; quote paths with `+` or other non-alphanumeric characters; check that every new file has its four entries.

## GitHub's compiler (Xcode 16, Swift 6.0) rejects long `+` chains the local one accepts (CI red since 4.54.0)
`Build & Release` failed on main three times with "the compiler is unable to type-check this expression in reasonable time" (`ProjectToolRunner.swift`: `"…" + list.map { "…" + (cond ? a : b) + "…" }.joined() + "\n"`). `-warn-long-expression-type-checking` on the local Xcode flags nothing, so only CI shows it, and only after the merge (the workflow runs on push to main only).
- Rule: do not build strings from three or more `+` operands that include a ternary, `??` or a closure; use `var text = …; text += …`, a local for each ternary, and string interpolation. A `map` over a list gets a named closure parameter and an explicit `-> String`.


## A source map must be checked on a real codebase, not just a small fixture (2026-10-31)

Code architecture 4.62.0 worked on a five-file shop, but its MarkView self-analysis produced a
flat catalogue, glob ownership and file-header citations. An inventory plus permission to read
files does not ensure that the answer uses implementation evidence. Supply bounded, numbered
source excerpts; balance languages/folders; request responsibility depth and exact paths; give
repairs the complete prior model and all affected issues. Validate dependency evidence against
the actual endpoint ownership. Inspect the first rendered overview on real data: show stable,
readable layers and reveal dense dependencies around a selection. Test Hide tests before any
Logical enrichment, since that pass used to be the only producer of path tags.

## A change observer must not live in a view that is only sometimes on screen (Agents tab title, 2026-11-02)
`AITerminalPanel` watched the toolbar's model choice, but a `switch` in `TOCView` builds it only while the Agents navigator tab is
open. A model picked on another tab was never seen, and `onAppear` reset the "seen" value, so the tab kept the old title and the agent
the old model for good. Rule: when a view mirrors state that can change while it is not mounted, reconcile from the state itself on
appear (compare what runs with what is chosen — idempotent) instead of relying on having seen the change event. Compare the one
value that matters (the model), not a derived string (the whole startup command also changes with linked folders and tools).

## The final result of a speech recognizer may be only its last window (built-in dictation, 2026-11-02)
`SFSpeechRecognizer` works in windows of about a minute: each finished window arrives as its own result, and the result with
`isFinal` holds only the last one. Taking `isFinal` alone returned 27 s of a 207 s recording (392 of 3023 characters) with no error.
The short test phrases passed; only a recording longer than a minute showed it. Rule: test a recognizer, uploader or any streaming API
with an input longer than its documented or suspected chunk size (here the app records up to 10 minutes), and print every callback
(`isFinal`, size, time range) before trusting the first one that looks final. Run the *production* source in a throwaway signed probe
app (own bundle id, so its TCC grant is separate); remove it afterwards, because `tccutil reset` needs the app to still exist.

## A file open already gets a new window per URL; test against the installed build, not a guess (Finder file view, 2026-11-02)
I assumed an external file open lands in the active window and designed "blank window takes it, else open a new window". The first live
runs showed an extra blank window after a two-file open and I could not tell whether my code made it. Copying the installed app under
another bundle id (`ditto /Applications/MarkView.app`, `plutil -replace CFBundleIdentifier`, ad-hoc `codesign`) gave the baseline in two
minutes: 4.64.0 does the same (SwiftUI opens one window per URL of an open request; the blank one takes the request). The debug log
(`openInActiveWindow (trigger, window empty: …)`) then showed which path ran.
- Rule: when a window count or placement looks odd, run the same steps on a baseline copy of the shipped build before changing code; add
  the one log field that tells the branches apart and keep it.
- Scratch launch that works: `open -a <abs path>/Scratch.app <file>` (LaunchServices; one instance, own bundle id). A binary started
  directly under `sandbox-exec` registered but never showed a window. The LaunchServices launch is not sandboxed and writes lines to the
  real `~/markview_debug.log`, and `tccutil`/defaults need the same bundle id removed afterwards (`defaults delete`, remove
  `~/Library/Application Support/MarkView-<id>`, `lsregister -u`). Window ids for `screencapture -l` come from
  `CGWindowListCopyWindowInfo` filtered by pid (cast `kCGWindowOwnerPID` through `NSNumber`).
- A per-window layout the app sets (not the user) must not be written to the shared UserDefaults default: `showFileTree.didSet` did, and so
  did the window restore, which would have turned one Finder-opened file into "no file tree" for every later window.

## A feature that can fail silently is not done: every outcome needs something on screen (built-in dictation, 2026-11-02)
4.64.0/4.65.0 shipped dictation without a key, and the first report from another Mac was "the microphone turns on, I speak, nothing
appears". The terminal mic dropped an empty transcript without a word and showed errors only as a hover tooltip, so "no model", "Dictation
off", "muted input" and "wrong language" were indistinguishable from each other and from "it works but heard nothing". I had tested the
recognizer on synthetic speech on one Mac, never the failure paths on screen.
- Rule: before calling an input feature done, list every outcome (success, empty, each error, silent input) and make each one visible where
  the user is looking (not only a tooltip); name the setting that decides the result (here the language, which built-in recognition cannot
  detect); and tell silence in the recording from silence in the recognizer by measuring the recording.
- A hardened-runtime question can be answered locally: an ad-hoc probe signed with `--options runtime` and the shipped entitlements
  (`codesign -dv` shows `adhoc,runtime`) behaves like the notarized build for Speech/microphone entitlements.
- `tccutil reset <service> <bundle id>` fails ("No such bundle identifier") once the probe bundle is deleted; reset before deleting it, and
  from a path LaunchServices knows (not always the case for bundles under /private/tmp).

## Bug status is a merge event, not a checklist item; keep the integration driver alive (bug audit, 2026-11-02)

Nine bug fixes were ready in worktrees, but the statuses stayed `fixing` for an hour and Boris asked twice what was going on.
The merge driver ran as a background shell of the session and died with it; the status files live in the fix branches, so
nothing moved until each PR merged. A `git reset --hard` on the shared main checkout also wiped locally set statuses.

- Set `fixing` through MarkView when work starts, and let the fix branch carry `fixed`; never hand-edit the status in the
  shared checkout.
- Write the PR body before queueing a branch; a missing body file stopped the whole queue.
- Tell Boris the pipeline shape once (sequential PRs, ~5 min of CI each) so a quiet hour reads as progress, not a hang.


## A stand-in that writes its own confirmation proves only the app side (model memory, 2026-11-03)

I checked the new Agents model menu against a stub `claude` that read the typed line and wrote the "Set model to …" log entry itself, and
reported "works". Boris asked "Are you sure?": the stub proved MarkView's side (paste, title, remembered value) and nothing about the
real CLI. A 30-line pty script then ran the real Claude Code, pasted `/model sonnet` with the bracketed-paste markers and Enter, and read
the answer, with the saved default unchanged because the value was the one already stored.

- Rule: before saying a feature works, name the contract with the outside program and test that contract against the real program
  (a pty is enough for a CLI); a stand-in only covers what the app does with its answer.
- The same run showed a bug the stub hid: the activity parser counted the CLI's own command entries (`<command-name>`, `<local-command-*>`)
  as work, so after `/model` the agent looked busy and the new menu stayed off. After a new action, check the state it leaves behind.
- A per-agent action must act on that agent's session. The panel's observer follows only the project's own assistant, so a pick in a Copilot
  tab beside a Claude project changed a stored value and restarted nothing.
- Clean up test files by identity (the session id the run itself reported, or the registry file of its pid), never by a heuristic such as
  "small, recent, only commands": that also removed a 2.6 KB `/model`-only transcript of another session.
- The AX walker of a scratch run answered "not found" for menu items that were on screen; check the harness (list, then press in one process)
  before suspecting the app.

## 2026-11-03: BUG-050, a prototype of a large app far from the original

- A user message that arrives while a tool call is running is a request, not noise. I answered one ("the prototype is infinitely far from the
  original") with "No response requested" and only handled it two turns later. Read every message that interleaves with a tool result, and
  acknowledge it in the same turn.
- Count before you trust a summary: the planner "saw the project" but was given 400 of 891 files sorted by path, so it never saw the widgets or the
  theme. Run the real function on the real data (`inventory` on broker-fabric) before designing the fix, and keep the number in the bug report.
- Bug ids collide when several sessions work in one repository: another session took BUG-049 while I held an untracked report with the same id.
  Before creating or finishing a bug, `git fetch` and look at `docs/bugs/` on `origin/main`; rebase early, not at the end.
- When a reviewer judges fidelity ("infinitely far"), a bigger prompt does not help; give the model the original artefacts that can be copied
  verbatim (CSS, fonts) and let it write only what cannot be copied (one screen per widget, read from its whole source file).
- A planned step may be changed when its cost is out of proportion (a second planner pass re-emitting 26 entries); say so in the plan and the report
  instead of implementing it silently, and keep the cheaper measurement honest (named or read, not "reproduced").


## 2026-11-03: BUG-051, a request for the whole prototype cannot be one answer

- Size the *result* before designing a request: "Convert all preview to english" meant new text for 45 files (about 450 KB), more than one
  structured answer holds. The build already fans out per screen; revise had to do the same, not get a bigger prompt. A router answer that
  lists the files (`remaining`) plus one run per file keeps the read-only runs, the atomic `apply` and the versions unchanged.
- Never throw away what the model said: an empty change with a `summary` is an answer ("nothing to change" or "too big"), and the generic
  "no files, edits or deletes" error hid the only evidence. Show the summary; keep an error for a truly silent answer.
- When the log holds only metadata (`ai-calls.jsonl`: tokens and seconds), replay the exact request on the real CLI. The system prompt can be
  read out of the Swift source with a regex, so the replica cannot drift from the app. Two replays showed "2 and 4 edits, says incomplete",
  one replay of the fixed prompt showed the router listing exactly the 45 files measured beforehand.
- Check a setting before blaming it: "the language note contradicts the request" was refuted by one `defaults read` (the key was unset, so
  the note was empty). The Russian text came from a prompt that never states a language, not from a setting.
- A pure core (`PrototypeFiles.applying`) lets a run that owns one file be checked in memory, so a sweep writes once at the end and a
  cancelled one leaves the site as it was. Also tolerate junk in model lists (`as? [Any]` + `compactMap`): one non-string element turned a
  whole `remaining` list into nothing until a unit test caught it.
- Boris asked "why not use the agent process?": the answer was in the code (`CLICompletion` is read-only by design, `apply` is the only
  writer). Look for the recorded invariant before answering, and say what it buys (atomic apply, versions) and what the alternative costs.

## BUG-052: a prompt that leaves the language open lets the model pick it
- A reconstruction copies text, so the language of the original is part of the data. With the output language on "Document language" nothing was
  appended to any prompt and the model chose Russian for an English application. Decide the default explicitly in the prompt
  (`PrototypeAI.sourceLanguageRule`) and let an explicit setting or the reviewer's request override it; never rely on the model to infer it from
  the project, whose documents may be in another language.
- A record-writing tool call (`markview_add_decision` and the like) with a malformed parameter list can still succeed and store the stray markup as
  text: read the record back (`markview_get_feature` with `id`) after every write and repair it with `markview_update_object`.

## BUG-053: check what a screen shows, not only that its file exists
- "No JavaScript error" is not "it works": a render function that returns an empty element, or an `App.load` that swallows its callback's error into
  a card, throws nothing. Verify generated UI by looking at the page (`PrototypeAudit` opens every route and measures what each adds to the shell),
  and verify generated files by content (a comment-only file has the right path and is still a stub).
- Validate a heuristic against a real artefact before trusting it: the audit run on the real strikedesk v8 found Trade, Transport and Trade journal;
  the fixture alone would have passed a weaker heuristic.

## Themes: a new manifest field must be added to the lenient decoder, and a heuristic must meet real data
- `PrototypeFiles.Manifest` decodes through a hand-written `init(from:)` (so old files open); a new stored field that is not added there is silently
  dropped on every load. A round-trip test (`encode` then `decode`, field still there) caught it; write that test with every new manifest field.
- The first scanner pass looked right on the fixture and found 3 of StrikeDesk's 4 themes: the base theme (`dark`) is `:root` with no attribute
  selector. Only running it on the real stylesheets showed that; the planner now also reads the theme ids and the default from the source.

## Sync baseline: record what a unit was built from, and prove the mapping on a real plan
- The plan's `evidence` and `components` are the only unit → source mapping there is; a unit built from files the model never listed cannot be tracked,
  so every unit carries `incomplete` and shows as "unknown" instead of "in sync" when its sources are not fully known. Never report "in sync" on a guess.
- Check a new module against a real model run, not only fixtures: the real plan listed the three files of a small app for both screens, so one edit
  marked both screens as changed, which is true but invisible in a one-file fixture.

## Feature status: the app moves it, not git
- MarkView sets a feature to `implementing` only when the feature is handed to implementation inside the app ("Create issues", "Implement with AI");
  later statuses follow the linked issues. `markview_set_status` stops at `ready` on purpose, and `docs/features/*` must not be edited by hand.
  Implementing a feature in my own branch and PR leaves it showing `Ready` (Boris asked why, 2026-11-03).
- Boris then allowed setting it myself (2026-11-03): the tool refuses `implementing`/`implemented`, so edit only the `status:` line of the feature's
  `overview.md`, set `implementing` when work starts and `implemented` once the release is published, and check it with `markview_list_features`.
- Before starting a feature outside that flow, say so. Name the branch `feat/<feature-slug>`
  and put the slug and the REQ ids in the PR description. State the real status of the feature in the final report; never let `Ready` stand for "built".

## Incremental sync: a unit rebuilt alone still leans on files nobody rewrote
- The first real run of the incremental sync rewrote both screens but the new order added in the source never appeared: the sample rows live in
  `data.js`, a shared foundation file the sync does not rebuild, and the screens read them from `DB`. A fixture with a stub assistant cannot show
  this. After adding an incremental path, run it once with the real assistant on a change that touches data, not only on a label.
- When a shared file cannot safely be rewritten, say so to the writer (here: define missing data inside the screen), to the person (reply and
  sheet) and as an open question (Q-005), instead of letting a green status imply the prototype matches the code.
- Keep scratch files in the session scratchpad; a helper written to `/tmp` had to be deleted by hand.

## Web app discovery: a monorepo hides its apps below the scan depth
- Discovery (`WebAppPreview.targets`) only listed the root and two levels, so an Electron app at `apps/strikedesk/app/packages/shell` was never
  offered, and its `rspack serve` renderer script was unknown anyway. Check both when an app "is not found": where it lives relative to the scan, and
  whether its dev server command is recognised (`servesWebOnly`). Run the app's own function on the real project (`swiftc` with `WebAppPreview.swift` and
  a three-line main) instead of reasoning about it.
- Workspace packages share the lockfile of the workspace root; look for it in the parents, not only in the package folder.
- A standalone test script can rot unnoticed because CI does not run it: `web-preview-tests.sh` had not compiled since `BrowserSession` grew new
  dependencies. Run the script you extend before adding checks, and fix its file list if it fails for reasons unrelated to your change.


## Prototype audit: text in the DOM is not text on screen
- The audit only checked that text existed, so the option desk (the main widget of strikedesk) passed it while every row sat inside
  `flex:1 1 0; min-height:0; overflow:hidden` boxes that collapsed to 0 px under a host of automatic height. A check of "content exists" needs a
  geometry check beside it: measure the boxes that clip (overflow not visible and under 8 px) before calling a screen fine.
- Verify a new audit rule on the real prototype first (copy the site, inject `PrototypeAudit.script` in headless Chrome), then on a fixture with
  negative cases (a scrolling table, an `aria-hidden` list, a folded panel) so it does not cry wolf.
- A harness that compiles models from the main working tree silently runs the OLD code when a fix lives in a worktree: `report(from:)` dropped the
  unknown kind and the repair round got no findings. Compile the harness from the worktree that holds the change, and check that its first output
  shows the new behaviour before trusting the run.
- Never `defaults read <domain> | grep ...` for a key you only suspect: it can print a credential. Read one named key.


## A separate process does not see the app's settings: read the real preferences file
- BUG-057 took hours because every headless planner run answered in English: the setting that caused the Russian (Output language) lives in the
  app's preferences, and a harness process has its own. Before concluding "the model ignored the rule", list what the app adds to the prompt:
  grep for every setting that reaches the prompt (`ActionOutputLanguage.current`, `ProjectAIChoice`, model and backend keys) and read their values.
- `defaults read com.markview.MarkView` from this shell returned a 10-key container copy; the real file has 150 keys. Read
  `~/Library/Preferences/com.markview.MarkView.plist` with `plistlib` (print key names and the single value you need, never the whole file: it holds API keys).
  A "key absent" answer from `defaults` is not proof; I wrote a wrong fact into a bug record because of it.
- A harness that re-implements a call (my `PrototypeCLIStub`) hides differences; compiling the real `CLICompletion.swift` with tiny stubs (`SemanticDatabase`, `AICallLog`) took five minutes.
- A test that persists state outside the repository (WebKit data of `prototype-runtime-tests`) passes once and fails the next time; give such harnesses a non-persistent store.

## Move the bug status at every stage, and carry the status files into the PR
- Boris reminded me (2026-11-03) to change bug statuses in MarkView while fixing. Set `fixing` when the work starts (`markview_set_bug_status`), `fixed`
  only after the release is verified, and do it for every bug the release closes (BUG-057 and BUG-058 were still `fixing` on `main` after their releases).
- The MarkView tools write into the main working tree, not into my worktree. Copy the changed `docs/bugs/BUG-nnn-*.md` into the branch of the next PR
  (`diff` first: only the status line should differ), otherwise `main` keeps the old status.

## Measure a heuristic on the real data before wiring it in, and with the real haystack
- BUG-059: my first measurement said the option desk showed 22% of its source's labels, so I planned a 40% threshold. The Swift module with the same idea said 51%
  and flagged only the settings window, because I had added the shared `data.js` to the text it searched, and `data.js` holds the words of every screen. Running the
  module on all 22 screens of the real prototype before wiring it in found that; without `data.js` it named exactly two screens (trade 32%, settings 9%).
- Rules: run a new check over every real unit before choosing a threshold; read the missing list for noise (it showed `0 && diff`, code from a JSX comparison); say in
  the code and the report that the threshold was chosen on the same data; and prove the repair on a COPY with the real assistant (here 32% to 92%, 9.4 KB to 42 KB)
  and a headless render next to the real screenshot, not only with synthetic fixtures.


## "No longer raw HTML" is not "looks like the real app": compare with the real render
- BUG-063 shipped in 5.13.2 with a screenshot of a styled vivaa gallery as proof. Boris's next report (StrikeDesk OptionDesk, BUG-065) showed that "styled" was
  the wrong bar: his requirement is the real result, pixel for pixel. I had never put a prototype screen next to the real application's render.
- Before saying a visual defect is fixed, render the real application (its own dev server or build, with a stub for what it needs from the host) and the prototype
  at the same viewport, look at both, and list what differs. A probe took 15 minutes: the real built StrikeDesk renderer in headless Chrome with a stub of
  `window.strikedesk` already showed the full-height vertical tabs, fonts and colours that the prototype lacked.
- When a report names one screen, check the cause list in the project's own files first (which stylesheets are linked, which fonts exist), not only the generic
  mechanism: the OptionDesk stylesheets were copied but linked from no page.

## A narrow rule needs a broad real corpus, and a text lint must read what the defect needs
- BUG-064: my loader lint of 5.13.1 flagged 7 of 40 vivaa screens because it read a retry handler (code that runs later) and ignored what the callback returns.
  A defect that has two halves (clear the host, then return it or its children) is found only by reading both halves, and only in code that runs before the
  callback returns. Tested on 12 screens it looked clean; the 40-screen prototype of the next report broke it.
- Run a new check over every real unit available (all prototypes on disk) before shipping it, and say which corpus it was checked on.

## A model file that gains a dependency breaks every standalone test that compiles it
- Bug validity check (5.14.0): `BugReport.load` in `FeatureModels.swift` started to read `BugValidity.sectionName`, and `tools/tests/feature-discovery-tests.sh`,
  which compiles `FeatureModels.swift` on its own with a fixed file list, stopped compiling. The app build was green, so only running the neighbouring suites
  found it.
- After adding a type to a model file, `grep -l <file> tools/tests/*.sh` and run each suite that compiles it, not only the new test.

## Check a prompt against the real assistant, not only against fakes
- The validity check was tested with fake answers (evidence rules, order of steps) and then once with the real `claude` CLI on an export of main: two fixed bugs were
  closed with evidence that exists, an open one stayed open, and a report about a feature that does not exist came back inconclusive ("not found" is not proof).
  A throwaway harness that compiles the model file with a small `main.swift` is enough; keep it in the scratchpad, not in the repository.

## `exec` in front of a shell command line changes what the exit status means
- UI Studio started the dev server as `/bin/sh -c "exec <command>"` to make the server the group leader. For a compound command
  (`npm run build && npm run dev`, `cd web; vite`) `exec` replaces the shell with the first part only, so a server that failed in a
  later part was reported with the status of the first (exit 3 read as 0). The standalone check caught it; the app build could not.
- Start a user's command line with `/bin/sh -c <command>` as it is and put the process group on the shell (`POSIX_SPAWN_SETPGROUP`);
  signal the group with `killpg`. Pass the working folder as `$1` (`cd -- "$1"`), never by building it into the script.

## A main-frame load blocked by a content rule list fails with WebKitErrorDomain 104
- Navigating the UI Studio preview to an address the connection policy blocks does not reach `decidePolicyFor` as a normal load: it
  fails in `didFailProvisionalNavigation` with WebKitErrorDomain code 104 ("blocked by a content blocker"). Treat 104 as "blocked by
  the policy" and report it, not as a network error. Test the compiled rule list in a real `WKWebView` with a look-alike host and
  another local port, because only WebKit decides what a `url-filter` matches.

## Zoom a WKWebView by scaling its bounds, not with pageZoom or magnification
- `pageZoom` is browser zoom: it changes the CSS viewport (`innerWidth`), so a zoomed-out preview lays the page out differently,
  which PRE-03 forbids. A container whose bounds stay at the page's viewport and whose frame is viewport × zoom keeps `innerWidth`
  and maps clicks correctly; check it with real `NSEvent` clicks in a window at two zoom levels.

## Harness clicks through `window.sendEvent` depend on which window has the focus
- The session harness first clicked the preview with synthetic `NSEvent`s sent to its window; one run passed and the next, with no
  code change, failed because select mode never got the click. On the CI runner `NSWindow.sendEvent` dropped every click in the
  page harness too (the test window never becomes key): hit test the point in the window and call `mouseDown`/`mouseUp` on the view
  that was hit, which still checks the zoom mapping. A check that is about the session (select without action, then ask and change) dispatches a DOM click; the
  native-click path under zoom is covered once, in the page harness, where the window is ordered front and key.

## The CI compiler is not the local one: a clean local build does not prove the CI build
- UI Studio built in a few minutes locally (Xcode 27.2) and with `-warn-long-expression-type-checking=15` showed nothing, but Xcode
  26.6 in CI stopped on one per-pixel expression ("unable to type-check this expression in reasonable time"), and Build & Release,
  then pinned to Xcode 16, needed 26 minutes instead of 12. Keep mixed integer conversions in typed steps in hot loops, push early
  so CI compiles the branch, and do not read a long CI step as a hang before comparing it with earlier runs of the same step.
- A windowed test harness on a runner must print unbuffered (`setvbuf(stdout, nil, _IONBF, 0)`), name its steps and stop itself
  with the last step after a time limit; a cancelled step otherwise leaves an empty log.


## A selection is identified by what it is, never by where it was (BUG-068)
- A positional `tag:nth-of-type(n)` selector survives no layout change: when a restore brings back a consent banner, the old path
  leads to the banner's button. Revalidating "the only element on that path" then edits the wrong component. Keep a fingerprint
  (tag, classes, component, source node, own text) and accept a candidate only when it matches; when nothing matches, keep the
  element as it was selected and say so instead of substituting another one.

## Framework data requests belong to the development server (BUG-070)
- Next.js `router.refresh()` and `<Link>` fetch `/?_rsc=…` with an `rsc` header; server actions post with `next-action`. Sent to
  the simulator, they waited for rule preparation and failed, and Next.js then reloads the whole page. Next 16 also serves cached
  server fetches in development unless the request says `cache-control: no-cache`.

## React 19 + Turbopack: map the debug stack through the chunk's source map (BUG-069)
- React 19 dropped `_debugSource`; `_debugStack` points at a bundled chunk under `/_next/static/chunks/`, which is not a project
  file. Turbopack serves `<chunk>.map` as an indexed map (`sections`) whose sources are `file://` URLs. Decode only up to the
  wanted line; a 400 KB app chunk maps in a few milliseconds. A static server that serves a build from the app folder makes the
  chunk look like a project file: treat scripts in bundler output folders as generated.

## A page loaded during recording gets a fresh runtime (BUG-071)
- Any switch the session flips in the current page (recording, selecting) is lost when the application loads another page. Put
  it in the runtime configuration and reinstall the user script when it changes. Replays that may cross a page load must run
  step by step from Swift; count `didCommit` to tell "the step loaded a page" from "the step failed". WebKit has no public error
  code for "the page that ran this script was replaced".

## Next.js 16 refuses a second `next dev` in the same folder
- `next dev` takes `.next/dev/lock`; a second server for the same app exits with "Another next dev server is already running in
  this directory". UI Studio cannot start its own server (with simulated service URLs and the test clock) while the person's own
  server runs; it can only use that server as it is, and must say so.

## `gh release create` can fail with HTTP 500 while release.sh still exits 0
- After notarization the publish step printed `HTTP 500` and no release existed. Check `gh release view v<version>` after every
  publish; rerun only the `gh release create` line from the same clean worktree (the DMGs are already stapled).

## A test clock in the past breaks file watchers (DEC-006)
- webpack's watchpack compares file times with `Date.now()` at the start of a watch. Under a test time in the past every recent
  file looks changed, so the server rebuilds without end. Replacing `Date` in a whole Node process is too wide: the preload now
  moves the clock only inside the async context of a server `request` event (AsyncLocalStorage), so builds, watchers and tools
  keep the real clock. webpack still compiles from inside the page's request, so a webpack dev server keeps the real clock and
  the UI says so. Turbopack and Vite do not compare file times with the clock.

## Assistant memory must not reach across sessions (BUG-068, REQ-009)
- Sending the last turns of the saved history would send yesterday's request about another element (the consent banner) with
  today's change, which is how the wrong component got edited in the first place. Show the whole history in the thread, but send
  only the turns of the current session (plus a clarification being answered).

## GitHub can reject a push with "Internal Server Error"
- `git push` printed `! [remote rejected] main -> main (Internal Server Error)` and nothing reached GitHub. Retry, then compare
  `git ls-remote … refs/heads/main` with the local HEAD; do not trust the exit status alone.

## Conflict-resolution scripts and conflict markers in code
- `UIStudioSession.swift` builds undo conflicts with `<<<<<<<` markers in its own source, so "no `<<<<<<<` left" is a false
  failure. Match markers only at the start of a line together with the branch or commit name.

## Fake credentials in test fixtures
- A literal `sk_live_…` (or another provider prefix) in a test file can trip GitHub's push protection. Assemble fake keys at run
  time (`"sk_" + "live_" + …`) so the shape is tested without a key-shaped literal in the repository.

## New optional fields on a synthesized Codable type
- A synthesized decoder fails the whole file when one element of an optional array is malformed, and UI Studio then replaces
  environment.json. Give stored entries a lenient `init(from:)` (unknown enum values fall back, missing fields are empty) and
  check that a file written before the field, and a damaged entry, both still load.

## A test value must keep the shape the libraries check (BUG-073)
- UI Studio gave a JWT secret an unsigned `header.payload.` test value. vivaa's auth middleware requires three non-empty
  segments, failed closed and sent every page to login. A replacement value has to pass the same shape checks as the real
  one: a JWT is signed (HS256 with a fixed test key) and keeps only a known `role` claim.
- The unit test asserted `hasSuffix(".")`, so it pinned the bug down. When a test checks a format, check it against what the
  real consumer accepts, not against what the code happens to produce.

## Application deadlines are shorter than an agent (BUG-074)
- vivaa gives each server call 5 s. Preparing a simulation rule when the request arrives takes an agent 17–30 s, so the first
  render always failed, however long MarkView waited. Prepare the requests a page makes before it loads, save the route as
  prepared, and count a deadline per attempt from when it gets a slot, never including the queue.

## Installing MarkView ends this session and its agents
- The detached install quits MarkView, and the Claude Code session runs in one of its terminals. A background agent of the
  session stopped with it and its worktree was clean, so its work was lost. Install only when no agent is running.

## A readiness probe must not render the page (BUG-076)
- UI Studio decided a server was up when `GET /` returned its whole body within 0.8–1 s. A server-rendered page whose data
  calls wait for simulation rules never does, so the session stayed at Starting. Each probe also rendered the page again and
  started more rule preparations. Probe by TCP connect (`WebAppPreview.firstListening`) and give the first load the compile
  time instead.
- Once the probe returned early, a preparation that finished during the restore reported the session ready before the page
  loaded. A restore owns the state until it ends (`restoringPage`).

## WebKit and the UI Studio log (REQ-011)
- WebKit asks `decidePolicyFor` about a redirect's target before `didReceiveServerRedirect`, so the "from" address of a
  redirect has to be taken in `didStartProvisionalNavigation`.
- `busy` is nil while a session launches, so "state is degraded and busy is nil" does not mean the page has finished loading.

## A model-written rule is checked against the data it serves (BUG-078)
- The agent named `limit` and `offset` as list filters. The simulator applied every named filter by equality, so every list
  came back empty, and nothing told anyone why. The simulator now treats paging names as paging and ignores a filter on a
  field no record has. When a page is empty, read `.markview/studio/environment.json`: compare the rule's filters with
  the request's query, and the seed's foreign keys with the group the page shows.
- A seed of six records was all in one of six categories. Prompts state coverage ("2-4 records for every value the page
  groups by"). A Swift check after preparation is the real guard (REQ-014).
- A preparation prompt that allowed "unsupported" for "a third-party SDK" made the agent refuse a consent write because
  the real route used the Supabase admin SDK. The mock-up policy (DEC-007) has to be stated in every prompt that can
  refuse.
- Never `curl` a dev server that a UI Studio session is using. Each request renders a page, starts preparations and fills
  the log with failures of your own making.

## A runtime that calls the page's handlers must never rethrow their errors itself (BUG-079)
- The UI Studio runtime caught an exception from the page's `onload` of a simulated XHR and rethrew it with
  `setTimeout(() => { throw error })`. The throw then belonged to the user script, which has no URL, so WebKit gave the
  page, its error overlay and our log only "Script error.". Use `reportError(error)` (`surface` in the runtime): the error
  stays the page's own and keeps its message and stack. A harness probe showed that eval'd `webpack://` code keeps its
  message, so that was not the cause.
- When a page says "Script error.", first ask which of our own frames was on the stack, before blaming the bundler.
- The development server's own endpoints must pass, never be simulated. Rspack's lazy compilation is
  `POST /lazy-compilation-using-`. A prepared rule answered it, the server never built the lazy chunk, and the app stayed on
  its loading screen.
- An Electron renderer run as a web page needs its preload bridge simulated (REQ-016). A no-op stand-in hands the app
  proxies instead of data, and it crashes far from the cause.

## "MarkView eats all resources": measure each process before blaming one (BUG-081…BUG-084, 5.26.0)
- Start with `footprint <pid>` and `vmmap --summary` (the physical footprint peak), `/usr/bin/sample <pid> 3`, `top -o cpu`
  for child processes, and `~/Library/Logs/DiagnosticReports/*cpu_resource*.diag`. Here there were three separate causes:
  a 25 GB launch peak in MarkView, an Rspack child at ~700% CPU, and MarkView's main thread busy redacting its log.
- A test clock in the past must never reach a dev server's file watcher (DEC-006). Rspack and Rsbuild bundle watchpack.
  Detect them by their scripts (`rspack serve|dev`, `rsbuild dev`) and keep their real clock. The Node preload also keeps
  dev-server endpoints (`/lazy-compilation-using-`, `*.hot-update.*`, HMR sockets) out of the request clock scope: a server
  can compile inside a page's request.
- A synchronous walk that reads files with `FileHandle.read(upToCount:)` keeps every chunk until its autorelease pool
  drains. In an actor function, that is the end of the walk. Wrap per-file work in `autoreleasepool`. Do not hash large or
  binary files; size, date and file identity are enough to notice a change. Skip build caches and agent worktrees.
- Work that runs on every line of a child's output (redaction, parsing) belongs off the main actor and coalesced to a few
  updates per second.
- A context change can only fill data the prompt shows where it comes from. A page's data often comes from a fixed-answer
  rule (`respond`) registered late among hundreds. The prompt therefore lists the rules that answered the page first, with
  the shape of their current answers. A new body of such a rule is a real change, not a fake, and it must keep every key
  of the current answer. Show answers within a character budget, not a count, so dozens of `{"ok":true}` answers cannot
  push out the one that matters.
- Verify a prompt change against the real project: rebuild the prompt from its `environment.json` and session log, run the
  assistant on it once, and check the answer with the app's own validator.
- 5.26.0 still failed in the app: the assistant refused because the prompt showed the answer with its lists shortened, and
  it believed it needed the hidden items. My check had passed on another model, without the conversation history, once.
  Rules: verify on the tool, model and effort the app uses (`~/Library/Application Support/MarkView/ai-calls.jsonl`), with
  the real history, several runs. A fix must not depend on the model: show small data whole (fixed answers are a few KB),
  and add a deterministic guard. An `unsupported` note that gives up on a fixed-answer rule is sent back once (5.26.1).

## One release for a growing request: keep the plan, the records and the tests in step (research map, 5.33.0)

Boris asked for a bigger scope three times in one session (narrative report, diagram/image nodes with Draw, then translation and
a language choice at export) and wanted a single release.
- When the scope grows mid-release, stop the running build at once (a release build of the old scope is wasted work), write the
  new requirement and decision records first, then extend `tasks/todo.md`; do not publish the old scope "meanwhile".
- Independent pure modules (the report, the translation) go to separate agents with a written contract (public API, failure
  classes, tests that must pass); the wiring that touches shared files (`WorkspaceManager`, the page script) stays with one author.
- A new control must not reuse the class name that tests and code query for another control: the Mermaid source field copied
  `rm-desc` and 15 checks failed at once. Give each control its own class before writing its CSS.
- A hidden WebKit page has `visibilityState: hidden`, so CSS transitions do not advance: a screenshot taken after a theme change
  shows half-way colours (grey toolbar). Switch transitions off in the probe before judging a screenshot.
- The live check of an AI feature runs the module code itself (prompt, schema, parse, check, repair loop, apply) against the real
  CLI on a copy of the real data; a stub of the process layer is enough, and nothing shows a window.

## 2026-11-05 — UI Studio "implementing" for a week, and Fix data (REQ-017)

Boris asked why a feature was still `implementing` and said to close it if all was well. It was not well: REQ-017 was never
built, the criteria of REQ-001 and REQ-010..016 were never ticked, and the status had silently flipped back to `implementing`
in a later commit and stayed there.
- A request to "just close it" is a request to check first: read the feature's requirements, criteria and status history
  (`git log -p -- overview.md`) before touching the status. Close only what the evidence supports; say what is not done.
- Every commit that adds a requirement to a feature already `implemented` moves it back to `implementing`. Put "set the status
  back" on the plan of that release, and tick criteria in the same release that proves them (the check names carry the REQ id,
  so `grep "ok  REQ-0NN"` on the suite logs is the evidence), not later in a batch.
- `main.swift` top-level `let` globals initialise in execution order: constants declared after `Task { await run() }` are still
  uninitialised when the task runs (segfault, exit 139). Declare them before it or keep them local to the function.
- WebKit's `reason.stack` of an unhandled rejection has no message line (`@http://host/app.js:7:89`), unlike V8. Anything that
  reads a rejection must add `name: message` itself; the pure checks passed, only a session run against a real page showed it.
- A probe that shells out must not assume GNU tools: macOS has no `timeout`, so eight "live" runs failed in 0 s with an empty
  answer. Read the first line of a stderr file before trusting a batch of runs.
- A seed written back after an `await` must replace only what it changed (the corrected entities): a refill running meanwhile
  would be overwritten by a whole-seed assignment.

## 2026-11-05 — Documentation always goes to main, whoever left it (issue-lifecycle goal)

Asked what to do with an uncommitted `docs/bugs/BUG-065-…` status change that belonged to none of my work, Boris answered:
"docs go to main always; if you see docs you may pick them up from any place, on any branch."
- Documentation (README, `docs/**`, `tasks/**`, records) is committed straight to `main` in a docs-only commit, including
  documentation changes I did not write and those on other branches or in other worktrees. Check the diff is documentation only
  (`git diff --stat`), name the file in the message, never force-push. Do not ask and do not leave the tree dirty because of it.
- The question to ask before a final clean-up is only about files that are not documentation.

## 2026-11-05 — A change removes the code it replaces (issue-lifecycle goal)

While the lifecycle replaced the status writers, Boris said: "Don't leave old code. Any old code must be removed." I had kept
compatibility paths next to the new ones: a manual-Sync closing rule beside the lifecycle planner, a `markReady` branch that wrote
the status itself, guard stubs for tools that are routed elsewhere, a constant only a test read, and test doubles in the app target.
- When a new path takes over a behaviour, delete the old path in the same change: its branches, flags that only kept the old
  behaviour (`verifiedCompletion ?? true`), the tests that pinned it, and comments that describe it. Do not keep a fallback "for
  callers that do not pass the new argument": change the callers.
- Before calling a rewiring done, list the public declarations of the new files and of the files it touched, and count their
  uses outside their own file (`grep -rw name MarkView`). One use that is only a test is dead production code, or a test double
  that belongs under `tools/tests/`.
- A replaced behaviour is re-expressed as a check of the new path (the planner's checks replaced the old `decide` checks); a
  deleted check is not a lost check when the new suite already proves the same fact.

## 2026-11-05 — Text that promises behaviour needs the code that performs it (issue-lifecycle goal)

An independent review of the lifecycle glue found that the hand-off prompts, the MCP guide and the control tools told the agent "MarkView
records implemented / fixed itself", while no code ever did: the pure rules had a `system` actor for it, but nothing called it, so a bug
handed to the assistant would stay `fixing` for ever. Every check was green because the checks covered the rules, not the caller.
- For each sentence in a prompt or a guide that says what the app does, name the function that does it and the place that calls it
  (`grep` for the caller). A rule with no caller is a promise with no behaviour.
- A pure module that is green on its own proves the rule, not the wiring. List the entry points of the feature (who calls the service,
  when, from which thread) and make sure each one is exercised, or is named as unverified in the review.
- A review by a reader who did not write the code, given the specification and the file list but not my conclusions, finds this kind of
  gap; ask for it before the final verification, not after.

## 2026-11-07 — Replacing a blocked script: when the page can see it (BUG-103)

Stripe.js was blocked by the connection policy and `loadStripe()` rejected, which broke payment pages. The stand-in design only worked
after three facts were measured in a real WKWebView, not assumed:
- A blocked parser-inserted `<script src>` fires `error` after `load` and after the next inline script may already have run, so defining
  the global at `error` is too late for a static tag. Install the stand-in as soon as the tag enters the document (a MutationObserver
  on `document`) and use the `error` event only for the callback and the `load` event.
- A page loaded with `loadHTMLString` under a content rule list comes up blank. Serve test pages from a loopback HTTP port, as the real
  session does, or the check proves nothing.
- Addresses the person allowed must never be replaced: the page runtime needs the same regex list the rule list is built from
  (`allowedFilters`), passed from Swift, with a check that both sides agree.
- In `main.swift` test files, global `let` constants initialise in execution order: put page constants above `application.run()`, or
  they are still empty when the checks read them.
- A new check is only evidence if it fails without the fix: the 19 new web checks were run against the runtime from `origin/main`
  and failed there (4 of 23 passed because they assert that unrelated addresses stay blocked).

## 2026-11-07 — An all-or-nothing guard over a batched answer (BUG-104)

"pull request descriptions could not be read" made every delivery unconfirmable for days. The collector asked GitHub for 40
`pullRequest(number: N)` fields per GraphQL query and required `gh` to exit 0 with no `errors`. A direct commit titled `... (#293)`
names an issue: GitHub answers NOT_FOUND for that one field, `gh api graphql` exits 1, and every other field still has its data.
The code already knew ("a squash title can end in an issue number") but the guard that rejected the whole answer ran first.
- Read the real answer before writing the parser: partial `data` plus `errors` with `path ["repository","pN"]` and exit status 1.
- Tolerate exactly the expected error (type and path of a requested field) and fail for everything else, so a rate limit, a permission
  error or a missing repository is never read as "no work found".
- The fake `gh` of a test must answer like the real one for the awkward input (an issue number, status 1), or the test never meets the bug.
- Read-only lookups that quietly return nothing on error hide for a long time; the visible symptom (a rejected request) was two layers
  away from the cause. When a check says "could not be read", look at what it did with the part it could read.

## 2026-11-07 — A render step whose cost depends on the size of the page (BUG-105)

A 832 KB Markdown file with 253 Mermaid diagrams froze the editor page for 57 s. Parsing (55 ms), HTML (6 ms) and one diagram in an empty page
(9 ms) were all fast; the same diagram cost 155 ms inside the document. What was measured, in real WebKit with the shipping page:
- The cost is linear in the number of page elements (8.5 µs each) and paid once per diagram: a `<style>` element entering the document
  makes WebKit recalculate the styles of every element. The scratch container, `mermaid.render` instead of `run` and `content-visibility`
  did not change it; a shadow root removed it but broke diagrams that look elements up through `document`.
- Elements that are not displayed are not styled: drawing in chunks while the document body is hidden (shown again in the same task, so no
  frame is painted without it) took the document from 57 s to 5 s. The show after each chunk costs about a second, so very short chunks are
  slower overall (100 ms chunks: 36 s) and very long ones freeze the page; 600 ms was the compromise.
- Time a feature on the real file that was reported, not on a generated one, and keep a generated document (`editor-diagrams-tests.sh`) that
  fails on the old code (13.8 s without an answer) for the regression check.
- A timer-gap meter inside the page (`setTimeout` loop recording the longest gap) is the right measure of "frozen": total time says nothing
  about whether the page answered meanwhile. Read it after a moment, because a stalled page answers its timer only after the stall.
- Look at the other side of the bridge when a page is slow to open: `handleBlocksDelta` writes every block to SQLite one by one on the main
  thread. Alone it takes 0.1-0.3 s; with another process holding the write lock it took 28.8 s for 1339 blocks. Measure the cost model before
  deciding how to change a threading rule.

## 2026-11-07 — BUG-106: a shallow clone has no parent for its oldest commit

- `git log --name-only` shows a root commit's whole tree as added. A shallow clone has such a "root" at its boundary (`.git/shallow`) although
  the commit is an ordinary one, so any rule that reads the changed paths of the oldest commit is wrong there: here a documentation record
  became "code work" and blocked a delivered bug.
- Do not trust an agent's or a user's diagnosis of a refusal, and do not trust the first plausible one of mine either: the report said "the old
  commit is taken for the work", the cause was the shallow boundary, found only by running the real collector on the real repository and
  then on a deeper clone of it (the verdict changed from `incomplete` to `complete`).
- A file list that cannot be read is "unknown", never "everything" and never "nothing"; a unit that cannot be judged must not add a definite gap.
- A checks file placed after a call that returns `Never` (`finish(...)`) is dead code: put new checks before it, and show them failing on the
  old code first.


## 2026-11-07 — Beautiful PDF export of a document (5.40.0)

- Test on the real document the person names, not only on generated ones. Boris's 840 KB business plan (253 diagrams of seven types, 2354
  table rows, Russian text) found three defects that the showcase fixture could not: a Sankey diagram drawn at a fixed size with no
  `viewBox` (a box narrower than the drawing cut it, and the overflow guard refused the whole export), the timer throttle below, and the
  Cyrillic text layer below.
- "Both processes idle while the run is slow" means waiting, not computing. `/usr/bin/sample` on the harness and on its WebContent process
  showed 0 % CPU in both: the layout loop yielded to the event loop with `setTimeout(0)` after every page, and a `WKWebView` that is not in a
  window is a hidden page whose timers WebKit aligns to a second and then to longer intervals. 120 diagrams took 117 s; a `MessageChannel`
  task instead of the timer took 8 s. Never pace work with timers in an off-screen web view.
- Look at the text extracted from a PDF (`pdftotext`, `PDFPage.string`), not only at pixels, for every script the app prints. The macOS
  system font (`-apple-system`, SF) writes U+0138 (ĸ) into the text layer instead of the Russian letter к: the page looks right but copying
  and searching "рынок" find nothing. Helvetica Neue and Arial map it correctly. The check names the failing words and fails on the old font.
- A sanitizer that strips attributes can silently break a library's own output: removing every inline `style` removed KaTeX's layout and
  printed formulas as a jumble. Allow what the library writes by property name (sizes, offsets, spacing, colours), never by a pattern that
  rejects bad values (`url(` is bypassed by `u\72l(`), and test with a real formula and with markup that only wears the class of one.
- Detect the language from running prose only: front matter, table rows and diagram sources are English words in a Russian plan and made the
  whole PDF get English labels ("Contents", "DOCUMENT") from a 4000-character prefix.
- A bold line of its own (`**Table 1.2 — …**`) is a caption and keeps with the next block; a paragraph that ends with a colon too.
- An independent review after "all checks pass" still found real defects (an `<img>` with an address that is not a URL aborted the whole
  export, a leading `---` rule was taken for front matter and swallowed the text up to the next rule, a very long title made the cover
  fail). Reproduce each with a check that fails on the old code, then fix.
- Show every new check failing without its fix, in the same run as the fix: the old engine failed six checks, the old font two, the missing
  caption rule ten stranded captions.
- A check that passes locally can fail on the CI runner because its macOS version differs: wide letter spacing came back from the text
  extraction as "D O C U M E N T" there (compare text without white space), and a timer assertion that expected "1:1x" read the page 6 s
  late on a slow runner (give timing checks a window). The first CI run is part of the verification, not a formality.

## 2026-11-08 — X-Ray comparison by date (5.42.0): state shared between two screens of one page

- The PR X-Ray tab and the project X-Ray are one web page with one `ui` object. Putting the full map of a change on the Logical view id made it
  share the open parts, the focus, the selected node and the "only flagged" / "hide tests" switches with the project's own view. An
  independent review found it by asking "what is left behind when the person hops tabs". Give a mode its own state key (`stateKey()`), and
  clear what only makes sense inside the mode (selection, switches whose controls are hidden there) when entering or leaving it.
- A "do it once" guard (`prExpandedFor`) must be keyed by everything that makes the work valid again (view, source, file list) and reset with
  the root, or a second visit finds the screen in its initial, collapsed state.
- A request-scoped wish ("analyze when loaded") must be taken when the request starts, not read after the load: a failed or replaced load then
  cannot leave it behind for an unrelated request. Overlapping loads need a token checked after every await; a replaced load writes nothing.
- A single click that navigates away (opens the file viewer) is right on a map that shows only files of the change and wrong on a map that
  shows the whole project: gate the shortcut on what the node is, not on which tab is open.
- Checks that pass on the first run prove little: every new group here was shown failing on the old page (67 of the first 80 web checks) and
  under a targeted mutation of the new code (halo off, container lost, guard never reset, shared state, tap always opens, risk always wins).
- A watchdog with a fixed total budget fails a healthy run on a slow machine. `research-map-web-tests` allowed 240 s for a suite that takes
  about 55 s locally and 3-4 minutes on a CI runner; on #316 every check was `ok` and the job still failed with "TIMEOUT: no result after
  240 s" (the same job had failed this way on other branches; a re-run passed). Watch progress instead of total time: stop after 120 s
  without a reported check, with a generous cap (20 minutes) for the whole run. Show the old budget failing on a slow stand-in and both new
  limits biting on a stuck run.

## 2026-11-08 — BUG-107: two flexible SwiftUI siblings split the width equally

- A list and a detail pane that are both flexible children of one `HStack` get the width in equal parts until one of them has a maximum. A `minWidth` and an
  `idealWidth` on the list did not make it narrow: the list took half of the sheet and the two versions a quarter each. Bound the secondary pane
  (`maxWidth`) and let the primary one take the rest; give a sheet an `idealWidth`/`idealHeight`, or it opens at its minimum.
- A SwiftUI layout can be measured without a UI test target: host the shipping view in a borderless `NSWindow` far outside the displays (never ordered front), set the
  content size, run the layout, and read the frames of the AppKit hosts (`ListCoreScrollView` for a `List`, `HostingScrollView` for a `ScrollView`). Compile the view as it
  ships and stub only its model and environment inside the test file. Run the same checks against the old file (`git show origin/main:…`) to see the bug as numbers
  that match the screenshot before changing the view.
- The working tree is the lifecycle store: MarkView writes the status of a bug or feature into its Markdown file and records any other change to that file as an "external
  edit, unverified" discrepancy. After I committed the bug record to main from a throwaway worktree I ran `git checkout -- docs/bugs/…` in the project tree to "clean it",
  which put `status: open` back and created the discrepancy. Never restore, stash or reset a file the lifecycle tools wrote; copy it byte for byte to where it has to go and
  leave the project tree alone (the next `git switch` brings identical bytes). Repair a wrong status only through the tools (`markview_set_bug_status` with the reason).


## 2026-11-08 — feature-3: moving a hard-coded table into data

- Move the old table into the new data type first and run the unchanged suites against it (`ProjectWorkflow.standard`): the policy, completion and GitHub suites passing
  untouched is the proof that the standard workflow behaves as before. Only then add the checks for what is new. Every consumer that still compares a status by name (`== "closed"`,
  `["fixed", "closed"].contains`) is a bug in a project with other names: grep the string literals of every status after the refactor and replace each with a role or a workflow lookup.
- A test script compiles only the files it lists. Adding a Foundation-only file (`ProjectWorkflow.swift`) that an existing file now depends on breaks every script that compiles that
  file, with a "cannot find type" error far from the cause: add it to each script (`control-agent-tools`, `project-agent-tools`, `ui-studio-session`, …) in the same change.
- A check that depends on commit timestamps is flaky when two commits land in the same second. The collector chose "the last commit" by date; in a depth-2 shallow clone with two roots
  the order was a coin flip (about one run in six). Choose by topology (`rev-list --first-parent`, last line), never by time, and run a suspect check ten times before trusting it.
- SourceKit shows "Cannot find type/scope" for every file of a multi-file target it has not indexed together. Compile (`xcodebuild`, or the suite script) before believing it.
- Saving a workflow that removes a status or variant in use is a two-step write with an ordering rule: the file first, then the reassignment of items as records of their own kind. A crash between
  the steps leaves items on a status the workflow no longer has, which reads as `unknown` and is never a pass; the next start finishes the move.

## 2026-11-08 — five suites that were "known failures" for weeks

- A failure called "not mine, fails on clean main" is still a failure: Boris asked to fix it ("even if the errors were not in this session"). Run every suite once at the start of a task, write down the red
  ones, and fix them in a branch of their own instead of carrying the list from report to report.
- Four of the five were stale tests, one was a stale file list; none was an app bug. In each case a later commit changed behaviour on purpose and updated only its own test: the operation kind order
  (`b1ce96c` aligned the panel with `ProjectOperation.primaryKindOrder`), "every regular file is openable" (`18fb9da`), and `DeploymentStore` gaining `CloudServices` and `ProviderHints`
  (`17415de`). When a behaviour changes, grep `tools/tests` for the old expectation and for every script that compiles the changed file.
- Before changing a test, find the commit that made it fail and read its message: that decides whether the test or the app is wrong. Change the app only with Boris's approval.
- A web-view harness must not use the persistent website data store: the prototype runtime keeps the chosen role in `localStorage`, so the second run on a machine started as the role the first run
  ended with. A harness passes on a clean CI runner and fails on a developer machine. Use `WKWebsiteDataStore.nonPersistent()` and run a suite twice in a row before calling it stable.
- zsh treats a bare `=====` in `echo` as an expansion and aborts the command: quote separators.

## 2026-11-08 — merging without waiting for CI (second reminder)

- Boris said on 2026-11-04 that CI is not waited for, and said it again on 2026-11-08 while I was polling the checks of a test-only PR: "I said you can merge without waiting for CI".
  Rule: after my own verification (suites, Debug build) open the PR, merge it at once (`gh pr merge --merge --delete-branch`), release and install; read the check results afterwards and report them.
  Never start an `until ... gh pr checks` wait loop before a merge. A rule from an older CLAUDE.md line or memory note ("wait for every check run") does not outrank a direct instruction from Boris.
