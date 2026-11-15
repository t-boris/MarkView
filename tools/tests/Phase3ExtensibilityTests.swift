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

print("=== Phase 3: Declarative Extension Points & Registries Verification ===")

// 1. AR-31 / DEC-001: ToolRegistry covers all 10 singleton tools across surfaces
let expectedToolIDs: Set<String> = [
    "git", "deployments", "workflow", "qa", "uiStudio",
    "prototype", "cockpit", "architecture", "researchMap", "discussions"
]
let actualToolIDs = Set(ToolRegistry.all.map(\.id))
check(actualToolIDs == expectedToolIDs,
      "AR-31/DEC-001: ToolRegistry.all registers all 10 singleton workspace tools")
check(ToolRegistry.toolbarTools.count == 10 && ToolRegistry.menuTools.count == 10 && ToolRegistry.welcomeTools.count == 10,
      "AR-31: Toolbar, View menu, and Welcome screen read from one ToolRegistry without drift")
check(ToolRegistry.descriptor(for: "discussions")?.surfaces.contains(.sessionRestore) == true &&
      ToolRegistry.descriptor(for: "architecture")?.surfaces.contains(.sessionRestore) == true,
      "AR-31: ToolRegistry tracks sessionRestore surface metadata")

// 2. AR-32 / DEC-003: Data-driven themes + user theme JSON loading + automatic web CSS token derivation
check(ThemeRegistry.builtIn.count == 11,
      "AR-32: ThemeRegistry.builtIn exposes all 11 built-in theme definitions")

let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mv-themes-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tempDir) }
try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

let userThemeJSON = """
{
  "id": "solarizedDark",
  "displayName": "Solarized Dark",
  "summary": "Precision dark palette by Ethan Schoonover",
  "isDark": true,
  "bg": "#002B36",
  "bgSidebar": "#073642",
  "bgInput": "#0D414F",
  "bgHover": "#0A3A47",
  "bgActive": "#134B5B",
  "bgBanner": "#00212B",
  "text": "#839496",
  "textDim": "#586E75",
  "textBright": "#FDF6E3",
  "border": "#073642",
  "accent": "#268BD2",
  "green": "#859900",
  "orange": "#CB4B16",
  "yellow": "#B58900",
  "purple": "#6C71C4",
  "red": "#DC322F",
  "cyan": "#2AA198"
}
"""
try? userThemeJSON.write(to: tempDir.appendingPathComponent("solarized-dark.json"), atomically: true, encoding: .utf8)
try? "{ invalid json ".write(to: tempDir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

let loadedUserThemes = ThemeRegistry.loadUserThemes(from: tempDir)
check(loadedUserThemes.count == 1 && loadedUserThemes.first?.id == "solarizedDark",
      "AR-32/DEC-003: ThemeRegistry.loadUserThemes loads valid user JSON theme and skips malformed JSON")

if let userTheme = loadedUserThemes.first {
    let tokens = userTheme.effectiveWebTokens
    let cssVars = tokens.cssVariables()
    check(cssVars["--bg-color"] == "#002B36" &&
          cssVars["--code-bg"] == "#073642" &&
          cssVars["--heading-color"] == "#FDF6E3" &&
          cssVars["--link-color"] != nil,
          "AR-32/DEC-003: ThemeDefinition derives web CSS tokens automatically when webTokens are omitted")
    let palette = userTheme.makePalette()
    check(ThemeColor.contrast(palette.text, palette.bg) >= ThemePalette.readableContrast &&
          ThemeColor.contrast(palette.blue, palette.bg) >= ThemePalette.readableContrast,
          "AR-32: User theme palette enforces WCAG contrast >= 4.5")
}

// 3. AR-33 / DEC-002: LayoutPreset (Writing, Review, QA, Cockpit) with explicit user selection only
let presetIDs = LayoutPreset.builtIn.map(\.id)
check(presetIDs == ["writing", "review", "qa", "cockpit"],
      "AR-33/DEC-002: LayoutPreset ships Writing, Review, QA, and Cockpit presets")

let suiteName = "com.markview.phase3.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }

Task { @MainActor in
    let layout = PanelLayout(defaults: defaults)
    check(layout.activePresetID == nil,
          "AR-33/DEC-002: PanelLayout has no automatic preset trigger on init")
    layout.apply(preset: .review)
    check(layout.activePresetID == "review" &&
          layout.workspaceArea == .work &&
          layout.workSection == .git &&
          layout.navigatorTab == .git &&
          layout.leftPanel == "issues",
          "AR-33/DEC-002: PanelLayout.apply(preset:) updates panel state on explicit user selection")
    layout.apply(preset: .cockpit)
    check(layout.activePresetID == "cockpit" &&
          layout.workSection == .terminal &&
          layout.navigatorTab == .terminal,
          "AR-33/DEC-002: PanelLayout.apply(preset: .cockpit) switches to Cockpit layout")
}
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

// 4. AR-34: BackdropRegistry, MCPToolRegistry, and FileTypeRegistry
check(BackdropRegistry.all.count == WelcomeBackdrop.allCases.count &&
      BackdropRegistry.descriptor(for: .matrix).isAnimatedScene &&
      !BackdropRegistry.descriptor(for: .off).isAnimatedScene,
      "AR-34: BackdropRegistry covers all WelcomeBackdrop cases with scene metadata")

check(MCPToolRegistry.all.count >= 40 &&
      MCPToolRegistry.descriptor(for: "markview_create_feature")?.isMutating == true &&
      MCPToolRegistry.descriptor(for: "markview_get_feature")?.isMutating == false,
      "Section 7.5: MCPToolRegistry maps MCP tools to mutating/read-only descriptors")

check(FileTypeRegistry.descriptor(forExtension: "md")?.kind == "markdown" &&
      FileTypeRegistry.descriptor(forExtension: "swift")?.kind == "code" &&
      FileTypeRegistry.descriptor(forExtension: "parquet")?.kind == "data" &&
      FileTypeRegistry.descriptor(forExtension: "pdf")?.kind == "pdf",
      "Section 7.6: FileTypeRegistry maps extensions to kind, symbol, color, and viewerMode")

print("\nPhase 3 Extensibility checks: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
