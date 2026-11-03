---
type: bug
id: BUG-057
title: Prototype from code is translated to Russian again although the source language rule is in every prompt (BUG-052 did not hold)
status: open
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
updated: 2026-11-03
---

# Prototype from code is translated to Russian again although the source language rule is in every prompt (BUG-052 did not hold)

## Summary

A prototype of apps/strikedesk made with MarkView 5.8.0, which contains the BUG-052 fix, still has Russian labels, Russian screen names and the assumption that all labels are translated to Russian. The source interface is English (no .ts or .tsx file of the renderer outside tests contains Cyrillic) and Output language is on Document language (the setting is not stored at all).

## Steps to reproduce

1. Delete the old strikedesk prototype, open broker-fabric in MarkView 5.8.0 with Output language left on Document language.
2. AI Tools, New Prototype from Code, source apps/strikedesk, brief "Reconstruct the web interface of apps/strikedesk." (English).
3. Read the screen names, the labels in site/screens/*.js and the assumptions in prototype.json.

## Expected

Labels are the English strings of the source (\"Strikes\", \"Max Profit\", ...), screen names and the summary, assumptions and gaps are English (the `sourceLanguageRule` of PrototypeAI), index.html has lang=\"en\".

## Actual

strike-desk v1..v5 (built 10:06-10:30, app started 09:47): screen names in Russian (\"Торговля опционами\", \"Обзор счетов\", ...), the plan summary in Russian, and the assumption \"Все видимые подписи, сообщения, подсказки и названия элементов прототипа переводятся на русский язык\"; option-desk.js has 186 Cyrillic words, e.g. \"Страйки\" for the source's \"Strikes\". The app's AI call log shows both builds (10:01 and 10:18) ran on Codex (gpt-6.1-terra), not Claude. Delivery of the rule was checked in code: every build path passes `promptLanguage`, and for Codex it goes as the leading <instructions> block (PrototypeSession.swift:318, CLICompletion.swift); the Codex invocation of the app was reproduced argument by argument in a harness.

Reproduction attempts (2026-11-03, real CLIs, ephemeral, project root broker-fabric, production `sourceLanguageRule`, plan stage only): Claude with the empty scope, Codex with the empty scope and Codex with the app's real scope (strikedesk shell package, Electron) all answered in English: 0 Cyrillic characters in 107 463, 81 820 and 67 705 respectively; the plan summary was English and the assistant even noted \"Use English and set index.html lang to en\". So the rule works in a clean headless run, and the Russian in Boris's prototype is NOT explained by the rule being ignored in the plan prompt.

Still unexplained: something in the in-app runs made the assistant believe that the labels must be Russian (it wrote that as an assumption). Excluded: Output language (the key is absent, so the document-language path with the source rule is taken), the source language (no Cyrillic in the renderer), the brief (empty in the manifest), the global Codex AGENTS.md (empty). Not excluded: a difference between the app's process and the harness (environment, Codex home or memory, model reasoning effort from the app's preferences), a project-level instruction file read by Codex from the project root, or the Russian-speaking conversation context of an older prototype folder. Next step needs data from the app itself: one new prototype creation with a diagnostic that records, for the plan call only, whether the language rule is the last block of the prompt that Codex receives (length and the first 120 characters of that block, no document content).

## Environment

MarkView 5.8.0, project broker-fabric, prototype strike-desk, Output language = Document language (UserDefaults key actions.outputLanguage absent)
