# Workspace interface layout

This layout applies DEC-001, DEC-014, DEC-021, DEC-023, and DEC-027. It is a build target, not a prototype gate.

## Window shell

- Put a full-width header above every content column. Keep the padded project title, clickable color icon, and thin color band in the window frame. The project name remains readable independently of color.
- Use a compact three-destination workspace switcher in the header: Files (`folder`), Project Map (`viewfinder`), Work (`checklist`). Give every icon a tooltip and accessibility label.
- Put independent navigation, center-content, and labelled Terminal toggles, shared Search, assistant/model, New, theme, and an overflow menu in the header. Show the Contents control only for Markdown files. The overflow and menu bar expose every header action. Preserve the existing File and View menu commands and shortcuts.
- Use native materials and system label colors for window chrome. Share a small set of surface, spacing, typography, border, focus, and status tokens with the bundled editor. Project color marks identity only; task and handoff status include text.

## Files

```text
all shown: [file navigation] | [tabs + document/image/editor] | [assistant terminal]
two shown: any two columns, each full height
one shown: any one column fills the content area below the header
```

- The document is the visual focus, with a comfortable reading measure and fewer persistent editor controls. Show common style, insert, mode, save, and search actions; selection-specific actions appear at selection. Existing formatting actions remain in menus and retain their shortcuts.
- Keep local folder filtering in file navigation. The shared Search control opens project-wide results with scope labels.
- Keep tabs and editor content alive while visiting the other workspaces, including scroll position and unsaved drafts.
- The right column shows Terminal by default. Contents is an optional Markdown heading view in the same column. All columns are docked below the header and independently toggled; none floats over another. At least one remains visible. The terminal is reachable through the labelled header control and `⌘3`, grows when adjacent columns close, and refits on every visible resize.

## Project Map

```text
wide:    [scope/views] | [X-Ray canvas] | [selected component details]
compact: [scope/views menu] [X-Ray canvas] [details toggle]
```

- Make the X-Ray graph the central surface. Put view selection, component search, filters, overlays, fit, rescan, analyze, and stop in grouped controls. Keep graph legend, progress, and selected details accessible after side panels collapse.
- An Open Files action on a component or analysis result activates Files at the related path. A Back to Map route retains map selection and zoom.
- Structure and document information appear after local scanning; assistant work is explicitly launched and shows its own progress and result.

## Work

```text
wide:    [features/bugs + Git sections] | [selected task or Git content] | [context/results]
compact: [task navigation menu] [selected task or Git content] [context toggle]
```

- Give Explore, Review, Resolve, and Build the main content area. Present the selected feature title, status word, readiness, known decisions, open questions, and next action without requiring the narrow legacy Feature panel.
- Put Git Changes, Pull Requests, Issues, and Actions beside feature work. Keep their current controls and filters, with contextual routes to Files and Project Map.
- Show handoff readiness, latest revision, actor, time, linked file paths, and changed-since-handoff as text. Let the author add project-relative links and mark ready; let the developer Resume in Files and return to Work. Provide current and handed-off snapshot browsers side by side or through a clear version switch.
- Managed AI actions use an action card to show scope, assistant, output, progress, Stop, errors, and review. Assistant terminals open at useful width and keep their session tabs and prompts.

## Start and search

- Start gives a primary Open Folder action, Open File and New Project secondary actions, recent projects/drafts, and a short author path to create a specification. When a project has handed-off work, Resume opens explicitly linked files in Files and a related Work route. Missing links appear by path. An empty link list offers Browse Files and Open Specification.
- Shared search opens from a visible magnifier and a new shortcut that does not change the editor's `⌘K` Insert Link or `⌘F` in-document find. Results are grouped by File, Content, and Command with project-relative paths and current-context availability. Search continues to work without an assistant.

## Visual verification

Inspect each workspace and the start/search/AI/handoff states in the running app at 1440 × 900 and 900 × 600 points, 100% and 200% interface text, light/dark/increased-contrast appearances. Verify keyboard focus, tooltip/accessibility labels, overflow access, and no clipped terminal rows or columns.
