---
type: bug
id: BUG-121
title: New scenario shows only "Starting the assistant" for the whole run
status: backlog
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-10
provenance: Created by an AI agent through MarkView
---

# New scenario shows only "Starting the assistant" for the whole run

## Summary

After "Write scenario" the End-to-End QA sheet shows "Starting the assistant" with a spinner for minutes and nothing else, so it looks hung.

## Steps to reproduce

1. Open End-to-End QA and choose New scenario…
2. Describe a goal and choose Write scenario with Codex as the project's assistant
3. Watch the line under the players field

## Expected

The sheet says what the assistant is doing (which file it reads, what it searches, that it is writing) and how long it has been working.

## Actual

The line stays "Starting the assistant" until the scenario appears. QAModel.setActivity kept only read, search, thinking and writing; Codex reads files by running shell commands (.run), and web search and fetch were dropped too, so no progress text was ever produced. There was no clock either.

## Environment

MarkView 5.58.0, Codex CLI as the assistant, web QA scenario for dev.vivaa.ai
