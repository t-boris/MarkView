# Handoff storage

The approved handoff record (DEC-011, DEC-012, DEC-017) is stored at `docs/handoffs/<feature-slug>/revisions/<number>/` in the project. Each revision contains `record.json` and `files/`, a complete copy of the feature folder at that moment. The record stores the revision number, actor, time, explicit project-relative linked file paths, and content hashes.

This folder is outside `docs/features/<feature-slug>`, so writing a revision does not set its own changed-since-handoff flag. It is project content and can be committed or shared with collaborators. MarkView's Remove/Recreate Metadata commands remove `.dde` caches but do not remove handoff history. Shared Search and the observed-change review exclude immutable revision copies to avoid duplicate hits and unrelated change alerts.

The current feature folder remains editable. The Work handoff panel compares every regular file in that folder with the latest revision, including additions, changes, and deletions from outside MarkView. Mark ready again creates another complete revision without changing an already-ready feature's lifecycle state.
