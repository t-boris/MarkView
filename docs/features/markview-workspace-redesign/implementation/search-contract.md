# Shared project search contract

This contract implements REQ-003 and DEC-018. Search is local and requires no assistant.

- Open Search from the toolbar magnifier or `⌘⇧K`. `⌘F` remains document find and `⌘K` remains Insert Link in the editor.
- Results are labeled `Command`, `File`, or `Content`. File results show a project-relative path. Content results show the path, line, and a short excerpt. Commands appear only when their required project, Git repository, or active file is available.
- The index is memory-only and is rebuilt when Search opens or the user presses Refresh. It scans file names for regular non-symlink files. Readable UTF-8 text of at most 2 MiB is indexed for `md`, `markdown`, `txt`, common source and configuration extensions, CSV/TSV, and canvas files, plus extensionless README, LICENSE, Makefile, Dockerfile, Gemfile, `.gitignore`, and `.editorconfig`.
- `.git`, `.dde`, immutable `docs/handoffs` revisions, generated output folders, dependency folders, virtual environments, and known credential file types are excluded. Binary, oversized, or unsupported files can match by name but have no content results.
- The Search sheet shows indexing progress and the time of the last completed index. External edits can make results stale until Refresh or reopening Search. Before opening a result, MarkView checks that it still exists inside the project. Missing or moved results trigger an index refresh and an explanation.
- Local Files/Issues filters and document find remain independent of shared Search.
