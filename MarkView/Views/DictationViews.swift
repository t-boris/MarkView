import SwiftUI
import AppKit

/// Microphone toggle for a text field: record, then stop and insert the transcript. Shown
/// only while an OpenAI key is set — the caller hides it otherwise (DEC-002).
struct DictationButton: View {
    @ObservedObject var dictation: DictationController
    /// The transcript and the window the mic was clicked in (the field's window).
    let insert: (String, NSWindow?) -> Void

    var body: some View {
        Button(action: toggle) {
            Group {
                switch dictation.phase {
                case .idle: Image(systemName: "mic")
                case .starting, .recording: Image(systemName: "mic.fill")
                case .transcribing: ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(dictation.isRecording || dictation.phase == .starting ? VSDark.red : .secondary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color(nsColor: .textBackgroundColor)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(dictation.phase == .transcribing)
        .help(help)
    }

    private func toggle() {
        let window = NSApp.keyWindow
        dictation.toggle { [weak window] transcript in insert(transcript, window) }
    }

    private var help: String {
        switch dictation.phase {
        case .idle: return "Dictate (Whisper): click to record, click again to insert the text at the cursor"
        case .starting: return "Waiting for the microphone…"
        case .recording: return "Stop and insert the text · Esc cancels"
        case .transcribing: return "Transcribing…"
        }
    }
}

/// The line under a dictation field: recording time and the cap warning, transcribing,
/// or the last failure (with a way to microphone settings when access was denied).
struct DictationStatusView: View {
    @ObservedObject var dictation: DictationController

    var body: some View {
        switch dictation.phase {
        case .idle:
            if let message = dictation.message {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(VSDark.orange)
                    Text(message).foregroundColor(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if dictation.microphoneDenied {
                        Button("Open Microphone Settings") { openMicrophoneSettings() }
                    }
                    Button(action: dictation.dismissMessage) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                .font(.caption)
            }
        case .starting:
            label(dot: VSDark.red, "Starting the microphone…")
        case .recording:
            let left = max(0, dictation.maxDuration - dictation.elapsed)
            label(dot: VSDark.red, "Recording \(Self.clock(dictation.elapsed)) — click the mic to insert the text, Esc to cancel"
                  + (dictation.nearLimit ? " · stops in \(Self.clock(left))" : ""),
                  warning: dictation.nearLimit)
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("Transcribing… you can keep typing; the text goes to the cursor.").foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
    }

    private func label(dot: Color, _ text: String, warning: Bool = false) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).foregroundColor(warning ? VSDark.orange : .secondary)
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum DictationInsertion {
    /// Inserts a transcript into the field's own window's first responder text view when the
    /// field is focused there — at the cursor, replacing a selection — and otherwise appends it
    /// to `text`. Another window's text view (the user moved on) is never touched. A space
    /// separates it from a word it would touch. The field's whole text is never replaced.
    static func insert(_ transcript: String, window: NSWindow?, fieldFocused: Bool, text: inout String) {
        if fieldFocused, let view = window?.firstResponder as? NSTextView, view.isEditable {
            let range = view.selectedRange()
            let content = view.string as NSString
            let before = range.location > 0 ? content.substring(with: NSRange(location: range.location - 1, length: 1)) : ""
            let afterIndex = range.location + range.length
            let after = afterIndex < content.length ? content.substring(with: NSRange(location: afterIndex, length: 1)) : ""
            let piece = (needsSpace(before) ? " " : "") + transcript + (isWordCharacter(after) ? " " : "")
            // Through the text view, so it is one undoable edit and the binding follows.
            view.insertText(piece, replacementRange: range)
        } else {
            let last = text.last.map(String.init) ?? ""
            text += (needsSpace(last) ? " " : "") + transcript
        }
    }

    private static func needsSpace(_ neighbour: String) -> Bool {
        guard let scalar = neighbour.unicodeScalars.first else { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// A following letter or digit gets a space; punctuation stays attached.
    private static func isWordCharacter(_ neighbour: String) -> Bool {
        guard let scalar = neighbour.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }
}
