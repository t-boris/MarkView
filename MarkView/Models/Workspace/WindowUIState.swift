import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// One value of a window's own interface state, in the form a window saves with its session.
enum WindowUIValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
}

/// A type a window can keep as its own interface state: what `@AppStorage` offered for the same job, minus the sharing. Its stored
/// form in `UserDefaults` (`SettingsValue`) is the starting value the most recently changed window leaves for new windows.
protocol WindowUIStorable: SettingsValue {
    var windowUIValue: WindowUIValue { get }
    init?(windowUIValue: WindowUIValue)
    /// The value the most recently changed window left for new windows to start with, read from the snapshot a window takes of
    /// UserDefaults when it is created.
    static func seed(from snapshot: [String: Any], key: String) -> Self?
}

extension Bool: WindowUIStorable {
    var windowUIValue: WindowUIValue { .bool(self) }
    init?(windowUIValue: WindowUIValue) { guard case .bool(let value) = windowUIValue else { return nil }; self = value }
    static func seed(from snapshot: [String: Any], key: String) -> Bool? { snapshot[key] as? Bool }
}

extension Int: WindowUIStorable {
    var windowUIValue: WindowUIValue { .int(self) }
    init?(windowUIValue: WindowUIValue) { guard case .int(let value) = windowUIValue else { return nil }; self = value }
    static func seed(from snapshot: [String: Any], key: String) -> Int? { snapshot[key] as? Int }
}

extension Double: WindowUIStorable {
    var windowUIValue: WindowUIValue { .double(self) }
    init?(windowUIValue: WindowUIValue) { guard case .double(let value) = windowUIValue else { return nil }; self = value }
    static func seed(from snapshot: [String: Any], key: String) -> Double? { snapshot[key] as? Double }
}

extension String: WindowUIStorable {
    var windowUIValue: WindowUIValue { .string(self) }
    init?(windowUIValue: WindowUIValue) { guard case .string(let value) = windowUIValue else { return nil }; self = value }
    static func seed(from snapshot: [String: Any], key: String) -> String? { snapshot[key] as? String }
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

    /// This window's value; a key it has not used yet starts from the snapshot (else its default), and keeps that value from then on.
    func value<T: WindowUIStorable>(_ key: SettingsKey<T>) -> T {
        if let stored = own[key.name], let value = T(windowUIValue: stored) { return value }
        let start = T.seed(from: starting, key: key.name) ?? key.defaultValue
        own[key.name] = start.windowUIValue
        return start
    }

    /// This window's value if it has one of its own (no seed is taken, nothing is remembered).
    func existing<T: WindowUIStorable>(_ key: SettingsKey<T>) -> T? {
        own[key.name].flatMap { T(windowUIValue: $0) }
    }

    /// `publishing: false` for a value no SwiftUI view shows (a divider position kept by an AppKit view): it changes on every
    /// frame of a drag and must not redraw the views that observe this state.
    func set<T: WindowUIStorable>(_ newValue: T, for key: SettingsKey<T>, publishing: Bool = true) {
        let stored = newValue.windowUIValue
        guard own[key.name] != stored else { return }
        if publishing { objectWillChange.send() }
        own[key.name] = stored
        Settings(defaults).set(newValue, for: key)
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
