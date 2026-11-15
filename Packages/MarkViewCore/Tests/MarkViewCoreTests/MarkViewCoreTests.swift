import Foundation
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

    func testJSONLinesRotation() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mvjsonl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let log = JSONLinesFile(url: temp.appendingPathComponent("events.jsonl"), maxBytes: 1024)
        for i in 0..<60 {
            try log.appendLine("{\"seq\":\(i),\"msg\":\"\(String(repeating: "x", count: 30))\"}")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.url.appendingPathExtension("1").path))
        XCTAssertFalse(log.readLines().isEmpty)
    }

    func testSettingsRegistryDefaults() {
        let suiteName = "com.markview.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SettingsRegistry.int(SettingsRegistry.appFontScalePercent, in: defaults), 100)
        SettingsRegistry.set(130, for: SettingsRegistry.appFontScalePercent, in: defaults)
        XCTAssertEqual(SettingsRegistry.int(SettingsRegistry.appFontScalePercent, in: defaults), 130)
    }
}
