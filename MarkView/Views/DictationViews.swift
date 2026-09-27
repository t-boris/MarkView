import SwiftUI
import AppKit

/// Microphone toggle for a text field: record, then stop and insert the transcript. Shown
/// only while an OpenAI key is set — the caller hides it otherwise (DEC-002).
struct DictationButton: View {
    @ObservedObject var dictation: DictationController
    var prominent = false
    /// The transcript and the window the mic was clicked in (the field's window).
    let insert: (String, NSWindow?) -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                switch dictation.phase {
                case .idle: Image(systemName: "mic")
                case .starting, .recording: Image(systemName: "mic.fill")
                case .transcribing: ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                if prominent { Text(title).uiFont(size: 12, weight: .medium) }
            }
            .uiFont(size: 13)
            .foregroundColor(dictation.isRecording || dictation.phase == .starting ? VSDark.red : prominent ? .primary : .secondary)
            .frame(width: prominent ? nil : 24, height: 24)
            .padding(.horizontal, prominent ? 10 : 0)
            .padding(.vertical, prominent ? 3 : 0)
            .background(RoundedRectangle(cornerRadius: prominent ? 6 : 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: prominent ? 6 : 12).stroke(Color.secondary.opacity(prominent ? 0.4 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(dictation.phase == .transcribing)
        .help(help)
    }

    private var title: String {
        switch dictation.phase {
        case .idle: return "Dictate"
        case .starting: return "Starting…"
        case .recording: return "Stop dictation"
        case .transcribing: return "Transcribing…"
        }
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
                .uiFont(.caption)
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
            .uiFont(.caption)
        }
    }

    private func label(dot: Color, _ text: String, warning: Bool = false) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).foregroundColor(warning ? VSDark.orange : .secondary)
            Spacer(minLength: 0)
        }
        .uiFont(.caption)
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
    /// Inserts a transcript into `text`: at the cursor (replacing a selection) when the field is
    /// focused in its own window, otherwise at the end. Only the cursor position is read from the
    /// window's text view; the edit itself always goes to `text`. Editing the text view directly
    /// does not work: its binding update is overwritten when this `inout` is written back
    /// (BUG-003). A space separates the transcript from a word it would touch.
    static func insert(_ transcript: String, window: NSWindow?, fieldFocused: Bool, text: inout String) {
        if fieldFocused, let view = window?.firstResponder as? NSTextView, view.isEditable,
           view.string == text, let range = Range(view.selectedRange(), in: text) {
            let before = text[..<range.lowerBound].last.map(String.init) ?? ""
            let after = text[range.upperBound...].first.map(String.init) ?? ""
            let piece = (needsSpace(before) ? " " : "") + transcript + (isWordCharacter(after) ? " " : "")
            text.replaceSubrange(range, with: piece)
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
