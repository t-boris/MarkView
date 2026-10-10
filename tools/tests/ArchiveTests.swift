import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}
func sh(_ command: String, in dir: URL) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", command]
    p.currentDirectoryURL = dir
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("archive-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

// Names and kinds.
check(Archive.isArchive(URL(fileURLWithPath: "/x/a.ZIP")) && Archive.isArchive(URL(fileURLWithPath: "/x/a.tar.gz")) && Archive.isArchive(URL(fileURLWithPath: "/x/a.tgz")), "archive extensions, also compound ones")
check(!Archive.isArchive(URL(fileURLWithPath: "/x/a.md")) && !Archive.isArchive(URL(fileURLWithPath: "/x/a.gz")), "other files are not archives")
check(Archive.baseName(URL(fileURLWithPath: "/x/photos.tar.gz")) == "photos" && Archive.baseName(URL(fileURLWithPath: "/x/a.b.zip")) == "a.b", "base name drops the archive extension")
check(Archive.isSafe("a/b.txt") && !Archive.isSafe("../x") && !Archive.isSafe("a/../../x") && !Archive.isSafe("/etc/passwd") && !Archive.isSafe(""), "safe and unsafe paths")
check(Archive.escaped("a[1]*.txt") == "a\\[1\\]\\*.txt", "glob characters in member names are escaped")

// A source tree with awkward names.
let src = work.appendingPathComponent("src")
try FileManager.default.createDirectory(at: src.appendingPathComponent("docs/sub dir"), withIntermediateDirectories: true)
try "hello\n".write(to: src.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
try "deep\n".write(to: src.appendingPathComponent("docs/sub dir/note one.md"), atomically: true, encoding: .utf8)
try "star\n".write(to: src.appendingPathComponent("a[1].txt"), atomically: true, encoding: .utf8)
try "wild\n".write(to: src.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
try "ds\n".write(to: src.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

// compress → zip → list.
let zipped = try Archive.compress([src])
check(zipped.lastPathComponent == "src.zip" && FileManager.default.fileExists(atPath: zipped.path), "compress makes src.zip next to the folder")
let again = try Archive.compress([src])
check(again.lastPathComponent == "src 2.zip", "a taken name gets a number")
let many = try Archive.compress([src.appendingPathComponent("readme.md"), src.appendingPathComponent("b.txt")])
check(many.lastPathComponent == "Archive.zip" && many.deletingLastPathComponent().standardizedFileURL == src.standardizedFileURL, "several items: Archive.zip in their common folder")
let entries = try Archive.list(zipped)
let paths = Set(entries.map(\.path))
check(paths.contains("src/readme.md") && paths.contains("src/docs/sub dir/note one.md") && paths.contains("src/a[1].txt"), "listing keeps nested paths, spaces and brackets: \(paths.sorted())")
check(!paths.contains("src/.DS_Store"), ".DS_Store is left out")
check(entries.first { $0.path == "src/docs" }?.isDirectory == true, "directories are marked")
check(entries.first { $0.path == "src/readme.md" }?.size == 6, "sizes are read")

// One entry, including a name that looks like a glob.
let note = try Archive.extractEntry(entries.first { $0.path == "src/docs/sub dir/note one.md" }!, from: zipped)
check((try? String(contentsOf: note, encoding: .utf8)) == "deep\n", "one entry is unpacked to the cache")
let bracket = try Archive.extractEntry(entries.first { $0.path == "src/a[1].txt" }!, from: zipped)
check((try? String(contentsOf: bracket, encoding: .utf8)) == "star\n", "a name with brackets is read, not matched as a pattern")
let wildcardTarget = try Archive.extractEntry(entries.first { $0.path == "src/b.txt" }!, from: zipped)
check((try? String(contentsOf: wildcardTarget, encoding: .utf8)) == "wild\n", "a plain name next to a glob-like one")
do { _ = try Archive.extractEntry(entries.first { $0.path == "src/docs" }!, from: zipped); check(false, "a folder cannot be opened") }
catch { check(true, "a folder cannot be opened") }

// Extract everything.
let dest = Archive.uniqueFolder(for: zipped)
check(dest.lastPathComponent == "src" || dest.lastPathComponent == "src 2", "extract folder is named after the archive: \(dest.lastPathComponent)")
let count = try Archive.extractAll(zipped, to: dest)
check(count == 4 && FileManager.default.fileExists(atPath: dest.appendingPathComponent("src/docs/sub dir/note one.md").path), "extract all unpacks every file (\(count))")
do { _ = try Archive.extractAll(zipped, to: dest); check(false, "an existing folder is never written into") }
catch { check(true, "an existing folder is never written into") }

// tar.gz.
let tgz = work.appendingPathComponent("pack.tar.gz")
sh("tar -czf pack.tar.gz -C src readme.md docs", in: work)
let tgzEntries = try Archive.list(tgz)
check(Set(tgzEntries.map(\.path)).isSuperset(of: ["readme.md", "docs/sub dir/note one.md"]), "tar.gz is listed")

// Zip-slip: entries with .. and an absolute path.
let evil = work.appendingPathComponent("evil.zip")
sh("""
python3 - <<'PY'
import zipfile
z = zipfile.ZipFile("evil.zip", "w")
z.writestr("ok.txt", "fine")
z.writestr("../escaped.txt", "bad")
z.writestr("/abs/escaped.txt", "bad")
z.close()
PY
""", in: work)
let evilEntries = (try? Archive.list(evil)) ?? []
check(evilEntries.contains { !$0.isSafe }, "an unsafe path in the archive is flagged")
let evilDest = work.appendingPathComponent("evil-out")
do { _ = try Archive.extractAll(evil, to: evilDest); check(false, "an archive with an unsafe path is refused") }
catch let error as ArchiveError { check({ if case .unsafe = error { return true }; return false }(), "an archive with an unsafe path is refused") }
check(!FileManager.default.fileExists(atPath: evilDest.path) && !FileManager.default.fileExists(atPath: work.appendingPathComponent("escaped.txt").path), "nothing was written")
do { _ = try Archive.extractEntry(evilEntries.first { !$0.isSafe }!, from: evil); check(false, "an unsafe entry is not opened") }
catch { check(true, "an unsafe entry is not opened") }

// Not an archive / broken.
let broken = work.appendingPathComponent("broken.zip")
try "not a zip".write(to: broken, atomically: true, encoding: .utf8)
do { _ = try Archive.list(broken); check(false, "a broken archive fails") } catch { check(true, "a broken archive fails with a message: \(error.localizedDescription)") }

print(failures == 0 ? "All archive checks passed." : "\(failures) archive check(s) failed.")
exit(failures == 0 ? 0 : 1)
