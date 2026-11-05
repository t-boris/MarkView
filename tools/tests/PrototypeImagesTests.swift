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

// Normalising to PNG, the pasteboard and the limits are checked in image-attachments-tests.sh; here is where Prototype Studio
// keeps the images it sends.
let png = ImageAttachments.pngData(from: makeImage(200, 100))!
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proto-img-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let saved = try PrototypeImages.save(png, in: tmp)
check(saved.deletingLastPathComponent().lastPathComponent == "attachments" && saved.pathExtension == "png", "saved under attachments/")
check(saved.deletingLastPathComponent().deletingLastPathComponent().path == tmp.path, "attachments/ is in the prototype's folder")
check((try Data(contentsOf: saved)) == png, "saved bytes are the PNG")
let other = try PrototypeImages.save(png, in: tmp)
check(other != saved, "every image is a new file")

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
