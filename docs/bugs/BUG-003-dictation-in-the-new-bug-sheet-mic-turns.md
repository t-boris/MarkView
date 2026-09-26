---
type: bug
id: BUG-003
title: "Dictation in the New Bug sheet: mic turns red, but clicking it again inserts no text"
status: open
severity: high
reporter: Boris Tsekinovsky
created: 2026-09-26
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Что было написано под полем ввода, пока микрофон был красным?
    why: Если там было «Starting the microphone…», запись так и не началась, и второй клик просто отменил её без сообщения. Если шёл таймер «Recording 0:05», значит, проблема дальше — в распознавании или вставке текста.
    options:
      - label: Таймер Recording
        text: «Recording 0:0x — click the mic…» с идущим временем
      - label: Starting
        text: «Starting the microphone…»
      - label: Не заметил
        text: Не обратил внимания
    status: answered
    answer: Не заметил. Не обратил внимания
  - id: BQ-2
    text: Что появилось после второго клика по микрофону?
    why: Так станет понятно, дошло ли дело до запроса к Whisper и была ли ошибка (ключ, сеть, пустая запись).
    options:
      - label: Спиннер, потом ничего
        text: Появился «Transcribing…», затем текст не вставился
      - label: Сообщение об ошибке
        text: Появилось предупреждение под полем (укажите текст)
      - label: Ничего
        text: Иконка сразу стала обычной, без спиннера и сообщений
    status: open
  - id: BQ-3
    text: Работает ли диктовка в других местах, например в окне New Feature?
    why: "Так станет понятно, в чём проблема: в запуске записи или Whisper вообще или только в окне New Bug."
    options:
      - label: Работает
        text: В других окнах текст вставляется
      - label: Тоже не работает
        text: Текст нигде не вставляется
      - label: Не пробовал
        text: В других местах не проверял
    status: open
  - id: BQ-4
    text: Сколько времени прошло между первым и вторым кликом, и спрашивала ли macOS когда-нибудь доступ к микрофону для MarkView?
    why: Если клик был быстрым или доступа к микрофону нет, запись могла не успеть начаться. Тогда второй клик просто отменяет её.
    status: open
issue: "#23"
---

# Dictation in the New Bug sheet: mic turns red, but clicking it again inserts no text

## Summary

In the New Bug intake sheet the user clicks the microphone, speaks, and the icon turns red. Clicking the mic again inserts no transcript. The user did not notice the status line under the field while recording (BQ-1), so we can't tell `.starting` apart from `.recording`. What appeared after the second click is still unknown (BQ-2). Several code paths end silently with nothing inserted. The most likely one: the icon is red in both `.starting` and `.recording`, and a click during `.starting` calls cancel(), which drops the recording without any message.

## Steps to reproduce

1. Set an OpenAI API key in Settings (otherwise the mic button is hidden, per DEC-002).
2. Open Feature navigator → New Bug.
3. Click the microphone button next to the text field; the icon turns red.
4. Speak for a few seconds.
5. Click the microphone button again.
6. Check the text field, the status line under it, and the console for [Whisper] logs.

## Expected

After the second click the phase changes to `.transcribing` (spinner, "Transcribing…"). Then the Whisper transcript is inserted at the cursor or appended to the field. On failure an inline message appears under the field (error, "No speech recognized.", or microphone access denied).

## Actual

The mic icon turns red while the user speaks. The second click inserts no text. The user did not notice whether the status line said 'Starting the microphone…' or 'Recording 0:0x' during recording, and whether an error or spinner appeared afterwards is unknown.

## Environment

MarkView macOS app (Darwin 27.0.0), New Bug intake sheet, Whisper dictation through the OpenAI API. App build, Whisper model, microphone device and permission state are unknown.

## Suspected code

- `MarkView/Views/DictationViews.swift` — DictationButton shows the same red mic.fill in both `.starting` and `.recording`, so the user can't tell whether recording actually started.
- `MarkView/Models/DictationController.swift` — toggle(): in `.starting` a click calls cancel(), which discards the recording and sets no message. recordingChanged() resets to idle without a message. stop() shows only a generic 'Transcription failed.' when whisper.error is nil.
- `MarkView/Models/WhisperClient.swift` — stopRecording() returns nil with no error when its state is missing, and it fails on an audio file under 100 bytes. The transcribe() failure paths return nil. startRecording() may never publish isRecording = true.
- `MarkView/Views/FeatureNavigatorView.swift` — Insertion depends on `editorFocused`. `.onDisappear` and the removal handler call dictation.cancel(), which could drop a transcript in flight.

## Likely causes

- The recorder never reaches `.recording` and the controller stays in `.starting` with a red icon. The second click then counts as cancel(), so nothing is inserted or reported.
- The audio file is empty or tiny (wrong input device or permission problem), so stopRecording() fails.
- The Whisper request fails (invalid key, HTTP error, network) and the error shows only in the status line, which the user missed.
- Whisper returns empty text, so the only feedback is 'No speech recognized.'.
- The transcript is inserted into the wrong first responder.

## Missing information

- What appeared under the field after the second click (BQ-2)
- Console logs with the [Whisper] prefix
- Microphone permission state and input device
- Whether dictation works in the New Feature sheet or in other fields
- Whether the problem reproduces every time

## Clarifications

**BQ-1** Что было написано под полем ввода, пока микрофон был красным?
→ Не заметил. Не обратил внимания

## Original description

Микрофончик не работает. Когда я пытаюсь открыть баг, я говорю в микрофон, он выделяется красным, потом я нажимаю на микрофон, он ничего не вставляет, никакого текста.
