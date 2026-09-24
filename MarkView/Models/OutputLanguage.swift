import Foundation
import CryptoKit

/// Language everything the AI writes is in (toolbar and DDE Settings): X-Ray, Explain,
/// filters and reviews. The storage key predates the removal of the Actions tab.
enum ActionOutputLanguage {
    static let storageKey = "actions.outputLanguage"
    /// Stored value meaning "same language as the source document".
    static let documentLanguage = "document"

    /// (stored value, menu label). Values other than `documentLanguage` go into the prompt.
    static let options: [(value: String, label: String)] = [
        (documentLanguage, "Document language"),
        ("English", "English"),
        ("Russian", "Русский"),
        ("Ukrainian", "Українська"),
        ("German", "Deutsch"),
        ("French", "Français"),
        ("Spanish", "Español"),
        ("Hebrew", "עברית"),
        ("Chinese (Simplified)", "中文"),
    ]

    static func label(for value: String) -> String {
        options.first { $0.value == value }?.label ?? value
    }

    /// The language chosen for everything the AI writes.
    static var current: String { UserDefaults.standard.string(forKey: storageKey) ?? documentLanguage }

    /// Instruction for generated text that is not a transformation of one document:
    /// code explanations, architecture descriptions, rating reasons, reviews.
    static func explanationLine(_ value: String = current) -> String {
        value == documentLanguage
            ? "Write all natural-language text in the language the project's documents and code comments mostly use; English when unclear."
            : "Write every natural-language text you produce (names, titles, summaries, explanations, reasons) in \(value). Keep code, identifiers, file paths and the fixed enum values of the JSON schema exactly as specified."
    }

    static func promptLine(for value: String) -> String {
        value == documentLanguage
            ? "Write in the same language as the source document."
            : "Write the whole result in \(value), even if the source document is in another language. Keep code, identifiers, file names and Mermaid node IDs unchanged."
    }
}

/// SHA-256 of text as lowercase hex: cache keys and "did the content change" checks.
enum ContentHash {
    static func of(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
