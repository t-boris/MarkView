import AppKit
import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

/// Opt-in live checks: the normal hosted suite skips this class and never calls a provider.
final class ManualPrototypeLiveHostTests: XCTestCase {
    @MainActor private func enableClaudeRunner() throws -> (SettingsKey<String>, String?) {
        let claude = try XCTUnwrap(CLITool(rawValue: "claude"))
        let key = Setting.cliPath(claude.rawValue)
        let oldPath = Settings.standard.stored(key)
        if let path = ProcessInfo.processInfo.environment["MARKVIEW_MANUAL_CLAUDE_BIN"], !path.isEmpty {
            Settings.standard.set(path, for: key)
        }
        AIAssistantRunner.setTestRunner { request, delta, activity in
            var live = request
            live.toolOverride = claude
            live.assistantOverride = nil
            return try await CLICompletion.run(live, onDelta: delta, onActivity: activity)
        }
        return (key, oldPath)
    }

    @MainActor func testManualPrototypeBuild() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MARKVIEW_MANUAL_PROTOTYPE"] == "build" else { throw XCTSkip("Manual live prototype build is not enabled.") }
        let rootPath = try XCTUnwrap(environment["MARKVIEW_MANUAL_PROTOTYPE_ROOT"])
        let source = try XCTUnwrap(environment["MARKVIEW_MANUAL_PROTOTYPE_SOURCE"])
        let (key, oldPath) = try enableClaudeRunner()
        defer { AIAssistantRunner.setTestRunner(nil); Settings.standard.set(oldPath, for: key) }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let slug = "live-" + UUID().uuidString.lowercased()
        let folder = PrototypeFiles.folder(root: root, slug: slug)
        try FileManager.default.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
        let stage: PrototypeAI.Stage = { event in
            switch event {
            case .phase(let text): print("PHASE \(text)")
            case .plan(let title, _, _, let screens): print("PLAN \(title): \(screens.map(\.id))")
            case .screen(let id, let state): print("SCREEN \(id): \(state)")
            case .component(let path, let state): print("COMPONENT \(path): \(state)")
            case .milestone(let text): print("MILESTONE \(text)")
            case .log(let text), .step(let text): print(text)
            case .written, .status: break
            }
        }
        let record: PrototypeAI.Record = { print("usage: \($0.inputTokens) in / \($0.outputTokens) out") }
        let started = Date()
        let built = try await PrototypeAI.build(root: root, folder: folder, brief: "", sources: [source], language: "", record: record, stage: stage)
        print("BUILT \(built.title): \(built.screens) failed: \(built.failed) in \(Int(Date().timeIntervalSince(started))) s")
        try PrototypeFiles.snapshot(folder: folder, version: 1)
        let outcome = try await PrototypeAI.revise(root: root, folder: folder,
            instruction: "Add a priority badge colour legend to the ticket list header, and make urgent tickets show their SLA countdown.",
            pick: nil, runtimeErrors: [], language: "", record: record, stage: stage)
        print("REVISED: \(outcome.summary)\nwritten: \(outcome.written)")
        var manifest = PrototypeFiles.Manifest(title: built.title, slug: slug, brief: "", sources: [source])
        manifest.version = 2
        manifest.history = [.init(version: 1, instruction: "", summary: built.summary, date: Date()),
                            .init(version: 2, instruction: "legend", summary: outcome.summary, date: Date())]
        let spec = try await PrototypeAI.specification(root: root, folder: folder, manifest: manifest, language: "", record: record, stage: stage)
        let archive = try PrototypeExport.packageArchive(root: root, folder: folder, manifest: manifest, spec: spec)
        print("PROTOTYPE: \(folder.path)\nSPEC chars: \(spec.count)\nZIP: \(archive.path)")
    }

    @MainActor func testManualPrototypeHandoff() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MARKVIEW_MANUAL_PROTOTYPE"] == "handoff" else { throw XCTSkip("Manual live prototype hand-off is not enabled.") }
        let folder = URL(fileURLWithPath: try XCTUnwrap(environment["MARKVIEW_MANUAL_PROTOTYPE_FOLDER"]), isDirectory: true)
        let root = URL(fileURLWithPath: try XCTUnwrap(environment["MARKVIEW_MANUAL_PROTOTYPE_ROOT"]), isDirectory: true)
        let screen = try XCTUnwrap(environment["MARKVIEW_MANUAL_PROTOTYPE_SCREEN"])
        let files = try XCTUnwrap(environment["MARKVIEW_MANUAL_PROTOTYPE_FILES"]).split(separator: ",").map(String.init)
        let (key, oldPath) = try enableClaudeRunner()
        defer { AIAssistantRunner.setTestRunner(nil); Settings.standard.set(oldPath, for: key) }
        let manifest = try XCTUnwrap(PrototypeFiles.loadManifest(folder))
        let versionSite = PrototypeFiles.versionFolder(of: folder, manifest.version)
        let liveSite = PrototypeFiles.site(of: folder)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mv-handoff-live-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var unit = PrototypeHandoff.Unit(id: screen, name: screen, kind: .screen, files: files, components: [], alsoChangedInCode: [], changes: [], described: false)
        let theme = manifest.themes.flatMap { item in item.effective.map { PrototypeScreenshots.Theme(attribute: item.attribute, id: $0) } }
        let renderer = PrototypeScreenshots()
        for (side, site) in [("before", versionSite), ("after", liveSite)] {
            let png = try await renderer.capture(.init(site: site, screen: screen, page: nil), theme: theme)
            let file = scratch.appendingPathComponent(PrototypeHandoff.shotFileName(unitID: screen, side: side))
            try png.write(to: file)
            if side == "before" { unit.before = .taken(file.path) } else { unit.after = .taken(file.path) }
            print("shot \(side): \(png.count) bytes")
        }
        let draft = PrototypeHandoff.Draft(title: "t", prototypeTitle: manifest.title, prototypeSlug: folder.lastPathComponent,
                                           version: manifest.version + 1, baselineVersion: manifest.version, units: [unit], requests: [])
        let diff = PrototypeHandoff.unitDiff(files: files,
            before: { try? String(contentsOf: versionSite.appendingPathComponent($0), encoding: .utf8) },
            after: { try? String(contentsOf: liveSite.appendingPathComponent($0), encoding: .utf8) })
        let lines = try await PrototypeAI.describeChange(root: root, scratch: scratch, versionSite: versionSite, liveSite: liveSite,
                                                        unit: unit, draft: draft, diff: diff, record: { _ in })
        for line in lines { print(" - \(line)") }
        XCTAssertFalse(lines.isEmpty, "The assistant must describe at least one change")
    }
}
