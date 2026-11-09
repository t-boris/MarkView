---
type: bug
id: BUG-033
title: Sync to GitHub issues reads stray numbers in explicit fields as issue links
status: done
branch: fix/bug-033-sync-stray-issue-numbers
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-02
provenance: Created by an AI agent through MarkView
---

# Sync to GitHub issues reads stray numbers in explicit fields as issue links

## Summary

The third alternative of `IssueSync.fieldPattern`, `(?<![\w/#])#?(\d+)\b`, accepts a bare number anywhere in an explicit GitHub field of a feature or bug. Sync closes issues without a preview, so a stray number can point at an unrelated open issue. REQ-002 of the sync feature intends free-text numbers to be ignored. Found by a read-only audit; the pattern was evaluated in Python with the same semantics, not run in Swift.

## Steps to reproduce

1. In a feature or bug front matter, set a GitHub field to `https://github.com/<owner>/<repo>/issues/41#issuecomment-1234`, or to text such as `see issue 12 in v2.3`.
2. With the GitHub integration on, open the Issues panel and run Sync.
3. Read the report rows.

## Expected

Only the real issue (#41, or #12) is linked; numbers inside a comment anchor or a version string are ignored.

## Actual

The pattern yields 41 and 1234 for the first value, and 12 and 3 for the second. Every extra number becomes a linked issue. If that issue is open and every item linked to it is done, Sync closes it with `gh issue close`.

## Environment

MarkView current main (ade7910), MarkView/Models/IssueSync.swift line 111-114; code reading and a Python evaluation of the pattern.

## Cause

`IssueSyncLinks.fieldReferences` scanned every explicit field value with one pattern whose third alternative,
`(?<![\w/#])#?(\d+)\b`, accepted a digit run anywhere that did not follow a word character, `/` or `#`. A value was
treated as text to search, not as a reference.

- The URL alternative stopped at the issue number, so the rest of the same URL was scanned again:
  `/issues/41#issuecomment-1234` gave 41 and then 1234 (preceded by `-`).
- In `see issue 12 in v2.3` the `12` is a standalone digit run and the `3` follows a `.`.
- Any number in a sentence, version or note in a field qualified in the same way.

Sync closes issues without a preview (DEC-002), so every extra number was a candidate for `gh issue close`.
REQ-002 and DEC-001 say free-text numbers are ignored; the field scan did not apply that to a field's own text.

## Resolution

A field value is now either a list of references or prose (`IssueSync.swift`, `fieldPattern` and `fieldReferences`).

- A full issue or pull request URL matches together with the rest of its word, so an anchor or a query adds no
  number. Full URLs count wherever they stand in a value, as they do in Markdown text (DEC-001).
- `owner/name#n`, `#n` and `n` must be whole words: they start the value or follow a space, comma or semicolon, and
  end the value or precede one. `v2.3`, `12abc` and `12.` are not references.
- These short forms count only when nothing else is left in the value once the references are removed, apart from
  the separators. In `see issue 12 in v2.3`, `#36 (main)` or `#1 and #2` they are ignored. An item whose fields
  yield nothing is reported as unlinked, as before.

Still accepted: a field that is just a number, `#n`, `owner/name#n`, full issue and pull request URLs (with or
without scheme and `www.`), and lists separated by spaces, commas or semicolons (`#1, #2`, `1 2`). A YAML list
gives one string per element and each is judged apart.

## Not changed

- `textReferences` (full issue URLs in Markdown) and `issueURLPattern`.
- Which fields and documents are read (`IssueSyncLoader`, DEC-012), the eligibility rules, what Sync closes and
  how it closes it.
- Pull request URLs, other repositories and the report rows behave as before.

Behaviour that is narrower on purpose: a value that mixes a short reference with words, such as `#36 (main)` or
`#1 and #2`, no longer links. The spec lists the accepted forms but does not say whether words around a reference
are allowed (F-004, DEC-006); closing the wrong issue cannot be undone, an unlinked item shows in the report.

## Verification

- `tools/tests/issue-sync-tests.sh`: 70 checks pass. 16 of the new checks failed against the previous pattern
  before the change (anchor and query on a URL, `see issue 12 in v2.3`, versions, numbers with suffixes, sentences
  with `#n`, mixed lists), and all earlier checks still pass.
- The old and the new `fieldReferences` give the same references for all 59 distinct `issue`, `issues`, `epic` and
  plan `github` values in this repository's `docs/` and `tasks/` (compiled standalone, compared line by line).
- Debug build with `xcodebuild` (see CLAUDE.md) passes.
- Not exercised: a real Sync run against GitHub from the Issues panel (`gh api`, `gh issue close`), or Sync over
  the whole project with the loader. The change is confined to the pure parsing module; the loader and the run are
  covered by the build and by reading the call path.
