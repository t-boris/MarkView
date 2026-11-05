import Foundation

@main struct WorkspaceRedesignTests {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }

    /// The app writes the live status through the lifecycle service; the checks write it the same way, byte for byte.
    nonisolated static func writeReady(_ overview: URL) -> @Sendable (String) -> Bool {
        { _ in
            guard let text = try? String(contentsOf: overview, encoding: .utf8) else { return false }
            var (front, body) = FrontMatter.split(text)
            front.set("status", "ready")
            return (try? front.join(body: body).write(to: overview, atomically: true, encoding: .utf8)) != nil
        }
    }

    static func main() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("markview-redesign-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        let feature = project.appendingPathComponent("docs/features/demo")
        try FileManager.default.createDirectory(at: feature.appendingPathComponent("questions"), withIntermediateDirectories: true)
        try "---\ntitle: Demo\nstatus: draft\n---\n\nOriginal overview.\n".write(
            to: feature.appendingPathComponent("overview.md"), atomically: true, encoding: .utf8)
        try "First answer.\n".write(to: feature.appendingPathComponent("questions/Q-001.md"),
                                      atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "func workspaceSearch() {}\n".write(to: project.appendingPathComponent("src/main.swift"),
                                                   atomically: true, encoding: .utf8)
        try "secret-value".write(to: project.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ignored-content".write(to: project.appendingPathComponent(".git/internal.md"),
                                        atomically: true, encoding: .utf8)

        let handoff = SpecificationHandoffStore.shared
        try await handoff.setLinkedFiles(["src/main.swift", "src/missing.swift"], project: project, slug: "demo")
        let first = try await handoff.markReady(project: project, slug: "demo", actor: "Boris", commitStatus: Self.writeReady(feature.appendingPathComponent("overview.md")))
        check(first.number == 1 && first.actor == "Boris", "first handoff records revision and actor")
        check(first.linkedFiles == ["src/main.swift", "src/missing.swift"], "explicit links survive missing files")
        let ready = try await handoff.state(project: project, slug: "demo")
        check(ready.isReady && !ready.hasChanged, "published handoff matches current folder")
        check((try String(contentsOf: feature.appendingPathComponent("overview.md"), encoding: .utf8)).contains("status: ready"),
              "initial handoff marks specification ready")

        try "Updated answer.\n".write(to: feature.appendingPathComponent("questions/Q-001.md"),
                                        atomically: true, encoding: .utf8)
        try "Added externally.\n".write(to: feature.appendingPathComponent("discussion.md"),
                                          atomically: true, encoding: .utf8)
        let changed = try await handoff.state(project: project, slug: "demo")
        check(changed.changes.contains { $0.path == "questions/Q-001.md" && $0.kind == .modified },
              "external modifications appear")
        check(changed.changes.contains { $0.path == "discussion.md" && $0.kind == .added },
              "external additions appear")
        let old = try await handoff.snapshotText(project: project, slug: "demo", revision: 1,
                                                  path: "questions/Q-001.md")
        check(old == "First answer.\n", "handed-off snapshot stays immutable")

        try FileManager.default.removeItem(at: feature.appendingPathComponent("questions/Q-001.md"))
        let deleted = try await handoff.state(project: project, slug: "demo")
        check(deleted.changes.contains { $0.path == "questions/Q-001.md" && $0.kind == .deleted },
              "external deletion appears")
        let second = try await handoff.markReady(project: project, slug: "demo", actor: "Developer", commitStatus: Self.writeReady(feature.appendingPathComponent("overview.md")))
        let current = try await handoff.state(project: project, slug: "demo")
        check(second.number == 2 && !current.hasChanged, "ready again publishes a clean independent revision")
        check(current.history.count == 2 && current.currentHashes["questions/Q-001.md"] == nil,
              "history is retained and deleted file is absent")
        let metadata = project.appendingPathComponent(".dde/cache")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: project.appendingPathComponent(".dde"))
        check((try await handoff.state(project: project, slug: "demo")).history.count == 2,
              "metadata removal leaves handoff history intact")
        do {
            try await handoff.setLinkedFiles(["../outside.md"], project: project, slug: "demo")
            check(false, "a link cannot escape the project")
        } catch HandoffError.invalidPath {
            check(true, "a link cannot escape the project")
        }

        // The status can be written by the lifecycle service instead of by the handoff (issue-lifecycle-management).
        let gated = project.appendingPathComponent("docs/features/gated")
        try FileManager.default.createDirectory(at: gated, withIntermediateDirectories: true)
        let gatedOverview = gated.appendingPathComponent("overview.md")
        let gatedText = "---\ntitle: Gated\nstatus: draft\n---\n\nGated overview.\n"
        try gatedText.write(to: gatedOverview, atomically: true, encoding: .utf8)
        final class Seen: @unchecked Sendable { var from = "" }
        let seen = Seen()
        let refused = try? await handoff.markReady(project: project, slug: "gated", actor: "Boris", commitStatus: { _ in false })
        check(refused == nil, "a status write the lifecycle declines fails the handoff")
        check((try String(contentsOf: gatedOverview, encoding: .utf8)) == gatedText, "a declined status write leaves the overview alone")
        check((try await handoff.state(project: project, slug: "gated")).history.isEmpty, "a declined status write removes the new revision")
        let committed = try await handoff.markReady(project: project, slug: "gated", actor: "Boris", commitStatus: { from in
            seen.from = from
            return Self.writeReady(gatedOverview)(from)
        })
        let gatedState = try await handoff.state(project: project, slug: "gated")
        check(committed.number == 1 && seen.from == "draft", "the lifecycle write is told the status it replaces")
        check(gatedState.isReady && !gatedState.hasChanged, "a status written by the lifecycle matches the handed-off snapshot")
        check((try String(contentsOf: gatedOverview, encoding: .utf8)).contains("status: ready"), "the lifecycle write sets ready")

        let search = ProjectSearchIndex()
        try await search.rebuild(root: project, progress: { _ in })
        let names = await search.search("main.swift")
        check(names.contains { $0.scope == .file && $0.path == "src/main.swift" }, "filename search")
        let contents = await search.search("workspaceSearch")
        check(contents.contains { $0.scope == .content && $0.path == "src/main.swift" && $0.line == 1 },
              "source content search with line")
        check((await search.search("secret-value")).isEmpty, "credential content excluded")
        check((await search.search("ignored-content")).isEmpty, "Git metadata excluded")
        check((await search.search("First answer")).isEmpty, "immutable handoff copies excluded from search")
        try Array(repeating: "needle", count: 160).joined(separator: "\n").write(
            to: project.appendingPathComponent("000-many-results.md"), atomically: true, encoding: .utf8)
        try "No matching content.\n".write(to: project.appendingPathComponent("zzz-needle.md"),
                                             atomically: true, encoding: .utf8)
        try await search.rebuild(root: project, progress: { _ in })
        check((await search.search("needle")).contains { $0.scope == .file && $0.path == "zzz-needle.md" },
              "filename search continues after content result limit")
        try FileManager.default.removeItem(at: project.appendingPathComponent("src/main.swift"))
        try await search.rebuild(root: project, progress: { _ in })
        check((await search.search("workspaceSearch")).isEmpty, "refresh removes deleted content")
        let changes = ProjectChangeScanner()
        try await changes.open(project)
        try "A new external note.\n".write(to: project.appendingPathComponent("note.md"),
                                              atomically: true, encoding: .utf8)
        let observed = try await changes.refresh()
        check(observed.contains { $0.path == "note.md" && $0.kind == .added &&
            $0.current == "A new external note.\n" }, "review records externally added text")
        await changes.acknowledge()
        check((try await changes.refresh()).isEmpty, "mark reviewed establishes a new baseline")
        try "Revised external note.\n".write(to: project.appendingPathComponent("note.md"),
                                              atomically: true, encoding: .utf8)
        let modified = try await changes.refresh()
        check(modified.contains { $0.path == "note.md" && $0.kind == .modified &&
            $0.before == "A new external note.\n" && $0.current == "Revised external note.\n" },
            "review compares old and current text")
        try FileManager.default.removeItem(at: project.appendingPathComponent("note.md"))
        let removed = try await changes.refresh()
        check(removed.contains { $0.path == "note.md" && $0.kind == .deleted },
              "review detects external deletion")
        print("Workspace redesign checks: \(checks), failures: 0")
    }
}
