// Checks the workspace window title (MarkView/Models/WindowTitle.swift) against REQ-001, REQ-003,
// DEC-005 and DEC-006.
import Foundation

var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want { print("ok  \(name)") } else { failures += 1; print("FAIL \(name): got \(got.debugDescription) want \(want.debugDescription)") }
}

check("folder open", WindowTitle.text(version: "1.4", folderName: "my-project"), "MarkView 1.4 — my-project")
check("no folder", WindowTitle.text(version: "1.4", folderName: nil), "MarkView 1.4")
check("empty folder name", WindowTitle.text(version: "1.4", folderName: ""), "MarkView 1.4")
check("empty version, folder", WindowTitle.text(version: "", folderName: "foo"), "MarkView — foo")
check("empty version, no folder", WindowTitle.text(version: "", folderName: nil), "MarkView")

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)/my-project", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
let name = WindowTitle.folderName(of: dir)
check("display name of a folder", name, "my-project")
let title = WindowTitle.text(version: "1.4", folderName: name)
check("full path never in the title", String(title.contains(dir.path) || title.contains("/")), "false")
let volume = WindowTitle.folderName(of: URL(fileURLWithPath: "/"))
check("root volume has a name, not '/'", String(!volume.isEmpty && volume != "/"), "true")
check("missing folder falls back to last component", WindowTitle.folderName(of: URL(fileURLWithPath: "/no/such/place-xyz")), "place-xyz")

print(failures == 0 ? "All window title checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
