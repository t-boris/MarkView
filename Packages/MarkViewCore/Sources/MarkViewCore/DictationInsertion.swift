import AppKit

public enum DictationInsertion {
    /// Inserts a transcript into `text`: at the cursor (replacing a selection) when the field is
    /// focused in its own window, otherwise at the end. Only the cursor position is read from the
    /// window's text view; the edit itself always goes to `text`. Editing the text view directly
    /// does not work: its binding update is overwritten when this `inout` is written back
    /// (BUG-003). A space separates the transcript from a word it would touch.
    @MainActor
    public static func insert(_ transcript: String, window: NSWindow?, fieldFocused: Bool, text: inout String) {
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
