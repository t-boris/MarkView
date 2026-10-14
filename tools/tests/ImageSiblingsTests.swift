import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) { if !ok { failures += 1; print("FAIL: \(name)") } }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("siblings-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
for name in ["10.png", "2.png", "1.png", "notes.txt", ".hidden.png"] {
    FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
}
let list = ImageSiblings.list(in: dir) { $0.pathExtension == "png" }
check(list.map(\.lastPathComponent) == ["1.png", "2.png", "10.png"], "Finder order, no hidden or non-images")

let first = list[0], last = list[2]
check(ImageSiblings.neighbour(of: first, in: list, step: 1, wrap: false)?.lastPathComponent == "2.png", "next")
check(ImageSiblings.neighbour(of: first, in: list, step: -1, wrap: false) == nil, "nothing before the first")
check(ImageSiblings.neighbour(of: last, in: list, step: 1, wrap: false) == nil, "nothing after the last")
check(ImageSiblings.neighbour(of: last, in: list, step: 1, wrap: true)?.lastPathComponent == "1.png", "wraps to the first")
check(ImageSiblings.neighbour(of: first, in: list, step: -1, wrap: true)?.lastPathComponent == "10.png", "wraps to the last")
check(ImageSiblings.neighbour(of: first, in: [first], step: 1, wrap: true) == nil, "a lone image has no neighbour")
check(ImageSiblings.position(of: list[1], in: list) == "2 / 3", "position")
check(ImageSiblings.position(of: first, in: [first]) == nil, "no position for a lone image")

if failures == 0 { print("image siblings: all checks passed") } else { exit(1) }
