---
type: bug
id: BUG-057
title: "Prototype from code is translated to Russian: the global Output language (Russian) replaces the keep-the-source-language rule"
status: fixing
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
updated: 2026-11-03
---

# Prototype from code is translated to Russian: the global Output language (Russian) replaces the keep-the-source-language rule

## Summary

A prototype of apps/strikedesk (an English interface; no .ts or .tsx file of the renderer outside tests contains Cyrillic) comes out with Russian screen names, Russian labels and the assumption 'all visible labels, messages and hints are translated to Russian'. Cause (proven 2026-11-03): the app setting Output language is Russian (actions.outputLanguage = Russian in ~/Library/Preferences/com.markview.MarkView.plist). WorkspaceManager.openPrototype turns it into the session's languageNote ('Write every label, text and message in the prototype in Russian.'), and PrototypeAI.languageNote(explicit:mode:) let an explicit language REPLACE the BUG-052 source-language rule, even in code mode. The assistant followed the instruction it was given; the assumption it wrote is a restatement of it.

Fix (5.10.2): in code mode the source-language rule always applies and the global Output language is ignored (it is for explanations and documents, not for the labels of a reconstruction). A request of the reviewer in the chat that asks for another language still overrides the rule. Requirements prototypes and the specification export still follow the Output language. An existing prototype is not rewritten: run Sync with Rebuild everything, or create it again.

## Steps to reproduce

1. Set Settings, Output language to Russian (the setting is global).
2. AI Tools, New Prototype from Code, source apps/strikedesk, brief "Reconstruct the web interface of apps/strikedesk." (English).
3. Read the screen names, the labels in site/screens/*.js and the assumptions in prototype.json: they are Russian.

## Expected

Labels are the English strings of the source ("Strikes", "Max Profit", ...), screen names and the summary, assumptions and gaps are English (the `sourceLanguageRule` of PrototypeAI), index.html has lang="en", whatever the Output language is.

## Actual

strike-desk v1..v5 (built 10:06-10:30 with 5.8.0) and the later strikedesk v1: screen names in Russian, the plan summary in Russian, option-desk.js with 186 Cyrillic words ("Strikes" became the Russian word). The AI call log shows both builds ran on Codex. Four headless planner runs (Claude, Codex, and Codex with the app's code scope; ephemeral, project root broker-fabric) answered in English: 0 Cyrillic characters in 107 463, 81 820 and 67 705 for three of them. They did not see the setting because it lives in the app's preferences, which a separate process does not read; that is why the cause stayed unexplained for hours. An earlier version of this record said the setting was absent: wrong, `defaults read com.markview.MarkView` returned a 10-key container copy instead of the 150-key ~/Library/Preferences file.

## Environment

MarkView 5.8.0, project broker-fabric, prototype strike-desk, Output language = Document language (UserDefaults key actions.outputLanguage absent)
