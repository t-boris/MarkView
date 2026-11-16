import Foundation
import JavaScriptCore
import XCTest
@testable import MarkViewCore

/// `JS.call` (AR-04): what a script built from a value does when a real JavaScript engine runs it. JavaScriptCore is the engine of
/// the app's web views; a context has no window and no page, so these checks are pure. A page function `capture` records the
/// arguments it was called with, and the test compares them with what Swift sent.
final class JSCallTests: XCTestCase {
    private final class Rig {
        let context = JSContext()!
        private(set) var lastException: String?
        init() {
            context.exceptionHandler = { [unowned self] _, value in lastException = value?.toString() }
            context.evaluateScript("var window = this; var calls = []; var evil = 0; function capture() { calls.push(Array.prototype.slice.call(arguments)); }")
        }
        /// Runs `script`; the exception it raised, if any.
        func run(_ script: String) -> String? {
            lastException = nil
            context.evaluateScript(script)
            return lastException
        }
        var calls: [[Any]] { (context.evaluateScript("calls")?.toArray() as? [[Any]]) ?? [] }
        var evilCount: Int { Int(context.evaluateScript("evil")?.toInt32() ?? -1) }
    }

    private let hostileValues: [String] = [
        "it's",
        "say \"hi\"",
        "back\\slash and \\' and \\\"",
        "line\nbreak\r\n and \t tab",
        "separators \u{2028} and \u{2029} inside",
        "</script><script>evil=1</script>",
        "'); evil++; ('",
        "\"); evil++; (\"",
        "`${evil++}`",
        "\u{0}\u{1}\u{1F}",
        "emoji \u{1F600} and \u{1F468}\u{200D}\u{1F469}",
        "// comment /* block */",
        "",
    ]

    func testEveryHostileStringArrivesUnchangedAndRunsNothing() {
        for value in hostileValues {
            let rig = Rig()
            guard let script = JS.call("capture", args: [value]) else { return XCTFail("could not encode \(value.debugDescription)") }
            XCTAssertNil(rig.run(script), "script raised for \(value.debugDescription)")
            XCTAssertEqual(rig.evilCount, 0, "a value ran code: \(value.debugDescription)")
            XCTAssertEqual(rig.calls.first?.first as? String, value, "value changed on the way: \(value.debugDescription)")
        }
    }

    func testAVeryLongStringArrivesUnchanged() {
        let rig = Rig()
        let long = String(repeating: "ab'\"\\\u{2028}</script>", count: 150_000)
        guard let script = JS.call("capture", args: [long, 7]) else { return XCTFail("could not encode") }
        XCTAssertGreaterThan(script.utf8.count, 3_000_000)
        XCTAssertNil(rig.run(script))
        XCTAssertEqual(rig.calls.first?.first as? String, long)
        XCTAssertEqual((rig.calls.first?.last as? NSNumber)?.intValue, 7)
    }

    func testSeparatorsAreWrittenAsEscapesNotRawCharacters() {
        let script = JS.call("capture", args: ["a\u{2028}b\u{2029}c"])
        XCTAssertEqual(script, "capture(\"a\\u2028b\\u2029c\")")
        XCTAssertFalse(script?.contains("\u{2028}") ?? true)
    }

    func testEachKindOfArgumentIsEncodedAsJSON() {
        let rig = Rig()
        let nothing: String? = nil
        let some: String? = "x"
        let script = JS.call("capture", args: ["s", 3, 2.5, true, false, NSNull(), nothing as Any, some as Any,
                                               ["a", 1, ["nested": "it's"]] as [Any], ["key": "va\"lue", "n": NSNull()] as [String: Any]])
        XCTAssertNotNil(script)
        XCTAssertNil(rig.run(script ?? ""))
        // Object keys have no order, so the two objects are compared by member.
        let row = rig.context.evaluateScript("JSON.stringify(calls[0].slice(0, 9)) + '|' + calls[0][9].key + '|' + calls[0][9].n + '|' + Object.keys(calls[0][9]).length")?.toString() ?? ""
        XCTAssertEqual(row, "[\"s\",3,2.5,true,false,null,null,\"x\",[\"a\",1,{\"nested\":\"it's\"}]]|va\"lue|null|2")
        XCTAssertEqual(JS.call("window.f", args: [true]), "window.f(true)", "a Swift Bool is `true`, never `1`")
        XCTAssertEqual(JS.call("window.f"), "window.f()")
    }

    func testAnArgumentThatCannotBeEncodedGivesNoScript() {
        XCTAssertNil(JS.call("capture", args: [Double.nan]))
        XCTAssertNil(JS.call("capture", args: [Double.infinity]))
        XCTAssertNil(JS.call("capture", args: [Date()]), "a Date is not a JSON value")
        XCTAssertNil(JS.call("capture", args: [["a": Double.nan]]))
    }

    func testOnlyAPlainIdentifierPathIsAFunction() {
        XCTAssertNotNil(JS.call("window.mvSetTheme"))
        XCTAssertNotNil(JS.call("document.documentElement.classList.toggle", args: ["x", true]))
        XCTAssertNotNil(JS.call("$.ajax"))
        XCTAssertNotNil(JS.call("_private1"))
        for name in ["", "f()", "f(1);g", "f g", "a.b(", "x[0]", "1abc", "window..f", ".f", "f.", "a;b", "a\nb", "a-b", "\u{43B}", "f`x`", "(function(){})"] {
            XCTAssertNil(JS.call(name, args: ["v"]), "accepted the function name \(name.debugDescription)")
        }
    }

    func testIfDefinedSkipsAMissingFunctionAndCallsADefinedOne() {
        let rig = Rig()
        XCTAssertNil(rig.run(JS.call("window.missing", args: ["v"], ifDefined: true) ?? "throw 1"), "a missing function is skipped, not an error")
        XCTAssertNotNil(rig.run(JS.call("window.missing", args: ["v"]) ?? "throw 1"), "without ifDefined a missing function raises")
        XCTAssertNil(rig.run(JS.call("capture", args: ["v"], ifDefined: true) ?? "throw 1"))
        XCTAssertEqual(rig.calls.count, 1)
    }

    func testDiscardingResultEvaluatesToUndefined() {
        let rig = Rig()
        rig.context.evaluateScript("function later() { return Promise.resolve(1); }")
        let plain = rig.context.evaluateScript(JS.call("later") ?? "")
        let discarded = rig.context.evaluateScript(JS.call("later", discardingResult: true) ?? "")
        XCTAssertTrue(plain?.isObject ?? false)
        XCTAssertTrue(discarded?.isUndefined ?? false)
    }

    func testJSONTextArrivesAsAParsedValueAndAnInvalidTextRunsNothing() {
        let rig = Rig()
        let json = "{\"title\":\"it's </script>\",\"list\":[1,2,{\"k\":\"\\u2028\"}]}"
        XCTAssertNil(rig.run(JS.call("capture", args: [JS.JSONText(json), "id"]) ?? "throw 1"))
        XCTAssertEqual(rig.context.evaluateScript("calls[0][0].title")?.toString(), "it's </script>")
        XCTAssertEqual(rig.context.evaluateScript("calls[0][0].list[2].k")?.toString(), "\u{2028}")
        XCTAssertEqual(rig.context.evaluateScript("calls[0][1]")?.toString(), "id")

        // Text that is not JSON never becomes code: the page's JSON.parse throws and the call does not happen.
        let before = rig.calls.count
        let error = rig.run(JS.call("capture", args: [JS.JSONText("1); evil++; (2")]) ?? "throw 1")
        XCTAssertNotNil(error)
        XCTAssertEqual(rig.evilCount, 0)
        XCTAssertEqual(rig.calls.count, before)
    }

    func testJSONTextOfAnEncodableValue() {
        struct Skeleton: Encodable { var title: String; var count: Int }
        let rig = Rig()
        guard let text = JS.JSONText(encoding: Skeleton(title: "a'b\"c", count: 3)) else { return XCTFail("not encoded") }
        XCTAssertNil(rig.run(JS.call("capture", args: [text]) ?? "throw 1"))
        XCTAssertEqual(rig.context.evaluateScript("calls[0][0].title + '|' + calls[0][0].count")?.toString(), "a'b\"c|3")
    }

    func testSequenceRunsInOrderAndOneMissingScriptGivesNone() {
        let rig = Rig()
        let script = JS.sequence([JS.call("capture", args: ["first"]), JS.call("capture", args: ["second", 2])])
        XCTAssertNil(rig.run(script ?? "throw 1"))
        XCTAssertEqual(rig.calls.compactMap { $0.first as? String }, ["first", "second"])
        XCTAssertNil(JS.sequence([JS.call("capture"), JS.call("no(good")]))
        XCTAssertNil(JS.sequence([nil]))
    }
}
