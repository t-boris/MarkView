import Foundation
import WebKit

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

print("=== Phase 2: Shared Core Infrastructure & MarkViewCore Verification ===")

let sem = DispatchSemaphore(value: 0)
Task {
    // 1. AR-25: Subprocess async run, output cap, and timeout escalation
    let echoRes = await Subprocess.run(SubprocessSpec(executable: "/bin/echo", arguments: ["phase2-ok"]))
    check(echoRes.succeeded && echoRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "phase2-ok",
          "AR-25: Subprocess.run executes command and captures stdout")

    let capRes = await Subprocess.run(SubprocessSpec(
        executable: "/bin/sh",
        arguments: ["-c", "yes 0123456789abcdef | head -n 400"],
        timeout: 5,
        maxOutputBytes: 1024
    ))
    check(capRes.truncated && capRes.stdout.utf8.count <= 1024,
          "AR-25: Subprocess.run enforces maxOutputBytes cap without pipe deadlock")

    let timeoutRes = await Subprocess.run(SubprocessSpec(
        executable: "/usr/bin/python3",
        arguments: ["-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(10)"],
        timeout: 0.2
    ))
    check(timeoutRes.timedOut,
          "AR-25: Subprocess.run escalates SIGTERM -> SIGKILL on timeout")

    sem.signal()
}
sem.wait()

// 2. AR-24: AtomicFile, ProjectPaths (symlink containment), ContentHash, JSONLinesFile, AppLogger
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mv-phase2-\(UUID().uuidString)")
let root = temp.appendingPathComponent("workspace")
let outside = temp.appendingPathComponent("outside")
defer { try? FileManager.default.removeItem(at: temp) }

try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
let secret = outside.appendingPathComponent("secret.md")
try? AtomicFile.write("top secret", to: secret, permissions: 0o600)

let validDoc = root.appendingPathComponent("docs/guide.md")
try? AtomicFile.write("# Guide", to: validDoc)
check(ProjectPaths.contains(validDoc, root: root) &&
      ProjectPaths.relativePath(of: validDoc, under: root) == "docs/guide.md",
      "AR-24: ProjectPaths.contains and relativePath accept in-project files")

let symlinkEscape = root.appendingPathComponent("docs/escape.md")
try? FileManager.default.createSymbolicLink(at: symlinkEscape, withDestinationURL: secret)
check(!ProjectPaths.contains(symlinkEscape, root: root),
      "AR-24: ProjectPaths.contains rejects symlinks pointing outside root")

// 3. AR-38 / AR-24: Collision-free projectCacheIdentifier
let idA = ProjectPaths.projectCacheIdentifier(for: URL(fileURLWithPath: "/Users/alice/app"))
let idB = ProjectPaths.projectCacheIdentifier(for: URL(fileURLWithPath: "/Users/bob/app"))
check(idA != idB && idA.hasPrefix("app-"),
      "AR-24/AR-38: ProjectPaths.projectCacheIdentifier disambiguates identically named folders")

// 4. AR-24: RotatingJSONLinesFile rotation
let jsonl = RotatingJSONLinesFile(url: temp.appendingPathComponent("log.jsonl"), maxBytes: 1024)
for i in 0..<50 {
    try? jsonl.appendLine("{\"i\":\(i),\"pad\":\"\(String(repeating: "a", count: 32))\"}")
}
check(FileManager.default.fileExists(atPath: jsonl.url.appendingPathExtension("1").path) && !jsonl.readLines().isEmpty,
      "AR-24: JSONLinesFile rotates to .1 when maxBytes is exceeded")

// 5. AR-18: SettingsRegistry typed keys & scoped UserDefaults snapshot in AIAssistants
let suite = "com.markview.phase2.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
check(SettingsRegistry.int(SettingsRegistry.appFontScalePercent, in: defaults) == 100,
      "AR-18: SettingsRegistry returns default value when unset")
SettingsRegistry.set(140, for: SettingsRegistry.appFontScalePercent, in: defaults)
check(SettingsRegistry.int(SettingsRegistry.appFontScalePercent, in: defaults) == 140,
      "AR-18: SettingsRegistry stores and reads typed value")

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let pickerSwift = (try? String(contentsOf: repoRoot.appendingPathComponent("MarkView/Views/AIAssistantPickerView.swift"), encoding: .utf8)) ?? ""
let wmSwift = (try? String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/WorkspaceManager.swift"), encoding: .utf8)) ?? ""
check(pickerSwift.contains("AIAssistantPreferences.snapshot(project: project)"),
      "AR-18: AIAssistantPickerView ignores unrelated UserDefaults changes via snapshot")
check(wmSwift.contains("workspaceLogger.debug") && !wmSwift.contains("markview_debug.log"),
      "AR-24/AR-42: WorkspaceManager.debugLog uses os.Logger instead of ~/markview_debug.log")

// 6. AR-27: WeakScriptMessageHandler breaks retain cycle
final class DummyHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}
weak var weakHandler: DummyHandler?
autoreleasepool {
    let handler = DummyHandler()
    weakHandler = handler
    let proxy = WeakScriptMessageHandler(handler)
    _ = proxy.target
}
check(weakHandler == nil,
      "AR-27: WeakScriptMessageHandler does not retain its target")

// 7. AR-44 step 2 / DEC-006: Packages/MarkViewCore exists with StrictConcurrency enabled
let pkgSwift = (try? String(contentsOf: repoRoot.appendingPathComponent("Packages/MarkViewCore/Package.swift"), encoding: .utf8)) ?? ""
check(pkgSwift.contains("name: \"MarkViewCore\"") && pkgSwift.contains("StrictConcurrency"),
      "AR-44/DEC-006/DEC-010: Packages/MarkViewCore/Package.swift exists with StrictConcurrency")

print("\nPhase 2 Core checks: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
