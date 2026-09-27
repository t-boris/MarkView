import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  " + name) } else { failures += 1; print("FAIL " + name) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("understanding-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
try "# Decision\nThe reason\n".write(to: root.appendingPathComponent("docs/DEC-001.md"), atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: root) }
let sha = String(repeating: "a", count: 40)
func source(_ id: String, _ kind: String, path: String = "", target: String = "", url: String = "") -> [String: Any] {
    ["id": id, "kind": kind, "label": "Evidence \(id)", "path": path, "start": 2, "end": 900, "target": target, "url": url]
}
let references = [source("S1", "code", path: "code.swift"), source("S2", "document", path: "docs/DEC-001.md"),
                  source("S3", "component", target: "editor"), source("S4", "deployment", target: "app"),
                  source("S5", "commit", target: sha), source("S6", "pr", target: "26", url: "https://github.com/test/repo/pull/26")]
func section(_ text: String, _ ids: [String]) -> [String: Any] { ["text": text, "sources": ids] }
let valid: [String: Any] = ["what": section("A thing", ["S1", "S3"]), "why": section("Solves a problem", ["S2"]),
                          "how": section("The flow", ["S1", "S4"]), "origin": section("The documented decision", ["S2", "S5", "S6"]),
                          "originFound": true, "sources": references]
func parse(_ object: Any?) throws -> UnderstandingAnswer {
    try UnderstandingAnswer.parse(object, root: root, components: ["editor"], deployment: ["app"], commits: [sha],
                                  pullRequests: ["https://github.com/test/repo/pull/26"])
}
func rejected(_ name: String, _ object: Any?) {
    do { _ = try parse(object); check(name, false) } catch { check(name, !error.localizedDescription.isEmpty) }
}
let answer = try parse(valid)
check("all six evidence types survive validation", answer.sources.count == 6)
check("file ranges are clamped", answer.sources[0].start == 2 && answer.sources[0].end == 4)
check("parsing never saves research", !FileManager.default.fileExists(atPath: root.appendingPathComponent("docs/research").path))
rejected("nil/empty answers give a reason", nil)
rejected("legacy location-only answer is rejected", ["answer": "See code.swift"])
var bad = valid; bad["why"] = section(" \n", []); rejected("empty explanatory section is rejected", bad)
bad = valid; bad["how"] = section("Flow", ["unknown"]); rejected("dangling citation is rejected", bad)
bad = valid; bad["origin"] = section("Origin", ["S1"]); rejected("origin needs document/commit/PR evidence", bad)
bad = valid; bad["sources"] = references + [references[0]]; rejected("duplicate citations are rejected", bad)
bad = valid; bad["sources"] = [source("S1](bad)", "code", path: "code.swift")]; rejected("invalid citation identifiers are rejected", bad)
bad = valid; bad["sources"] = [source("S1", "code", path: "../outside.swift")]; rejected("path traversal is rejected", bad)
bad = valid; bad["sources"] = [source("S1", "code", path: "/etc/passwd")]; rejected("absolute paths are rejected", bad)
bad = valid; bad["sources"] = [source("S1", "code", path: "missing.swift")]; rejected("missing evidence is rejected", bad)
try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
check("symlinks cannot escape the workspace", UnderstandingAnswer.relativePath("escape/passwd", root: root) == nil)
bad = valid; bad["sources"] = [source("S1", "component", target: "missing")]; rejected("unknown X-Ray target is rejected", bad)
bad = valid; bad["sources"] = [source("S1", "commit", target: String(repeating: "b", count: 40))]; rejected("unseen commit is rejected", bad)
bad = valid; bad["sources"] = [source("S1", "pr", target: "26", url: "https://github.com/evil/repo/pull/26")]; rejected("unseen PR is rejected", bad)
check("external and mismatched commit URLs are rejected", !UnderstandingAnswer.isGitHubURL("https://example.com/commit/" + sha, kind: .commit, target: sha)
      && !UnderstandingAnswer.isGitHubURL("https://github.com/a/b/commit/other", kind: .commit, target: sha))
var noOrigin = valid; noOrigin["originFound"] = false; noOrigin["origin"] = section("No origin source was found. Git/PR access unavailable.", [])
let missingOrigin = try parse(noOrigin)
check("absent origin is explicit in saved answer", missingOrigin.markdown(question: "Q").contains("No origin source found."))

let folder = root.appendingPathComponent("docs/research")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try "untouched".write(to: folder.appendingPathComponent("RES-001-existing.md"), atomically: true, encoding: .utf8)
try "untouched too".write(to: folder.appendingPathComponent("RES-009.md"), atomically: true, encoding: .utf8)
let question = "What is this?\n" + String(repeating: "A long question. ", count: 40)
let saved = try answer.save(question: question, root: root, author: "Tester", date: "2026-09-27")
let content = try String(contentsOf: saved, encoding: .utf8)
let front = FrontMatter.split(content).0
check("save uses next free RES number", saved.lastPathComponent.hasPrefix("RES-010-"))
check("existing file is never overwritten", try String(contentsOf: folder.appendingPathComponent("RES-001-existing.md"), encoding: .utf8) == "untouched")
check("research format includes id and type", front.string("type") == "research" && front.string("id") == "RES-010")
check("entire question, sections and sources are saved", content.contains(question) && content.contains("## What") && content.contains("## Why")
      && content.contains("## How") && content.contains("## Origin") && content.contains("## Sources") && content.contains("Source S6"))
check("source file links retain lines", content.contains("../../code.swift#L2-L4"))
let image = root.appendingPathComponent("screenshot.png")
try Data([1, 2, 3]).write(to: image)
let copied = try UnderstandingAttachments.copy([image], to: root.appendingPathComponent(".dde/understanding/test"), root: root)
check("unsaved attachments stay outside research", copied.first?.hasPrefix(".dde/understanding/") == true)
let withImage = try answer.save(question: "Explain this screenshot", root: root, author: "Tester", date: "2026-09-27",
    attachments: copied.map { root.appendingPathComponent($0) })
let imageBody = try String(contentsOf: withImage, encoding: .utf8)
check("explicit save embeds question images", imageBody.contains("## Question attachments") && imageBody.contains("![") && imageBody.contains("assets/RES-011-"))
try FileManager.default.removeItem(at: root.appendingPathComponent(".dde"))
let assetFolders = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("assets"), includingPropertiesForKeys: nil)
check("saved image survives closing the transient question", try FileManager.default.contentsOfDirectory(atPath: assetFolders[0].path).count == 1)
do {
    _ = try UnderstandingAttachments.copy([image], to: root.appendingPathComponent("escape/attachments"), root: root)
    check("attachment destination cannot escape via symlink", false)
} catch { check("attachment destination cannot escape via symlink", true) }
let lock = NSLock()
var files: [URL] = []
var saveErrors = 0
DispatchQueue.concurrentPerform(iterations: 8) { _ in
    do {
        let file = try answer.save(question: "Concurrent question", root: root, author: "Tester", date: "2026-09-27")
        lock.lock(); files.append(file); lock.unlock()
    } catch { lock.lock(); saveErrors += 1; lock.unlock() }
}
check("concurrent saves reserve distinct numeric ids", saveErrors == 0 && Set(files.map { $0.lastPathComponent.prefix(7) }).count == 8)
check("save leaves no reservation files", try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasSuffix(".reserve") })
if failures > 0 { exit(1) }
print("All understanding answer checks passed")
