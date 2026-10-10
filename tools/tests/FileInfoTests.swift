import Foundation
import AppKit

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("file-info-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
func value(_ info: FileInfo, _ label: String) -> String? { info.rows.first { $0.label == label }?.value }

let text = dir.appendingPathComponent("note.md")
try "one two\nthree\n\nfour five six\n".write(to: text, atomically: true, encoding: .utf8)
let t = FileInfo.load(text)
check(value(t, "Name") == "note.md", "name")
check(value(t, "Lines") == "4" && value(t, "Words") == "6" && value(t, "Characters") == "29", "text counts: \(value(t, "Lines") ?? "-") \(value(t, "Words") ?? "-") \(value(t, "Characters") ?? "-")")
check(value(t, "Size")?.contains("29 bytes") == true || value(t, "Size") == "29 bytes", "size: \(value(t, "Size") ?? "-")")
check(value(t, "Modified") != nil && value(t, "Created") != nil && value(t, "Kind") != nil, "dates and kind are there")
check(value(t, "Path")?.hasSuffix("note.md") == true, "path")

let noNewline = dir.appendingPathComponent("a.txt")
try "a b".write(to: noNewline, atomically: true, encoding: .utf8)
check(value(FileInfo.load(noNewline), "Lines") == "1", "a last line without a newline counts")
let empty = dir.appendingPathComponent("empty.txt")
FileManager.default.createFile(atPath: empty.path, contents: Data())
check(value(FileInfo.load(empty), "Lines") == "0", "an empty file has no lines")

let binary = dir.appendingPathComponent("blob.bin")
try Data([1, 2, 0, 3]).write(to: binary)
check(value(FileInfo.load(binary), "Lines") == nil, "a binary file has no text counts")

let image = dir.appendingPathComponent("pic.png")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 7, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
try rep.representation(using: .png, properties: [:])!.write(to: image)
check(value(FileInfo.load(image), "Dimensions") == "12 × 7 px", "image dimensions: \(value(FileInfo.load(image), "Dimensions") ?? "-")")
check(value(FileInfo.load(image), "Lines") == nil, "an image has no text counts")

check(FileInfo.sizeString(512) == "512 bytes" || FileInfo.sizeString(512).hasSuffix("bytes"), "small size: \(FileInfo.sizeString(512))")
check(FileInfo.sizeString(12_603).contains("(12,603 bytes)"), "larger size shows the exact bytes: \(FileInfo.sizeString(12_603))")

print(failures == 0 ? "All file info checks passed." : "\(failures) file info check(s) failed.")
exit(failures == 0 ? 0 : 1)
