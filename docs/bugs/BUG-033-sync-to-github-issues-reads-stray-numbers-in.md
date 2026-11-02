---
type: bug
id: BUG-033
title: Sync to GitHub issues reads stray numbers in explicit fields as issue links
status: open
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
