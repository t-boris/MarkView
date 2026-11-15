import Foundation
import WebKit
import XCTest
@testable import MarkViewCore

final class MarkViewCoreTests: XCTestCase {
    func testSubprocessRunAndOutputCap() async {
        let ok = await Subprocess.run(SubprocessSpec(executable: "/bin/echo", arguments: ["hello", "world"]))
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")

        let capped = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "yes abcdefghijklmnopqrstuvwxyz | head -n 500"],
            timeout: 5,
            maxOutputBytes: 1024
        ))
        XCTAssertTrue(capped.truncated)
        XCTAssertLessThanOrEqual(capped.stdout.utf8.count, 1024)
    }

    func testSubprocessTimeoutEscalation() async {
        let timedOut = await Subprocess.run(SubprocessSpec(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(10)"],
            timeout: 0.2
        ))
        XCTAssertTrue(timedOut.timedOut)
    }

    func testSubprocessMergesEnvironmentAndRespectsExtraPATH() async throws {
        // Environment override merges with inherited environment instead of wiping it (`FU-04`).
        let merged = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s|%s' \"$PATH\" \"$MARKVIEW_TEST_ENV\""],
            environment: ["MARKVIEW_TEST_ENV": "merged-ok"]
        ))
        XCTAssertTrue(merged.succeeded)
        let parts = merged.stdout.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 2)
        XCTAssertFalse(parts[0].isEmpty, "Inherited PATH must be preserved when spec.environment is set")
        XCTAssertEqual(parts[1], "merged-ok")

        // `settings.cli.extraPATH` resolves custom binary locations (`FU-04`).
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mvbin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let toolURL = tempDir.appendingPathComponent("mv-custom-tool")
        try AtomicFile.write("#!/bin/sh\necho extra-path-ok\n", to: toolURL, permissions: 0o755)

        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Subprocess.extraPATHDefaultsKey)
        defaults.set(tempDir.path, forKey: Subprocess.extraPATHDefaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: Subprocess.extraPATHDefaultsKey) }
            else { defaults.removeObject(forKey: Subprocess.extraPATHDefaultsKey) }
        }

        let resolved = Subprocess.resolveExecutable("mv-custom-tool")
        XCTAssertEqual(resolved, toolURL.path)
        let res = await Subprocess.run(SubprocessSpec(executable: "mv-custom-tool"))
        XCTAssertTrue(res.succeeded)
        XCTAssertEqual(res.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "extra-path-ok")
    }

    func testSubprocessDoesNotHangOnDetachedDescendantHoldingStdout() async {
        // Spawns a background sleep child that keeps stdout open after parent exits;
        // Subprocess.run must return promptly without blocking on unbounded readDataToEndOfFile (`FU-04`).
        let res = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "echo parent-done; sleep 3 &"],
            timeout: 2
        ))
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertFalse(res.timedOut)
        XCTAssertTrue(res.stdout.contains("parent-done"))
        XCTAssertLessThan(res.durationMs, 1500)
    }

    func testAtomicFilePermissionsBeforeRename() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mvatomic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let secret = temp.appendingPathComponent("token")
        try AtomicFile.write("secret-token", to: secret, permissions: 0o600)
        let attrs = try FileManager.default.attributesOfItem(atPath: secret.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)

        // When permissions is nil, overwriting preserves existing file mode (`FU-04`).
        try AtomicFile.write("secret-token-v2", to: secret, permissions: nil)
        let preservedAttrs = try FileManager.default.attributesOfItem(atPath: secret.path)
        let preservedMode = (preservedAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(preservedMode & 0o777, 0o600)
    }

    func testSubprocessCancellationAndProcessGroupKill() async {
        // Pre-cancelled Task must abort before/during launch and not block (`FU-04`).
        let canceledTask = Task { () -> SubprocessResult in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return await Subprocess.run(SubprocessSpec(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: 5
            ))
        }
        canceledTask.cancel()
        let canceled = await canceledTask.value
        XCTAssertFalse(canceled.succeeded)
        XCTAssertLessThan(canceled.durationMs, 1500)

        // Timed-out parent spawning a child process group must terminate promptly (`FU-04`).
        let groupTimedOut = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 10 & wait"],
            timeout: 0.25
        ))
        XCTAssertTrue(groupTimedOut.timedOut)
        XCTAssertLessThan(groupTimedOut.durationMs, 3000)
    }

    func testProjectPathsSymlinkContainment() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mvcore-\(UUID().uuidString)")
        let root = temp.appendingPathComponent("project")
        let outside = temp.appendingPathComponent("outside")
        defer { try? FileManager.default.removeItem(at: temp) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try AtomicFile.write("secret", to: secret)

        let insideFile = root.appendingPathComponent("docs/readme.md")
        try AtomicFile.write("# Readme", to: insideFile)
        XCTAssertTrue(ProjectPaths.contains(insideFile, root: root))
        XCTAssertEqual(ProjectPaths.relativePath(of: insideFile, under: root), "docs/readme.md")

        let escapeLink = root.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: secret)
        XCTAssertFalse(ProjectPaths.contains(escapeLink, root: root))
    }

    func testProjectCacheIdentifierUniqueness() {
        let a = URL(fileURLWithPath: "/Users/alice/work/app")
        let b = URL(fileURLWithPath: "/Users/bob/work/app")
        XCTAssertNotEqual(ProjectPaths.projectCacheIdentifier(for: a), ProjectPaths.projectCacheIdentifier(for: b))
    }

    func testWeakScriptMessageHandlerDoesNotRetainTarget() {
        final class DummyHandler: NSObject, WKScriptMessageHandler {
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
        }
        weak var weakTarget: DummyHandler?
        autoreleasepool {
            let target = DummyHandler()
            weakTarget = target
            let proxy = WeakScriptMessageHandler(target)
            _ = proxy.target
        }
        XCTAssertNil(weakTarget)
    }
}
