import Foundation

/// One value of a window's own interface state, in the form a window saves with its session.
enum WindowUIValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
}

/// A type a window can keep as its own interface state: what `@AppStorage` offered for the same job, minus the sharing.
protocol WindowUIStorable {
    var windowUIValue: WindowUIValue { get }
    init?(windowUIValue: WindowUIValue)
    /// The value the most recently changed window left for new windows to start with, read from the snapshot a window takes of
    /// UserDefaults when it is created.
    static func seed(from snapshot: [String: Any], key: String) -> Self?
    func writeSeed(to defaults: UserDefaults, key: String)
}

/// A String-valued enum keeps its raw value; an unknown stored raw value is no value.
extension WindowUIStorable where Self: RawRepresentable, Self.RawValue == String {
    var windowUIValue: WindowUIValue { .string(rawValue) }
    init?(windowUIValue: WindowUIValue) {
        guard case .string(let raw) = windowUIValue else { return nil }
        self.init(rawValue: raw)
    }
    static func seed(from snapshot: [String: Any], key: String) -> Self? { (snapshot[key] as? String).flatMap { Self(rawValue: $0) } }
    func writeSeed(to defaults: UserDefaults, key: String) { defaults.set(rawValue, forKey: key) }
}

extension Bool: WindowUIStorable {
    var windowUIValue: WindowUIValue { .bool(self) }
    init?(windowUIValue: WindowUIValue) { guard case .bool(let value) = windowUIValue else { return nil }; self = value }
    static func seed(from snapshot: [String: Any], key: String) -> Bool? { snapshot[key] as? Bool }
    func writeSeed(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

extension Int: WindowUIStorable {
    var windowUIValue: WindowUIValue { .int(self) }
    init?(windowUIValue: WindowUIValue) { guard case .int(let value) = windowUIValue else { return nil }; self = value }
    static func seed(from snapshot: [String: Any], key: String) -> Int? { snapshot[key] as? Int }
    func writeSeed(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

extension Double: WindowUIStorable {
    var windowUIValue: WindowUIValue { .double(self) }
    init?(windowUIValue: WindowUIValue) { guard case .double(let value) = windowUIValue else { return nil }; self = value }
    static func seed(from snapshot: [String: Any], key: String) -> Double? { snapshot[key] as? Double }
    func writeSeed(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

extension String: WindowUIStorable {
    var windowUIValue: WindowUIValue { .string(self) }
    init?(windowUIValue: WindowUIValue) { guard case .string(let value) = windowUIValue else { return nil }; self = value }
    static func seed(from snapshot: [String: Any], key: String) -> String? { snapshot[key] as? String }
    func writeSeed(to defaults: UserDefaults, key: String) { defaults.set(self, forKey: key) }
}

/// What one window shows of itself: the expanded sections, the widths, the mode of a panel. Every window owns one (through its
/// `WorkspaceManager`), so changing a value in one window leaves every other window alone (BUG-120 and the audit that followed it).
///
/// The shared `@AppStorage` it replaces is observed by every window at once: a write in one re-renders the others. Here a window's own
/// value lives in this object and is saved with the window's session, so a relaunch gives each window its own again. UserDefaults gets
/// the value only as the STARTING value of the next new window: a window takes a snapshot of those starting values when it is created
/// and reads them from it, so a later change in another window never reaches it, not even a panel the window opens much later.
/// Nothing observes those keys.
final class WindowUIState: ObservableObject {
    private var own: [String: WindowUIValue] = [:]
    private let defaults: UserDefaults
    /// What the windows before this one had left in UserDefaults when this one was created.
    private let starting: [String: Any]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.starting = defaults.dictionaryRepresentation()
    }

    /// This window's value; a key it has not used yet starts from the snapshot (else `fallback`), and keeps that value from then on.
    func value<T: WindowUIStorable>(_ key: String, fallback: T) -> T {
        if let stored = own[key], let value = T(windowUIValue: stored) { return value }
        let start = T.seed(from: starting, key: key) ?? fallback
        own[key] = start.windowUIValue
        return start
    }

    /// This window's value if it has one of its own (no seed is taken, nothing is remembered).
    func existing<T: WindowUIStorable>(_ key: String) -> T? {
        own[key].flatMap { T(windowUIValue: $0) }
    }

    /// `publishing: false` for a value no SwiftUI view shows (a divider position kept by an AppKit view): it changes on every
    /// frame of a drag and must not redraw the views that observe this state.
    func set<T: WindowUIStorable>(_ newValue: T, for key: String, publishing: Bool = true) {
        let stored = newValue.windowUIValue
        guard own[key] != stored else { return }
        if publishing { objectWillChange.send() }
        own[key] = stored
        newValue.writeSeed(to: defaults, key: key)
    }

    /// What the window saves in its session.
    var saved: [String: WindowUIValue] { own }

    /// Takes the values a window saved (a session saved before this state existed has none: the window keeps its starting values).
    func restore(_ values: [String: WindowUIValue]?) {
        guard let values, !values.isEmpty else { return }
        objectWillChange.send()
        own.merge(values) { _, saved in saved }
    }
}
