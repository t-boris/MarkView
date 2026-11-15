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

// 1. AR-31 / DEC-001 / FU-02: ToolRegistry matches the 8 live workspace tools and toolbar/session surfaces
let expectedToolIDs: Set<ToolDescriptor.ToolID> = [
    .git, .deployments, .workflow, .qa, .uiStudio, .cockpit, .discussions, .changeReview
]
let actualToolIDs = Set(ToolRegistry.all.map(\.id))
check(actualToolIDs == expectedToolIDs && ToolRegistry.all.count == 8,
      "AR-31/FU-02: ToolRegistry.all registers the 8 live singleton workspace tools")

let expectedPrimaryIDs: [ToolDescriptor.ToolID] = [.git, .deployments, .workflow, .qa, .uiStudio, .cockpit]
check(ToolRegistry.primaryToolbarTools.map(\.id) == expectedPrimaryIDs,
      "AR-31/FU-02: ToolRegistry.primaryToolbarTools matches the 6 primary toolbar buttons in order")
check(ToolRegistry.descriptor(for: .git)?.title == "Git" &&
      ToolRegistry.descriptor(for: .cockpit)?.sentinelPath == ".dde/.markview-cockpit",
      "AR-31/FU-02: ToolRegistry.descriptor(for:) resolves live tool metadata")

let sampleRoot = URL(fileURLWithPath: "/tmp/markview-tool-registry-test")
check(ToolRegistry.sentinelURL(for: .git, in: sampleRoot).path == "/tmp/markview-tool-registry-test/.dde/.markview-git" &&
      ToolRegistry.sentinelURL(for: .uiStudio, in: sampleRoot, suffix: "abc").path == "/tmp/markview-tool-registry-test/.dde/.markview-ui-studio-abc",
      "AR-31/FU-02: ToolRegistry.sentinelURL resolves per-tool sentinel URLs")

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
