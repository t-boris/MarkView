import Foundation

/// Call on a background executor. Running records load paused so a restart cannot resume work by itself.
enum CockpitRunStore {
    /// Runs were written with `JSONEncoder`'s default dates, so they keep them.
    private static let fileStore = SchemaVersionedStore<CockpitRun>(dates: .referenceDate)
    private static func directory(_ root: URL) -> URL { root.appendingPathComponent(".dde/cockpit/runs", isDirectory: true) }
    private static func url(_ id: UUID, root: URL) -> URL { directory(root).appendingPathComponent(id.uuidString + ".json") }

    static func save(_ run: CockpitRun, root: URL) throws {
        let folder = directory(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let target = url(run.id, root: root)
        try fileStore.save(run, to: target, permissions: 0o600)
    }

    static func load(_ id: UUID, root: URL) throws -> CockpitRun {
        // A run that cannot be read throws and is never replaced by an empty one; a save copies it to a backup first.
        var run = try fileStore.load(from: url(id, root: root)).get()
        guard run.id == id else { throw CocoaError(.fileReadCorruptFile) }
        // The interruption happened when the run was last seen alive, not when this file is read.
        run.prepareAfterRestart(now: run.lastKnownActivity ?? Date())
        return run
    }

    static func loadAll(root: URL) throws -> [CockpitRun] {
        let folder = directory(root)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return try files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { file in
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { throw CocoaError(.fileReadCorruptFile) }
                return try load(id, root: root)
            }
    }
}
