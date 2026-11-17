import Foundation
import MarkViewCore
import os
import XCTest
@testable import MarkView

extension EditorHostTests {
    func testClaudeSessionModelParsing() {
        func check(_ name: String, _ condition: Bool, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, name + " " + detail, line: line)
        }
        let start = ISO8601DateFormatter().date(from: "2026-11-03T10:00:00Z")!
        func stamp(_ seconds: Int, fractional: Bool = true) -> String {
            let date = start.addingTimeInterval(TimeInterval(seconds))
            if fractional {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.string(from: date)
            }
            return ISO8601DateFormatter().string(from: date)
        }

        func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        func reply(_ model: String, at seconds: Int, sidechain: Bool = false) -> Data {
            line(["type": "assistant", "timestamp": stamp(seconds), "isSidechain": sidechain,
                  "message": ["role": "assistant", "model": model, "content": [["type": "text", "text": "ok"]]]])
        }
        func switchCommand(_ shown: String, at seconds: Int, asParts: Bool = false) -> Data {
            let text = "<local-command-stdout>Set model to `\(shown)` and saved as your default for new sessions</local-command-stdout>"
            let content: Any = asParts ? [["type": "text", "text": text]] : text
            return line(["type": "user", "timestamp": stamp(seconds), "message": ["role": "user", "content": content]])
        }
        func user(_ text: String, at seconds: Int) -> Data {
            line(["type": "user", "timestamp": stamp(seconds), "message": ["role": "user", "content": text]])
        }

        // Names and families.
        check("an id names its family", ClaudeSessionModel.family(of: "claude-sonnet-5-5") == "sonnet")
        check("a display name names its family", ClaudeSessionModel.family(of: "Fable 5.1") == "fable")
        check("opus", ClaudeSessionModel.family(of: "claude-opus-5-5") == "opus")
        check("haiku", ClaudeSessionModel.family(of: "Claude Haiku 5.5") == "haiku")
        check("another vendor names none", ClaudeSessionModel.family(of: "gpt-5") == nil)

        // The reply of the session.
        check("the newest reply wins",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), reply("claude-sonnet-5-5", at: 5)])?.model == "sonnet")
        check("an id without a known family is kept as logged",
              ClaudeSessionModel.reading(lines: [reply("claude-nova-6-0", at: 1)])?.model == "claude-nova-6-0")
        check("a subagent's reply is not the session's model",
              ClaudeSessionModel.reading(lines: [reply("claude-sonnet-5-5", at: 1), reply("claude-haiku-5-5", at: 9, sidechain: true)])?.model == "sonnet")
        check("a placeholder reply is skipped",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1), reply("<synthetic>", at: 9)])?.model == "opus")
        check("the reading carries the time of the line",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 7)])?.date == start.addingTimeInterval(7))

        // /model confirms before the next reply.
        check("a /model confirmation after a reply wins",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), switchCommand("Sonnet 5.5", at: 4)])?.model == "sonnet")
        check("a reply after the confirmation wins",
              ClaudeSessionModel.reading(lines: [switchCommand("Sonnet 5.5", at: 1), reply("claude-opus-5-5", at: 4)])?.model == "opus")
        check("a confirmation whose content is a list of parts",
              ClaudeSessionModel.reading(lines: [switchCommand("Opus 5.5", at: 2, asParts: true)])?.model == "opus")
        check("a confirmation without a family is ignored",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), switchCommand("Default (recommended)", at: 4)])?.model == "fable")
        check("ordinary user text that mentions a model is not a switch",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), user("please use sonnet for this", at: 4)])?.model == "fable")

        // Only what happened since the agent started counts (a continued session carries old replies).
        check("lines older than since are ignored",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1), reply("claude-sonnet-5-5", at: 3)],
                                         since: start.addingTimeInterval(10)) == nil)
        check("a line at since counts",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 10)], since: start.addingTimeInterval(10))?.model == "opus")
        check("old lines do not hide newer ones",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1), reply("claude-sonnet-5-5", at: 20)],
                                         since: start.addingTimeInterval(10))?.model == "sonnet")

        // Odd input.
        check("no lines, no reading", ClaudeSessionModel.reading(lines: []) == nil)
        check("garbage and blank lines are skipped",
              ClaudeSessionModel.reading(lines: [Data("not json".utf8), Data(), reply("claude-haiku-5-5", at: 1), Data("{".utf8)])?.model == "haiku")
        check("a line without a time is skipped",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1),
                                                 line(["type": "assistant", "message": ["model": "claude-haiku-5-5"]])])?.model == "opus")
        check("a time without fractions is read",
              ClaudeSessionModel.reading(lines: [line(["type": "assistant", "timestamp": stamp(3, fractional: false),
                                                       "message": ["model": "claude-opus-5-5"]])])?.date == start.addingTimeInterval(3))

        // Concurrent readers share the two timestamp parsers without changing their results.
        let concurrentLines = [reply("claude-opus-5-5", at: 1), line(["type": "assistant", "timestamp": stamp(3, fractional: false),
                                                                       "message": ["model": "claude-sonnet-5-5"]])]
        let expectedConcurrentDate = start.addingTimeInterval(3)
        let concurrentErrors = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let result = ClaudeSessionModel.reading(lines: concurrentLines)
            if result?.model != "sonnet" || result?.date != expectedConcurrentDate { concurrentErrors.withLock { $0 += 1 } }
        }
        check("concurrent readers parse fractional and plain timestamps consistently", concurrentErrors.withLock { $0 } == 0)

        // Titles.
        check("title: the model part is replaced", ClaudeSessionModel.title("Claude Code · fable", model: "sonnet") == "Claude Code · sonnet")
        check("title: a numbered tab keeps its number", ClaudeSessionModel.title("Claude Code 2 · fable", model: "opus") == "Claude Code 2 · opus")
        check("title: a title without a model gets one", ClaudeSessionModel.title("Claude Code", model: "sonnet") == "Claude Code · sonnet")
    }
}

extension EditorHostTests {
    func testCodexLaunchSchemaFiles() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("codex-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { chmod(scratch.path, 0o755); try? FileManager.default.removeItem(at: scratch) }

        func request(schema: [String: Any]?) -> CompletionLaunchRequest {
            CompletionLaunchRequest(prompt: "Answer.", systemPrompt: nil, jsonSchema: schema, readableFolder: nil, extraReadableFolders: [],
                                    linkedFolders: { [] }, allowWeb: false, images: [], effort: nil, model: nil, workDir: scratch,
                                    scratchDirectory: { scratch })
        }
        func listing() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted() }

        let schema: [String: Any] = ["type": "object", "properties": ["answer": ["type": "string"], "tags": ["type": "array", "items": ["type": "string"]]]]
        let provider = CodexProvider()

        // No schema, no file.
        let plain = try provider.launch(request(schema: nil))
        check(plain.schemaFile == nil && !plain.arguments.contains("--output-schema") && listing().isEmpty, "a launch without a schema writes nothing")

        // A schema: saved whole in the scratch folder, strict as Codex needs it, and named in the arguments.
        let first = try provider.launch(request(schema: schema))
        let file = first.schemaFile
        check(file?.deletingLastPathComponent().standardizedFileURL.path == scratch.standardizedFileURL.path && file?.lastPathComponent.hasPrefix("schema-") == true
              && file?.pathExtension == "json", "the schema file is in the run's scratch folder")
        if let index = first.arguments.firstIndex(of: "--output-schema") {
            check(first.arguments.indices.contains(index + 1) && first.arguments[index + 1] == file?.path, "the CLI is told to read that very file")
        } else { check(false, "the CLI is told to read that very file") }
        let saved = file.flatMap { try? Data(contentsOf: $0) }
        let parsed = saved.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(parsed != nil && (parsed?["additionalProperties"] as? Bool) == false && (parsed?["required"] as? [String]) == ["answer", "tags"],
              "the file holds the whole strict schema (closed object, every property required)")
        let expected = try CompletionJSON.string(CodexProvider.strictSchema(schema))
        check(saved.map { String(decoding: $0, as: UTF8.self) } == expected, "byte for byte what the schema serialises to")
        check(file.map { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o644 } == true, "it is an ordinary file, readable by the CLI")
        check(listing().count == 1, "and nothing else is in the folder (no temporary file)")

        // Every launch has a file of its own.
        let second = try provider.launch(request(schema: ["type": "object", "properties": ["x": ["type": "string"]]]))
        check(second.schemaFile != nil && second.schemaFile != file && listing().count == 2 && (file.flatMap { try? Data(contentsOf: $0) }) == saved,
              "a second launch has its own file and leaves the first as it was")

        // A scratch folder that refuses the file: the launch fails, with no partial schema, and the earlier files are as they were.
        let before = listing()
        chmod(scratch.path, 0o555)
        var refused = false
        do { _ = try provider.launch(request(schema: schema)) } catch { refused = true }
        chmod(scratch.path, 0o755)
        check(refused, "a scratch folder that refuses the schema fails the launch")
        check(listing() == before && (file.flatMap { try? Data(contentsOf: $0) }) == saved, "and adds no partial file, and the earlier schema keeps its bytes")
    }
}
