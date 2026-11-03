---
type: bug
id: BUG-052
title: Prototype from code translates the labels of the original interface
status: fixed
branch: fix/bug-052-prototype-label-language
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

## Cause

No prompt of the build names a language. The output language setting is "Document language" by default, and then `languageNote` is empty, so the
assistant chooses a language itself. For a prototype made from code that choice is wrong in principle: the labels of the original are data to be
copied, not text to be written. On strikedesk the assistant wrote Russian (all 23 screen names, labels, `lang="ru"`, summaries and assumptions)
for an interface with English strings and English project instructions; why it chose Russian is not proven (the project has hundreds of Russian
files under `docs/features`; the Codex memory folder was not read).

## Resolution

- `PrototypeAI.languageNote(explicit:mode:)`: an explicit output language is used as before. For a prototype made from code on "Document language"
  every run gets `sourceLanguageRule`: copy each visible label, message, tooltip and placeholder exactly as the source writes it, in the source's own
  language, never translate; text the source does not provide is in the language of the source's interface (English when it has no visible text);
  set `lang` of index.html to that language; write `summary`, `assumptions`, `gaps` and the purpose of each screen in English (they are saved in
  the project's files); a request of the reviewer for another language overrides it ("Convert all preview to english" keeps working).
- `PrototypeSession.promptLanguage` carries it into the build, the sync, every revision and the fix rounds. Requirements prototypes and the
  SPEC.md run are unchanged.
- To change an existing prototype: set Output language to English (DDE Settings), reopen the prototype tab (the setting is read when it opens),
  and send "Convert all preview to english" (a file-by-file revision since 5.5.0). A sync rebuilds everything, so do it only after the setting.

## Verification

- `tools/tests/prototype-tests.sh`: the note per mode and setting, the rule reaches the code plan, data, shell, screen, component and revise
  prompts, requirements prompts unchanged (the pinned digests did not change).
- Real `claude` CLI through the real `PrototypeAI.build` (code mode, Document language) on two tiny apps. English interface with a Russian notes
  file in the project: `lang="en"`, no Cyrillic character in any generated file, English summary and assumptions. Russian interface: labels kept
  (Заказы, Клиенты, Добавить клиента), `lang="ru"`, English summary, assumptions and gaps. So the rule does not harm a Russian source.
- Control run of the English app with the rule switched off: also English. This tiny project does not reproduce the report, so the live run is
  **not** proof that the rule removes the bug; what is proven is that every prompt now carries the rule (unit tests) and that it does not change
  the outcome where the model already behaved.
- Debug `xcodebuild`: build succeeded, app version 5.5.1.
- Not verified: the Codex provider that produced the report (the runs used `claude`); a full build of the strikedesk prototype, where the first
  rebuild after this release is Boris's check.
