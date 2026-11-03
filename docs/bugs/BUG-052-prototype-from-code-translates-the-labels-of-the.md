---
type: bug
id: BUG-052
title: Prototype from code translates the labels of the original interface
status: fixing
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
---

# Prototype from code translates the labels of the original interface

## Summary

A prototype reconstructed from code came out in Russian although the original interface, the project documentation and the first request are English. No prompt of the build names a language; with the output language left at "Document language" nothing is appended to any request, so the assistant picks a language itself. A reconstruction must keep the labels of the original, so a translation is a fidelity error.

## Steps to reproduce

1. Open broker-fabric (English interface source, Russian feature documents under docs/features).
2. AI Tools, New Prototype from Code, source apps/strikedesk, leave Output language on Document language.
3. Read the screen names, the labels and the lang attribute of index.html of the result.

## Expected

The visible text of the prototype is the text of the original interface, in its own language (English here). Text the build has to invent follows the language of the original interface. An explicit Output language setting still wins. The lang attribute of the page matches.

## Actual

strikedesk v8: all 23 screen names, labels, messages and the assumptions are Russian and index.html has lang="ru", while apps/strikedesk/.../renderer has no file with Cyrillic text and strings such as "Max Profit" and "Order broker". The assistant's own summaries are Russian too. Why the assistant chose Russian is not proven (the project has hundreds of Russian files under docs/features; the Codex memory folder was not read).

## Environment

MarkView 5.5.0, Codex (gpt-6.1-terra), project broker-fabric, prototype strikedesk
