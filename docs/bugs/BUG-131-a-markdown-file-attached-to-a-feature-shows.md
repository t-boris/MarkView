---
type: bug
id: BUG-131
title: A Markdown file attached to a feature shows up as a second source with the same id
status: done
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
schema: 1
---

# A Markdown file attached to a feature shows up as a second source with the same id

## Summary

When a .md file is attached to a feature (new-feature intake, quick intake, or dropped on the Sources panel), MarkView copies it into the feature's references/ folder as "SRC-nnn-<file name>.md". The feature loader reads every .md file in references/ whose name starts with "SRC-" as a source object, so the copy is listed as an extra source next to the real one. Its title is the first line of the attached file, and it has no role, facts or file link. Found by a hosted test of the attachment ingest (2026-11-26) that counted 8 sources for 4 attached .md files. Plain-text, PDF and image attachments are not affected.

## Steps to reproduce

1. Open a project with MarkView features.
2. Start a new feature (or a quick feature) and attach a Markdown file, e.g. notes.md, whose first line is "Attachment one says ...".
3. Open the feature's Sources (references) list.

## Expected

One source for the attached file (SRC-001, title notes.md) with its role, summary, facts and a link to the copied file.

## Actual

Two sources: the real one, and the copied file SRC-001-notes.md read as a source object of its own (title "Attachment one says ...", no role, no facts, no file). The cause is in two places: FeatureIngest copies the attachment under "\(source.id)-\(name)" into references/, and FeatureModels lists every references/*.md file that starts with "SRC-" as a source.

## Environment

MarkView 7.9.0 (main 93b86c44); code paths MarkView/Models/Lifecycle/FeatureIngest.swift (addSource copy) and MarkView/Models/Lifecycle/FeatureModels.swift:527 (object listing).
