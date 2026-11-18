// Manual check against the real assistant (not part of the automatic checks): opens a copy of an application in a real UI Studio
// session, lets Studio repair what it can by itself (REQ-020) or prepare the main screens (REQ-021), or review the environment (DEC-015), and prints what happened, how long
// it took and what the assistant cost. Run by tools/tests/ui-studio-live-run.sh on a COPY of the project.
import AppKit
import Foundation
import XCTest
@testable import MarkView

final class LiveTotals: @unchecked Sendable {
    var calls = 0
    var cost = 0.0
}

@MainActor private final class LiveWindowServices: StudioWindowServices {
    let totals: LiveTotals
    init(totals: LiveTotals) { self.totals = totals }
    func studioRecordUsage(_ input: Int, _ output: Int, _ cost: Double) {
        totals.calls += 1
        totals.cost += cost
    }
}

/// This class is excluded from the automatic host suite and requires explicit manual opt-in.
@MainActor
final class ManualUIStudioLiveHostTests: XCTestCase {
func testManualUIStudio() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["MARKVIEW_MANUAL_STUDIO"] == "1" else { throw XCTSkip("Manual UI Studio is not enabled.") }
    let js = try XCTUnwrap(env["MARKVIEW_MANUAL_STUDIO_JS"])
    let folderPath = try XCTUnwrap(env["MARKVIEW_MANUAL_STUDIO_PROJECT"])
    let mode = try XCTUnwrap(env["MARKVIEW_MANUAL_STUDIO_MODE"])
    let scenarioName = env["MARKVIEW_MANUAL_STUDIO_SCENARIO"]
    AIAssistantRunner.setTestRunner { request, delta, activity in
        try await CLICompletion.run(request, onDelta: delta, onActivity: activity)
    }
    defer { AIAssistantRunner.setTestRunner(nil) }
    StudioSession.runtimeFolder = URL(fileURLWithPath: js)
    StudioSession.nodePreloadURL = URL(fileURLWithPath: js).appendingPathComponent("markview-ui-studio-node.cjs")
    // The launcher that serves an Electron app's renderer without Electron, as the app bundle has it.
    WebAppPreview.webOnlyLauncher = URL(fileURLWithPath: js).appendingPathComponent("markview-web-only.mjs")
    let folder = URL(fileURLWithPath: folderPath).resolvingSymlinksInPath()
    guard let target = WebAppPreview.targets(root: folder).first else {
        print("No web application target in \(folder.path)")
        XCTFail("Manual UI Studio could not continue")
        return
    }
    print("Target: \(target.label) `\(target.command)` ports \(target.ports) electron \(target.isElectron)")
    let totals = LiveTotals()
    let started = Date()
    func elapsed() -> String { String(format: "%4.0fs", Date().timeIntervalSince(started)) }
    let session = StudioSession(root: folder)
    // The page is in a window nobody can see, as in the app: the assistant's requests start with a picture of the page.
    let window = NSWindow(contentRect: CGRect(x: 60, y: 60, width: 1100, height: 860), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let host = StudioPreviewScrollView(webView: session.webView)
    host.frame = window.contentView!.bounds
    host.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(host)
    host.viewport = CGSize(width: session.viewport.width, height: session.viewport.height)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    let windowServices = LiveWindowServices(totals: totals)
    session.windowServices = windowServices
    session.start(target)
    _ = await waitUntil(600) { [.ready, .degraded, .failed].contains(session.state) && session.busy == nil }
    print("[\(elapsed())] opened: \(session.state) \(session.stateDetail)")

    func problems() -> [String] {
        session.sessionLog.entries.filter(\.problem).map { String($0.text.prefix(220)).replacingOccurrences(of: "\n", with: " ") }
    }
    func repairLines() -> [String] {
        session.sessionLog.entries.map(\.text).filter { $0.hasPrefix("Repair") || $0.hasPrefix("Not caused") || $0.hasPrefix("Fixed data") }
            .map { String($0.prefix(260)).replacingOccurrences(of: "\n", with: " ") }
    }

    if let scenarioName {
        guard let wanted = session.savedScenarios.first(where: { $0.name == scenarioName || $0.id == scenarioName }) else {
            print("No scenario named \(scenarioName); saved: \(session.savedScenarios.map(\.name))")
            await session.close()
            XCTFail("Manual UI Studio could not continue")
        return
        }
        print("[\(elapsed())] activating scenario \(wanted.name)")
        session.activate(wanted)
        _ = await waitUntil(300) { session.busy == nil }
    }

    switch mode {
    case "repair":
        print("[\(elapsed())] problems before any repair: \(problems().count)")
        problems().prefix(12).forEach { print("   ! \($0)") }
        // Let the automatic repair run its course: done when nothing has changed for a minute.
        var lastCount = -1, quiet = 0
        for _ in 0..<(15 * 60 / 5) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let count = session.sessionLog.entries.count
            let working = session.busy != nil || session.repair.autoRepairTask != nil && !(session.repair.autoRepairTask?.isCancelled ?? true) && session.repair.repairItems(automatic: true).first != nil
            quiet = (count == lastCount && !working) ? quiet + 1 : 0
            lastCount = count
            if quiet >= 12 { break }
        }
        print("[\(elapsed())] repair lines:")
        repairLines().forEach { print("   · \($0)") }
        print("[\(elapsed())] problems after: \(problems().count)")
        problems().prefix(12).forEach { print("   ! \($0)") }
        print("Undo offered: \(session.repair.repairUndo.map { "yes (\($0.automatic ? "automatic" : "by click")): \($0.summary)" } ?? "no")")
        print("Items still repairable: \(session.repair.repairItems(automatic: false).map { $0.kind.rawValue + " " + String($0.key.prefix(80)) })")
    case "screens":
        for _ in 0..<(25 * 60 / 5) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if session.screenTask == nil, session.screenWork == nil, session.screenBook.discovered != nil { break }
        }
        print("[\(elapsed())] screens: \(session.screenBook.entries.count), main \(session.screenBook.main.count)")
        for entry in session.screenBook.entries {
            print("   \(session.state(of: entry.screen).rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \(entry.screen.name) — \(entry.screen.route) \(entry.screen.main == true ? "[main]" : "")\(entry.failure.map { " FAILED: " + $0 } ?? "")")
        }
        // Every prepared main screen is opened in turn: the first opening checks it on the page (no assistant call when it reaches its
        // screen), a miss falls back to the assistant.
        for entry in session.screenBook.main where session.state(of: entry.screen).opensAtOnce {
            let before = totals.calls, started = Date()
            print("[\(elapsed())] opening \(entry.screen.name) from its prepared scenario")
            session.openScreen(entry.screen)
            // The work starts a moment after the click: wait for it to start, then for it to end.
            _ = await waitUntil(10) { session.busy != nil }
            _ = await waitUntil(420) { session.busy == nil && session.screenWork == nil }
            let how = totals.calls == before ? "directly, no assistant call" : "through the assistant (\(totals.calls - before) call)"
            print("   → state \(session.state(of: entry.screen).rawValue) \(how), \(Int(Date().timeIntervalSince(started))) s, scenario \(session.scenario.name)")
        }
        problems().prefix(8).forEach { print("   ! \($0)") }
    case "load":
        // Only the opening and the scenario's load: what the page and the log say, with no repair and no screens.
        print("[\(elapsed())] state \(session.state) \(session.stateDetail), route \(session.route), generation \(session.pageGeneration)")
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let text = (try? await session.call("return document.body.innerText.slice(0, 500);")) as? String ?? "(no text)"
        print("page text: \(text.replacingOccurrences(of: "\n", with: " | "))")
        print("problems: \(problems().count) \(problems().prefix(4))")
        // STUDIO_EVAL: a JavaScript function body evaluated on the page, for looking at one answer of the simulation.
        if let script = ProcessInfo.processInfo.environment["STUDIO_EVAL"] {
            let value = try? await session.call(script)
            print("eval: \(String(describing: value).prefix(1500))")
        }
        for saved in session.savedScenarios where !saved.id.hasPrefix("screen-") {
            print("compatibility of \(saved.name): \(StudioScenarioCompatibility.problems(saved, spec: session.spec))")
        }
        session.sessionLog.entries.filter { $0.kind == .navigation || $0.kind == .notice || $0.problem }.suffix(14).forEach {
            print("   \($0.kind.rawValue) \($0.problem ? "!" : "-") \(String($0.text.prefix(200)))")
        }
    case "review":
        // The one-time review of the environment (DEC-015) and what the page does with it: the response envelope, then a blocking dialog
        // that must go when its button is pressed. `dialog` and `button` are CSS selectors; the defaults are those of product-promotion-desk.
        let dialog = ProcessInfo.processInfo.environment["STUDIO_DIALOG"] ?? "[data-testid=\"agent-question\"]"
        let button = ProcessInfo.processInfo.environment["STUDIO_DIALOG_BUTTON"] ?? "[data-testid=\"agent-question-done\"]"
        let reviewed = await waitUntil(900) { session.spec.envelopes != nil && session.busy == nil && session.reviewTask == nil }
        print("[\(elapsed())] reviewed: \(reviewed), envelopes \(session.spec.envelopes.map { "\($0.count)" } ?? "none")")
        session.spec.envelopes?.forEach { print("   envelope \($0.prefix) → \($0.resultKey) \($0.successFields.keys.sorted()) failure \($0.failure != nil)") }
        session.sessionLog.entries.map(\.text).filter { $0.hasPrefix("Reviewed") || $0.contains("review of the environment") }
            .forEach { print("   log: \(String($0.prefix(300)))") }
        print("rules: \(session.spec.rules.count) (fixed answers \(session.spec.rules.filter { $0.operation == .respond }.count)), entities \(session.spec.entities.map(\.name))")
        // The page loads again on the reviewed answers: give it time to draw.
        _ = await waitUntil(60) { session.busy == nil && !session.isPreparing }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        print("route \(session.route), scenario \(session.scenario.name)")
        func shown() async -> String {
            ((try? await session.call("const d = document.querySelector(selector); return d ? d.innerText.replace(/\\s+/g, ' ').slice(0, 160) : '(no dialog)';", ["selector": dialog])) as? String) ?? "(no answer)"
        }
        print("page text: \(((try? await session.call("return document.body.innerText.slice(0, 300);")) as? String ?? "(no text)").replacingOccurrences(of: "\n", with: " | "))")
        var before = await shown()
        for _ in 0..<40 where before == "(no dialog)" {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            before = await shown()
        }
        print("dialog before: \(before)")
        for step in 1...4 {
            let clicked = (try? await session.call("const b = document.querySelector(selector); if (!b) return false; b.click(); return true;", ["selector": button])) as? Bool ?? false
            if !clicked { print("press \(step): no button"); break }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            print("press \(step): \(await shown())")
        }
        print("page html: \(((try? await session.call("return document.body.innerHTML.slice(0, 240);")) as? String ?? "(none)").replacingOccurrences(of: "\n", with: " "))")
        print("problems: \(problems().count)")
        problems().prefix(10).forEach { print("   ! \($0)") }
    default:
        print("unknown mode \(mode)")
    }
    print("[\(elapsed())] assistant calls: \(totals.calls), cost $\(String(format: "%.2f", totals.cost))")
    await session.close()
    withExtendedLifetime(windowServices) {}
}

func waitUntil(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

}
