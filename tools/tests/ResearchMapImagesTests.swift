// Checks MarkView/Models/ResearchMapImages.swift (REQ-017, DEC-018): the kind of a picture is read from its bytes, the
// size is limited, and a picture is stored under a safe unique name next to the map file.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
}
typealias I = ResearchMapImages

let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 40))
let png2 = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 9, count: 40))
let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 1, count: 30))
let gif = Data("GIF89a".utf8 + Array(repeating: 2, count: 30))
let webp = Data("RIFF".utf8 + [0, 0, 0, 0] + "WEBP".utf8 + Array(repeating: 3, count: 20))
let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>".utf8)
let html = Data("<html><body>hi</body></html>".utf8)

check("PNG by its bytes", I.fileExtension(of: png) == "png")
check("JPEG by its bytes", I.fileExtension(of: jpeg) == "jpg")
check("GIF by its bytes", I.fileExtension(of: gif) == "gif")
check("WebP by its bytes", I.fileExtension(of: webp) == "webp")
check("SVG is refused (it can carry scripts)", I.fileExtension(of: svg) == nil)
check("HTML is refused", I.fileExtension(of: html) == nil)
check("an empty or tiny file is refused", I.fileExtension(of: Data()) == nil && I.fileExtension(of: Data([0x89])) == nil)

check("a name is cut to a safe base", I.safeBase("My Screen Shot (1).PNG") == "My-Screen-Shot-1")
check("a path in the name is dropped", I.safeBase("../../etc/passwd.png") == "passwd" && I.safeBase("C:\\Users\\a\\pic.jpg") == "pic")
check("a name with nothing usable becomes image", I.safeBase("???.png") == "image" && I.safeBase("") == "image" && I.safeBase("...") == "image")
check("a long name is cut", I.safeBase(String(repeating: "a", count: 200) + ".png").count == 48)
check("non-ASCII letters do not reach the file system", I.safeBase("снимок экрана.png") == "image")

check("a good picture decodes", { if case .success(let data) = I.decode(base64: png.base64EncodedString()) { return data == png } else { return false } }())
check("text that is not Base64 is refused", { if case .failure(let f) = I.decode(base64: "%%% not base64 %%%") { return f.message == "The picture could not be read." } else { return false } }())
check("other file types are refused", { if case .failure(let f) = I.decode(base64: svg.base64EncodedString()) { return f.message == "Use a PNG, JPEG, GIF or WebP picture." } else { return false } }())
check("an oversized picture is refused", { if case .failure(let f) = I.decode(base64: (png + Data(repeating: 0, count: I.sizeLimit)).base64EncodedString()) { return f.message == "The picture is larger than 6 MB." } else { return false } }())
check("an empty picture is refused", { if case .failure = I.decode(base64: "") { return true } else { return false } }())

let root = FileManager.default.temporaryDirectory.appendingPathComponent("markview-images-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let map = root.appendingPathComponent("docs/research/map.md")
try! FileManager.default.createDirectory(at: map.deletingLastPathComponent(), withIntermediateDirectories: true)
func stored(_ data: Data, _ name: String) -> String {
    if case .success(let path) = I.store(base64: data.base64EncodedString(), suggestedName: name, besideMap: map) { return path }
    return "FAILED"
}
let first = stored(png, "Screen Shot.PNG")
check("a picture is stored in images/ beside the map", first == "images/Screen-Shot.png" && FileManager.default.fileExists(atPath: map.deletingLastPathComponent().appendingPathComponent(first).path), first)
check("the stored bytes are the picture", (try? Data(contentsOf: map.deletingLastPathComponent().appendingPathComponent(first))) == png)
check("the same picture under the same name is reused", stored(png, "Screen Shot.PNG") == first)
let second = stored(png2, "Screen Shot.png")
check("a different picture with the same name gets a number", second == "images/Screen-Shot-2.png", second)
check("…and the first is not overwritten", (try? Data(contentsOf: map.deletingLastPathComponent().appendingPathComponent(first))) == png)
check("the kind comes from the bytes, not from the name", stored(jpeg, "photo.png") == "images/photo.jpg")
check("a hostile name stays inside images/", stored(gif, "../../../outside.gif") == "images/outside.gif" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.gif").path))
check("nothing was written outside images/", { let files = (try? FileManager.default.contentsOfDirectory(atPath: map.deletingLastPathComponent().path)) ?? []; return files == ["images"] }())
check("a refused picture writes nothing", { if case .failure = I.store(base64: svg.base64EncodedString(), suggestedName: "x.svg", besideMap: map) { return !FileManager.default.fileExists(atPath: map.deletingLastPathComponent().appendingPathComponent("images/x.svg").path) } else { return false } }())

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("all ok")
