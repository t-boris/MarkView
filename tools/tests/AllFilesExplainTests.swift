// Compiled with the production FileType, FileNode and FileExplanationPrompt by the shell harness.
var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("ok   \(label)") } else { failures += 1; print("FAIL \(label)") }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
func file(_ name: String) -> URL { root.appendingPathComponent(name) }
func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: file(name)) }
for name in [".env", ".env.local", ".custom", "settings.mystery", "NO_EXTENSION", "notes.txt", ".gitignore"] {
    try write(name, "SERVICE_PORT=8080\n")
    check(FileType.isOpenable(file(name)), "\(name) can open")
    check(FileType.from(url: file(name)) == .code, "\(name) uses text/code instead of Markdown")
}
check(FileType.codeLanguage(for: file(".env.local")) == "properties", "environment variants have known highlighting")
check(FileType.codeLanguage(for: file(".custom")) == nil, "unknown dotfiles have no guessed highlighting")
check(FileType.sourceLanguage(for: file("settings.mystery")) == "", "unknown extensions stay plain text")
check(FileType.sourceLanguage(for: file("NO_EXTENSION")) == "", "unknown extensionless names stay plain text")
check(FileType.sourceLanguage(for: file("main.swift")) == "swift", "known source retains highlighting")
for (name, language) in [("config.yaml", "yaml"), ("config.json", "json"), ("config.xml", "xml"), ("README.md", "markdown"), ("board.canvas", "json")] {
    check(FileType.sourceLanguage(for: file(name)) == language, "\(name) has highlighted Explain source")
    check(FileType.from(url: file(name)) != .code, "\(name) retains its dedicated viewer")
}
try fm.createDirectory(at: file(".private"), withIntermediateDirectories: true)
try fm.createDirectory(at: file(".git"), withIntermediateDirectories: true)
try write(".private/hidden.unknown", "hidden text")
try fm.createSymbolicLink(at: file("linked.unknown"), withDestinationURL: file("notes.txt"))
let node = FileNode.buildTree(from: root)
let names = Set((node.children ?? []).map(\.name))
check(names.contains(".env") && names.contains(".env.local") && names.contains("settings.mystery"), "tree includes hidden and unknown files")
check(names.contains(".private") && names.contains(".git") && names.contains("linked.unknown"), "tree includes hidden folders and file symlinks")
let hidden = node.children!.first { $0.name == ".private" }!
hidden.loadChildren()
check(hidden.children?.first?.name == "hidden.unknown", "hidden folders can be browsed")
check(try FileType.readText(at: file("linked.unknown")) == "SERVICE_PORT=8080\n", "file symlinks decode their target")
for encoding in [String.Encoding.utf8, .utf16, .utf32] {
    try "port: 8080\r\nname: café 🌱\n".data(using: encoding)!.write(to: file("unicode"))
    check(try FileType.readText(at: file("unicode")) == "port: 8080\r\nname: café 🌱\n", "Unicode \(encoding.rawValue) decoded without changing lines")
}
try Data([0xEF, 0xBB, 0xBF] + Array("plain".utf8)).write(to: file("bom"))
check(try FileType.readText(at: file("bom")) == "plain", "UTF-8 BOM is removed")
try Data([0, 1, 2, 0xFF]).write(to: file("binary.unknown"))
check(FileType.isOpenable(file("binary.unknown")), "binary files remain visible")
do { _ = try FileType.readText(at: file("binary.unknown")); check(false, "binary bytes rejected") }
catch FileType.TextReadError.binary { print("ok   binary bytes rejected") }
try Data().write(to: file("empty"))
check(try FileType.readText(at: file("empty")) == "", "empty files open as text")
let large = file("large")
fm.createFile(atPath: large.path, contents: nil)
let handle = try FileHandle(forWritingTo: large)
try handle.truncate(atOffset: 33 * 1024 * 1024)
try handle.close()
do { _ = try FileType.readText(at: large); check(false, "oversized generic text is bounded") }
catch FileType.TextReadError.tooLarge { print("ok   oversized generic text is bounded") }
for name in ["config.yaml", "config.json", "config.xml", ".env.local", "settings.toml"] {
    let prompt = FileExplanationPrompt.instructions(path: name)
    check(prompt.contains("what it is responsible for") && prompt.contains("effect of changing") && prompt.contains("without repeating their values"), "\(name) explains configuration responsibilities without echoing secrets")
}
check(FileExplanationPrompt.instructions(path: "unusual.xyz").contains("actual contents"), "unknown text explanation follows contents")
check(FileExplanationPrompt.instructions(path: "README.md").contains("documentation file"), "Markdown keeps document explanation")
check(FileExplanationPrompt.instructions(path: "main.swift").contains("source code"), "source keeps code explanation")
check(FileType.hasTextSource(file("data.csv")) && FileType.hasTextSource(file("app.log")), "text data has Explain source")
check(!FileType.hasTextSource(file("data.parquet")) && !FileType.hasTextSource(file("book.xlsx")), "binary data is never sent as text")
print(failures == 0 ? "All file/Explain checks passed." : "\(failures) checks failed.")
exit(failures == 0 ? 0 : 1)
