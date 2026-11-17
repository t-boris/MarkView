import Foundation

/// Selects the language for on-device dictation.
public enum DictationLanguage {
    /// BCP 47 form of an identifier ("ru_RU" → "ru-RU").
    public static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// The language part of an identifier, lowercased ("zh-Hans-CN" → "zh").
    static func languageCode(_ identifier: String) -> String {
        normalized(identifier).split(separator: "-").first.map { $0.lowercased() } ?? ""
    }

    /// Languages to try, best first, each one `supported`. A stored choice is the only candidate:
    /// when its model is missing the user is told so, never given another language. Otherwise each
    /// system language in order — itself when supported, then the supported variants of the same
    /// language ("ru-US" finds "ru-RU").
    public static func candidates(stored: String, preferred: [String], supported: [String]) -> [String] {
        let available = supported.map(normalized)
        func match(_ identifier: String) -> [String] {
            let wanted = normalized(identifier).lowercased()
            let code = languageCode(identifier)
            let exact = available.filter { $0.lowercased() == wanted }
            let sameLanguage = available.filter { languageCode($0) == code && $0.lowercased() != wanted }.sorted()
            return exact + sameLanguage
        }
        let trimmed = stored.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return Array(match(trimmed).prefix(1)) }
        var seen = Set<String>()
        return preferred.flatMap(match).filter { seen.insert($0).inserted }
    }
}

/// The text of a whole recording. macOS recognizes audio in windows of about a minute: each finished
/// window is reported as its own result and the final result holds only the last one, so keeping just
/// the final result drops everything before it (a 207 s recording came back as its last 27 s). Pure,
/// so it is testable on its own.
public struct TranscriptWindows {
    public init() {}
    private var texts: [Int: String] = [:]

    /// A window that starts `start` seconds into the audio. A window reported again replaces its
    /// earlier text instead of repeating it.
    public mutating func add(start: TimeInterval, text: String) {
        texts[Int(start.rounded(.down))] = text
    }

    /// The windows in audio order, joined by a space; windows with no speech add nothing.
    public var text: String {
        texts.keys.sorted()
            .compactMap { texts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
