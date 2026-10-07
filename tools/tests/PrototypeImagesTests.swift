import AppKit

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}
func makeImage(_ width: Int, _ height: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    return image
}
func size(of png: Data) -> (Int, Int)? {
    guard let rep = NSBitmapImageRep(data: png) else { return nil }
    return (rep.pixelsWide, rep.pixelsHigh)
}
func isPNG(_ data: Data) -> Bool { data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) }

// Conversion: PNG out, small images keep their size, large ones shrink to the longer side.
let small = PrototypeImages.pngData(from: makeImage(200, 100))
check(small.map(isPNG) == true, "converts to PNG")
check(small.flatMap(size) ?? (0, 0) == (200, 100), "small image keeps its size")
let big = PrototypeImages.pngData(from: makeImage(4000, 1000))
check(big.flatMap(size) ?? (0, 0) == (1600, 400), "large image shrinks to 1600 on the long side")
check(PrototypeImages.pngData(from: NSImage(size: .zero)) == nil, "empty image gives nothing")

// Pasteboard: an image, an image file, and text only.
let board = NSPasteboard(name: NSPasteboard.Name("markview.prototype.test.\(UUID().uuidString)"))
board.clearContents()
board.writeObjects([makeImage(120, 80)])
check(PrototypeImages.images(on: board).count == 1, "reads an image from the pasteboard")

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proto-img-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let file = tmp.appendingPathComponent("shot.png")
try small!.write(to: file)
board.clearContents()
board.writeObjects([file as NSURL])
let fromFile = PrototypeImages.images(on: board)
check(fromFile.count == 1 && fromFile.first.flatMap(size) ?? (0, 0) == (200, 100), "reads an image file copied in Finder")

let text = tmp.appendingPathComponent("note.txt")
try "hello".write(to: text, atomically: true, encoding: .utf8)
board.clearContents()
board.writeObjects([text as NSURL])
check(PrototypeImages.images(on: board).isEmpty, "a copied text file is not an image")
board.clearContents()
board.setString("just text", forType: .string)
check(PrototypeImages.images(on: board).isEmpty, "plain text gives no image, so the paste goes on as text")

// Saving and choosing a file.
let saved = try PrototypeImages.save(small!, in: tmp)
check(saved.deletingLastPathComponent().lastPathComponent == "attachments" && saved.pathExtension == "png", "saved under attachments/")
check((try Data(contentsOf: saved)) == small!, "saved bytes are the PNG")
check(PrototypeImages.image(at: file) != nil, "an image file can be chosen")
check(PrototypeImages.image(at: text) == nil, "a text file cannot")

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
