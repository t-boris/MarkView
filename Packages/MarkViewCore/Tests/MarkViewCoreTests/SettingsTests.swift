import Foundation
import XCTest
@testable import MarkViewCore

/// `AR-18`: the settings store reads and writes the same property-list values the app always wrote, a default stands in for
/// anything missing or of another type, and an observer hears about its own keys only. `Setting`'s names are pinned by the app's
/// `SettingsKeyTableTests` in `MarkViewCoreTests`.
final class SettingsTests: XCTestCase {
    private func freshDefaults() -> (UserDefaults, () -> Void) {
        let suite = "settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testDefaultStoredValueAndRemoval() {
        let (defaults, cleanup) = freshDefaults()
        defer { cleanup() }
        let settings = Settings(defaults)
        let flag = SettingsKey<Bool>("test.flag", default: true)
        XCTAssertTrue(settings.value(flag), "nothing stored: the key's default")
        XCTAssertNil(settings.stored(flag), "nothing stored: stored() is nil, not the default")
        XCTAssertFalse(settings.contains(flag))

        settings.set(false, for: flag)
        XCTAssertFalse(settings.value(flag))
        XCTAssertEqual(settings.stored(flag), false)
        XCTAssertTrue(settings.contains(flag))
        XCTAssertEqual(defaults.object(forKey: "test.flag") as? Bool, false, "the value is the plain property-list value under the key's name")

        settings.remove(flag)
        XCTAssertTrue(settings.value(flag), "removed: the default again")
        XCTAssertFalse(settings.contains(flag))
    }

    func testOptionalSetRemovesTheKey() {
        let (defaults, cleanup) = freshDefaults()
        defer { cleanup() }
        let settings = Settings(defaults)
        let text = SettingsKey<String>("test.text", default: "")
        settings.set("one", for: text)
        XCTAssertEqual(settings.stored(text), "one")
        settings.set(nil, for: text)
        XCTAssertNil(settings.stored(text), "setting nil removes the key")
    }

    func testEveryValueTypeRoundTrips() {
        let (defaults, cleanup) = freshDefaults()
        defer { cleanup() }
        let settings = Settings(defaults)
        let int = SettingsKey<Int>("test.int", default: 0), double = SettingsKey<Double>("test.double", default: 0)
        let data = SettingsKey<Data>("test.data", default: Data()), list = SettingsKey<[String]>("test.list", default: [])
        let table = SettingsKey<[String: Any]>("test.table", default: [:])
        settings.set(7, for: int); settings.set(2.5, for: double)
        settings.set(Data([1, 2, 3]), for: data); settings.set(["a", "b"], for: list)
        settings.set(["profiles": ["claude"], "shown": 1] as [String: Any], for: table)
        XCTAssertEqual(settings.value(int), 7)
        XCTAssertEqual(settings.value(double), 2.5)
        XCTAssertEqual(settings.value(data), Data([1, 2, 3]))
        XCTAssertEqual(settings.value(list), ["a", "b"])
        XCTAssertEqual(settings.value(table)["profiles"] as? [String], ["claude"])
        XCTAssertEqual(settings.value(table)["shown"] as? Int, 1)
    }

    func testAValueOfAnotherTypeIsTheDefault() {
        let (defaults, cleanup) = freshDefaults()
        defer { cleanup() }
        let settings = Settings(defaults)
        defaults.set("large", forKey: "test.percent")
        defaults.set(300.5, forKey: "test.flag")
        let percent = SettingsKey<Int>("test.percent", default: 100), flag = SettingsKey<Bool>("test.flag", default: true)
        XCTAssertEqual(settings.value(percent), 100, "text under an Int key is the default, as `as? Int ?? default` was")
        XCTAssertNil(settings.stored(percent))
        XCTAssertTrue(settings.value(flag), "a number under a Bool key is the default")
    }

    func testTwoStoresDoNotShareValues() {
        let (first, firstCleanup) = freshDefaults()
        let (second, secondCleanup) = freshDefaults()
        defer { firstCleanup(); secondCleanup() }
        let key = SettingsKey<String>("test.shared", default: "none")
        Settings(first).set("first", for: key)
        XCTAssertEqual(Settings(second).value(key), "none", "a store made on another UserDefaults reads its own values")
    }

    func testAKeyKnowsItsScopeAndType() {
        let key = SettingsKey<Double>("test.width", default: 380, scope: .window)
        XCTAssertEqual(key.erased, AnySettingsKey(name: "test.width", scope: .window, valueType: "Double"))
        XCTAssertEqual(SettingsKey<[String]>("test.list", default: []).erased.valueType, "Array<String>")
        XCTAssertEqual(SettingsKey<Bool>("test.flag", default: false).erased.scope, .app, "the default scope is the app")
    }

    func testAnObserverHearsItsOwnKeysOnly() {
        let (defaults, cleanup) = freshDefaults()
        defer { cleanup() }
        let settings = Settings(defaults)
        let mine = SettingsKey<Bool>("test.mine", default: false), other = SettingsKey<Int>("test.other", default: 0)
        var calls = 0
        let observer = SettingsObserver([mine.erased], defaults: defaults) { calls += 1 }

        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
        settings.set(1, for: other)
        settle()
        XCTAssertEqual(calls, 0, "a write to another key (a divider drag, a window's own state) is not heard")

        settings.set(true, for: mine)
        settle()
        XCTAssertEqual(calls, 1, "a change of its own key is heard once")

        settings.set(true, for: mine)
        settings.set(2, for: other)
        settle()
        XCTAssertEqual(calls, 1, "writing the value it already has is not a change")

        settings.remove(mine)
        settle()
        XCTAssertEqual(calls, 2, "removing the key is a change")
        withExtendedLifetime(observer) {}
    }

    func testAnObserverThatIsGoneHearsNothing() {
        let (defaults, cleanup) = freshDefaults()
        defer { cleanup() }
        let settings = Settings(defaults)
        let key = SettingsKey<String>("test.gone", default: "")
        var calls = 0
        var observer: SettingsObserver? = SettingsObserver([key.erased], defaults: defaults) { calls += 1 }
        observer = nil
        settings.set("changed", for: key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(calls, 0, "releasing the observer removes it")
        XCTAssertNil(observer)
    }
}
