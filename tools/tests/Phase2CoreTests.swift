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

    let canceledTask = Task { () -> SubprocessResult in
        try? await Task.sleep(nanoseconds: 15_000_000)
        return await Subprocess.run(SubprocessSpec(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: 5
        ))
    }
    canceledTask.cancel()
    let cancelRes = await canceledTask.value
    check(!cancelRes.succeeded && cancelRes.durationMs < 1500,
          "FU-04: Pre-cancelled Task does not launch or block in Subprocess.run")

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

// 4. AR-24 & FU-04: AtomicFile permissions (initial set + nil preservation on overwrite)
let permURL = temp.appendingPathComponent("perm.secret")
try? AtomicFile.write("secret-v1", to: permURL, permissions: 0o600)
let perm1 = (try? FileManager.default.attributesOfItem(atPath: permURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
try? AtomicFile.write("secret-v2", to: permURL, permissions: nil)
let perm2 = (try? FileManager.default.attributesOfItem(atPath: permURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
check(perm1 == 0o600 && perm2 == 0o600, "FU-04: AtomicFile.write sets 0600 permissions and preserves existing mode when permissions is nil")

let extraBinDir = temp.appendingPathComponent("extra-bin")
try? FileManager.default.createDirectory(at: extraBinDir, withIntermediateDirectories: true)
let toolScript = extraBinDir.appendingPathComponent("mv-phase2-probe")
try? AtomicFile.write("#!/bin/sh\necho extra-path-ok\n", to: toolScript, permissions: 0o755)
let extraSuite = "com.markview.phase2.extrapath.\(UUID().uuidString)"
if let extraDefaults = UserDefaults(suiteName: extraSuite) {
    defer { extraDefaults.removePersistentDomain(forName: extraSuite) }
    extraDefaults.set(extraBinDir.path, forKey: Subprocess.extraPATHDefaultsKey)
    let dirs = Subprocess.configuredExtraPATHDirectories(defaults: extraDefaults)
    let resolvedViaExtra = Subprocess.resolveExecutable(
        "mv-phase2-probe",
        searchPaths: Subprocess.effectiveSearchPaths(extra: dirs)
    )
    check(resolvedViaExtra == toolScript.path,
          "FU-04: Subprocess resolves executables from settings.cli.extraPATH")
}

// 5. AR-27: WeakScriptMessageHandler breaks retain cycle
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

print("\nPhase 2 Core checks: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
