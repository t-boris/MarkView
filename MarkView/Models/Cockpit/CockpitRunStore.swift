import Foundation

/// Call on a background executor. Running records load paused so a restart cannot resume work by itself.
enum CockpitRunStore {
    private static func directory(_ root: URL) -> URL { root.appendingPathComponent(".dde/cockpit/runs", isDirectory: true) }
    private static func url(_ id: UUID, root: URL) -> URL { directory(root).appendingPathComponent(id.uuidString + ".json") }

    static func save(_ run: CockpitRun, root: URL) throws {
        let folder = directory(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let target = url(run.id, root: root)
        try JSONEncoder().encode(run).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    static func load(_ id: UUID, root: URL) throws -> CockpitRun {
        var run = try JSONDecoder().decode(CockpitRun.self, from: Data(contentsOf: url(id, root: root)))
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
