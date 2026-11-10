import SwiftUI

/// `@AppStorage` for a value that belongs to the window: the same call (`@WindowStorage("key") var width = 340.0`, `$width` is a Binding),
/// but the value lives in the window's `WindowUIState` (put in the environment once, at the window's root), so another window never sees it.
@propertyWrapper
struct WindowStorage<Value: WindowUIStorable>: DynamicProperty {
    @EnvironmentObject private var state: WindowUIState
    private let key: String
    private let fallback: Value

    init(wrappedValue: Value, _ key: String) {
        self.fallback = wrappedValue
        self.key = key
    }

    var wrappedValue: Value {
        get { state.value(key, fallback: fallback) }
        nonmutating set { state.set(newValue, for: key) }
    }

    var projectedValue: Binding<Value> {
        let state = state, key = key, fallback = fallback
        return Binding(get: { state.value(key, fallback: fallback) }, set: { state.set($0, for: key) })
    }
}
