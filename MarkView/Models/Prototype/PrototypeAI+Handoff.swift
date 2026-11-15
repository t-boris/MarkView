import Foundation

extension PrototypeAI {
    /// One unit's description is a short answer; a run that has not finished by then is given up and the unit keeps the text made from the review requests.
    static let describeTimeout: TimeInterval = 240

    /// One assistant run that says what the application's code must change for one changed unit of a prototype (feature "Prototype and
    /// code stay in step", REQ-018): it is given the unit's files before and after, the line difference, the review requests and the two
    /// screenshots, and answers with a short list. It reads only `scratch` (the pictures) and the two folders of the prototype, never the
    /// application's source, and writes nothing. `record` counts the run in the workspace's usage like every other prototype run.
    static func describeChange(root: URL, scratch: URL, versionSite: URL, liveSite: URL, unit: PrototypeHandoff.Unit,
                               draft: PrototypeHandoff.Draft, diff: String, record: @escaping Record) async throws -> [String] {
        let fm = FileManager.default
        func existing(_ folder: URL) -> [String] {
            unit.files.map { folder.appendingPathComponent($0).path }.filter { fm.fileExists(atPath: $0) }
        }
        let prompt = PrototypeHandoff.describePrompt(unit: unit, draft: draft, beforeFiles: existing(versionSite), afterFiles: existing(liveSite), diff: diff)
        let pictures = [unit.before, unit.after].compactMap { $0.path.map { URL(fileURLWithPath: $0) } }
        let result = try await call(root: root, system: PrototypeHandoff.describeSystem, prompt: prompt, schema: PrototypeHandoff.describeSchema,
                                    label: "prototype:handoff:\(draft.prototypeSlug)", effort: "low", images: pictures,
                                    reading: "the prototype's versions", readable: scratch, alsoReadable: [versionSite, liveSite], timeout: Self.describeTimeout,
                                    record: record, stage: { _ in })
        guard let lines = PrototypeHandoff.parseDescription(result.structured) else {
            throw PrototypeFiles.Failure.edits(["The assistant's answer is not a list of changes."])
        }
        return lines
    }
}
