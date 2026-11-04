import Foundation

/// A JSON value of UI Studio's simulated data: scenario records, request and response bodies, agent proposals.
/// Numbers keep integers as integers when they are written back (`anyValue`), so an id `7` never becomes `7.0`.
enum StudioJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([StudioJSON])
    case object([String: StudioJSON])

    // MARK: Conversion

    /// From a `JSONSerialization` value (or anything built of dictionaries, arrays, strings, numbers and NSNull).
    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            // NSNumber hides Bool; CFBoolean is the only boolean NSNumber.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let bool as Bool: self = .bool(bool)
        case let int as Int: self = .number(Double(int))
        case let double as Double: self = .number(double)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { StudioJSON(any: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { StudioJSON(any: $0) })
        default: self = .string(String(describing: value!))
        }
    }

    /// Parses JSON text; nil when it is not JSON (fragments such as `"text"` or `3` are accepted).
    init?(text: String) {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        self.init(any: value)
    }

    /// The value for `JSONSerialization`.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return Int(value) }
            return value
        case .string(let value): return value
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        }
    }

    /// Compact JSON text with sorted keys (stable for hashing and comparisons).
    var text: String {
        let value = anyValue
        guard JSONSerialization.isValidJSONObject(value) else {
            // A fragment: wrap it so JSONSerialization accepts it, then unwrap.
            guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .withoutEscapingSlashes]),
                  let wrapped = String(data: data, encoding: .utf8) else { return "null" }
            return String(wrapped.dropFirst().dropLast())
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([StudioJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: StudioJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { try container.encode(Int(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Access

    var objectValue: [String: StudioJSON]? { if case .object(let value) = self { return value }; return nil }
    var arrayValue: [StudioJSON]? { if case .array(let value) = self { return value }; return nil }
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    subscript(key: String) -> StudioJSON? { objectValue?[key] }

    /// The value with every list cut to its first `items` elements plus a note of how many more there are, so the shape
    /// of a long answer fits a prompt (BUG-084).
    func abbreviated(items: Int) -> StudioJSON {
        switch self {
        case .array(let list):
            var kept = list.prefix(items).map { $0.abbreviated(items: items) }
            if list.count > items { kept.append(.string("… \(list.count - items) more like these")) }
            return .array(kept)
        case .object(let object):
            return .object(object.mapValues { $0.abbreviated(items: items) })
        default:
            return self
        }
    }

    /// The value as a key for comparing ids: `7`, `"7"` and `7.0` are the same record.
    var identityKey: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return String(Int(value)) }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    /// The JSON type name used by the schema checks: string, integer, number, boolean, object, array, null.
    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number(let value): return value.rounded() == value ? "integer" : "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// Size of the value when written, for the payload limits.
    var approximateSize: Int { text.utf8.count }
}
