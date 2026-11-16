import Foundation
import XCTest
@testable import MarkViewCore

final class CoreInfrastructureTests: XCTestCase {
    func testSubprocessOutputLimitsTimeoutAndCancellation() async {
        let echo = await Subprocess.run(SubprocessSpec(executable: "/bin/echo", arguments: ["phase2-ok"]))
        XCTAssertTrue(echo.succeeded)
        XCTAssertEqual(echo.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "phase2-ok")

        let capped = await Subprocess.run(SubprocessSpec(executable: "/bin/sh",
            arguments: ["-c", "yes 0123456789abcdef | head -n 400"], timeout: 5, maxOutputBytes: 1024))
        XCTAssertTrue(capped.truncated)
        XCTAssertLessThanOrEqual(capped.stdout.utf8.count, 1024)

        let timedOut = await Subprocess.run(SubprocessSpec(executable: "/usr/bin/python3",
            arguments: ["-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(10)"], timeout: 0.2))
        XCTAssertTrue(timedOut.timedOut)

        let task = Task {
            try? await Task.sleep(nanoseconds: 15_000_000)
            return await Subprocess.run(SubprocessSpec(executable: "/bin/sleep", arguments: ["5"], timeout: 5))
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertFalse(cancelled.succeeded)
        XCTAssertLessThan(cancelled.durationMs, 1500)
    }

    func testPathsAtomicPermissionsAndExecutableSearch() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mv-core-\(UUID().uuidString)")
        let root = temp.appendingPathComponent("workspace")
        let outside = temp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let secret = outside.appendingPathComponent("secret.md")
        try AtomicFile.write("top secret", to: secret, permissions: 0o600)
        let document = root.appendingPathComponent("docs/guide.md")
        try AtomicFile.write("# Guide", to: document)
        XCTAssertTrue(ProjectPaths.contains(document, root: root))
        XCTAssertEqual(ProjectPaths.relativePath(of: document, under: root), "docs/guide.md")
        let escape = root.appendingPathComponent("docs/escape.md")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: secret)
        XCTAssertFalse(ProjectPaths.contains(escape, root: root))
        let idA = ProjectPaths.projectCacheIdentifier(for: URL(fileURLWithPath: "/Users/alice/app"))
        let idB = ProjectPaths.projectCacheIdentifier(for: URL(fileURLWithPath: "/Users/bob/app"))
        XCTAssertNotEqual(idA, idB)
        XCTAssertTrue(idA.hasPrefix("app-"))

        let permissionFile = temp.appendingPathComponent("perm.secret")
        try AtomicFile.write("secret-v1", to: permissionFile, permissions: 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: permissionFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try AtomicFile.write("secret-v2", to: permissionFile, permissions: nil)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: permissionFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let extraBin = temp.appendingPathComponent("extra-bin")
        try FileManager.default.createDirectory(at: extraBin, withIntermediateDirectories: true)
        let executable = extraBin.appendingPathComponent("mv-phase2-probe")
        try AtomicFile.write("#!/bin/sh\necho extra-path-ok\n", to: executable, permissions: 0o755)
        let suite = "com.markview.phase2.extrapath.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Settings(defaults).set(extraBin.path, for: Setting.extraPATH)
        let dirs = Subprocess.configuredExtraPATHDirectories(defaults: defaults)
        XCTAssertEqual(Subprocess.resolveExecutable("mv-phase2-probe", searchPaths: Subprocess.effectiveSearchPaths(extra: dirs)), executable.path)
    }
}
