import CryptoKit
import Foundation

struct HandoffRevision: Codable, Identifiable {
    let number: Int
    let actor: String
    let createdAt: Date
    let linkedFiles: [String]
    let hashes: [String: String]

    var id: Int { number }
}

struct HandoffChange: Identifiable {
    enum Kind: String { case added, modified, deleted }
    let path: String
    let kind: Kind
    var id: String { path }
}

struct HandoffState {
    let revision: HandoffRevision?
    let history: [HandoffRevision]
    let currentLinks: [String]
    let currentHashes: [String: String]
    let changes: [HandoffChange]

    var isReady: Bool { revision != nil }
    var hasChanged: Bool { !changes.isEmpty }
}

struct HandoffResume {
    let slug: String
    let title: String
    let linkedFiles: [String]
    let missingFiles: [String]
}

enum HandoffError: LocalizedError {
    case invalidPath(String)
    case missingOverview
    case unsupportedSymlink(String)
    case uneditableOverview
    case changedDuringHandoff

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Invalid project-relative path: \(path)"
        case .missingOverview: return "The feature has no overview.md file."
        case .unsupportedSymlink(let path): return "The feature contains a symbolic link that cannot be snapshotted safely: \(path)"
        case .uneditableOverview: return "The feature overview contains YAML that MarkView cannot rewrite safely."
        case .changedDuringHandoff: return "The specification changed while preparing the handoff. Review it and try again."
        }
    }
}

/// Owns durable handoff revisions. All file I/O and hashing run on this actor,
/// outside the main actor. Metadata lives outside the feature folder so it never
/// sets its own changed-since-handoff flag.
actor SpecificationHandoffStore {
    static let shared = SpecificationHandoffStore()

    private let fm = FileManager.default

    func state(project: URL, slug: String) throws -> HandoffState {
        let folder = try featureFolder(project: project, slug: slug)
        let history = try revisions(project: project, slug: slug)
        let latest = history.last
        let links = try currentLinks(folder: folder)
        let current = try hashes(in: folder)
        let previous = latest?.hashes ?? [:]
        let changes: [HandoffChange] = latest == nil ? [] : Set(current.keys).union(previous.keys).compactMap { path in
            if previous[path] == nil { return HandoffChange(path: path, kind: .added) }
            if current[path] == nil { return HandoffChange(path: path, kind: .deleted) }
            if current[path] != previous[path] { return HandoffChange(path: path, kind: .modified) }
            return nil
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return HandoffState(revision: latest, history: history, currentLinks: links,
                            currentHashes: current, changes: changes)
    }

    func markReady(project: URL, slug: String, actor: String) throws -> HandoffRevision {
        let folder = try featureFolder(project: project, slug: slug)
        let overview = folder.appendingPathComponent("overview.md")
        guard let text = try? String(contentsOf: overview, encoding: .utf8) else { throw HandoffError.missingOverview }
        var (front, body) = FrontMatter.split(text)
        guard front.isLossless else { throw HandoffError.uneditableOverview }
        let currentStatus = front.string("status")
        let shouldSetReady = ["idea", "exploring", "draft", "review", "resolving", ""].contains(currentStatus)
        if shouldSetReady {
            front.set("status", "ready")
        }

        let directory = try handoffDirectory(project: project, slug: slug)
        let history = try revisions(project: project, slug: slug)
        let number = (history.last?.number ?? 0) + 1
        let name = String(format: "%06d", number)
        let target = directory.appendingPathComponent("revisions/" + name, isDirectory: true)
        let staging = directory.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let files = staging.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        var manifest = try copyAndHash(from: folder, to: files)
        let originalManifest = manifest
        if shouldSetReady {
            let updated = front.join(body: body)
            let snapshotOverview = files.appendingPathComponent("overview.md")
            try updated.write(to: snapshotOverview, atomically: true, encoding: .utf8)
            manifest["overview.md"] = SHA256.hash(data: Data(updated.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        let revision = HandoffRevision(number: number, actor: actor, createdAt: Date(),
                                       linkedFiles: try currentLinks(folder: folder), hashes: manifest)
        let data = try JSONEncoder().encode(revision)
        try data.write(to: staging.appendingPathComponent("record.json"), options: .atomic)
        guard try hashes(in: folder) == originalManifest else { throw HandoffError.changedDuringHandoff }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Publish the revision first. If the live status write fails, remove the
        // new revision so a handoff never points to a state the project did not reach.
        try fm.moveItem(at: staging, to: target)
        if shouldSetReady {
            do {
                guard (try? String(contentsOf: overview, encoding: .utf8)) == text else {
                    throw HandoffError.changedDuringHandoff
                }
                try front.join(body: body).write(to: overview, atomically: true, encoding: .utf8)
            } catch {
                try? fm.removeItem(at: target)
                throw error
            }
        }
        return revision
    }

    func setLinkedFiles(_ links: [String], project: URL, slug: String) throws {
        let folder = try featureFolder(project: project, slug: slug)
        let overview = folder.appendingPathComponent("overview.md")
        guard let text = try? String(contentsOf: overview, encoding: .utf8) else { throw HandoffError.missingOverview }
        var (front, body) = FrontMatter.split(text)
        guard front.isLossless else { throw HandoffError.uneditableOverview }
        let normalized = try Array(Set(links.map(validRelativePath))).sorted()
        front["handoff_files"] = .list(normalized.map { .string($0) })
        try front.join(body: body).write(to: overview, atomically: true, encoding: .utf8)
    }

    func snapshotText(project: URL, slug: String, revision: Int, path: String) throws -> String? {
        let relative = try validRelativePath(path)
        let root = try handoffDirectory(project: project, slug: slug)
            .appendingPathComponent("revisions/" + String(format: "%06d", revision) + "/files", isDirectory: true)
        let file = root.appendingPathComponent(relative)
        guard file.resolvingSymlinksInPath().standardizedFileURL.path
                .hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
            throw HandoffError.invalidPath(path)
        }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    func currentText(project: URL, slug: String, path: String) throws -> String? {
        let relative = try validRelativePath(path)
        let root = try featureFolder(project: project, slug: slug)
        let file = root.appendingPathComponent(relative)
        guard file.resolvingSymlinksInPath().standardizedFileURL.path
                .hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
            throw HandoffError.invalidPath(path)
        }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    private func featureFolder(project: URL, slug: String) throws -> URL {
        let safe = try validRelativePath(slug)
        guard !safe.contains("/") else { throw HandoffError.invalidPath(slug) }
        return project.appendingPathComponent("docs/features/" + safe, isDirectory: true)
    }

    private func handoffDirectory(project: URL, slug: String) throws -> URL {
        let safe = try validRelativePath(slug)
        guard !safe.contains("/") else { throw HandoffError.invalidPath(slug) }
        return project.appendingPathComponent("docs/handoffs/" + safe, isDirectory: true)
    }

    private func validRelativePath(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.contains("\\") else { throw HandoffError.invalidPath(path) }
        return path
    }

    private func currentLinks(folder: URL) throws -> [String] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("overview.md"), encoding: .utf8) else { return [] }
        let (front, _) = FrontMatter.split(text)
        return try front.strings("handoff_files").map(validRelativePath)
    }

    private func revisions(project: URL, slug: String) throws -> [HandoffRevision] {
        let directory = try handoffDirectory(project: project, slug: slug).appendingPathComponent("revisions", isDirectory: true)
        let paths = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return paths.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("record.json")) else { return nil }
            return try? JSONDecoder().decode(HandoffRevision.self, from: data)
        }.sorted { $0.number < $1.number }
    }

    private func hashes(in folder: URL) throws -> [String: String] {
        try copyAndHash(from: folder, to: nil)
    }

    private func copyAndHash(from folder: URL, to destination: URL?) throws -> [String: String] {
        let root = folder.standardizedFileURL.path + "/"
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [:] }
        var result: [String: String] = [:]
        while let url = enumerator.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { throw HandoffError.invalidPath(path) }
            let relative = String(path.dropFirst(root.count))
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw HandoffError.unsupportedSymlink(relative) }
            guard values.isRegularFile == true else { continue }
            var hasher = SHA256()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            result[relative] = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if let destination {
                let copy = destination.appendingPathComponent(relative)
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: copy)
            }
        }
        return result
    }
}
