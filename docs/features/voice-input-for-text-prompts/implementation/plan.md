---
type: plan
feature: voice-input-for-text-prompts
title: Voice input for intake text prompts (Whisper dictation)
issues:
  - id: I-1
    title: Extract reusable Whisper dictation service from Terminal
    summary: Refactor the existing Terminal dictation (recording, OpenAI Whisper upload with auto language detection, no translation) into a shared service/controller usable by native SwiftUI fields. The service enforces a single active recording app-wide, exposes idle/recording/transcribing states and elapsed time, supports cancel (discard, no result), and applies the recording cap (reuse the Terminal limit if one exists, otherwise 10 min with a 30 s warning and auto-stop that transcribes what was recorded). It deletes temp audio after completion, failure or cancel. Terminal dictation must keep working on the shared service.
    requirements: [REQ-002, REQ-003]
    decisions: [DEC-001, DEC-003, DEC-005, DEC-007, DEC-008, DEC-010]
  - id: I-2
    title: Mic control component with key-gated visibility
    summary: Build a reusable mic toggle control for SwiftUI text inputs. It is shown only while an OpenAI key is configured and reacts live when the key is added or removed. Removing the key during recording or transcription cancels it and discards the audio. The control shows a recording indicator with elapsed time and the cap warning, then a transcribing state, matching the Terminal control. Esc cancels without inserting.
    requirements: [REQ-001, REQ-003]
    decisions: [DEC-002, DEC-003, DEC-007, DEC-008]
  - id: I-3
    title: Cursor-position transcript insertion into native text fields
    summary: Implement insertion of the finished transcript into the originating field. The text goes at the current cursor position when transcription completes, or is appended at the end if the field is not focused. It must never replace the whole field. The field stays editable during transcription, and the inserted text is ordinary editable text. This likely needs an NSTextView-backed wrapper or selection tracking for the SwiftUI editors used in FeatureIntake.
    requirements: [REQ-002]
    decisions: [DEC-007, DEC-003]
  - id: I-4
    title: Integrate mic into FeatureIntake fields
    summary: Attach the mic control to the new-feature description, the new-bug description and the free-text answer inputs inside FeatureIntake, including custom answer text. Closing or cancelling the intake sheet stops recording or transcription and discards the result. Starting the mic on another field cancels the current recording. Q-document answers, resolution dialogs, chat, the Markdown editor, code editors and the terminal do not get the mic.
    requirements: [REQ-001, REQ-003]
    decisions: [DEC-004, DEC-009, DEC-006, DEC-007]
  - id: I-5
    title: Permission and failure handling with inline errors
    summary: Request microphone permission on first use and verify that NSMicrophoneUsageDescription is present. If access is denied, show an inline message below the field with a button that opens System Settings > Privacy > Microphone. Network, API and invalid-key failures show a non-blocking inline error and leave the field text unchanged. An empty or silent transcript inserts nothing and shows 'No speech recognized'. Typing stays possible after any failure.
    requirements: [REQ-004]
    decisions: [DEC-011, DEC-002]
  - id: I-6
    title: Privacy disclosure and documentation
    summary: Update the README and the OpenAI key help text in Settings. They should state that dictated audio is sent to OpenAI for transcription and billed to the user's key, and that the mic appears in intake fields only when a key is configured. This also improves discoverability, which matters because the control is hidden without a key.
    requirements: [REQ-001, REQ-004]
    decisions: [DEC-010, DEC-002]
updated: 2026-09-26
---

# Implementation plan — Voice input for text prompts

## I-1: Extract reusable Whisper dictation service from Terminal

Refactor the existing Terminal dictation (recording, OpenAI Whisper upload with auto language detection, no translation) into a shared service/controller usable by native SwiftUI fields. The service enforces a single active recording app-wide, exposes idle/recording/transcribing states and elapsed time, supports cancel (discard, no result), and applies the recording cap (reuse the Terminal limit if one exists, otherwise 10 min with a 30 s warning and auto-stop that transcribes what was recorded). It deletes temp audio after completion, failure or cancel. Terminal dictation must keep working on the shared service.

Requirements: REQ-002, REQ-003
Decisions: DEC-001, DEC-003, DEC-005, DEC-007, DEC-008, DEC-010

## I-2: Mic control component with key-gated visibility

Build a reusable mic toggle control for SwiftUI text inputs. It is shown only while an OpenAI key is configured and reacts live when the key is added or removed. Removing the key during recording or transcription cancels it and discards the audio. The control shows a recording indicator with elapsed time and the cap warning, then a transcribing state, matching the Terminal control. Esc cancels without inserting.

Requirements: REQ-001, REQ-003
Decisions: DEC-002, DEC-003, DEC-007, DEC-008

## I-3: Cursor-position transcript insertion into native text fields

Implement insertion of the finished transcript into the originating field. The text goes at the current cursor position when transcription completes, or is appended at the end if the field is not focused. It must never replace the whole field. The field stays editable during transcription, and the inserted text is ordinary editable text. This likely needs an NSTextView-backed wrapper or selection tracking for the SwiftUI editors used in FeatureIntake.

Requirements: REQ-002
Decisions: DEC-007, DEC-003

## I-4: Integrate mic into FeatureIntake fields

Attach the mic control to the new-feature description, the new-bug description and the free-text answer inputs inside FeatureIntake, including custom answer text. Closing or cancelling the intake sheet stops recording or transcription and discards the result. Starting the mic on another field cancels the current recording. Q-document answers, resolution dialogs, chat, the Markdown editor, code editors and the terminal do not get the mic.

Requirements: REQ-001, REQ-003
Decisions: DEC-004, DEC-009, DEC-006, DEC-007

## I-5: Permission and failure handling with inline errors

Request microphone permission on first use and verify that NSMicrophoneUsageDescription is present. If access is denied, show an inline message below the field with a button that opens System Settings > Privacy > Microphone. Network, API and invalid-key failures show a non-blocking inline error and leave the field text unchanged. An empty or silent transcript inserts nothing and shows 'No speech recognized'. Typing stays possible after any failure.

Requirements: REQ-004
Decisions: DEC-011, DEC-002

## I-6: Privacy disclosure and documentation

Update the README and the OpenAI key help text in Settings. They should state that dictated audio is sent to OpenAI for transcription and billed to the user's key, and that the mic appears in intake fields only when a key is configured. This also improves discoverability, which matters because the control is hidden without a key.

Requirements: REQ-001, REQ-004
Decisions: DEC-010, DEC-002
