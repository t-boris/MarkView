---
type: bug
id: BUG-061
title: Pictures in a Markdown file are not shown (README.md shows empty picture boxes)
status: done
severity: critical
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
---

# Pictures in a Markdown file are not shown (README.md shows empty picture boxes)

## Summary

Opening README.md in MarkView shows the pictures as large empty boxes instead of the images. Reported by Boris on 2026-11-03 right after 5.12.0 was released.

## Steps to reproduce

1. Open the MarkView repository (or any folder whose README.md has pictures such as <img src="docs/images/xray-component.png" width="820">).
2. Open README.md in the editor.
3. Look at the places where the pictures are.

## Expected

Every picture the document refers to, with a Markdown image or an HTML img tag, with a relative path, is drawn at the size the document asks for.

## Actual

The pictures are not drawn; empty boxes of the size the document asks for stay where they should be.

## Cause (confirmed by reproduction in an isolated debug copy, 2026-11-03)

- The editor page cannot read files. Only Markdown images (`![](path)`) were turned into data URIs, by a regular expression over the text; an HTML `<img src="docs/images/x.png" width="820">` kept its file path and showed as an empty box. The refreshed README uses HTML images.
- The same workaround changed the text the editor held. Opening any file with a relative Markdown picture marked its tab modified (179,993 characters for a 729-byte file), and the next save wrote the base64 into the file. `docs/bugs/BUG-007-…md` had been corrupted this way (374 KB); it was restored from its asset files.

## Fix (5.12.1, PR #273)

The text goes to the editor exactly as on disk. The pictures are served by the app at `markview-doc:///<path>` (like `markview-data:`): Markdown and HTML (`img`, `srcset`, `picture`), only pictures, only inside the project folder and the folders of open documents, symbolic links and `..` that leave them refused. The page puts the author's own paths back when a WYSIWYG edit is turned into Markdown. Checks: `tools/tests/document-files-tests.sh`.

## Environment

MarkView 5.12.0 (and earlier), macOS. Fixed in 5.12.1.
