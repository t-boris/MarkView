---
type: bug
id: BUG-136
title: Antigravity's model menu shows 4 hard-coded models instead of the account's list
status: in-review
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-27
provenance: Created by an AI agent through MarkView
schema: 1
---

# Antigravity's model menu shows 4 hard-coded models instead of the account's list

## Summary

The assistant menu (and Settings, the X-Ray model menu) offers only Default and four models for Antigravity: Gemini 4 Argon (Medium), Gemini 3.8 Flash (Medium), Claude Opus 5.5 (Medium) and Claude Sonnet 5.5 (Medium). AntigravityProvider.modelOptions() returns a fixed list ("A few of `agy models`"), while `agy models` lists 27 models for the account on 2026-11-27: Gemini 4 Neon, Carbon, Argon and Hydrogen at Low/Medium/High/XHigh, three Orchestrator models, Gemini 3.8 Flash at three levels, Claude Opus 5.5 and Sonnet 5.5 at three levels, GPT-OSS 120B. Cline and Copilot already take the account's models from the CLI and keep the last list (ACPModelCache); Antigravity was left out because it is not an ACP assistant.

## Steps to reproduce

1. Choose Antigravity as the project's assistant in the toolbar menu
2. Open the menu's Model section
3. Compare it with the output of `agy models` in a terminal

## Expected

The menu lists every model `agy models` gives for the signed-in account (with Default first), refreshed from the CLI when no list is kept yet and when Settings checks the assistant.

## Actual

Default plus four fixed models; the other 23 (e.g. Gemini 4 Neon, Hydrogen, any High or Low level, Orchestrator, GPT-OSS) can only be typed by hand as a custom model id.

## Environment

MarkView 7.21.0 installed (same code in 7.21.2), agy at ~/.local/bin/agy, macOS 27.2, 2026-11-27; code: MarkView/Models/AI/Providers/AntigravityProvider.swift:39
