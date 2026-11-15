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

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default

print("=== Phase 1: Repository Hygiene & Cleanup Verification ===")

// 1. AR-30 / DEC-004: EditorWeb, EDITOR_IMPLEMENTATION.md, QUICKSTART.md deleted
check(!fm.fileExists(atPath: root.appendingPathComponent("EditorWeb").path),
      "AR-30: EditorWeb/ is removed")
check(!fm.fileExists(atPath: root.appendingPathComponent("EDITOR_IMPLEMENTATION.md").path),
      "AR-30: EDITOR_IMPLEMENTATION.md is removed")
check(!fm.fileExists(atPath: root.appendingPathComponent("QUICKSTART.md").path),
      "AR-30: QUICKSTART.md is removed")

// 2. AR-46 / DEC-005: setup.sh and project.yml deleted; bump-version.sh & release.sh read project.pbxproj
check(!fm.fileExists(atPath: root.appendingPathComponent("setup.sh").path),
      "AR-46: setup.sh is removed")
check(!fm.fileExists(atPath: root.appendingPathComponent("project.yml").path),
      "AR-46: project.yml is removed")
let bumpScript = (try? String(contentsOf: root.appendingPathComponent("bump-version.sh"), encoding: .utf8)) ?? ""
let releaseScript = (try? String(contentsOf: root.appendingPathComponent("release.sh"), encoding: .utf8)) ?? ""
check(!bumpScript.contains("project.yml") && bumpScript.contains("project.pbxproj") && bumpScript.contains("marketing_count"),
      "AR-46/AR-47: bump-version.sh reads and verifies MARKETING_VERSION in project.pbxproj")
check(!releaseScript.contains("project.yml") && releaseScript.contains("project.pbxproj"),
      "AR-46: release.sh reads MARKETING_VERSION from project.pbxproj")

// 3. AR-47 / AR-48: install.sh, tools/importance-check.sh, dead compiler/model files, and dead bridge methods removed
check(!fm.fileExists(atPath: root.appendingPathComponent("install.sh").path),
      "AR-47: install.sh is removed")
check(!fm.fileExists(atPath: root.appendingPathComponent("tools/importance-check.sh").path),
      "AR-47: tools/importance-check.sh is removed")
check(!fm.fileExists(atPath: root.appendingPathComponent("MarkView/Models/IncrementalCompiler.swift").path) &&
      !fm.fileExists(atPath: root.appendingPathComponent("MarkView/Models/DependencyGraphScheduler.swift").path) &&
      !fm.fileExists(atPath: root.appendingPathComponent("MarkView/Models/SemanticModel.swift").path),
      "AR-48: dead IncrementalCompiler, DependencyGraphScheduler, and SemanticModel are removed")
let bridgeSwift = (try? String(contentsOf: root.appendingPathComponent("MarkView/Bridge/WebViewBridge.swift"), encoding: .utf8)) ?? ""
check(!bridgeSwift.contains("struct BridgeMessage") &&
      !bridgeSwift.contains("func requestHTML(") &&
      !bridgeSwift.contains("func preparePrintLayout(") &&
      !bridgeSwift.contains("func restoreEditLayout("),
      "AR-28/AR-48: dead BridgeMessage, requestHTML, preparePrintLayout, restoreEditLayout removed from WebViewBridge")

// 4. AR-22: TOCView.Tab moved to PanelLayout (NavigatorTab) and view items moved out of Models/
let panelLayoutSwift = (try? String(contentsOf: root.appendingPathComponent("MarkView/Models/PanelLayout.swift"), encoding: .utf8)) ?? ""
check(panelLayoutSwift.contains("enum NavigatorTab: String, CaseIterable") && !panelLayoutSwift.contains("TOCView.Tab"),
      "AR-22: PanelLayout owns NavigatorTab without referencing TOCView.Tab")
check(fm.fileExists(atPath: root.appendingPathComponent("MarkView/Views/AIToolJobsBanner.swift").path) &&
      fm.fileExists(atPath: root.appendingPathComponent("MarkView/Views/AppFontScaleView.swift").path) &&
      fm.fileExists(atPath: root.appendingPathComponent("MarkView/Views/QAWebWindow.swift").path) &&
      !fm.fileExists(atPath: root.appendingPathComponent("MarkView/Models/QAWebWindow.swift").path),
      "AR-22: AIToolJobsBanner, AppFontScaleView, and QAWebWindow live in MarkView/Views/")

// 5. AR-47: project.pbxproj no longer duplicates editor assets in PBXResourcesBuildPhase, Cockpit phase has inputs/outputs, MANIFEST.txt & THIRD_PARTY_NOTICES.md & .editorconfig present
let pbx = (try? String(contentsOf: root.appendingPathComponent("MarkView.xcodeproj/project.pbxproj"), encoding: .utf8)) ?? ""
check(!pbx.contains("/* index.html in Resources */") &&
      !pbx.contains("/* BUILD_NOTES.md in Resources */") &&
      pbx.contains("$(DERIVED_FILE_DIR)/cockpit-runtime.stamp"),
      "AR-47: project.pbxproj avoids duplicate flat editor resources and declares Cockpit build phase outputs")
let vendorManifest = (try? String(contentsOf: root.appendingPathComponent("MarkView/Resources/Editor/vendor/MANIFEST.txt"), encoding: .utf8)) ?? ""
check(vendorManifest.contains("dompurify") && vendorManifest.contains("codemirror-bundle") && !vendorManifest.contains("html: false"),
      "AR-47: vendor/MANIFEST.txt lists newer bundles and documents DOMPurify sanitisation posture")
check(fm.fileExists(atPath: root.appendingPathComponent("THIRD_PARTY_NOTICES.md").path) &&
      fm.fileExists(atPath: root.appendingPathComponent(".editorconfig").path),
      "AR-47: THIRD_PARTY_NOTICES.md and .editorconfig exist")

// 6. AR-44 step 1: tools/tests/manifest.json and tools/tests/run.sh exist and list > 160 suites
let manifestData = (try? Data(contentsOf: root.appendingPathComponent("tools/tests/manifest.json"))) ?? Data()
let manifestObj = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any]
let suites = manifestObj?["suites"] as? [[String: Any]] ?? []
check(suites.count >= 160 && fm.isExecutableFile(atPath: root.appendingPathComponent("tools/tests/run.sh").path),
      "AR-44 step 1: tools/tests/manifest.json (\(suites.count) suites) and executable tools/tests/run.sh exist")

print("\nPhase 1 cleanup checks: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
