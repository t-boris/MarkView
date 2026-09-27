---
type: bug
id: BUG-003
title: "Dictation in the New Bug sheet: mic turns red, but clicking it again inserts no text"
status: fixed
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
    status: answered
    answer: Ничего. Иконка сразу стала обычной, без спиннера и сообщений
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
    status: answered
    answer: Работает. В других окнах текст вставляется
  - id: BQ-4
    text: Сколько времени прошло между первым и вторым кликом, и спрашивала ли macOS когда-нибудь доступ к микрофону для MarkView?
    why: Если клик был быстрым или доступа к микрофону нет, запись могла не успеть начаться. Тогда второй клик просто отменяет её.
    status: open
  - id: BQ-5
    text: Есть ли MarkView в списке «Системные настройки → Конфиденциальность и безопасность → Микрофон», и если есть, включён ли переключатель?
    why: "Судя по коду, запись так и не началась: диктовка застряла на запуске микрофона, а второй клик её молча отменил. Состояние разрешения покажет, в чём причина: запрос доступа не приходит вообще или приходит, но запись всё равно не стартует."
    options:
      - label: Нет в списке
        text: MarkView в списке нет
      - label: Есть, включён
        text: MarkView в списке, доступ включён
      - label: Есть, выключен
        text: MarkView в списке, доступ выключен
    status: answered
    answer: Есть, включён. MarkView в списке, доступ включён
  - id: BQ-6
    text: Если сейчас открыть New Bug и повторить диктовку, ошибка воспроизводится каждый раз?
    why: New Bug и New Feature — это один и тот же код. Если ошибка бывает только иногда, дело скорее во времени между кликами или в другом активном микрофоне (терминал, голосовая заметка), а не в самом окне New Bug.
    options:
      - label: Всегда
        text: Воспроизводится при каждой попытке в New Bug
      - label: Иногда
        text: Иногда в New Bug текст вставляется нормально
      - label: Было один раз
        text: Сейчас работает и в New Bug
    status: answered
    answer: Всегда. Воспроизводится при каждой попытке в New Bug
  - id: BQ-7
    text: Когда вы диктовали в New Bug, была ли одновременно открыта другая диктовка — в терминале или голосовая заметка?
    why: Если да, другая запись могла перехватить микрофон и молча остановить диктовку в New Bug. Это главная версия.
    options:
      - label: Да
        text: Была активна другая диктовка или запись
      - label: Нет
        text: Другой диктовки не было
      - label: Не знаю
        text: Не помню
    status: answered
    answer: Нет. Другой диктовки не было
  - id: BQ-8
    text: Как вы открываете окно New Bug, когда диктовка не работает?
    why: "Код окна у New Bug и New Feature общий. Поэтому стабильная разница, скорее всего, в том, как открыто окно: при открытии из issue или из файла окно может перерисоваться и молча сбросить запись."
    options:
      - label: Навигатор
        text: Кнопка «+» / New Bug в Feature navigator
      - label: Из GitHub issue
        text: New Bug из issue или с кнопкой «From GitHub Issue…»
      - label: Из файла
        text: New Bug из открытого документа или файла
      - label: Другое
        text: Иначе или не помню
    status: answered
    answer: Навигатор. Кнопка «+» / New Bug в Feature navigator
issue: "#23"
---

# Dictation in the New Bug sheet: mic turns red, but clicking it again inserts no text

## Summary

Dictation in the New Bug sheet opened from the Feature navigator '+': the mic turns red on the first click, and the second click returns it to idle at once with no spinner, message or text. It fails on every attempt (BQ-6). New Feature and other windows work (BQ-3). Microphone permission is granted (BQ-5) and nothing else was dictating (BQ-7). The entry point is the navigator '+' (BQ-8). In the code, that path creates a plain `IntakeRequest(kind: .bug)`, the same shape as New Feature, with no loadIssue, linkedIssue or attachments. The earlier theory that issue loading or an `intake` mutation re-creates the sheet therefore does not apply here. No bug-specific code in IntakeSheet affects dictation: the only `.bug` branch is the linked-issue toggle, which is hidden without a linked issue. So the cause is still unknown. The top candidates are a silent recorder failure or a silent cancel from `.starting`. Either way, the UI hides the real reason, because cancels and failures show no message.

## Steps to reproduce

1. Set an OpenAI API key in Settings.
2. In the Feature navigator, click '+' in the Bugs section to open New Bug.
3. Click the mic button in the text field; the icon turns red.
4. Speak for about 3–5 seconds and watch the status line under the field: is it 'Recording 0:0x' or nothing?
5. Click the mic button again.
6. Observe: the icon resets at once, with no spinner, message or inserted text. Capture the [Whisper] console logs and the DictationController phase transitions.
7. Repeat with '+' in the Features section (New Feature) and compare the logs.

## Expected

First click: `.starting` → `.recording`, with 'Recording 0:0x' shown. Second click: `.transcribing` with a spinner, then the transcript is inserted. New Bug and New Feature behave the same. Any cancel or failure shows an inline message.

## Actual

In New Bug opened from the navigator, every attempt fails the same way: a red icon, then idle on the second click with no spinner, message or text. New Feature inserts text normally.

## Environment

MarkView macOS app (Darwin 27.0.0). New Bug intake sheet opened from the Feature navigator '+' (IntakeRequest(kind: .bug)). Whisper through the OpenAI API. Microphone permission granted, no concurrent dictation, reproduces 100%. Unknown: app build, input device.

## Suspected code

- `MarkView/Models/DictationController.swift` — toggle() in `.starting` cancels silently, and recordingChanged(false) resets to idle with no message. Either path matches the symptom: idle at once, no spinner.
- `MarkView/Models/WhisperClient.swift` — A recorder that fails or stops right after start may not report an error to the controller. Its shared-microphone interruption logic may also stop the intake recording.
- `MarkView/Views/DictationViews.swift` — `.starting` and `.recording` both show a red mic. No message is shown after a cancel or failure, so the user cannot see which one happened.
- `MarkView/Views/FeatureNavigatorView.swift` — IntakeSheet owns the dictation. `.onDisappear` and `onChange(openAIKey.isEmpty)` cancel it. It is the only shared code with kind-dependent branches (line ~476, the bug-only toggle); check whether anything differs for `.bug` in the navigator path.
- `MarkView/Views/ContentView.swift` — `.sheet(item: $workspaceManager.intake)`: any reassignment of `intake` while the sheet is open re-creates it and resets the @StateObject. Less likely now that the path has no loadIssue.

## Likely causes

- The recording ends or fails right after it starts, and recordingChanged(false) returns the phase to idle without an error. Why only New Bug is unexplained.
- The phase never leaves `.starting` (the recorder start never confirms), and the second click triggers the silent cancel().
- Something re-renders or re-creates the sheet on the bug path (onDisappear → cancel). Less likely: the navigator path builds the same IntakeRequest shape as New Feature.
- Amplifying UX defect: cancels and failures produce no message, which hides the real cause.

## Missing information

- [Whisper] console logs and the DictationController phase transitions for one failing attempt in New Bug, and for one working attempt in New Feature
- Whether 'Recording 0:0x' appears while the mic is red (tells `.starting` apart from `.recording`)
- Time between the first and second click (BQ-4)
- App build and input device

## Clarifications

**BQ-1** Что было написано под полем ввода, пока микрофон был красным?
→ Не заметил. Не обратил внимания

**BQ-2** Что появилось после второго клика по микрофону?
→ Ничего. Иконка сразу стала обычной, без спиннера и сообщений

**BQ-3** Работает ли диктовка в других местах, например в окне New Feature?
→ Работает. В других окнах текст вставляется

**BQ-5** Есть ли MarkView в списке «Системные настройки → Конфиденциальность и безопасность → Микрофон», и если есть, включён ли переключатель?
→ Есть, включён. MarkView в списке, доступ включён

**BQ-7** Когда вы диктовали в New Bug, была ли одновременно открыта другая диктовка — в терминале или голосовая заметка?
→ Нет. Другой диктовки не было

**BQ-6** Если сейчас открыть New Bug и повторить диктовку, ошибка воспроизводится каждый раз?
→ Всегда. Воспроизводится при каждой попытке в New Bug

**BQ-8** Как вы открываете окно New Bug, когда диктовка не работает?
→ Навигатор. Кнопка «+» / New Bug в Feature navigator

## Original description

Микрофончик не работает. Когда я пытаюсь открыть баг, я говорю в микрофон, он выделяется красным, потом я нажимаю на микрофон, он ничего не вставляет, никакого текста.

## Resolution (2026-09-26, 2.17.1)

**Reproduced** in a Developer ID-signed copy of 2.17.0 with temporary stderr tracing, run beside the
installed app. Recording and Whisper both worked (`starting → recording → transcribing → idle`,
transcript returned), and the transcript reached `DictationInsertion.insert`. The field's text then
went from 0 to 45 characters and straight back to 0. This happens in New Feature as well; nothing
about it is specific to New Bug.

**Root cause.** `DictationInsertion.insert(_:window:fieldFocused:text:)` received the field's text as
`inout String`. When the field was focused, it inserted the transcript through
`NSTextView.insertText(_:replacementRange:)`. The text view pushed the new value into the
`TextEditor` binding. When the function returned, Swift wrote the untouched `inout` copy (the old
text) back to the same `@State`, which erased the insertion. No error was raised, so the UI showed
nothing.

**Fix** (`MarkView/Views/DictationViews.swift`). The transcript is always written to `text`. The
text view is only used to read the cursor or selection (UTF-16 `NSRange` → `Range<String.Index>`).
When the field is not focused, or the view's string no longer matches `text`, the transcript is
appended. Spacing rules are unchanged.

**Verified** in the signed copy: New Bug from the navigator '+', field focused, dictate → the
transcript stays in the field (trace: text length 0 → 23, no rollback). A second dictation with the
cursor at the start inserted at the cursor. Debug build of the app succeeds.

**Not the cause:** the early theories in this report (a stuck `.starting`, sheet re-creation,
microphone permission). The trace showed the recorder starting and stopping normally every time.
