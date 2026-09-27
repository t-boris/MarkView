import Foundation

/// Creates the local project from a confirmed draft (REQ-004): an unused folder (DEC-009), the
/// specification with a README and .gitignore (DEC-023), and a local Git repository with the
/// files left uncommitted (DEC-005, DEC-018). Every stage is recorded in the draft as it
/// finishes, so a retry continues in the same folder without touching anything else (DEC-019).
enum ProjectBootstrap {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Run or continue bootstrap. `save` persists the draft after each stage.
    static func run(_ draft: inout ProjectDraft, specification: URL, slug: String, readme: String,
                    save: (ProjectDraft) async throws -> Void) async throws -> URL {
        guard let parentPath = draft.parentPath, let name = draft.folderName else {
            throw Failure(message: "Choose where to create the project.")
        }
        if let problem = ProjectNaming.folderNameProblem(name) { throw Failure(message: problem) }
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true)
        let destination = parent.appendingPathComponent(name, isDirectory: true)

        // 1. The folder: only a path that does not exist, unless it is the one this draft created.
        let ours = draft.createdPath == destination.path
        if !ours || !FileManager.default.fileExists(atPath: destination.path) {
            try await detached {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw Failure(message: "The folder \(parent.path) does not exist any more. Choose another location.")
                }
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw Failure(message: "“\(name)” already exists in \(parent.lastPathComponent). Nothing in it was changed — choose another name or location.")
                }
                // Without intermediate directories: fails instead of reusing a folder created meanwhile.
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            }
            draft.createdPath = destination.path
            draft.filesWritten = false
            draft.gitInitialized = false
            try await save(draft)
        }

        // 2. The specification, README and .gitignore (written again on retry: the folder is ours).
        if !draft.filesWritten {
            let featuresFolder = await FeatureStore.folderName
            try await detached {
                let target = destination.appendingPathComponent(featuresFolder, isDirectory: true)
                    .appendingPathComponent(slug, isDirectory: true)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: specification, to: target)
                try Data(readme.utf8).write(to: destination.appendingPathComponent("README.md"), options: .atomic)
                try Data(ProjectFoundation.gitignore.utf8).write(to: destination.appendingPathComponent(".gitignore"), options: .atomic)
            }
            draft.filesWritten = true
            try await save(draft)
        }

        // 3. Local Git, nothing committed.
        if !draft.gitInitialized {
            if !FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path) {
                var output = await GitHubClient.execute(["init", "-b", "main"], in: destination, git: true)
                if output.status != 0 {
                    // git older than 2.28 has no -b.
                    output = await GitHubClient.execute(["init"], in: destination, git: true)
                    if output.status == 0 {
                        _ = await GitHubClient.execute(["symbolic-ref", "HEAD", "refs/heads/main"], in: destination, git: true)
                    }
                }
                guard output.status == 0 else {
                    let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw Failure(message: "git init failed: " + (message.isEmpty ? "unknown error" : message))
                }
            }
            draft.gitInitialized = true
            try await save(draft)
        }
        return destination
    }

    private static func detached(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(operation: work).value
    }
}
