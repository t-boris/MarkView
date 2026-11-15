import CoreGraphics
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif
/// The export package of a prototype: its README and the archive the studio hands to the person.
enum PrototypeExport {
    enum ExportFailure: LocalizedError {
        case zip(String)
        var errorDescription: String? { if case .zip(let detail) = self { return "Could not create the archive: \(detail)" } else { return nil } }
    }

    /// README.md of the export package. A code-mode prototype is presented as a reconstruction of the
    /// existing interface with its known gaps, never as the original itself.
    static func readme(manifest: PrototypeFiles.Manifest) -> String {
        if manifest.mode == .code {
            var scope = "the project's existing web interface"
            if !manifest.sources.isEmpty { scope += " in " + manifest.sources.map { "`\($0)`" }.joined(separator: ", ") }
            var out = """
            # \(manifest.title) — approved prototype (v\(manifest.version))

            - `prototype/index.html` — open it in a browser; it is self-contained and needs no server.
            - `SPEC.md` — screens, states, flows, data, rules, source traceability and the reconstruction notes.
            - `CHANGES.md` — the review requests that shaped this version.

            The prototype is a reconstruction of \(scope), edited during review: it shows the agreed behaviour and \
            look of the change, not the original code. Implement the change in the existing code to match it; where \
            the prototype and SPEC.md differ, ask before choosing.

            """
            if manifest.gaps.isEmpty {
                out += "\nNo reconstruction gaps were recorded at generation.\n"
            } else {
                out += "\nKnown reconstruction gaps (behaviour of the original that the prototype simulates or lacks; they are " +
                    "not part of the change):\n"
                for gap in manifest.gaps { out += "- \(gap)\n" }
            }
            return out
        }
        return """
        # \(manifest.title) — approved prototype (v\(manifest.version))

        - `prototype/index.html` — open it in a browser; it is self-contained and needs no server.
        - `SPEC.md` — screens, states, flows, data, rules and requirement traceability.
        - `CHANGES.md` — the review requests that shaped this version.

        The prototype is the agreed behaviour and look. Implement the product to match it; where the prototype and \
        SPEC.md differ, ask before choosing.

        """
    }

    /// Packs `prototype/` (the live site), `SPEC.md`, `CHANGES.md` and `README.md` into
    /// `<root>/.dde/exports/prototypes/<slug>-v<version>.zip` (`PrototypeFiles.exportArchive`) and returns it.
    /// The archive is a derived binary, so it lives outside the committed prototype folder (DEC-006).
    static func packageArchive(root: URL, folder: URL, manifest: PrototypeFiles.Manifest, spec: String) throws -> URL {
        let fm = FileManager.default
        let name = "\(manifest.slug)-v\(manifest.version)"
        let archive = PrototypeFiles.exportArchive(root: root, slug: manifest.slug, version: manifest.version)
        let staging = fm.temporaryDirectory.appendingPathComponent("markview-proto-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        try fm.copyItem(at: PrototypeFiles.site(of: folder), to: staging.appendingPathComponent("prototype", isDirectory: true))
        try spec.write(to: staging.appendingPathComponent("SPEC.md"), atomically: true, encoding: .utf8)

        let formatter = ISO8601DateFormatter()
        var changes = "# Review history: \(manifest.title)\n\n"
        for entry in manifest.history {
            changes += "## v\(entry.version) — \(formatter.string(from: entry.date))\n"
            changes += entry.instruction.isEmpty ? "Initial build.\n\n" : "Request: \(entry.instruction)\n\n"
            changes += "\(entry.summary)\n\n"
        }
        try changes.write(to: staging.appendingPathComponent("CHANGES.md"), atomically: true, encoding: .utf8)

        try readme(manifest: manifest).write(to: staging.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: archive)
        let zip = Subprocess.runBlocking(SubprocessSpec(
            executable: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", staging.path, archive.path],
            timeout: 0, stdoutRouting: .discard))
        guard zip.succeeded else { throw ExportFailure.zip(zip.stderr) }
        return archive
    }
}
