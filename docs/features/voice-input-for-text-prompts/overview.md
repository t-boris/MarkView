---
type: feature
id: voice-input-for-text-prompts
title: Voice input for text prompts
status: review
owner: Boris Tsekinovsky
created: 2026-09-26
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: known
  Failure Scenarios: known
  Data Model: n/a
  Notifications: n/a
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
issue: "#21"
understanding_notes:
  Problem: Длинные описания медленно печатать; диктовка ускоряет ввод.
  Target Users: Пользователи MarkView, создающие фичи и баги через intake.
  Primary Workflow: Переключатель записи, после остановки текст вставляется в позицию курсора (DEC-003).
  Permissions: Нужно разрешение на микрофон; если его нет — корректная деградация (REQ-004).
  Failure Scenarios: Отказ в доступе, ошибка транскрипции, отсутствие ключа (DEC-002).
  Data Model: Аудио не сохраняется.
  Notifications: Не применимо.
  Security: Аудио отправляется в OpenAI Whisper с ключом пользователя, так же как в Терминале; это осознанный выбор.
  Analytics: Не применимо.
  Dependencies: Используется существующая диктовка Терминала (Whisper API) и ключ OpenAI из настроек.
  Acceptance Criteria: Критерии есть в REQ-001…REQ-004.
questions_left: 0
---

# Voice input for text prompts

## Idea

Let users dictate instead of typing wherever MarkView asks for free text: the new-feature and new-bug intake and any other text-entry prompt. Speech is transcribed into the field and can then be edited.

## Problem

Writing a long feature or bug description by typing is slow and discourages detail. Speaking lets users capture their thoughts faster and more fully.

## Scope

IN: a microphone control on free-text inputs in the new feature and new bug intake (FeatureIntake) and in other text prompts; live or final transcription inserted at the cursor; permission handling; the user can edit the transcript. OUT: voice commands or navigating the app by voice; audio storage or attachments; AI rewriting of the transcript (unless decided otherwise); code-editor and terminal inputs.
