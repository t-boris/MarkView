---
type: bug
id: BUG-040
title: Book X-Ray never extracts reStructuredText hyperlinks
status: fixed
branch: fix/bug-040-book-xray-rst-links
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

## Cause

`BookBuilder.links(in:format:)` removed every single-backtick span (`codeSpan`) from a line before it ran any
format-specific pattern, so Markdown code such as `` `[a](a.md)` `` would not count as a link. The reStructuredText
embedded hyperlink `` `text <path>`_ `` is a single-backtick span too. By the time the `.rst` case ran
`rstLink` (`<([^>\s]+)>`_`) the whole hyperlink was gone, so the pattern could never match a link written on one line.

Reproduced by a standalone test before the fix (`See `the setup guide <setup.rst>`_.` gave no link, and a book of two
`.rst` files had no edge). The only form that worked by accident was a hyperlink whose text wrapped onto a second
line: that line holds a single backtick, so it was not a span and `rstLink` matched it.

## Resolution

For `.rst` documents `links(in:format:)` now reads the embedded hyperlink from the raw line, with only the RST inline
literals (``` ``text`` ```) removed, instead of from the line stripped of all backtick spans. `rstLink` itself is unchanged.

Because the pattern now sees text it never saw before, literal text is kept out explicitly:

- Inline literals are removed before the match, so ``` ``see `x <no.rst>`_`` ``` is not a link, including a literal
  that holds a single backtick.
- `RSTLiteralBlocks` (new, private, in `BookBuilder.swift`) follows literal blocks line by line: a paragraph ending
  in `::`, a lone `::`, and the `code`, `code-block`, `sourcecode`, `parsed-literal`, `math` and `raw` directives
  open a block that holds every following blank or more-indented line. Other directives (`.. note::`) do not.
  Links on those lines are skipped.

Anonymous hyperlinks (`` `text <path>`__ ``), a `#fragment` (resolved to the section) and paths with `../` work, and
external targets (`https:`, `mailto:`) are still dropped by the existing `parse`.

## Not changed

- Markdown, AsciiDoc, Org and plain-text extraction: the new code runs only for `.rst`, and the new tests also pin
  the Markdown code-span rule, AsciiDoc `xref:`/`link:` (including inside backticks) and that the RST form is not a
  link in other formats.
- Wiki links in `.rst` files are still found on the line stripped of backtick spans, as before; a `[[x]]` inside an
  RST literal is still counted as it was. Only the new RST hyperlink path knows about literal blocks.
- Link forms that were not extracted before and still are not (checked by running the extraction): RST hyperlink
  targets with named references (`.. _setup: setup.rst` used as `` `setup`_ `` or `setup_`), internal targets,
  Sphinx roles (`` :doc:`...` ``, `:ref:`), `.. include::`; AsciiDoc `<<setup.adoc#,text>>`; Org links with a
  description (`[[file:x.org][text]]`). Only the embedded hyperlink was the reported defect. The feature overview's
  "RST targets" can be read as the named `.. _name: path` form, so that form is an open decision: adding it means
  collecting target definitions the way Markdown reference definitions are collected.
- The literal-block rule is a line-based approximation of RST (indentation relative to the opening line); it does
  not parse nested constructs such as a `::` inside a table cell.

## Verification

- `tools/tests/book-xray-tests.sh` passes (119 checks). The 25 new cases (a new "Links by format" section and an
  RST end-to-end book) cover embedded and anonymous hyperlinks, fragments, wrapped link text, external targets,
  inline literals, `::` and directive literal blocks (including the block ending, a list item, and `::` with no
  block), `.. note::` as non-literal, and the other formats. Against the previous `BookBuilder.swift` 16 of the
  new checks fail; with only the literal-block guard removed, 7 fail.
- A probe of the other forms listed under "Not changed" returned no links before and after the change.
- Debug build with `xcodebuild` (see CLAUDE.md) passes.
- Not exercised by a run: the real app, its X-Ray Book view and the cross-reference panel on an `.rst` folder.
  The path from `links(in:)` to `build` edges is covered by the standalone test; the panel is covered by reading.
  Real-world `.rst` or Sphinx documentation folders were not scanned, so false positives or misses in unusual
  RST layouts are untested.
