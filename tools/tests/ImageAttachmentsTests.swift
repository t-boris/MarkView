import AppKit

var failures = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : " " + detail()))
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
/// An image of random pixels: its PNG is about as large as the raw pixels, so a big one is over the size limit.
func noise(_ side: Int) -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    var generator = SystemRandomNumberGenerator()
    for offset in 0..<(rep.bytesPerRow * side) { rep.bitmapData![offset] = UInt8.random(in: 0...255, using: &generator) }
    let image = NSImage(size: NSSize(width: side, height: side))
    image.addRepresentation(rep)
    return image
}
func size(of png: Data) -> (Int, Int)? {
    guard let rep = NSBitmapImageRep(data: png) else { return nil }
    return (rep.pixelsWide, rep.pixelsHigh)
}
func isPNG(_ data: Data) -> Bool { data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) }
func isEightHex(_ name: String) -> Bool {
    let stem = name.dropLast(4)
    return name.hasSuffix(".png") && stem.count == 8 && stem.allSatisfy { "0123456789abcdef".contains($0) }
}

// Normalisation: PNG out, small images keep their size, large ones shrink to the longer side.
let small = ImageAttachments.pngData(from: makeImage(200, 100))
check(small.map(isPNG) == true, "converts to PNG")
check(small.flatMap(size) ?? (0, 0) == (200, 100), "small image keeps its size")
let big = ImageAttachments.pngData(from: makeImage(4000, 1000))
check(big.flatMap(size) ?? (0, 0) == (1600, 400), "large image shrinks to 1600 on the long side")
check(ImageAttachments.pngData(from: NSImage(size: .zero)) == nil, "empty image gives nothing")
check(ImageAttachments.maxCount == 6 && ImageAttachments.maxBytes == 8 * 1_048_576 && ImageAttachments.maxSide == 1600, "the limits")

// Pasteboard: an image, an image file, and text only.
let board = NSPasteboard(name: NSPasteboard.Name("markview.attachments.test.\(UUID().uuidString)"))
board.clearContents()
board.writeObjects([makeImage(120, 80)])
check(ImageAttachments.images(on: board).count == 1, "reads an image from the pasteboard")

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("image-attachments-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let file = tmp.appendingPathComponent("shot.png")
try small!.write(to: file)
board.clearContents()
board.writeObjects([file as NSURL])
let fromFile = ImageAttachments.images(on: board)
check(fromFile.count == 1 && fromFile.first.flatMap(size) ?? (0, 0) == (200, 100), "reads an image file copied in Finder")

let text = tmp.appendingPathComponent("note.txt")
try "hello".write(to: text, atomically: true, encoding: .utf8)
board.clearContents()
board.writeObjects([text as NSURL])
check(ImageAttachments.images(on: board).isEmpty, "a copied text file is not an image")
board.clearContents()
board.setString("just text", forType: .string)
check(ImageAttachments.images(on: board).isEmpty, "plain text gives no image, so the paste goes on as text")
check(ImageAttachments.image(at: file) != nil, "an image file can be chosen")
check(ImageAttachments.image(at: text) == nil, "a text file cannot")

// File naming: <8 hex digits>.png in the folder given, made when missing; every file is new.
let folder = tmp.appendingPathComponent("a/b/attachments")
let first = try ImageAttachments.save(small!, into: folder)
let second = try ImageAttachments.save(small!, into: folder)
check(first.deletingLastPathComponent().path == folder.path && isEightHex(first.lastPathComponent), "saved as <8 hex digits>.png in the folder",
      first.path)
let firstBytes = try Data(contentsOf: first), secondBytes = try Data(contentsOf: second)
check(first != second && firstBytes == small! && secondBytes == small!, "every save is a new file with the PNG bytes")
check(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count == 2, "nothing else is written")

// The list: images are added up to the count, a refusal is named.
var list = ImageAttachmentList()
check(list.isEmpty && list.notice == nil, "a new list is empty")
list.add([small!, small!, small!])
check(list.items.count == 3 && list.notice == nil, "images within the limits are added without a notice")
list.add([small!, small!, small!, small!, small!])
check(list.items.count == 6, "no more than six images are kept", "\(list.items.count)")
check(list.notice == "A request takes at most 6 images; 2 not added.", "the refusal by count is named", list.notice ?? "nil")
list.add([small!])
check(list.items.count == 6 && list.notice == "A request takes at most 6 images; 1 not added.", "a seventh image is refused with a notice", list.notice ?? "nil")
let removed = list.items[0].id
list.remove(removed)
check(list.items.count == 5 && !list.items.contains { $0.id == removed } && list.notice == nil, "an image can be removed, which clears the notice")
list.add([small!])
check(list.items.count == 6 && list.notice == nil, "a removed place can be taken again")
list.removeAll()
check(list.isEmpty && list.notice == nil, "removeAll empties the list")

// Size: a PNG over 8 MB after the 1600 px downscale is refused, with a notice; a smaller one is not.
let heavy = ImageAttachments.pngData(from: noise(2400))
check((heavy.flatMap(size) ?? (0, 0)) == (1600, 1600) && (heavy?.count ?? 0) > ImageAttachments.maxBytes, "a noisy screenshot is over 8 MB after the downscale",
      "\(heavy?.count ?? 0)")
list.add([heavy!])
check(list.isEmpty && list.notice == "An image is over 8 MB and not added.", "an image over 8 MB is refused with a notice", list.notice ?? "nil")
list.add([heavy!, Data(count: ImageAttachments.maxBytes + 1), small!])
check(list.items.count == 1 && list.notice == "2 images are over 8 MB and not added.",
      "the images that fit are kept next to the refused ones", list.notice ?? "nil")
list.add([Data("not an image".utf8)])
check(list.items.count == 1 && list.notice == "An image could not be read.", "data that is no image is named, not dropped silently", list.notice ?? "nil")
list.add([heavy!, small!, Data("x".utf8)])
check(list.items.count == 2 && list.notice == "An image is over 8 MB and not added. An image could not be read.", "several refusals share one line",
      list.notice ?? "nil")
list.removeAll()

// The pasteboard into the list: true when there were images (also when all were refused), false for text.
board.clearContents()
board.writeObjects([makeImage(90, 60)])
check(list.addFromPasteboard(board) && list.items.count == 1, "an image on the clipboard is taken")
board.clearContents()
board.setString("just text", forType: .string)
check(!list.addFromPasteboard(board) && list.items.count == 1 && list.notice == nil, "text on the clipboard is not taken")
for _ in 0..<5 { list.add([small!]) }
board.clearContents()
board.writeObjects([makeImage(90, 60)])
check(list.items.count == 6 && list.addFromPasteboard(board) && list.items.count == 6 && list.notice != nil,
      "a full list still takes the paste as an image: it is refused with a notice, not pasted as text")

// A paste of text goes in at the caret, in place of the selection, and the text view's delegate hears of it.
final class Listener: NSObject, NSTextViewDelegate {
    var changes = 0
    func textDidChange(_ notification: Notification) { changes += 1 }
}
let listener = Listener()
func textView(_ string: String) -> NSTextView {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    view.isEditable = true
    view.delegate = listener
    view.string = string
    return view
}
let middle = textView("Hello world")
middle.setSelectedRange(NSRange(location: 5, length: 0))
ImageAttachments.insertAtCaret(", dear", in: middle)
check(middle.string == "Hello, dear world", "text is inserted at the caret, not at the end", middle.string)
check(middle.selectedRange() == NSRange(location: 11, length: 0), "the caret ends after the inserted text", "\(middle.selectedRange())")
check(listener.changes == 1, "the text view's delegate is told, so a binding follows", "\(listener.changes)")
let replaced = textView("Hello world")
replaced.setSelectedRange(NSRange(location: 6, length: 5))
ImageAttachments.insertAtCaret("there", in: replaced)
check(replaced.string == "Hello there", "the selection is replaced", replaced.string)
let start = textView("world")
start.setSelectedRange(NSRange(location: 0, length: 0))
ImageAttachments.insertAtCaret("Hello ", in: start)
check(start.string == "Hello world", "a paste at the start goes before the text", start.string)

// Without a focused text view the text is appended to the draft; an empty clipboard pastes nothing.
var appended: [String] = []
board.clearContents()
board.setString("tail", forType: .string)
ImageAttachments.pasteText(from: board) { appended.append($0) }
check(appended == ["tail"], "with no text view in focus the text is appended", "\(appended)")
board.clearContents()
ImageAttachments.pasteText(from: board) { appended.append($0) }
check(appended == ["tail"], "an empty clipboard pastes nothing", "\(appended)")

// Dropped items: a file of the Finder, a picture dragged from an app, other files, and text.
final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var pngs: [Data] = []
    func add(_ data: Data) { lock.withLock { pngs.append(data) } }
    var all: [Data] { lock.withLock { pngs } }
}
func drop(_ providers: [NSItemProvider], expecting count: Int) -> (accepted: Bool, images: [Data]) {
    let delivered = Delivered()
    let accepted = ImageAttachments.load(from: providers) { delivered.add($0) }
    let deadline = Date().addingTimeInterval(count == 0 ? 1 : 5)
    while Date() < deadline, delivered.all.count < count { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    return (accepted, delivered.all)
}
let droppedFile = drop([NSItemProvider(object: file as NSURL)], expecting: 1)
check(droppedFile.accepted && droppedFile.images.count == 1 && droppedFile.images.first.flatMap(size) ?? (0, 0) == (200, 100), "a dropped image file is read")
let droppedPicture = drop([NSItemProvider(object: makeImage(64, 48))], expecting: 1)
check(droppedPicture.accepted && droppedPicture.images.count == 1 && droppedPicture.images.first.flatMap(size) ?? (0, 0) == (64, 48), "a dropped picture is read")
let droppedText = drop([NSItemProvider(object: text as NSURL)], expecting: 0)
check(droppedText.images.isEmpty, "a dropped text file gives no image")
check(!ImageAttachments.load(from: [NSItemProvider(object: "just words" as NSString)]) { _ in }, "dropped text is refused")

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
