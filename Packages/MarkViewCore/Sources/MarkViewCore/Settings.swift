import Combine
import Foundation
import SwiftUI

/// Who a persisted setting belongs to (`AR-18`).
public enum SettingsScope: String, CaseIterable, Sendable {
    /// One value for the whole app: every window and every project reads and writes the same one.
    case app
    /// A window's own interface state. A window keeps its own value (`WindowUIState`); the stored value only seeds the next new
    /// window, so a change in one window never reaches another.
    case window
    /// One value per project: the name of the key carries the project (`features.active.<hash>`), so a project's choice never
    /// changes another's.
    case project
}

/// A type the settings store keeps in `UserDefaults`.
public protocol SettingsValue {
    /// The stored value, or nil when the key is not set or holds another type.
    static func read(from defaults: UserDefaults, name: String) -> Self?
    func write(to defaults: UserDefaults, name: String)
}

extension Bool: SettingsValue {
    public static func read(from defaults: UserDefaults, name: String) -> Bool? { defaults.object(forKey: name) as? Bool }
    public func write(to defaults: UserDefaults, name: String) { defaults.set(self, forKey: name) }
}

extension Int: SettingsValue {
    public static func read(from defaults: UserDefaults, name: String) -> Int? { defaults.object(forKey: name) as? Int }
    public func write(to defaults: UserDefaults, name: String) { defaults.set(self, forKey: name) }
}

extension Double: SettingsValue {
    public static func read(from defaults: UserDefaults, name: String) -> Double? { defaults.object(forKey: name) as? Double }
    public func write(to defaults: UserDefaults, name: String) { defaults.set(self, forKey: name) }
}

extension String: SettingsValue {
    public static func read(from defaults: UserDefaults, name: String) -> String? { defaults.string(forKey: name) }
    public func write(to defaults: UserDefaults, name: String) { defaults.set(self, forKey: name) }
}

extension Data: SettingsValue {
    public static func read(from defaults: UserDefaults, name: String) -> Data? { defaults.data(forKey: name) }
    public func write(to defaults: UserDefaults, name: String) { defaults.set(self, forKey: name) }
}

extension Array: SettingsValue where Element == String {
    public static func read(from defaults: UserDefaults, name: String) -> [String]? { defaults.stringArray(forKey: name) }
    public func write(to defaults: UserDefaults, name: String) { defaults.set(self, forKey: name) }
}

/// A property-list dictionary: callers that know the shape of the values cast them (`as? [String: String]`).
extension Dictionary: SettingsValue where Key == String, Value == Any {
    public static func read(from defaults: UserDefaults, name: String) -> [String: Any]? { defaults.dictionary(forKey: name) }
    public func write(to defaults: UserDefaults, name: String) { defaults.set(self, forKey: name) }
}

/// What a key is, without its value type: the registry's table and an observer's list.
public struct AnySettingsKey: Hashable, Sendable {
    public let name: String
    public let scope: SettingsScope
    /// The value type, for the registry's table (`Bool`, `String`, `Array<String>`, ...).
    public let valueType: String
}

/// A persisted setting: its name in `UserDefaults` (never changes, or the stored values are lost), the value it has when nothing
/// is stored, and who it belongs to. Every read and write of a setting names one of these; a raw string is never a key.
public struct SettingsKey<Value: SettingsValue> {
    public let name: String
    public let defaultValue: Value
    public let scope: SettingsScope

    public init(_ name: String, default defaultValue: Value, scope: SettingsScope = .app) {
        self.name = name
        self.defaultValue = defaultValue
        self.scope = scope
    }

    public var erased: AnySettingsKey { AnySettingsKey(name: name, scope: scope, valueType: String(describing: Value.self)) }
}

/// A key holds a name, an immutable default and a scope, so it can be shared between threads whatever the value type.
extension SettingsKey: @unchecked Sendable {}

/// The settings of one `UserDefaults` (the app's, or a test's own suite).
public struct Settings: @unchecked Sendable {
    public static let standard = Settings(.standard)

    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The stored value, or the key's default when nothing (or another type) is stored.
    public func value<Value>(_ key: SettingsKey<Value>) -> Value { stored(key) ?? key.defaultValue }

    /// The stored value; nil when nothing is stored, for a setting whose absence means something (a choice never made).
    public func stored<Value>(_ key: SettingsKey<Value>) -> Value? { Value.read(from: defaults, name: key.name) }

    public func contains<Value>(_ key: SettingsKey<Value>) -> Bool { defaults.object(forKey: key.name) != nil }

    public func set<Value>(_ value: Value, for key: SettingsKey<Value>) { value.write(to: defaults, name: key.name) }

    /// Stores `value`, or removes the key when it is nil.
    public func set<Value>(_ value: Value?, for key: SettingsKey<Value>) {
        if let value { set(value, for: key) } else { remove(key) }
    }

    public func remove<Value>(_ key: SettingsKey<Value>) { defaults.removeObject(forKey: key.name) }
}

/// Calls `onChange` when the value of one of its keys changes, and only then: a write to any other key (a divider drag, a window's
/// own state) does nothing. `UserDefaults` offers no per-key notification for a name with dots, so the observer listens to the
/// store's one general notification itself and compares its own keys with the values it saw last.
public final class SettingsObserver {
    private let defaults: UserDefaults
    private let names: [String]
    private var seen: [NSObject?]
    private var token: NSObjectProtocol?

    /// `onChange` runs on the main queue.
    public init(_ keys: [AnySettingsKey], defaults: UserDefaults = .standard, onChange: @escaping () -> Void) {
        self.defaults = defaults
        names = keys.map(\.name)
        seen = keys.map { defaults.object(forKey: $0.name) as? NSObject }
        token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            guard let self else { return }
            let now = names.map { defaults.object(forKey: $0) as? NSObject }
            guard !zip(now, seen).allSatisfy({ $0 == $1 }) else { return }
            seen = now
            onChange()
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    /// The same as a publisher for a SwiftUI `onReceive`: one observer per subscription, alive while the subscription is.
    public static func changes(of keys: [AnySettingsKey], defaults: UserDefaults = .standard) -> AnyPublisher<Void, Never> {
        Deferred { () -> AnyPublisher<Void, Never> in
            let subject = PassthroughSubject<Void, Never>()
            let observer = SettingsObserver(keys, defaults: defaults) { subject.send() }
            return subject.handleEvents(receiveCancel: { withExtendedLifetime(observer) {} }).eraseToAnyPublisher()
        }.eraseToAnyPublisher()
    }
}

/// `@AppStorage(key)`: the property takes its name and its default from the registry, so the two are written once.
extension AppStorage {
    public init(_ key: SettingsKey<Bool>) where Value == Bool { self.init(wrappedValue: key.defaultValue, key.name) }
    public init(_ key: SettingsKey<Int>) where Value == Int { self.init(wrappedValue: key.defaultValue, key.name) }
    public init(_ key: SettingsKey<Double>) where Value == Double { self.init(wrappedValue: key.defaultValue, key.name) }
    public init(_ key: SettingsKey<String>) where Value == String { self.init(wrappedValue: key.defaultValue, key.name) }
}
