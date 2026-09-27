import AppKit

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print((condition ? "ok  " : "FAIL ") + name)
    if !condition { failures += 1 }
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("intake-paste-tests-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let board = NSPasteboard.withUniqueName()
defer { board.releaseGlobally() }
board.setString("ordinary text", forType: .string)
check("plain text stays with the editor", try IntakeClipboard.attachments(from: board, folder: folder) == nil)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let blue = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)
for x in 0..<32 { for y in 0..<32 { bitmap.setColor(blue, atX: x, y: y) } }
let png = bitmap.representation(using: .png, properties: [:])!
board.clearContents(); board.setData(png, forType: .png)
let first = try IntakeClipboard.attachments(from: board, folder: folder)!
let second = try IntakeClipboard.attachments(from: board, folder: folder)!
check("PNG clipboard becomes a readable image attachment", first.count == 1 && NSImage(contentsOf: first[0]) != nil)
check("repeated image paste never overwrites", first != second && FileManager.default.fileExists(atPath: first[0].path))
board.clearContents(); board.setData(bitmap.tiffRepresentation!, forType: .tiff)
let tiff = try IntakeClipboard.attachments(from: board, folder: folder)!
check("TIFF screenshot paste converts to PNG", tiff[0].pathExtension == "png" && NSImage(contentsOf: tiff[0]) != nil)
board.clearContents(); board.writeObjects([first[0] as NSURL])
check("Finder file paste attaches the file", try IntakeClipboard.attachments(from: board, folder: folder) == first)
board.clearContents(); board.setString("<p>text only</p>", forType: .html)
check("HTML without an image remains text paste", try IntakeClipboard.attachments(from: board, folder: folder) == nil)
do {
    board.clearContents(); board.setData(png, forType: .png)
    _ = try IntakeClipboard.attachments(from: board, folder: first[0])
    check("image write failure is reported", false)
} catch { check("image write failure is reported", true) }
// Also supply an image for native Preview → Copy → intake paste verification.
if CommandLine.arguments.count > 1 { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
if failures > 0 { exit(1) }
print("All intake clipboard checks passed")
