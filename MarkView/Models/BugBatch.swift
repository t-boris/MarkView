import Combine
import Foundation

/// The window's bug basket for batch Fix with AI (issue #31): what is in it, what was dropped,
/// and the AI's "Suggest similar" answer. In memory only; a new folder starts with an empty
/// basket (DEC-008). The rules are in `BugBasket.swift`.
@MainActor
final class BugBatch: ObservableObject {
    unowned let store: FeatureStore

    @Published private(set) var basket = BugBasket()
    /// "2 bugs left the basket …": shown until dismissed or the basket changes again.
    @Published var notice: String?
    /// The last "Suggest similar" answer, without what has been added or dismissed since.
    @Published private(set) var suggestions: [SimilarBugs.Suggestion] = []
    /// A "Suggest similar" answer came back empty.
    @Published private(set) var noSuggestions = false
    @Published private(set) var suggestionError: String?

    static let suggestKey = "basket:suggest"
    private var bugsObserver: AnyCancellable?

    init(store: FeatureStore) {
        self.store = store
        // Reports change on disk (closed, deleted, fixed by the AI): the basket follows.
        // `$bugs` publishes before the property changes: the new list is the one passed in.
        bugsObserver = store.$bugs.dropFirst().sink { [weak self] bugs in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcile(Self.basketBugs(bugs, store: self.store))
            }
        }
    }

    /// Every report, as the basket sees it.
    var bugs: [BasketBug] { Self.basketBugs(store.bugs, store: store) }
    var items: [BasketBug] { basket.items(in: bugs) }
    var eligible: [BasketBug] { basket.eligible(in: bugs) }

    func contains(_ bug: BugReport) -> Bool { basket.contains(store.relativePath(bug.url)) }

    /// Only open bugs can go in (DEC-010).
    func canAdd(_ bug: BugReport) -> Bool { BugBasket.canAdd(Self.basketBug(bug, store: store)) }

    func toggle(_ bug: BugReport) {
        let path = store.relativePath(bug.url)
        if basket.contains(path) {
            basket.remove(path)
        } else if canAdd(bug) {
            basket.add(path)
        }
        notice = nil
        suggestions.removeAll { $0.path == path }
    }

    func remove(_ path: String) {
        basket.remove(path)
        notice = nil
        if basket.isEmpty { clearSuggestions() }
    }

    func add(_ suggestion: SimilarBugs.Suggestion) {
        if let bug = bugs.first(where: { $0.path == suggestion.path }), BugBasket.canAdd(bug) { basket.add(bug.path) }
        suggestions.removeAll { $0.path == suggestion.path }
    }

    func dismiss(_ suggestion: SimilarBugs.Suggestion) { suggestions.removeAll { $0.path == suggestion.path } }

    func clear() {
        basket.clear()
        notice = nil
        clearSuggestions()
    }

    /// Another folder was opened: its basket starts empty, without a notice.
    func reset() { clear() }

    func url(_ path: String) -> URL? { store.root?.appendingPathComponent(path) }

    /// Check the basket against the reports now (also done whenever they change).
    func reconcile() { reconcile(bugs) }

    private func reconcile(_ bugs: [BasketBug]) {
        let removed = basket.reconcile(with: bugs)
        if removed > 0 {
            notice = removed == 1 ? "1 bug left the basket: it was closed or deleted."
                : "\(removed) bugs left the basket: they were closed or deleted."
        }
        let candidates = Set(SimilarBugs.candidates(bugs, basket: basket).map(\.path))
        suggestions.removeAll { !candidates.contains($0.path) }
    }

    private func clearSuggestions() {
        suggestions = []
        noSuggestions = false
        suggestionError = nil
    }

    // MARK: - Suggest similar (REQ-006)

    /// Open bugs like the ones in the basket, proposed by the AI (a read-only structured call);
    /// each one is added only by the user's click.
    func suggestSimilar(using assistant: FeatureAssistant) async {
        let all = bugs
        let inBasket = basket.items(in: all)
        let candidates = SimilarBugs.candidates(all, basket: basket)
        clearSuggestions()
        guard !inBasket.isEmpty else { return }
        guard !candidates.isEmpty else {
            noSuggestions = true
            return
        }
        guard let root = store.root else { return }
        let prompt = await Task.detached {
            SimilarBugs.prompt(basket: inBasket.map { Self.candidate($0, root: root, length: 1_500) },
                               candidates: candidates.prefix(150).map { Self.candidate($0, root: root, length: 500) })
        }.value
        let answer = await assistant.structured(Self.suggestKey, prompt: prompt, schema: SimilarBugs.schema, timeout: 180)
        // The basket may have changed while the AI was reading.
        guard let answer, store.root == root else {
            if store.root == root { suggestionError = assistant.error ?? "The AI did not answer." }
            return
        }
        suggestions = SimilarBugs.parse(answer, candidates: SimilarBugs.candidates(bugs, basket: basket))
        noSuggestions = suggestions.isEmpty
    }

    nonisolated private static func candidate(_ bug: BasketBug, root: URL, length: Int) -> SimilarBugs.Candidate {
        let text = (try? String(contentsOf: root.appendingPathComponent(bug.path), encoding: .utf8)) ?? ""
        let body = FrontMatter.split(text).1.trimmingCharacters(in: .whitespacesAndNewlines)
        return SimilarBugs.Candidate(bug: bug, excerpt: String(body.prefix(length)))
    }

    private static func basketBugs(_ bugs: [BugReport], store: FeatureStore) -> [BasketBug] {
        bugs.map { basketBug($0, store: store) }
    }

    private static func basketBug(_ bug: BugReport, store: FeatureStore) -> BasketBug {
        BasketBug(path: store.relativePath(bug.url), key: bug.key, title: bug.title, status: bug.status, feature: bug.feature)
    }
}
