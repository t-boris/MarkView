import Foundation

// ProjectSearch.swift names these two; the real ones pull in half the app.
struct LinkedFolder { let name: String; let url: URL }
enum LinkedFolders { static let documentIdPrefix = "@linked/" }

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-search-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
func write(_ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}
try write("docs/readme.md", "# Title\nneedle in markdown\n")
try write("src/app.swift", "func run() { print(\"needle in swift\") }\n")
try write("web/Widget.vue", "<template><p>needle in vue</p></template>\n")        // not on the old extension list
try write("infra/main.tf", "resource \"x\" \"needle_in_terraform\" {}\n")           // not on the old list
try write("Procfile", "web: needle_in_procfile\n")                                  // no extension
try write("node_modules/pkg/index.js", "needle in node_modules\n")                  // excluded directory
try write(".env", "SECRET=needle_secret\n")                                          // excluded file
try Data([0x4e, 0x45, 0x00, 0x44, 0x4c, 0x45]).write(to: root.appendingPathComponent("blob.dat"))   // binary with NUL, no known extension
try Data("needle".utf8).write(to: root.appendingPathComponent("picture.png"))        // text bytes but a binary extension

// An archive with entries.
try write("pack/inside/deep note.txt", "needle inside the zip\n")
try write("pack/inside/diagram.drawio", "x\n")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
p.arguments = ["-rq", "bundle.zip", "pack"]
p.currentDirectoryURL = root
try p.run(); p.waitUntilExit()
try FileManager.default.removeItem(at: root.appendingPathComponent("pack"))

let index = ProjectSearchIndex()
try await index.rebuild(roots: [.project(root)]) { _ in }
let hits = await index.search("needle")
let content = hits.filter { $0.scope == .content }
let titles = Set(content.map(\.title))
check(titles.contains("readme.md") && titles.contains("app.swift"), "markdown and swift are found")
check(titles.contains("Widget.vue") && titles.contains("main.tf") && titles.contains("Procfile"), "text files of any extension are found: \(titles.sorted())")
check(!titles.contains("index.js") && !titles.contains(".env"), "excluded directories and files stay out")
check(!titles.contains("blob.dat") && !titles.contains("picture.png"), "binary files are not read")
check(content.first { $0.title == "app.swift" }?.line == 1, "a content hit carries its line")

let names = await index.search("deep note")
check(names.contains { $0.scope == .file && $0.path == "bundle.zip!/pack/inside/deep note.txt" }, "a file inside a zip is found by name: \(names.map { $0.path ?? "" })")
let files = await index.search("diagram")
check(files.contains { $0.scope == .file && ($0.path ?? "").hasSuffix("!/pack/inside/diagram.drawio") }, "another entry of the zip")
check(!(await index.search("inside the zip")).contains { $0.scope == .content }, "the text inside a zip is not searched")
check((await index.search("blob")).contains { $0.scope == .file && $0.path == "blob.dat" }, "a binary file is still found by name")
check(ProjectSearchIndex.text(of: root.appendingPathComponent("Procfile"), known: false) != nil && ProjectSearchIndex.text(of: root.appendingPathComponent("blob.dat"), known: false) == nil, "text sniffing")

print(failures == 0 ? "All project search checks passed." : "\(failures) project search check(s) failed.")
exit(failures == 0 ? 0 : 1)
