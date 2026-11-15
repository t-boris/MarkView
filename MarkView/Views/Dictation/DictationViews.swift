import SwiftUI
import AppKit

/// Microphone toggle for a text field: record, then stop and insert the transcript. It works
/// without an OpenAI key (macOS's built-in recognition), so callers always show it.
struct DictationButton: View {
    @Environment(\.palette) private var palette
    @ObservedObject var dictation: DictationController
    var prominent = false
    /// A smaller mic for a one-line field in a dense panel.
    var compact = false
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
            .uiFont(size: compact ? 11 : 13)
            .foregroundColor(dictation.isRecording || dictation.phase == .starting ? palette.red : prominent ? .primary : .secondary)
            .frame(width: prominent ? nil : compact ? 18 : 24, height: compact ? 18 : 24)
            .padding(.horizontal, prominent ? 10 : 0)
            .padding(.vertical, prominent ? 3 : 0)
            .background(RoundedRectangle(cornerRadius: prominent ? 6 : 12).fill(palette.bgInput))
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
        case .idle: return "Dictate: click to record, click again to insert the text at the cursor"
        case .starting: return "Waiting for the microphone…"
        case .recording: return "Stop and insert the text · Esc cancels"
        case .transcribing: return "Transcribing…"
        }
    }
}

/// The line under a dictation field: recording time and the cap warning, transcribing,
/// or the last failure (with a way to the microphone or Speech Recognition settings when access
/// was denied, and to DDE Settings when the API key, model or language is the problem).
struct DictationStatusView: View {
    @Environment(\.palette) private var palette
    @ObservedObject var dictation: DictationController
    /// Opens DDE Settings; without it the settings button is not shown.
    var openSettings: (() -> Void)? = nil

    var body: some View {
        switch dictation.phase {
        case .idle:
            if let message = dictation.message {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(palette.orange)
                    Text(message).foregroundColor(palette.textDim).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if dictation.microphoneDenied {
                        Button("Open Microphone Settings") { Self.openPrivacySettings("Privacy_Microphone") }
                    } else if dictation.speechDenied {
                        Button("Open Speech Recognition Settings") { Self.openPrivacySettings("Privacy_SpeechRecognition") }
                    } else if dictation.opensSettings, let openSettings {
                        Button("Open DDE Settings", action: openSettings)
                    }
                    Button(action: dictation.dismissMessage) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(palette.textDim)
                    Spacer(minLength: 0)
                }
                .uiFont(.caption)
            }
        case .starting:
            label(dot: palette.red, "Starting the microphone…")
        case .recording:
            let left = max(0, dictation.maxDuration - dictation.elapsed)
            label(dot: palette.red, "Recording\(dictation.language.map { " in \($0)" } ?? "") \(Self.clock(dictation.elapsed)) — click the mic to insert the text, Esc to cancel"
                  + (dictation.nearLimit ? " · stops in \(Self.clock(left))" : ""),
                  warning: dictation.nearLimit)
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("Transcribing… you can keep typing; the text goes to the cursor.").foregroundColor(palette.textDim)
                Spacer(minLength: 0)
            }
            .uiFont(.caption)
        }
    }

    private func label(dot: Color, _ text: String, warning: Bool = false) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).foregroundColor(warning ? palette.orange : .secondary)
            Spacer(minLength: 0)
        }
        .uiFont(.caption)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A pane of System Settings → Privacy & Security ("Privacy_Microphone", "Privacy_SpeechRecognition").
    static func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Opens DDE Settings for the window that shows a dictation field (its key, model or language needs a fix). ContentView sets it
/// for its window, so a sheet or panel needs no workspace of its own; outside any window the settings open without a project.
private struct OpenDictationSettingsKey: EnvironmentKey {
    static let defaultValue: () -> Void = { Task { @MainActor in DDESettingsWindow.show(workspace: nil) } }
}

extension EnvironmentValues {
    var openDictationSettings: () -> Void {
        get { self[OpenDictationSettingsKey.self] }
        set { self[OpenDictationSettingsKey.self] = newValue }
    }
}

/// What a field needs to offer voice input: the mic, the status line and whether a recording runs.
@MainActor
struct DictationParts {
    fileprivate let dictation: DictationController
    fileprivate let insert: (String, NSWindow?) -> Void
    fileprivate let openSettings: () -> Void

    func mic(prominent: Bool = false, compact: Bool = false) -> DictationButton {
        DictationButton(dictation: dictation, prominent: prominent, compact: compact, insert: insert)
    }

    /// The line under the field: recording time, transcribing, or what went wrong.
    var status: DictationStatusView { DictationStatusView(dictation: dictation, openSettings: openSettings) }

    var isRecording: Bool { dictation.isRecording }

    /// Starting, recording or transcribing: a sheet keeps its buttons from sending half-dictated text.
    var isActive: Bool { dictation.isActive }

    /// Drops a recording in progress without inserting anything (Esc).
    func cancel() { dictation.cancel() }
}

/// Voice input for one text field. It owns the recording (so it ends with the field), puts the transcript at the cursor of `text`,
/// and hands the mic and the status line to `content` to place. Every field that takes text for the assistant uses it:
///
///     DictationInput(text: $goal, isFocused: { goalFocused }) { voice in
///         VStack { editor.overlay(alignment: .bottomTrailing) { voice.mic().padding(6) }; voice.status }
///     }
struct DictationInput<Content: View>: View {
    @Environment(\.openDictationSettings) private var openSettings
    @StateObject private var dictation = DictationController()
    @Binding var text: String
    /// Whether the field has the keyboard focus; read when a transcript arrives, to insert at the cursor.
    let isFocused: () -> Bool
    /// A recording in progress is dropped when this changes: the field now shows something else.
    var resetOn: AnyHashable = 0
    @ViewBuilder let content: (DictationParts) -> Content

    var body: some View {
        content(DictationParts(dictation: dictation, insert: insert, openSettings: openSettings))
            .onDisappear { dictation.cancel() }
            .onChange(of: resetOn) { _ in dictation.cancel() }
    }

    private func insert(_ transcript: String, window: NSWindow?) {
        var value = text
        DictationInsertion.insert(transcript, window: window, fieldFocused: isFocused(), text: &value)
        text = value
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
