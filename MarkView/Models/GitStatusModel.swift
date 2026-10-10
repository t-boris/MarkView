import Foundation

/// What Git says about one path. Foundation only, so the parser can be checked on its own
/// (`tools/tests/git-status-tests.sh`).
enum GitFileState: String, CaseIterable {
    case modified, added, deleted, renamed, copied, typeChanged, conflicted, untracked, ignored, tracked

    /// One-letter badge, as the file tree writes it (untracked is U, a conflict is !).
    var letter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .conflicted: return "!"
        case .untracked: return "U"
        case .ignored: return "I"
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

/// How the file tree decorates a path.
struct GitDecoration: Equatable {
    var state: GitFileState?
    /// Everything changed in the file is staged.
    var staged = false
    /// For a folder: how many changed files it holds.
    var inside = 0
    /// Tooltip.
    var detail = ""
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

    /// The one state a row shows: a conflict, else the work tree's change, else the staged one.
    var displayState: GitFileState? { special ?? worktree ?? index }

    /// "Modified, not staged" / "Added, staged" / "Modified in the index and again in the work tree".
    var explanation: String {
        if let special { return special.title }
        switch (index, worktree) {
        case let (i?, w?): return "\(i.title) and staged, then \(w.title.lowercased()) again"
        case let (i?, nil): return "\(i.title), staged"
        case let (nil, w?): return "\(w.title), not staged"
        default: return ""
        }
    }
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
    var entries: [GitStatusEntry] = [] { didSet { index() } }

    static let empty = GitRepoStatus()

    // Lookups for the file tree, rebuilt whenever the entries change.
    private var byPath: [String: GitStatusEntry] = [:]
    private var inside: [String: (state: GitFileState, count: Int)] = [:]
    private var ignoredDirectories: [String] = []

    static func == (a: GitRepoStatus, b: GitRepoStatus) -> Bool {
        a.head == b.head && a.upstream == b.upstream && a.ahead == b.ahead && a.behind == b.behind && a.entries == b.entries
    }

    /// Strongest state first, for a folder that holds several.
    private static let urgency: [GitFileState] = [.conflicted, .deleted, .modified, .typeChanged, .renamed, .copied, .added, .untracked]

    private mutating func index() {
        byPath = [:]; inside = [:]; ignoredDirectories = []
        for entry in entries {
            if entry.special == .ignored {
                if entry.isDirectory { ignoredDirectories.append(entry.path) } else { byPath[entry.path] = entry }
                continue
            }
            byPath[entry.path] = entry
            guard let state = entry.displayState else { continue }
            var parts = entry.path.split(separator: "/").dropLast()
            while !parts.isEmpty {
                let folder = parts.joined(separator: "/")
                let known = inside[folder]
                let stronger = known.map { (Self.urgency.firstIndex(of: state) ?? 99) < (Self.urgency.firstIndex(of: $0.state) ?? 99) } ?? true
                inside[folder] = (stronger ? state : known!.state, (known?.count ?? 0) + 1)
                parts = parts.dropLast()
            }
        }
    }

    /// What the file tree shows for a file or folder (`path` relative to the repository, no trailing slash).
    func decoration(of path: String, isDirectory: Bool) -> GitDecoration {
        let ignored = byPath[path]?.special == .ignored || byPath[path + "/"]?.special == .ignored
            || ignoredDirectories.contains { $0 == path + "/" || path.hasPrefix($0) }
        if ignored { return GitDecoration(state: .ignored, staged: false, inside: 0, detail: "Ignored by Git") }
        if isDirectory {
            guard let summary = inside[path] else { return GitDecoration() }
            return GitDecoration(state: summary.state, staged: false, inside: summary.count,
                                 detail: "\(summary.count) changed file\(summary.count == 1 ? "" : "s") inside")
        }
        guard let entry = byPath[path], let state = entry.displayState else { return GitDecoration() }
        return GitDecoration(state: state, staged: entry.index != nil && entry.worktree == nil && entry.special == nil, inside: 0, detail: entry.explanation)
    }

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
        var collected: [GitStatusEntry] = []
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
                if entry.index != nil || entry.worktree != nil { collected.append(entry) }
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                var entry = GitStatusEntry(path: String(fields[10]))
                entry.special = .conflicted
                collected.append(entry)
            case "?", "!":
                guard record.count > 2 else { continue }
                var entry = GitStatusEntry(path: String(record.dropFirst(2)))
                entry.special = kind == "?" ? .untracked : .ignored
                collected.append(entry)
            default: continue
            }
        }
        status.entries = collected
        return status
    }

    /// Tracked files without any change: `git ls-files -z` minus the changed paths.
    static func cleanTracked(lsFiles: String, changed: Set<String>) -> [String] {
        lsFiles.split(separator: "\0", omittingEmptySubsequences: true).map(String.init).filter { !changed.contains($0) }
    }
}
