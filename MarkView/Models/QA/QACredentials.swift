import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-005): a player's sign-in. The assistant never sees a password: it writes the placeholders
// {{username}} and {{password}} where the credentials go, and the real values are put in only on the way into the page. What comes back
// from the page or a request is scrubbed of the password before the assistant, the feed or the run record can see it. Foundation only;
// checked by tools/tests/qa-tests.sh.

struct QACredentials: Equatable {
    static let usernamePlaceholder = "{{username}}"
    static let passwordPlaceholder = "{{password}}"
    static let mask = "••••"
    /// A password shorter than this is not scrubbed from text: it would blot out ordinary words.
    static let shortestScrubbed = 3

    var username: String?
    var password: String?

    /// The placeholders replaced by the real values. A value this player does not have leaves its placeholder as written, so nothing is made up.
    func fill(_ text: String) -> String {
        var value = text
        if let username { value = value.replacingOccurrences(of: Self.usernamePlaceholder, with: username) }
        if let password { value = value.replacingOccurrences(of: Self.passwordPlaceholder, with: password) }
        return value
    }

    /// The placeholders that are still in the text after `fill`: this player has no such value, and typing them would put the placeholder itself
    /// in the field.
    func unfilled(_ text: String) -> [String] {
        [Self.usernamePlaceholder, Self.passwordPlaceholder].filter { fill(text).contains($0) }
    }

    /// The text without the password.
    func scrub(_ text: String) -> String {
        guard let password, password.count >= Self.shortestScrubbed else { return text }
        return text.replacingOccurrences(of: password, with: Self.mask)
    }
}
