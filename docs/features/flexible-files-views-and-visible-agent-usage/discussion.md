# Discussion — Flexible Files Views and Visible Agent Usage

### Boris Tsekinovsky · 2026-11-08

И еще, кстати, перенеси пожалуйста Project Cycle Time туда же, наверх.

### AI · 2026-11-08

Добавим Project Cycle Time в верхнюю панель рабочего пространства рядом с показателями агентов. Сейчас он открывается из панели Features.

Как его лучше показывать наверху?

- **Кнопка «Cycle Time»** — компактно; открывает существующую сводку.
- **Показатель со значением** — время видно сразу, но он занимает больше места и нужно выбрать, какое именно значение показывать.

Какой вариант предпочитаешь?

### AI updated the requirements · 2026-11-08

DEC-001 written into the overview.

### Boris Tsekinovsky · 2026-11-08

Answers to the questions asked before implementation (2026-11-08):

1. "Openable files" = files MarkView has a viewer for, decided by extension or name (recommended option). Recorded as DEC-004. The code showed that FileType.isOpenable is true for every regular file, so the premise of F-001 was wrong.
2. Unsupported files: a click only selects them; the context menu has Open with Default App and the file-management actions (recommended option). Recorded as DEC-005.
3. Project Cycle Time in the top bar: a compact button that opens the existing summary (the answer to the AI's question above). Recorded as DEC-006.
4. CI for this work: do not wait for it. Merge after local verification and report the CI result afterwards. This overrides item 7 of the goal for this work only; it is a process rule, not a requirement.

### Boris Tsekinovsky · 2026-11-08

When I spoke about filters I also meant, for example, filtering out what .gitignore ignores, so it is not shown, or hiding hidden items: things of that kind. (Sent during implementation, 2026-11-08.)

The AI recorded it as a new requirement, "Hide items ignored by Git": a filter toggle beside the hidden-items toggle. It is off by default, because the specification only asks for hidden items to be excluded by default (AC-3) and ignored items are visible today; the default is a one-line change if Boris wants it on.

### Agent · 2026-11-08

Independent code review of the implementation (2026-11-08) found 5 major and 6 minor defects; all but one were fixed before the PR. Fixed: places (project folder, linked folders) can no longer be dragged (a drop would copy the whole tree on the main thread); a Tree selection holding a folder and rows under it acts on the outermost items only; the Tree destination folder is re-checked on disk, so a renamed or trashed folder falls back to the project folder; a vanished linked folder stays a folder row and can be unlinked; the recursive search is breadth-first, so a cap reached inside node_modules cannot starve a linked folder or shallow matches; Hide Git-ignored is ignored (and not counted) outside a Git repository; the controls row wraps to two rows in a narrow sidebar; the selection is pruned when filters or open folders change and Move/Trash are disabled when only places are selected; the viewer-only dotfile names (.gitignore, .zshrc, …) moved out of the tables the X-Ray scanner uses; the usage-chip popover state moved to the bar so a form change does not close it. Not changed: the Tree expansion state resets when the navigator switches between Files and Issues, exactly as the browsed folder did before this feature (parity, not a regression). Agent usage sources for other agents were surveyed (DEC-010): none has a reliable limit-and-reset source, so none is added.
