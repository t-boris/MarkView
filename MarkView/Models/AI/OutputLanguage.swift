import Foundation
import CryptoKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Language everything the AI writes is in (toolbar and DDE Settings): X-Ray, Explain,
/// filters and reviews. The storage key predates the removal of the Actions tab.
enum ActionOutputLanguage {
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
    static var current: String { Settings.standard.value(Setting.outputLanguage) }

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

/// SHA-256 and FNV-1a of text/data as lowercase hex: cache keys and "did the content change" checks (`AR-24`).
enum ContentHash {
    static func of(_ text: String) -> String {
        sha256Hex(text)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    static func fnv1a64Hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
