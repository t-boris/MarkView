import Foundation

@main enum PrototypeDeadlineTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-prototype-deadline-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = PrototypeFiles.folder(root: root, slug: "fixture")
        try FileManager.default.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
        let built = try await PrototypeAI.build(root: root, folder: folder, brief: "One screen", sources: [], language: "",
            record: { _ in }, stage: { _ in })
        precondition(built.screens == ["Home"] && built.failed.isEmpty)
        let screen = PrototypeFiles.site(of: folder).appendingPathComponent("screens/home.js")
        precondition(FileManager.default.fileExists(atPath: screen.path))
        _ = try await PrototypeAI.revise(root: root, folder: folder, instruction: "Revise title", pick: nil,
            runtimeErrors: [], language: "", record: { _ in }, stage: { _ in })
        let contents = try String(contentsOf: PrototypeFiles.site(of: folder).appendingPathComponent("index.html"), encoding: .utf8)
        precondition(contents.contains("Revised fixture") && contents.contains("screens/home.js"))
        let manifest = PrototypeFiles.Manifest(title: "Fixture", slug: "fixture", brief: "", sources: [])
        let spec = try await PrototypeAI.specification(root: root, folder: folder, manifest: manifest,
            language: "", record: { _ in }, stage: { _ in })
        precondition(spec.contains("Fixture specification"))
        let labels = await CLICompletion.audit.labels
        precondition(labels == ["prototype:plan", "prototype:foundation:shell", "prototype:foundation:data",
                                "prototype:screen:home", "prototype:revise", "prototype:spec"])
        print("Prototype deadline policy: plan, both foundations, saved screen, revision and specification complete without wall-clock limits.")
    }
}
