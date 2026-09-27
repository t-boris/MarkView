---
type: bug
id: BUG-009
title: Raw JSON shown for transcription errors
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Где именно появился JSON и что вы сделали перед ошибкой?
    why: Это определит путь отображения и позволит воспроизвести сбой.
    options:
      - label: New Bug / New Feature field
        text: The JSON appeared below a dictation field in an intake form.
      - label: Terminal microphone
        text: The JSON appeared in the Terminal microphone tooltip.
      - label: Other screen
        text: The JSON appeared elsewhere in MarkView.
    status: answered
    answer: New Bug / New Feature field. The JSON appeared below a dictation field in an intake form.
  - id: BQ-2
    text: Можете прислать точный текст ошибки или скриншот и версию MarkView? Секретный ключ и личные данные можно скрыть.
    why: HTTP-код и код ошибки помогут проверить конкретный сценарий; версия покажет, к какой сборке относится баг.
    status: open
issue: "#41"
---

# Raw JSON shown for transcription errors

## Summary

Transcription API errors can appear as raw JSON below a dictation field in New Bug and New Feature intake forms, leaving users without a clear explanation or next step.

## Steps to reproduce

1. Open a New Bug or New Feature intake form with an OpenAI API key configured.
2. Start dictation in a field, record audio, then stop to submit it.
3. If the transcription endpoint returns a non-200 response with a JSON body, inspect the inline message below the field. A reliable trigger for the reported API failure has not been confirmed.

## Expected

After transcription fails, show a readable explanation and a relevant recovery step in the intake form. Keep the field editable and preserve its existing text.

## Actual

User-reported: raw JSON appeared below a dictation field in a New Bug or New Feature intake form after transcription failed. Code inspection confirms that this inline message can contain the API response body; the specific failure has not been reproduced.

## Environment

MarkView native macOS app (macOS 13+), in a New Bug or New Feature intake form. Transcription uses an OpenAI API key and a selectable model: whisper-1, gpt-4o-transcribe, or gpt-4o-mini-transcribe. App version, macOS version, selected model, and API failure details are unknown.

## Suspected code

- `MarkView/Models/WhisperClient.swift` — For a non-200 response, constructs the published error from the HTTP status, selected model, and first 300 characters of the raw response body.
- `MarkView/Models/DictationController.swift` — On failed transcription, copies WhisperClient.error into the intake field’s inline message.
- `MarkView/Views/DictationViews.swift` — Renders the inline message directly; its only contextual recovery button is for denied microphone access.

## Likely causes

- Confirmed in code: WhisperClient includes the first 300 characters of a non-200 API response body in its error string without parsing it into a readable explanation.
- Confirmed in code: DictationController passes that string to the intake field’s inline message, and DictationStatusView renders it directly.
- The underlying API failure remains unknown because its HTTP status and error code have not been provided.

## Missing information

- The exact API failure, including HTTP status and error code, is unknown; this limits reproduction of the specific incident but does not prevent fixing the confirmed raw-response display path.
- The app version and selected transcription model are unknown.

## Clarifications

**BQ-1** Где именно появился JSON и что вы сделали перед ошибкой?
→ New Bug / New Feature field. The JSON appeared below a dictation field in an intake form.

## Resolution (2.25.2)

- Root cause: `WhisperClient.transcribe` built the error for any non-200 answer as
  `Whisper API error (HTTP <status>, model <model>): <first 300 characters of the body>`. OpenAI's body is a JSON
  error object, so the intake field (`DictationController` → `DictationStatusView`) showed raw JSON, including the
  masked key fragment OpenAI echoes. The terminal mic tooltip and the Settings self-test used the same string.
- Reproduced with a fake key against `/v1/audio/transcriptions`: HTTP 401, `{"error": {"message": "Incorrect API key
  provided: sk-fake-**********epro. …", "type": "invalid_request_error", "code": "invalid_api_key"}}` — exactly the
  text that landed below the field.
- Fix: `TranscriptionFailure` turns the status and OpenAI's error code into a problem, a next step and a short tag,
  e.g. "OpenAI rejected the API key. Check or replace the key in DDE Settings. (HTTP 401 · invalid_api_key)".
  Covered: bad key, no credit, rate limit, unavailable model, forbidden model, unsupported region, too large, too
  short, other 4xx, 5xx, non-JSON bodies, offline and timeout. Only snake_case codes reach the tag; the body is never
  shown or logged (the log gets the tag only).
- Recovery: for key and model problems (and unexplained failures, pointing to the "Record 3s and transcribe" test)
  the line under the field has an **Open DDE Settings** button (owner's choice); the field stays editable and its text
  is kept. The DDE Settings window opener is shared (`DDESettingsWindow`) by the menu and the intake sheet.
- Verified: `tools/tests/transcription-failure-tests.sh` (58 checks, including the captured 401 body); the real
  `WhisperClient` compiled into a harness with a fake key produced the message above and `errorOpensSettings = true`;
  Debug build. The failure line and button were not exercised in the running UI (needs a microphone grant for a test
  copy); the owner checks it with a wrong key after installing.
- BQ-2 remains open: the original HTTP status and code are unknown. The new tag makes a repeat report self-describing.

## Original description

У нас есть баг такой, что если ошибка во время транскрибации аудио в текст, то мы показываем просто там JSON. Сделай красивый показ ошибок, чтобы было понятно, в чем дело, и, в принципе, было бы неплохо, чтобы были какие-то следующие шаги, как это можно починить.
