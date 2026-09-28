# Capability migration map

Status: approved by Boris on 2026-09-28 (DEC-022).

## Preservation baseline and rules

- Fixed application release: `v2.27.0`, commit `a8a99c3a7a8eb5285c48b78642dd92a774a4df27`.
- `Files` owns project files, document and image editing, document context, and folder terminals. `Project Map` owns every X-Ray and architecture view. `Work` owns features, bugs, research, Git, GitHub, and managed assistant work. The assistant terminal is reachable from every workspace in a full-width lower area or a full-content terminal view at constrained widths.
- Shared search and the assistant selector are global. Settings, project identity, and application menus remain window-level. Each row below names its primary owner; cross-workspace routes are listed separately.
- The shell follows DEC-021: familiar icons for frequent actions, short labels for ambiguous states and important actions, tooltips/accessibility labels for icon-only controls, and contextual menus for secondary actions.
- Existing menu commands and keyboard shortcuts retain their behavior. In particular, the editor's `⌘K` remains Insert Link. A new shared-search shortcut must not override it. `⌘F` stays in-document find. `⌘1` and `⌘2` retain panel-toggle behavior, `⌘3` opens Terminal, and `⌘4` opens X-Ray.
- Each check compares the outcome with this fixed release. Checks include the 900 × 600 point window, 200% interface text, light/dark/increased-contrast appearance, session restoration, and no configured assistant where relevant.

## Window, navigation, and application commands

| ID | Existing capability and expected outcome | Primary destination and secondary route | Preservation check |
| --- | --- | --- | --- |
| W01 | New/open window, Finder Open With, Quick Action, drag-and-drop file or folder, and restored window open the intended project or file in the intended window. | Global window shell; dropped/opened files activate Files. | Exercise each entry with two windows; verify no request is taken twice. |
| W02 | Open File `⌘O`, Open Folder `⌘⇧O`, Close Folder, and New Project open/close the intended resource. | Global File menu and Files/start actions. | Exercise menu and start actions, including a window with an open folder. |
| W03 | Save `⌘S` and Export PDF `⌘E` save/export the active document. | Files, with unchanged File menu commands. | Edit, save, export, and compare output. |
| W04 | Recreate Metadata and Remove Metadata retain their confirmation and project data effects. | Global File menu and Settings > Maintenance. | Check both commands against a disposable project. |
| W05 | Toggle Theme `⌘⇧T` and DDE Settings `⌘⇧,` retain appearance and settings access. | Global toolbar/menu. | Change theme and each settings category; reopen window. |
| W06 | Toggle File Tree `⌘1`, Toggle Table of Contents `⌘2`, Terminal `⌘3`, and X-Ray `⌘4` retain their outcomes. | Files navigation, Files context, global terminal, Project Map; View menu from every workspace. | Invoke each shortcut and menu item from every workspace and narrow layout. |
| W07 | Project name, represented folder URL, clickable persistent color icon, and color band identify the window. | Global shell, unchanged across Files/Project Map/Work. | Change color, switch workspace/window, restore, and inspect title/icon/band. |
| W08 | Left/right panel visibility and widths, active panel selection, active tab, and window tabs/drafts restore per window. | Adaptive global shell with per-workspace navigation and inspector states. | Save/restore two windows with different states and unsaved drafts. |
| W09 | Toolbar New Feature/New Bug/I Need to Understand, document-based intake, Implement It with AI, assistant/model selection, AI tools, and theme remain reachable. | Work intake, Files document context, global assistant/actions/appearance toolbar. | Invoke each toolbar action with and without a project or document. |
| W10 | New Project draft creation, resume, discard, clarification, destination, project creation, and optional GitHub publish retain their results. | Start screen and Work; File menu secondary entry. | Resume a draft after relaunch and finish local and GitHub paths. |
| W11 | Standard macOS Edit, Window, and Help menu commands remain available alongside the custom File, View, and Settings commands. | Global menu bar. | Inspect menus in the running build and exercise standard window and edit operations. |

## Files and editor

| ID | Existing capability and expected outcome | Primary destination and secondary route | Preservation check |
| --- | --- | --- | --- |
| F01 | File tree browse, breadcrumbs, back, local folder filter, sort by name/date/direction, open file, and reveal active file work. | Files navigation; global search result activates Files. | Traverse nested folders; filter/sort; reveal an open document. |
| F02 | File tree creates a file, Git-ignored file, folder, or AI graph diagram in the chosen directory. | Files navigation and folder context menus. | Create each item and confirm location and Git status. |
| F03 | Folder include/exclude, X-Ray, research, Git stage-all, `.gitignore`, terminal here, Finder, Terminal.app, and Copy Path remain in folder context menu. | Files tree context; X-Ray activates Project Map; research activates Work. | Exercise each action on a disposable folder. |
| F04 | File stage/unstage/discard, `.gitignore`, X-Ray, intake, Implement with AI, terminal here, Finder, Terminal.app, and Copy Path remain in file context menu. | Files tree context; Git/feature/X-Ray routes activate Work or Project Map. | Exercise menu entries and verify resulting file, Git, or workspace state. |
| F05 | Text/Markdown/code/JSON/XML/YAML/canvas and image files open in the appropriate editor or viewer; SVG Source opens as text. | Files content. | Open representative fixtures and verify editable/viewable mode. |
| F06 | Tabs select, close, Close Others, Close Right, Close All, Copy Path, Show in Finder, and Reveal in File Tree; modified documents prompt/persist as before. | Files tab bar and context menu. Other workspace tabs keep their underlying sessions. | Exercise each tab command and restore with unsaved content. |
| F07 | Markdown visual/source mode, formatting, lists, headings, links, images, rules, code, tables, Mermaid, selection toolbar, save/reload, and font slider retain results. | Files document toolbar and contextual selection controls. | Edit a fixture with each operation, save, reload, and compare Markdown. |
| F08 | `⌘F` find in document, previous/next, case and regex modes, and `⌘K` Insert Link remain available in editor focus. | Files editor. | Verify shortcuts and controls on a multi-match document. |
| F09 | Contents/headings panel navigates and tracks the active heading; document status, word/character count, and diagnostics remain visible. | Files inspector or collapsible context sheet. | Jump among headings and verify status after edits. |
| F10 | Image zoom in/out, fit, actual size, Finder reveal, and SVG Source retain outcomes. | Files image viewer. | Open raster and SVG fixtures; exercise all controls. |
| F11 | Canvas, graph, code navigation, wiki links, file references, and embedded document links open their targets. | Files editor; linked X-Ray elements route through Project Map. | Exercise representative fixture links and graph nodes. |
| F12 | Folder terminal tab starts in the chosen directory, accepts input/dictation, restarts, and can be closed. | Files full-content terminal tab; global terminal switch. | Verify working directory, resize/refit, restart, close, and restored session. |
| F13 | Research bar shows running jobs, cancel, and Continue/Deepen for research documents. | Files document context with Work research route. | Start a research job, switch workspaces, cancel or continue. |

## Project Map and X-Ray

| ID | Existing capability and expected outcome | Primary destination and secondary route | Preservation check |
| --- | --- | --- | --- |
| M01 | Project, folder, file, and pull-request X-Ray open at the correct scope; a rescan refreshes disk structure without AI. | Project Map content; toolbar, Files context, GitHub PR secondary routes. | Open every scope and rescan after adding a file. |
| M02 | Logical/Structure views, overlays, flagged-only and type filters, AI search, fit, details toggle, legend, breadcrumbs, and graph navigation retain behavior. | Project Map canvas and context inspector. | Exercise each control against a fixture project. |
| M03 | X-Ray analysis, PR impact analysis/review, progress, Stop, retained partial analysis, and open related files retain results. | Project Map action controls; Files route for selected files. | Start/stop/retry analysis and open a mapped file. |
| M04 | Architecture, Data Flow, Pipeline, Deployment, Sequence, and ER AI diagrams; Critic, Audit, Code Structure Map, and Recursive Insight retain their outputs. | Project Map analysis and Work assistant results; global AI Tools entry. | Invoke each tool with configured assistant; inspect result tab/output. |
| M05 | Recursive Insight tab, progress, section retry, export/archive, and cancel retain results. | Project Map or Work result view, with global result tab access. | Run and cancel/finish a session; retry and export. |

## Work: specifications, bugs, research, Git, and GitHub

| ID | Existing capability and expected outcome | Primary destination and secondary route | Preservation check |
| --- | --- | --- | --- |
| T01 | Features and bugs list, text filter, status/type/implementation filter, sort, collapse, issue links, and sync/report remain available. | Work navigation. | Filter/sort/sync and open both item types. |
| T02 | Feature navigator lists documents, objects, linked issues, history, and status; opening an object opens its file. | Work navigation; file target activates Files with return route. | Open each item type and return to feature. |
| T03 | Feature Explore, Review, Resolve, Build stages, readiness conditions, status, discussion, context/results, restart/delete/cleanup, and cycle time retain state and outcomes. | Work main content, stage selector, and context. | Complete a feature journey; check history and cleanup. |
| T04 | Intake for feature, bug, and understanding from text, voice, files, document, GitHub issue, or PR retains created artifacts. | Work intake; Files and GitHub context secondary entries. | Exercise each source type in a disposable project. |
| T05 | Questions, answers, option selection, AI decide/research/skip, requirement approval, findings review/resolve/risk/dismiss, decisions accept/reject, assumptions, research gaps, plan/re-plan, implementation coverage, and issue creation retain artifacts. | Work stage content and object context. | Execute each state transition on a fixture feature and inspect files. |
| T06 | Sources add files/URL/GitHub issue/notes/voice, fact accept/reject/edit/discuss, and related research remain available. | Work feature Sources section. | Add every source type and inspect resulting records. |
| T07 | Bug investigation/status, AI investigation/fix, bug basket add/remove/suggest/fix batch, and linked issue actions retain results. | Work bugs navigation/main content. | Build a basket and check each action/outcome. |
| T08 | Research creation, web-search setting, target selection, running progress, cancellation, timeout/partial result, and Continue/Deepen retain outcomes. | Work research; Files document bar and folder context secondary routes. | Start, cancel, time out, resume, and inspect saved research. |
| T09 | Git init, status, branch, refresh, stage/unstage/stage-all, discard, diff, commit, history, pull, push, and publish retain outcomes. | Work > Git; Files tree status/context secondary routes. | Use disposable Git repo and compare working tree and log. |
| T10 | GitHub account/settings, repository picker, PR list/filter/search/create/review/comment/approve/request changes/merge/close, and browser/link actions retain outcomes. | Work > GitHub/PRs; File menu Publish secondary route. | Exercise on a test repository with `gh`; verify remote state. |
| T11 | GitHub Issues list/filter/create/open/edit labels/assignees/comment/close/reopen and Start with AI retain outcomes. | Work > GitHub/Issues; feature and file links as secondary routes. | Exercise test issue and inspect remote state. |
| T12 | GitHub Actions list/workflow dispatch/run detail/logs/cancel/rerun/failure explanation/fix with AI retain outcomes. | Work > GitHub/Actions; run and issue tabs remain navigable. | Exercise test workflow and compare remote run state. |
| T13 | Lifecycle manual marks, analytics, cycle-time view, issue sync, and GitHub feature plan publication retain their records. | Work feature and project tools. | Mark lifecycle stages, sync/publish, inspect resulting records. |

## Shared search, assistants, and settings

| ID | Existing capability and expected outcome | Primary destination and secondary route | Preservation check |
| --- | --- | --- | --- |
| S01 | Existing Markdown full-text Search panel and local file/issue filters remain available. | Global search with content scope; local filters stay in Files/Work. | Search indexed Markdown and use local filters independently. |
| S02 | New shared search finds project file names, supported readable text content, and available commands with explicit scope labels; works without AI. | Global search overlay; results route to owning workspace. | Search a fixture project, check index progress/stale/missing files and unavailable commands. |
| S03 | Assistant/model picker, output language, CLI paths/auth/PATH, research timeout, agent usage visibility, and error states retain their effects. | Global assistant selector and Settings. | Change each setting and verify subsequent action uses it. |
| S04 | Whisper key, microphone permission, model/test, and voice input in intake/terminal retain outcomes. | Settings and contextual voice controls. | Verify configured and missing-key states without logging secrets. |
| S05 | AI terminal profiles (Claude, Codex, shell), session tabs, prompt chips, PR picker, option-to-type, input, dictation, restart, and close remain available. | Global terminal area or full-content view at narrow width. | Start each profile, send/type prompt, resize/refit, restart, close. |
| S06 | Editor selection actions (translate RU/EN, explain, challenge, expand, research, edge cases, contradictions, related docs, diagram, requirement, decision, question, revise with comment) retain results. | Files selection menu; generated specification objects/results appear in Work. | Invoke each action on a fixture and verify output location. |
| S07 | AI launches from feature stages, bug flows, X-Ray, GitHub PR/Actions, graph creator, research, and Implement with AI retain their action-specific results. | Owner workspace plus global activity/review surface. | Check every action in the separate AI lifecycle inventory. |
| S08 | Settings appearance scale 80–200%, theme, GitHub integration, maintenance, and usage diagnostics remain available. | Global Settings. | Change each setting and verify persistence and visible effect. |

## Approval and implementation notes

1. Review every destination and cross-workspace route above. Approval makes this the DEC-010 implementation map; edits to a listed outcome, existing command, or shortcut require a separate decision under DEC-002 and DEC-013.
2. The map deliberately preserves the current `⌘K` editor link command. The shared search receives a new nonconflicting keyboard entry point during implementation.
3. AI action specifics (scope, assistant, output, progress, stop, partial/failure, external edits, review) are recorded in a separate inventory before changing those flows, as required by DEC-019.
