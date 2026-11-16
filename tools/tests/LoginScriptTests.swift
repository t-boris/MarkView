import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}
func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("login-script-\(UUID().uuidString)", isDirectory: true)
defer { chmod(scratch.path, 0o755); try? FileManager.default.removeItem(at: scratch) }
let folder = scratch.appendingPathComponent("MarkView", isDirectory: true)

// Where the scripts live when the caller names no folder: in the person's Application Support, under the (scratch) home.
check(LoginScript.folder.path == NSHomeDirectory() + "/Library/Application Support/MarkView" && NSHomeDirectory().hasSuffix("/home"),
      "the scripts go to Application Support/MarkView of the home folder")

// A first script: the folder is made, the file is whole, named by its tool and executable.
let first = "#!/bin/zsh\necho \"Signing in to Claude…\"\n\"/usr/local/bin/claude\" login\n"
let script = try LoginScript.write(named: "claude", body: first, in: folder)
check(script.lastPathComponent == "login-claude.command" && script.deletingLastPathComponent().path == folder.path, "the file is login-<name>.command in the folder")
check(text(script) == first, "the script holds exactly the body")
check(mode(script) == 0o755 && access(script.path, X_OK) == 0, "it is executable as written")

// The script runs: what Terminal does with it.
let echoOnly = try LoginScript.write(named: "echo", body: "#!/bin/sh\necho signed-in\n", in: folder)
let run = Process()
run.executableURL = echoOnly
let pipe = Pipe()
run.standardOutput = pipe
run.standardError = Pipe()
try run.run()
run.waitUntilExit()
check(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "signed-in\n" && run.terminationStatus == 0, "the saved script runs")

// A second sign-in replaces the script whole, even when the old file lost its mode.
chmod(script.path, 0o644)
let second = "#!/bin/zsh\nexport GH_CONFIG_DIR=\"/tmp/profile\"\ngh auth login\n"
_ = try LoginScript.write(named: "claude", body: second, in: folder)
check(text(script) == second && mode(script) == 0o755, "a new script replaces the old one whole and is executable again")
check(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() == ["login-claude.command", "login-echo.command"],
      "nothing but the scripts is left in the folder")

// A folder that refuses the file: the error is reported, and the script that was there stays as it was.
chmod(folder.path, 0o555)
var refused = false
do { _ = try LoginScript.write(named: "claude", body: "#!/bin/zsh\nrm -rf ~\n", in: folder) } catch { refused = true }
chmod(folder.path, 0o755)
check(refused, "a folder that refuses the script fails the write")
check(text(script) == second && mode(script) == 0o755, "and the old script keeps its bytes and its mode")

if failures > 0 { exit(1) }
print("All login script checks passed")
