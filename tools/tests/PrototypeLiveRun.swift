import Foundation
// Builds a prototype with the real assistant, revises it once and writes the specification.
// Arguments: <project root> <source path>. Prints what happened; the result is in <root>/.dde/prototypes.
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1]), source = args[2]
let folder = PrototypeFiles.folder(root: root, slug: "live")
try? FileManager.default.removeItem(at: folder)
try FileManager.default.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
let stage: PrototypeAI.Stage = { print("  stage: \($0)") }
let noRecord: PrototypeAI.Record = { print("  usage: \($0.inputTokens) in / \($0.outputTokens) out") }

let started = Date()
let events: PrototypeAI.Stage = { event in
    let t = String(format: "%5.0fs", Date().timeIntervalSince(started))
    switch event {
    case .phase(let text): print("\(t) PHASE \(text)")
    case .plan(let title, _, _, let screens): print("\(t) PLAN \(title): \(screens.map(\.id))")
    case .screen(let id, let state): print("\(t) SCREEN \(id): \(state)")
    case .milestone(let text): print("\(t) MILESTONE \(text)")
    case .log(let text), .step(let text): print("\(t)   \(text)")
    case .written, .status: break
    }
}
let built = try await PrototypeAI.build(root: root, folder: folder, brief: "", sources: [source], language: "", record: noRecord, stage: events)
print("BUILT \(built.title): \(built.screens) failed: \(built.failed) in \(Int(Date().timeIntervalSince(started))) s")
try PrototypeFiles.snapshot(folder: folder, version: 1)

let outcome = try await PrototypeAI.revise(root: root, folder: folder,
    instruction: "Add a priority badge colour legend to the ticket list header, and make urgent tickets show their SLA countdown.",
    pick: nil, runtimeErrors: [], language: "", record: noRecord, stage: stage)
print("REVISED: \(outcome.summary)\nwritten: \(outcome.written)")

var manifest = PrototypeFiles.Manifest(title: built.title, slug: "live", brief: "", sources: [source])
manifest.version = 2
manifest.history = [.init(version: 1, instruction: "", summary: built.summary, date: Date()),
                    .init(version: 2, instruction: "legend", summary: outcome.summary, date: Date())]
let spec = try await PrototypeAI.specification(root: root, folder: folder, manifest: manifest, language: "", record: noRecord, stage: stage)
let zip = try PrototypeAI.packageArchive(folder: folder, manifest: manifest, spec: spec)
print("SPEC chars: \(spec.count)\nZIP: \(zip.path)")
