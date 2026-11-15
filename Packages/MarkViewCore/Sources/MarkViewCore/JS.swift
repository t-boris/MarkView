import Foundation

/// The one way the app builds a script for a page (`AR-04`).
///
/// A script that names a page function is made here from the function's name and its arguments; every argument is encoded as
/// JSON, so a value can never become code. Nothing in the app splices a value into script text with string interpolation: a
/// script that takes no value is a constant literal, and a script that takes values is a `JS.call`.
public enum JS {
    /// A JSON text the page parses itself. The text travels as ONE JSON string literal and the script calls `JSON.parse` on it, so
    /// a large payload that was already encoded elsewhere (the X-Ray snapshot) is neither parsed nor copied by Swift, and a text that
    /// is not JSON fails in the page with a `SyntaxError` instead of changing the script.
    public struct JSONText {
        public let text: String
        public init(_ text: String) { self.text = text }

        /// `value` encoded with `JSONEncoder`; nil when it cannot be encoded.
        public init?<Value: Encodable>(encoding value: Value, encoder: JSONEncoder = JSONEncoder()) {
            guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return nil }
            self.text = text
        }
    }

    /// The script `function(arguments)`.
    ///
    /// - `function`: a plain identifier path such as `window.setContent` or `document.documentElement.classList.toggle`; anything
    ///   else (a call, a bracket, a space) makes the result nil.
    /// - `args`: `String`, `Bool`, numbers (finite), `NSNull`, an optional of those, arrays and string-keyed dictionaries of
    ///   those, and `JSONText`. Each is encoded as JSON. A value that cannot be encoded makes the result nil.
    /// - `ifDefined`: the call is skipped when the page has not defined the function (`fn && fn(...)`).
    /// - `discardingResult`: the script evaluates to `undefined` (`void fn(...)`), for a function that returns a promise, which
    ///   `evaluateJavaScript` cannot hand back.
    public static func call(_ function: String, args: [Any] = [], ifDefined: Bool = false, discardingResult: Bool = false) -> String? {
        guard isFunctionPath(function) else { return nil }
        var encoded: [String] = []
        encoded.reserveCapacity(args.count)
        for argument in args {
            guard let value = literal(argument) else { return nil }
            encoded.append(value)
        }
        let invocation = (discardingResult ? "void " : "") + "\(function)(\(encoded.joined(separator: ", ")))"
        return ifDefined ? "\(function) && \(invocation)" : invocation
    }

    /// Several scripts that run in order as one, so the page sees them together. Nil when any of them is nil.
    public static func sequence(_ scripts: [String?]) -> String? {
        var parts: [String] = []
        for script in scripts {
            guard let script else { return nil }
            parts.append(script)
        }
        return parts.joined(separator: "; ")
    }

    /// One value as a script expression that evaluates to it (a JSON literal), or nil when it cannot be encoded.
    public static func literal(_ value: Any) -> String? {
        if let json = value as? JSONText {
            guard let quoted = literal(json.text) else { return nil }
            return "JSON.parse(\(quoted))"
        }
        let unwrapped = unwrap(value)
        if unwrapped == nil || unwrapped is NSNull { return "null" }
        guard let unwrapped else { return nil }
        // JSONSerialization raises an Objective-C exception for a value it cannot encode, so check first. A bare string is not a
        // valid top-level object: wrap the value in an array and take the one element back out.
        guard JSONSerialization.isValidJSONObject([unwrapped]),
              let data = try? JSONSerialization.data(withJSONObject: [unwrapped]),
              let array = String(data: data, encoding: .utf8),
              array.first == "[", array.last == "]" else { return nil }
        // U+2028 and U+2029 end a line in older script grammars; they are legal in JSON strings, so write them as escapes.
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// `name(.name)*`, each name an ASCII identifier.
    private static func isFunctionPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        for name in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard let first = name.unicodeScalars.first, first.isASCII, first == "_" || first == "$" || isLetter(first) else { return false }
            guard name.unicodeScalars.allSatisfy({ $0.isASCII && ($0 == "_" || $0 == "$" || isLetter($0) || ("0"..."9").contains($0)) }) else { return false }
        }
        return true
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) }

    /// The wrapped value of an optional (any depth); nil for `.none`.
    private static func unwrap(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        guard let wrapped = mirror.children.first?.value else { return nil }
        return unwrap(wrapped)
    }
}
