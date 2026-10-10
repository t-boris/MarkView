import Foundation

/// What Git says about one path. Foundation only, so the parser can be checked on its own
/// (`tools/tests/git-status-tests.sh`).
enum GitFileState: String, CaseIterable {
    case modified, added, deleted, renamed, copied, typeChanged, conflicted, untracked, ignored, tracked

    /// One-letter badge, as `git status --short` writes it.
    var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .conflicted: return "U"
        case .untracked: return "?"
        case .ignored: return "!"
        case .tracked: return "·"
        }
    }

    var title: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        case .conflicted: return "Conflict"
        case .untracked: return "Untracked"
        case .ignored: return "Ignored"
        case .tracked: return "Tracked, unchanged"
        }
    }

    /// `X` or `Y` of a porcelain entry ("." = unchanged).
    init?(code: Character) {
        switch code {
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        default: return nil
        }
    }
}

/// The groups of the Git tab.
enum GitStatusGroup: String, CaseIterable, Identifiable {
    case conflicts = "Conflicts"
    case staged = "Staged"
    case changes = "Changes"
    case untracked = "Untracked"
    case ignored = "Ignored"
    case tracked = "Tracked"

    var id: String { rawValue }
}

/// One path of the working tree. A path changed in the index and again in the work tree has both
/// states and appears under Staged and under Changes.
struct GitStatusEntry: Identifiable, Hashable {
    var id: String { path }
    let path: String
    /// Where a rename or copy comes from.
    var origin: String?
    /// State in the index (staged), if any.
    var index: GitFileState?
    /// State in the work tree (not staged), if any.
    var worktree: GitFileState?
    /// Untracked, ignored or in conflict; `index`/`worktree` are nil for the first two.
    var special: GitFileState?

    var isConflict: Bool { special == .conflicted }
    var isDirectory: Bool { path.hasSuffix("/") }

    func state(in group: GitStatusGroup) -> GitFileState? {
        switch group {
        case .conflicts: return special == .conflicted ? .conflicted : nil
        case .staged: return index
        case .changes: return worktree
        case .untracked: return special == .untracked ? .untracked : nil
        case .ignored: return special == .ignored ? .ignored : nil
        case .tracked: return nil
        }
    }
}

/// The parsed state of a repository (`git status --porcelain=v2 -z --branch`).
struct GitRepoStatus: Equatable {
    var head = ""
    var upstream: String?
    var ahead = 0
    var behind = 0
    var entries: [GitStatusEntry] = []

    static let empty = GitRepoStatus()

    func entries(in group: GitStatusGroup) -> [GitStatusEntry] {
        entries.filter { $0.state(in: group) != nil }
    }

    func count(_ group: GitStatusGroup) -> Int { entries(in: group).count }

    /// Paths with a change, a conflict or no tracking (everything but ignored).
    var changedPaths: Set<String> {
        Set(entries.filter { $0.special != .ignored }.map(\.path))
    }

    /// Parse the output of `git status --porcelain=v2 -z --branch [--ignored]`.
    static func parse(_ output: String) -> GitRepoStatus {
        var status = GitRepoStatus()
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            if record.hasPrefix("# ") {
                let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.head": status.head = parts[1]
                case "branch.upstream": status.upstream = parts[1]
                case "branch.ab":
                    for word in parts[1].split(separator: " ") {
                        if word.hasPrefix("+") { status.ahead = Int(word.dropFirst()) ?? 0 }
                        if word.hasPrefix("-") { status.behind = Int(word.dropFirst()) ?? 0 }
                    }
                default: break
                }
                continue
            }
            guard let kind = record.first else { continue }
            switch kind {
            case "1", "2":
                // 1 XY sub mH mI mW hH hI path        2 XY sub mH mI mW hH hI Xscore path <NUL> origPath
                let fields = record.split(separator: " ", maxSplits: kind == "1" ? 8 : 9, omittingEmptySubsequences: false)
                guard fields.count == (kind == "1" ? 9 : 10), fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                var entry = GitStatusEntry(path: String(fields[fields.count - 1]))
                entry.index = GitFileState(code: xy[0])
                entry.worktree = GitFileState(code: xy[1])
                if kind == "2", i < records.count { entry.origin = records[i]; i += 1 }
                if entry.index != nil || entry.worktree != nil { status.entries.append(entry) }
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                var entry = GitStatusEntry(path: String(fields[10]))
                entry.special = .conflicted
                status.entries.append(entry)
            case "?", "!":
                guard record.count > 2 else { continue }
                var entry = GitStatusEntry(path: String(record.dropFirst(2)))
                entry.special = kind == "?" ? .untracked : .ignored
                status.entries.append(entry)
            default: continue
            }
        }
        return status
    }

    /// Tracked files without any change: `git ls-files -z` minus the changed paths.
    static func cleanTracked(lsFiles: String, changed: Set<String>) -> [String] {
        lsFiles.split(separator: "\0", omittingEmptySubsequences: true).map(String.init).filter { !changed.contains($0) }
    }
}
