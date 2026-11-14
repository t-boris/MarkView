import Foundation
import Darwin

/// A result retains the reviewed plan and build even if the linked QA details are deliberately deleted.
struct CockpitResult: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var plan: CockpitPlan
    var build: String
    var outcome: String
    var qaRunID: String?
}

/// Disk operations and QA cleanup share a process-wide file lock, including across MarkView windows and app instances.
enum CockpitResults {
    enum StoreError: Error { case lock, invalidRunID, missingRun }

    private static func directory(_ root: URL) -> URL { root.appendingPathComponent(".dde/cockpit/results", isDirectory: true) }

    static func withLock<T>(_ root: URL, _ body: () throws -> T) throws -> T {
        let parent = root.appendingPathComponent(".dde/cockpit", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let fd = open(parent.appendingPathComponent("retention.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw StoreError.lock }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw StoreError.lock }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Call only while holding `withLock`; a malformed result fails closed so cleanup cannot discard linked evidence.
    static func linkedRunIDsLocked(_ root: URL) throws -> Set<String> {
        let folder = directory(root)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var ids = Set<String>()
        for url in urls where url.pathExtension == "json" {
            let result = try JSONDecoder().decode(CockpitResult.self, from: Data(contentsOf: url))
            if let id = result.qaRunID {
                guard QARunRetention.runID(inBugKey: id + ":result") == id else { throw StoreError.invalidRunID }
                ids.insert(id)
            }
        }
        return ids
    }

    static func save(_ result: CockpitResult, root: URL) throws {
        try withLock(root) {
            if let id = result.qaRunID {
                guard QARunRetention.runID(inBugKey: id + ":result") == id else { throw StoreError.invalidRunID }
                guard FileManager.default.fileExists(atPath: QAStore.runFolder(root, runID: id).appendingPathComponent("run.json").path) else { throw StoreError.missingRun }
            }
            let folder = directory(root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let url = folder.appendingPathComponent(result.id.uuidString + ".json")
            try JSONEncoder().encode(result).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
