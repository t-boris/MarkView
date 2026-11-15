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

// 2. AR-46 / DEC-005: setup.sh, project.yml, and MarkView/Core deleted
check(!fm.fileExists(atPath: root.appendingPathComponent("setup.sh").path),
      "AR-46: setup.sh is removed")
check(!fm.fileExists(atPath: root.appendingPathComponent("project.yml").path),
      "AR-46: project.yml is removed")
check(!fm.fileExists(atPath: root.appendingPathComponent("MarkView/Core").path),
      "FU-04: duplicate MarkView/Core/ directory removed in favor of Packages/MarkViewCore")
check(!fm.fileExists(atPath: root.appendingPathComponent("Packages/MarkViewCore/Sources/MarkViewCore/SettingsRegistry.swift").path),
      "FU-01: unused SettingsRegistry.swift removed from MarkViewCore")

// 3. AR-47 / AR-48: install.sh, tools/importance-check.sh, and dead compiler/model files removed
check(!fm.fileExists(atPath: root.appendingPathComponent("install.sh").path),
      "AR-47: install.sh is removed")
check(!fm.fileExists(atPath: root.appendingPathComponent("tools/importance-check.sh").path),
      "AR-47: tools/importance-check.sh is removed")
check(!fm.fileExists(atPath: root.appendingPathComponent("MarkView/Models/IncrementalCompiler.swift").path) &&
      !fm.fileExists(atPath: root.appendingPathComponent("MarkView/Models/DependencyGraphScheduler.swift").path) &&
      !fm.fileExists(atPath: root.appendingPathComponent("MarkView/Models/SemanticModel.swift").path),
      "AR-48: dead IncrementalCompiler, DependencyGraphScheduler, and SemanticModel are removed")

// 4. AR-22: view items live in MarkView/Views/, not MarkView/Models/
check(fm.fileExists(atPath: root.appendingPathComponent("MarkView/Views/AI/AIToolJobsBanner.swift").path) &&
      fm.fileExists(atPath: root.appendingPathComponent("MarkView/Views/Appearance/AppFontScaleView.swift").path) &&
      fm.fileExists(atPath: root.appendingPathComponent("MarkView/Views/QA/QAWebWindow.swift").path) &&
      !fm.fileExists(atPath: root.appendingPathComponent("MarkView/Models/QAWebWindow.swift").path),
      "AR-22: AIToolJobsBanner, AppFontScaleView, and QAWebWindow live in MarkView/Views/")

// 5. Required notice, editorconfig, and external terminal script assets exist on disk
check(fm.fileExists(atPath: root.appendingPathComponent("MarkView/Resources/Editor/vendor/MANIFEST.txt").path) &&
      fm.fileExists(atPath: root.appendingPathComponent("MarkView/Resources/Editor/js/markview-terminal.js").path) &&
      fm.fileExists(atPath: root.appendingPathComponent("THIRD_PARTY_NOTICES.md").path) &&
      fm.fileExists(atPath: root.appendingPathComponent(".editorconfig").path),
      "AR-47/AR-01: vendor/MANIFEST.txt, js/markview-terminal.js, THIRD_PARTY_NOTICES.md, and .editorconfig exist")

// 6. AR-44 step 1 & FU-07: tools/tests/manifest.json has accurate suiteCount, valid paths, and executable tools/tests/run.sh
let manifestData = (try? Data(contentsOf: root.appendingPathComponent("tools/tests/manifest.json"))) ?? Data()
let manifestObj = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any]
let declaredCount = manifestObj?["suiteCount"] as? Int ?? -1
let suites = manifestObj?["suites"] as? [[String: Any]] ?? []
check(suites.count >= 160 && declaredCount == suites.count && fm.isExecutableFile(atPath: root.appendingPathComponent("tools/tests/run.sh").path),
      "AR-44/FU-07: tools/tests/manifest.json suiteCount (\(declaredCount)) matches suites.count (\(suites.count)) and run.sh is executable")
var missingPaths: [String] = []
for s in suites {
    if let script = s["script"] as? String, !fm.fileExists(atPath: root.appendingPathComponent(script).path) {
        missingPaths.append(script)
    }
    for src in (s["sources"] as? [String] ?? []) {
        if !fm.fileExists(atPath: root.appendingPathComponent(src).path) {
            missingPaths.append(src)
        }
    }
}
check(missingPaths.isEmpty,
      "FU-07: every script and source path in tools/tests/manifest.json exists on disk (\(missingPaths))")

// 7. AR-23: grab-bag files split into single-responsibility files in domain folders
let splitFilesExist = [
    "MarkView/Models/Workspace/DocumentScrollSideTable.swift",
    "MarkView/Models/Workspace/TaskBag.swift",
    "MarkView/Models/Workspace/MarkdownDocumentChunker.swift",
    "MarkView/Models/Workspace/SchemaVersionedStore.swift",
    "MarkView/Models/AI/AIOperation.swift",
    "MarkView/Models/AI/AssistantProviderRegistry.swift",
].allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
let grabBagsRemoved = [
    "MarkView/Models/WorkspaceControllers.swift",
    "MarkView/Models/AILayer.swift",
    "MarkView/Models/StorageAndSecurity.swift",
].allSatisfy { !fm.fileExists(atPath: root.appendingPathComponent($0).path) }
check(splitFilesExist && grabBagsRemoved,
      "AR-23: grab-bag files split into single-responsibility files in domain folders")

print("\nPhase 1 cleanup checks: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
