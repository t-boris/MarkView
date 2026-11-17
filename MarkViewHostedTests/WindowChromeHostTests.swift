import Combine
import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

@MainActor
private enum WindowChromeChecks {
    static var suites: [String] = []

    static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        XCTAssertTrue(condition, message, line: line)
    }

    static func defaults() -> UserDefaults {
        let name = "window-chrome-tests-\(UUID().uuidString)"
        suites.append(name)
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @MainActor
    static func shown(_ chrome: WindowChrome) -> [Bool] { [chrome.showFileTree, chrome.showCenter, chrome.terminalVisible, chrome.agentsVisible, chrome.showTOC] }

    /// The state a session saved by the previous version holds: only the fields that version wrote.
    static func saved(navigator: String = "Contents", files: Bool = false, navigatorShown: Bool = false, contents: Bool? = nil,
                      terminal: Bool? = nil, agents: Bool? = nil, center: Bool? = nil) -> WorkspacePanelState {
        WorkspacePanelState(navigator: navigator, left: "files", feature: "", git: "Changes", stage: "Explore",
                            showFiles: files, showNavigator: navigatorShown, contentsVisible: contents,
                            terminalVisible: terminal, agentsVisible: agents, showCenter: center)
    }

    @MainActor
    static func run() {
        // A new window shows the center panel only.
        let first = WindowChrome(defaults: defaults())
        check(shown(first) == [false, true, false, false, false], "a new window shows the center panel only (\(shown(first)))")

        // The toggles never hide the last panel.
        first.toggleCenter()
        check(first.showCenter, "the center panel cannot be hidden while it is the only one")
        first.toggleNavigation()
        check(first.showFileTree && first.showCenter, "the file tree opens beside the center")
        first.toggleCenter()
        check(first.showFileTree && !first.showCenter, "the center hides while the file tree stays")
        first.toggleNavigation()
        check(first.showFileTree, "the file tree cannot be hidden while it is the only one")
        first.toggleRightPanel()
        check(first.showFileTree && first.terminalVisible, "the right panel opens beside the file tree")
        first.toggleNavigation()
        check(!first.showFileTree && first.terminalVisible && !first.showCenter, "the file tree hides while the right panel stays")
        first.toggleRightPanel()
        check(first.terminalVisible, "the right panel cannot be hidden while it is the only one")

        // Opened from Finder: the document and nothing around it.
        first.showFileTree = true
        first.agentsVisible = true
        first.showDocumentOnly()
        check(!first.showFileTree && !first.terminalVisible && !first.agentsVisible && first.showCenter, "a document opened on its own hides the panels around it")

        // The panels of a window never reach another one; the Contents column is only the starting value of the next window.
        let shared = defaults()
        let one = WindowChrome(defaults: shared)
        let other = WindowChrome(defaults: shared)
        one.showTOC = true
        one.showFileTree = true
        one.agentsVisible = true
        check(shown(other) == [false, true, false, false, false], "another window keeps its own panels (\(shown(other)))")
        let next = WindowChrome(defaults: shared)
        check(next.showTOC && !next.showFileTree && !next.agentsVisible, "a new window starts with the Contents column the last window left, and nothing else")
        next.showTOC = false
        check(one.showTOC, "closing the Contents column in the new window leaves the first window alone")

        // Only the panel that changes redraws, and every change redraws once.
        let counted = WindowChrome(defaults: defaults())
        var emissions = 0
        let subscription = counted.objectWillChange.sink { emissions += 1 }
        counted.showFileTree = true
        counted.compactLayout = true
        counted.showGlobalSearch = true
        check(emissions == 3, "each panel change announces itself once (\(emissions))")
        subscription.cancel()

        // The panels a session saves come back.
        let combinations: [[Bool]] = [
            [false, true, false, false, false], [true, true, false, false, true], [true, false, true, true, true],
            [false, false, true, false, false], [true, false, false, true, false], [false, true, true, true, true],
        ]
        for combination in combinations {
            let source = WindowChrome(defaults: defaults())
            source.showFileTree = combination[0]; source.showCenter = combination[1]; source.terminalVisible = combination[2]
            source.agentsVisible = combination[3]; source.showTOC = combination[4]
            var panels = saved()
            source.save(into: &panels)
            guard let data = try? JSONEncoder().encode(panels), let decoded = try? JSONDecoder().decode(WorkspacePanelState.self, from: data) else {
                check(false, "the saved panels encode and decode"); continue
            }
            let target = WindowChrome(defaults: defaults())
            target.restore(decoded)
            let expected = combination[0] || combination[1] || combination[2] ? combination : [combination[0], true, combination[2], combination[3], combination[4]]
            check(shown(target) == expected, "panels \(combination) survive a session (got \(shown(target)))")
        }

        // A window saved with every panel hidden comes back showing the center.
        let hidden = WindowChrome(defaults: defaults())
        hidden.restore(saved(files: false, contents: false, terminal: false, agents: false, center: false))
        check(hidden.showCenter && !hidden.showFileTree && !hidden.terminalVisible, "a session with no panel shown restores the center")

        // Sessions saved before the agents panel and the Contents column were separate.
        let oldNavigatorOpen = WindowChrome(defaults: defaults())
        oldNavigatorOpen.restore(saved(navigator: "Contents", files: true, navigatorShown: true))
        check(oldNavigatorOpen.terminalVisible && !oldNavigatorOpen.agentsVisible && oldNavigatorOpen.showFileTree && oldNavigatorOpen.showCenter && !oldNavigatorOpen.showTOC,
              "an old session with the navigator open shows the right panel (\(shown(oldNavigatorOpen)))")
        let oldTerminal = WindowChrome(defaults: defaults())
        oldTerminal.restore(saved(navigator: "Terminal", files: false, navigatorShown: true))
        check(!oldTerminal.terminalVisible && oldTerminal.agentsVisible && oldTerminal.showCenter,
              "an old session whose navigator was the terminal shows the agents panel instead (\(shown(oldTerminal)))")
        let oldTerminalClosed = WindowChrome(defaults: defaults())
        oldTerminalClosed.restore(saved(navigator: "Terminal", files: true, navigatorShown: false))
        check(!oldTerminalClosed.terminalVisible && !oldTerminalClosed.agentsVisible && oldTerminalClosed.showFileTree,
              "an old session whose terminal was closed keeps it closed (\(shown(oldTerminalClosed)))")
        let unknownNavigator = WindowChrome(defaults: defaults())
        unknownNavigator.restore(saved(navigator: "Something later", files: true, navigatorShown: false, terminal: false, agents: true, center: true))
        check(unknownNavigator.agentsVisible && unknownNavigator.showCenter && unknownNavigator.showFileTree && !unknownNavigator.terminalVisible,
              "a navigator this version does not know does not break the restore (\(shown(unknownNavigator)))")
    }

}

extension EditorHostTests {
    @MainActor func testWindowChromeTogglesAndRestoration() {
        defer {
            for name in WindowChromeChecks.suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
            WindowChromeChecks.suites.removeAll()
        }
        WindowChromeChecks.run()
    }
}
