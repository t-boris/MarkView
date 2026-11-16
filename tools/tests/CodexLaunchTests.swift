import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
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

if failures > 0 { exit(1) }
print("All Codex launch checks passed")
