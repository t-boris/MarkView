import Foundation
import Combine

/// One thing a discussion has settled or still owes: a decision, an open question, or an option that was rejected.
struct DiscussionItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case decision, question, rejected

        var title: String {
            switch self {
            case .decision: return "Decided"
            case .question: return "Open question"
            case .rejected: return "Rejected"
            }
        }
    }

    var id: String
    var kind: Kind
    var text: String
    /// The turn that produced it (nil when typed by hand).
    var turn: Int?
}

/// One question and the answer to it. The answer is a Markdown note in `notes/`, shown as an Insight page.
struct DiscussionTurn: Codable, Identifiable, Equatable {
    /// 1, 2, 3… in the order asked.
    var id: Int
    var question: String
    var answer: String
    /// Questions the answer suggests asking next (each one goes deeper).
    var followUps: [String] = []
    var createdAt: Date
}

/// A conversation held before there is a feature: questions answered as pages, the decisions it reached and
/// what is still open. Stored in `.dde/discussions/<slug>/discussion.json`; the answers are notes beside it.
/// Foundation only, checked in `tools/tests/discussion-tests.sh`.
struct Discussion: Codable, Identifiable, Equatable {
    var slug: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var turns: [DiscussionTurn] = []
    var items: [DiscussionItem] = []

    var id: String { slug }

    func items(_ kind: DiscussionItem.Kind) -> [DiscussionItem] { items.filter { $0.kind == kind } }

    /// Relative path of the note that holds a turn's answer.
    static func noteName(_ turn: Int) -> String { String(format: "notes/%03d.md", turn) }

    /// The note of one turn: the question as the title, then the answer. This file is what Insight turns into a page.
    func note(for turn: DiscussionTurn) -> String {
        var out = "# \(turn.question)\n\n*Discussion: \(title)*\n\n\(turn.answer)\n"
        if !turn.followUps.isEmpty {
            out += "\n## Questions to ask next\n\n" + turn.followUps.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// What the assistant is told about the conversation so far: earlier questions with short answers, then the
    /// decisions, the open questions and the rejected options. The newest turns come last and keep more detail.
    func context(answerBudget: Int = 12_000) -> String {
        guard !turns.isEmpty || !items.isEmpty else { return "(nothing discussed yet)" }
        var out = ""
        var left = answerBudget
        for turn in turns.reversed() {
            let share = min(left, turn.id == turns.last?.id ? 4_000 : 1_500)
            guard share > 0 else { break }
            let text = String(turn.answer.prefix(share))
            left -= text.count
            out = "### Q\(turn.id): \(turn.question)\n\(text)\(turn.answer.count > share ? " […]" : "")\n\n" + out
        }
        out = "## Earlier questions and answers\n\n" + out
        for kind in DiscussionItem.Kind.allCases {
            let found = items(kind)
            guard !found.isEmpty else { continue }
            out += "## \(kind.title)\n" + found.map { "- \($0.text)" }.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    /// A file-name friendly slug from a title, unique among `existing`.
    static func slug(for title: String, existing: Set<String>) -> String {
        let base = title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").prefix(6).joined(separator: "-")
        let stem = base.isEmpty ? "discussion" : base
        var candidate = stem, n = 2
        while existing.contains(candidate) { candidate = "\(stem)-\(n)"; n += 1 }
        return candidate
    }
}

/// The discussions of the open project. Each lives in its own folder so a note can be opened as a document.
@MainActor
final class DiscussionStore: ObservableObject {
    @Published private(set) var discussions: [Discussion] = []
    @Published var selectedSlug: String?
    /// The question being answered now (the discussion's slug), nil when idle.
    @Published var asking: String?
    @Published var lastError: String?

    private(set) var root: URL?

    var selected: Discussion? { discussions.first { $0.slug == selectedSlug } }

    func setRoot(_ url: URL?) {
        guard url?.standardizedFileURL != root?.standardizedFileURL else { return }
        root = url
        discussions = []
        selectedSlug = nil
        asking = nil
        lastError = nil
        load()
    }

    static func base(root: URL) -> URL { root.appendingPathComponent(".dde/discussions", isDirectory: true) }
    func folder(_ slug: String) -> URL? { root.map { Self.base(root: $0).appendingPathComponent(slug, isDirectory: true) } }
    func noteURL(_ slug: String, turn: Int) -> URL? { folder(slug)?.appendingPathComponent(Discussion.noteName(turn)) }

    func load() {
        guard let root else { return }
        let base = Self.base(root: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        discussions = names.compactMap { name -> Discussion? in
            guard let data = try? Data(contentsOf: base.appendingPathComponent(name).appendingPathComponent("discussion.json")) else { return nil }
            return try? decoder.decode(Discussion.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
        selectedSlug = discussions.first?.slug
    }

    @discardableResult
    func create(title: String, now: Date = Date()) -> String? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard root != nil, !name.isEmpty else { return nil }
        let slug = Discussion.slug(for: name, existing: Set(discussions.map(\.slug)))
        let discussion = Discussion(slug: slug, title: name, createdAt: now, updatedAt: now)
        discussions.insert(discussion, at: 0)
        selectedSlug = slug
        save(discussion)
        return slug
    }

    func delete(_ slug: String) {
        guard let folder = folder(slug) else { return }
        try? FileManager.default.removeItem(at: folder)
        discussions.removeAll { $0.slug == slug }
        if selectedSlug == slug { selectedSlug = discussions.first?.slug }
    }

    /// Records an answer: the turn, its note, and the decisions and open questions it brought.
    func addTurn(_ slug: String, question: String, answer: String, followUps: [String], decisions: [String],
                 openQuestions: [String], now: Date = Date()) -> DiscussionTurn? {
        guard let index = discussions.firstIndex(where: { $0.slug == slug }) else { return nil }
        var discussion = discussions[index]
        let turn = DiscussionTurn(id: (discussion.turns.map(\.id).max() ?? 0) + 1, question: question, answer: answer,
                                  followUps: followUps, createdAt: now)
        discussion.turns.append(turn)
        for (kind, texts) in [(DiscussionItem.Kind.decision, decisions), (.question, openQuestions)] {
            for text in texts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !text.isEmpty
                && !discussion.items.contains(where: { $0.kind == kind && $0.text.lowercased() == text.lowercased() }) {
                discussion.items.append(DiscussionItem(id: UUID().uuidString, kind: kind, text: text, turn: turn.id))
            }
        }
        discussion.updatedAt = now
        discussions[index] = discussion
        save(discussion)
        if let url = noteURL(slug, turn: turn.id) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? discussion.note(for: turn).write(to: url, atomically: true, encoding: .utf8)
        }
        return turn
    }

    func addItem(_ slug: String, kind: DiscussionItem.Kind, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        change(slug) { $0.items.append(DiscussionItem(id: UUID().uuidString, kind: kind, text: clean, turn: nil)) }
    }

    func move(_ slug: String, item id: String, to kind: DiscussionItem.Kind) {
        change(slug) { d in if let i = d.items.firstIndex(where: { $0.id == id }) { d.items[i].kind = kind } }
    }

    func edit(_ slug: String, item id: String, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        change(slug) { d in if let i = d.items.firstIndex(where: { $0.id == id }) { d.items[i].text = clean } }
    }

    func remove(_ slug: String, item id: String) {
        change(slug) { $0.items.removeAll { $0.id == id } }
    }

    func rename(_ slug: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        change(slug) { $0.title = clean }
    }

    private func change(_ slug: String, _ edit: (inout Discussion) -> Void) {
        guard let index = discussions.firstIndex(where: { $0.slug == slug }) else { return }
        var discussion = discussions[index]
        edit(&discussion)
        discussion.updatedAt = Date()
        discussions[index] = discussion
        save(discussion)
    }

    private func save(_ discussion: Discussion) {
        guard let folder = folder(discussion.slug) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(discussion).write(to: folder.appendingPathComponent("discussion.json"), options: .atomic)
        } catch {
            lastError = "Could not save the discussion: \(error.localizedDescription)"
        }
    }
}
