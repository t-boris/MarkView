import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(name)")
    }
}

print("=== Phase 3: Declarative ToolRegistry & PanelLayout Verification ===")

// 1. AR-31 / DEC-001 / FU-02: ToolRegistry holds the 8 live tools, and the toolbar, the View menu and the shortcuts are generated from it
let registry = ToolRegistry.shared
let expectedToolIDs: [ToolID] = [.git, .deployments, .workflow, .qa, .uiStudio, .cockpit, .discussions, .changeReview]
check(registry.tools.map(\.id) == expectedToolIDs, "AR-31: ToolRegistry registers the 8 live singleton workspace tools, once each")

check(registry.toolbarTools(.primary).map(\.id) == [.git, .deployments, .workflow, .qa, .uiStudio, .cockpit],
      "AR-31: the primary toolbar cluster is Git, Deployments, Workflow, QA, UI Studio, Cockpit, in that order")
check(registry.toolbarTools(.afterBrowser).map(\.id) == [.discussions], "AR-31: Discussions is the one button after the Browser menu")
check(registry.tools.filter { $0.toolbar == nil }.map(\.id) == [.changeReview], "AR-31: Change Review has no toolbar button")

check(registry.menuTools(.afterAgents).map(\.id) == [.deployments, .discussions],
      "AR-31: the View menu shows Build & Deployment, then Discussions, after Agents")
check(registry.menuTools(.afterWebPreview).map(\.id) == [.uiStudio, .qa, .cockpit],
      "AR-31: the View menu shows UI Studio, End-to-End QA and Copilot Cockpit after Preview Web App")
check(registry.menuTools(.afterWebPreview).allSatisfy { $0.menu?.requiresFolder == true }
      && registry.menuTools(.afterAgents).allSatisfy { $0.menu?.requiresFolder == false },
      "AR-31: the menu items that need a folder are the ones the menu disabled without one")

// The shortcuts the app has always had, and no two tools on the same keys.
func shortcutHint(_ id: ToolID) -> String? { registry.descriptor(for: id)?.shortcut?.hint }
check(shortcutHint(.deployments) == "⌃⌘D" && shortcutHint(.discussions) == "⌃⌘I" && shortcutHint(.uiStudio) == "⌘7" && shortcutHint(.qa) == "⌘8",
      "AR-31: shortcuts are Build & Deployment ⌃⌘D, Discussions ⌃⌘I, UI Studio ⌘7, End-to-End QA ⌘8")
check(registry.tools.filter { $0.shortcut == nil }.map(\.id) == [.git, .workflow, .cockpit, .changeReview],
      "AR-31: Git, Workflow, Cockpit and Change Review have no shortcut")
let shortcuts = registry.tools.compactMap(\.shortcut)
check(Set(shortcuts).count == shortcuts.count, "AR-31: no two tools share a shortcut")
check(registry.descriptor(for: .deployments)?.help == "Build & Deployment (⌃⌘D)" && registry.descriptor(for: .git)?.help == "Git"
      && registry.descriptor(for: .qa)?.help == "End-to-End QA (⌘8)" && registry.descriptor(for: .cockpit)?.help == "Copilot Cockpit",
      "AR-31: the toolbar tooltip is the title plus the shortcut")

// One title and one icon per tool (the toolbar, the tab and the tile used to disagree for Workflow, QA, Discussions and UI Studio).
check(registry.tools.map(\.title) == ["Git", "Build & Deployment", "Workflow", "End-to-End QA", "UI Studio", "Copilot Cockpit", "Discussions", "File changes"],
      "AR-31: the titles the tabs show are unchanged")
check(registry.descriptor(for: .workflow)?.icon == "point.3.connected.trianglepath.dotted" && registry.descriptor(for: .qa)?.icon == "checkmark.shield"
      && registry.descriptor(for: .discussions)?.icon == "bubble.left.and.text.bubble.right" && registry.descriptor(for: .uiStudio)?.icon == "macwindow.and.cursorarrow",
      "AR-31: Workflow, QA, Discussions and UI Studio each have one icon")
check(Set(registry.tools.map(\.icon)).count == registry.tools.count, "AR-31: no two tools share an icon")

// Saved tabs of older sessions, and the project's placeholder files, depend on the sentinel paths and the saved keys.
let sampleRoot = URL(fileURLWithPath: "/tmp/markview-tool-registry-test")
let oldSentinels: [(ToolID, String)] = [
    (.git, ".dde/.markview-git"), (.deployments, ".dde/.markview-deployments"), (.workflow, ".dde/.markview-workflow"),
    (.qa, ".dde/.markview-qa"), (.uiStudio, ".dde/.markview-ui-studio-"), (.cockpit, ".dde/.markview-cockpit"),
    (.discussions, ".dde/.markview-discussions"), (.changeReview, ".dde/.markview-file-changes")
]
check(oldSentinels.allSatisfy { registry.descriptor(for: $0.0)?.sentinelURL(in: sampleRoot).path == "/tmp/markview-tool-registry-test/" + $0.1 },
      "AR-31/FU-02: every sentinel URL is the one older sessions used")
check(registry.descriptor(for: .uiStudio)?.sentinelURL(in: sampleRoot, suffix: "abc").path == "/tmp/markview-tool-registry-test/.dde/.markview-ui-studio-abc",
      "AR-31/FU-02: UI Studio's sentinel takes its session id")
check(registry.tools.map(\.id.rawValue) == ["git", "deployments", "workflow", "qa", "uiStudio", "cockpit", "discussions", "changeReview"],
      "AR-31: the saved keys of the tools are unchanged")

// One new descriptor is every surface at once: a registry with a fake tool generates its button, menu item, tab icon and title, and restore.
let fake = ToolDescriptor(id: ToolID(rawValue: "fakeTool"), title: "Fake Tool", icon: "star", sentinelPath: ".dde/.markview-fake",
                          shortcut: ToolShortcut(key: "9", modifiers: [.command, .option]), toolbar: .primary,
                          menu: ToolMenuEntry(slot: .afterAgents, order: 9, requiresFolder: true),
                          welcome: ToolWelcomeTile(section: .explore, order: 99, hint: "A tool nobody wrote"), restorable: true)
let extended = ToolRegistry(tools: registry.tools + [fake])
check(extended.toolbarTools(.primary).last?.id == fake.id, "AR-31: a new descriptor appears in the toolbar")
check(extended.menuTools(.afterAgents).last?.id == fake.id && fake.shortcut?.hint == "⌥⌘9", "AR-31: a new descriptor appears in the View menu, with its shortcut")
let fakeTile = WelcomeCatalogue.project(isGitRepo: false, registry: extended).first { $0.section == .explore }?.actions.last
check(fakeTile?.id == .tool(fake.id) && fakeTile?.title == "Fake Tool" && fakeTile?.symbol == "star" && fakeTile?.shortcut == "⌥⌘9",
      "AR-31: a new descriptor appears among the welcome tiles, in its section and place, with its icon and shortcut")
check(WelcomeCatalogue.project(isGitRepo: false, registry: registry).flatMap(\.actions).allSatisfy { $0.id != .tool(fake.id) },
      "AR-31: the real registry offers no tile for the fake tool")
check(extended.descriptor(for: fake.id)?.icon == "star" && extended.descriptor(for: fake.id)?.title == "Fake Tool",
      "AR-31: a new descriptor gives its tab an icon and a title")
check(extended.isRestorable(fake.id) && !registry.isRestorable(fake.id), "AR-31: a new descriptor is in the restore set; the real registry does not know it")
check(extended.descriptor(for: fake.id)?.sentinelURL(in: sampleRoot).path == "/tmp/markview-tool-registry-test/.dde/.markview-fake", "AR-31: a new descriptor gives its sentinel")
check(extended.toolbarTools(.primary).dropLast().map(\.id) == registry.toolbarTools(.primary).map(\.id)
      && extended.menuTools(.afterAgents).dropLast().map(\.id) == registry.menuTools(.afterAgents).map(\.id),
      "AR-31: the other tools keep their places")

// 2. AR-33 / FU-08: PanelLayout has no hidden layout presets and starts in default workspace state
let suiteName = "com.markview.phase3.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }

Task { @MainActor in
    let layout = PanelLayout(defaults: defaults)
    check(layout.workspaceArea == .files
              && layout.navigatorTab == .contents
              && layout.workSection == .features
              && layout.leftPanel == "files"
              && layout.gitSection == .changes,
          "AR-33/FU-08: PanelLayout initializes directly to clean defaults without presets")
}
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))

print("\nPhase 3 Extensibility checks: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
