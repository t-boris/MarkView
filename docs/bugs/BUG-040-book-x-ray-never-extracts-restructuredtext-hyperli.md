---
type: bug
id: BUG-040
title: Book X-Ray never extracts reStructuredText hyperlinks
status: open
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# Book X-Ray never extracts reStructuredText hyperlinks

## Summary

`BookBuilder.links` removes every single-backtick span from a line (`codeSpan`, pattern `` `[^`]*` ``) before it looks for links. The reStructuredText embedded hyperlink `` `text <path>`_ `` is such a span, so the `rstLink` pattern `<([^>\s]+)>`_` can never match and RST cross-references between chapters are missing from the book graph. No test covers RST or `xref:` links. Found by a read-only audit; confirmed by reading the code, not by running it.

## Steps to reproduce

1. Create a folder with two .rst documents where the first contains the line `` See `the setup guide <setup.rst>`_. ``.
2. Open the folder's X-Ray, Book view, and run Analyze.
3. Select the first chapter and look at its cross-references.

## Expected

A cross-reference from the first chapter to setup.rst appears in the panel and as an edge.

## Actual

No link is extracted for that line; the cross-reference is absent.

## Environment

MarkView current main (ade7910), MarkView/Models/BookBuilder.swift lines 409-410, 435 and 464-467; code reading only.
