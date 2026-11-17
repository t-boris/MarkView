import Foundation
import XCTest
@testable import MarkViewCore

final class LoginScriptTests: XCTestCase {
    func testWritesExecutableScriptsAtomically() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("login-script-\(UUID().uuidString)", isDirectory: true)
        let folder = scratch.appendingPathComponent("MarkView", isDirectory: true)
        defer { chmod(folder.path, 0o755); try? FileManager.default.removeItem(at: scratch) }
        func mode(_ url: URL) throws -> Int {
            try XCTUnwrap((FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue)
        }

        XCTAssertEqual(LoginScript.folder.path, NSHomeDirectory() + "/Library/Application Support/MarkView")
        let first = "#!/bin/zsh\necho \"Signing in to Claude…\"\n\"/usr/local/bin/claude\" login\n"
        let script = try LoginScript.write(named: "claude", body: first, in: folder)
        XCTAssertEqual(script.lastPathComponent, "login-claude.command")
        XCTAssertEqual(script.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), first)
        XCTAssertEqual(try mode(script), 0o755)
        XCTAssertEqual(access(script.path, X_OK), 0)

        let echo = try LoginScript.write(named: "echo", body: "#!/bin/sh\necho signed-in\n", in: folder)
        let result = await Subprocess.run(SubprocessSpec(executable: echo.path))
        XCTAssertEqual(result.stdout, "signed-in\n")
        XCTAssertEqual(result.exitCode, 0)

        chmod(script.path, 0o644)
        let second = "#!/bin/zsh\nexport GH_CONFIG_DIR=\"/tmp/profile\"\ngh auth login\n"
        _ = try LoginScript.write(named: "claude", body: second, in: folder)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), second)
        XCTAssertEqual(try mode(script), 0o755)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["login-claude.command", "login-echo.command"])

        chmod(folder.path, 0o555)
        XCTAssertThrowsError(try LoginScript.write(named: "claude", body: "#!/bin/zsh\necho replacement\n", in: folder))
        chmod(folder.path, 0o755)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), second)
        XCTAssertEqual(try mode(script), 0o755)
    }
}
