import Foundation
// Builds a prototype with the real assistant, revises it once and writes the specification.
// Arguments: <project root> <source path>. Prints what happened; the result is in <root>/.dde/prototypes.
let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1]), source = args[2]
let folder = PrototypeFiles.folder(root: root, slug: "live")
try? FileManager.default.removeItem(at: folder)
try FileManager.default.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
let stage: PrototypeAI.Stage = { print("  stage: \($0)") }
let noRecord: @MainActor (CLICompletion.Result) -> Void = { print("  usage: \($0.inputTokens) in / \($0.outputTokens) out") }

let built = try await PrototypeAI.generate(root: root, folder: folder, brief: "", sources: [source], language: "", record: noRecord, stage: stage)
print("BUILT \(built.title): \(built.outcome.written)\nscreens: \(built.outcome.screens)\nassumptions: \(built.outcome.assumptions)")
try PrototypeFiles.snapshot(folder: folder, version: 1)

let outcome = try await PrototypeAI.revise(root: root, folder: folder,
    instruction: "Add a priority badge colour legend to the ticket list header, and make urgent tickets show their SLA countdown.",
    pick: nil, runtimeErrors: [], language: "", record: noRecord, stage: stage)
print("REVISED: \(outcome.summary)\nwritten: \(outcome.written)")

var manifest = PrototypeFiles.Manifest(title: built.title, slug: "live", brief: "", sources: [source])
manifest.version = 2
manifest.history = [.init(version: 1, instruction: "", summary: built.outcome.summary, date: Date()),
                    .init(version: 2, instruction: "legend", summary: outcome.summary, date: Date())]
let spec = try await PrototypeAI.specification(root: root, folder: folder, manifest: manifest, language: "", record: noRecord, stage: stage)
let zip = try PrototypeAI.packageArchive(folder: folder, manifest: manifest, spec: spec)
print("SPEC chars: \(spec.count)\nZIP: \(zip.path)")
