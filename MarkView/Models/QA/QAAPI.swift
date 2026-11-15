import Foundation

/// A replayable HTTP step. Empty path checks the player's previous response without sending another request.
/// JSON values in assertions use JSON literals; paths use RFC 6901 JSON Pointers (empty means the whole document).
struct QAAPIRequest: Codable, Equatable {
    struct Header: Codable, Equatable { var name: String; var value: String }
    struct Assertion: Codable, Equatable { var pointer: String; var equals: String }
    struct Capture: Codable, Equatable { var name: String; var pointer: String; var secret: Bool = false }

    var method: String = "GET"
    var path: String = "/"
    var headers: [Header] = []
    var body: String = ""
    var statuses: [Int] = [200]
    var assertions: [Assertion] = []
    var captures: [Capture] = []
    var timeoutSeconds: Int = 20

    var problems: [String] {
        var errors: [String] = []
        if !["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) { errors.append("Use GET, HEAD, POST, PUT, PATCH, DELETE or OPTIONS.") }
        if statuses.isEmpty || statuses.contains(where: { !(100...599).contains($0) }) { errors.append("Expected statuses must contain HTTP status codes from 100 to 599.") }
        if !(1...120).contains(timeoutSeconds) { errors.append("Timeout must be between 1 and 120 seconds.") }
        for header in headers {
            if header.name.isEmpty || !header.name.utf8.allSatisfy({ (33...126).contains($0) && !Array("()<>@,;:\\\"/[]?={} ".utf8).contains($0) }) || !Self.validHeaderValue(header.value) {
                errors.append("Headers need a valid name and a single-line value.")
            }
        }
        for assertion in assertions {
            if !Self.validPointer(assertion.pointer) { errors.append("JSON paths must be JSON Pointers, for example /user/id.") }
            if (try? JSONSerialization.jsonObject(with: Data(assertion.equals.utf8), options: [.fragmentsAllowed])) == nil { errors.append("Expected JSON values must be JSON literals, for example 3, true or \"Alice\".") }
        }
        for capture in captures {
            if !QAScenario.isValidID(capture.name) || ["username", "password"].contains(capture.name) { errors.append("Capture names must be plain ids other than username or password.") }
            if !Self.validPointer(capture.pointer) { errors.append("Capture paths must be JSON Pointers.") }
        }
        if Set(captures.map(\.name)).count != captures.count { errors.append("Capture names must be unique within a step.") }
        return errors
    }

    static func validHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value == 9 || ($0.value >= 32 && $0.value != 127 && !CharacterSet.newlines.contains($0)) }
    }

    static func validPointer(_ path: String) -> Bool {
        guard path.isEmpty || path.hasPrefix("/") else { return false }
        return path.range(of: "~(?![01])", options: .regularExpression) == nil
    }

    static func value(at pointer: String, in object: Any) -> Any? {
        guard validPointer(pointer) else { return nil }
        if pointer.isEmpty { return object }
        var current: Any = object
        for part in pointer.dropFirst().components(separatedBy: "/") {
            let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let map = current as? [String: Any], let value = map[key] { current = value }
            else if let array = current as? [Any], let index = Int(key), String(index) == key, array.indices.contains(index) { current = array[index] }
            else { return nil }
        }
        return current
    }

    static func json(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Editing and generation use the exact same persisted representation.
    var source: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

struct QAAPIResult {
    var passed: Bool
    /// Safe evidence for the live feed, archived run and bug reports. Request headers and bodies are never included.
    var evidence: String
}

enum QAAPIError: LocalizedError {
    case invalid(String)
    case transport
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .transport: return "The API request could not finish (connection, timeout, redirect or response limit)."
        }
    }
}

