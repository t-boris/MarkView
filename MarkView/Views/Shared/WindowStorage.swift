import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// `@AppStorage` for a value that belongs to the window: the same call (`@WindowStorage(Setting.qaInspectorWidth) var width: Double`,
/// `$width` is a Binding), but the value lives in the window's `WindowUIState` (put in the environment once, at the window's root),
/// so another window never sees it.
@propertyWrapper
struct WindowStorage<Value: WindowUIStorable>: DynamicProperty {
    @EnvironmentObject private var state: WindowUIState
    private let key: SettingsKey<Value>

    init(_ key: SettingsKey<Value>) {
        self.key = key
    }

    var wrappedValue: Value {
        get { state.value(key) }
        nonmutating set { state.set(newValue, for: key) }
    }

    var projectedValue: Binding<Value> {
        let state = state, key = key
        return Binding(get: { state.value(key) }, set: { state.set($0, for: key) })
    }
}
