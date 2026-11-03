import AppKit
import Foundation

// Manual check against the real `claude` CLI (not part of the automatic checks): takes the before and after screenshots of one screen of a
// prototype and asks for the description of what the code must change (see prototype-handoff-live-run.sh).

@MainActor
func run() async {
    let args = CommandLine.arguments
    guard args.count >= 5 else { print("usage: <prototype folder> <screen id> <files, comma separated, relative to site/> <project root>"); exit(2) }
    let folder = URL(fileURLWithPath: args[1]), screen = args[2], files = args[3].split(separator: ",").map(String.init), root = URL(fileURLWithPath: args[4])
    guard let manifest = PrototypeFiles.loadManifest(folder) else { print("no prototype.json in \(folder.path)"); exit(1) }
    let versionSite = PrototypeFiles.versionFolder(of: folder, manifest.version), liveSite = PrototypeFiles.site(of: folder)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mv-handoff-live-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    var unit = PrototypeHandoff.Unit(id: screen, name: screen, kind: .screen, files: files, components: [], alsoChangedInCode: [], changes: [], described: false)
    let theme = manifest.themes.flatMap { t in t.effective.map { PrototypeScreenshots.Theme(attribute: t.attribute, id: $0) } }
    let renderer = PrototypeScreenshots()
    for (side, site) in [("before", versionSite), ("after", liveSite)] {
        do {
            let png = try await renderer.capture(.init(site: site, screen: screen, page: nil), theme: theme)
            let file = scratch.appendingPathComponent(PrototypeHandoff.shotFileName(unitID: screen, side: side))
            try png.write(to: file)
            if side == "before" { unit.before = .taken(file.path) } else { unit.after = .taken(file.path) }
            print("shot \(side): \(png.count) bytes")
        } catch { print("shot \(side) FAILED: \(error.localizedDescription)") }
    }
    let draft = PrototypeHandoff.Draft(title: "t", prototypeTitle: manifest.title, prototypeSlug: folder.lastPathComponent, version: manifest.version + 1,
                                       baselineVersion: manifest.version, units: [unit], requests: [])
    let diff = PrototypeHandoff.unitDiff(files: files,
                                         before: { try? String(contentsOf: versionSite.appendingPathComponent($0), encoding: .utf8) },
                                         after: { try? String(contentsOf: liveSite.appendingPathComponent($0), encoding: .utf8) })
    print("diff: \(diff.count) characters")
    let started = Date()
    do {
        let lines = try await PrototypeAI.describeChange(root: root, scratch: scratch, versionSite: versionSite, liveSite: liveSite, unit: unit,
                                                         draft: draft, diff: diff, record: { _ in })
        print("described in \(Int(Date().timeIntervalSince(started))) s:")
        for line in lines { print(" - \(line)") }
        print(lines.isEmpty ? "FAIL no changes described" : "ALL OK")
    } catch { print("FAIL \(error.localizedDescription)") }
    try? FileManager.default.removeItem(at: scratch)
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
app.run()
