import Foundation

/// Problems, repair and Undo (REQ-019, REQ-020, DEC-013). This file is the pure part: how a page load is told apart from a
/// navigation inside the page, how a problem row of the Log is classified, which repairs may run and how often, and how a data
/// fix is undone. The session runs the assistant and saves the results (UIStudioSession+Repair.swift).
///
/// A row is classified by fixed rules on its kind and text, never by the model, so what is repaired does not depend on what a
/// model thinks should be.

/// Which loads of an address start a new page.
enum StudioPageLoad {
    /// Loading `target` while the page shows `current` is a navigation inside the same document when the addresses differ only by
    /// the fragment (`/#/attention` → `/#/accounts`, a hash-routed application). WebKit then keeps the old page, which keeps the old
    /// generation: every request it makes is rejected as stale, and the load never finishes. A fresh page has to be loaded
    /// instead (an empty page first). A target without a fragment is always a new page.
    static func isFragmentNavigation(from current: URL?, to target: URL) -> Bool {
        guard let current, target.fragment != nil else { return false }
        return withoutFragment(current) == withoutFragment(target)
    }

    private static func withoutFragment(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }
}

enum StudioProblem {
    /// What a problem is, by its row.
    enum Kind: String, Sendable {
        /// A page error the simulated data may have caused: the assistant corrects records (Fix).
        case dataError
        /// A request or channel nothing could answer, a preparation that failed or timed out: it is prepared again (Prepare).
        case missingRule
        /// The application sent the page to its sign-in page: the test user is signed in (Sign in).
        case signInRedirect
        /// A third-party service the connection policy blocks: reported, no action can help.
        case blockedService
        /// A page error the assistant already judged not caused by data: reported with its pointer, no action.
        case notData
        /// The expected result of a page reload (a message of an earlier page generation): not a problem.
        case noise
        /// Any other problem row: shown, no action.
        case other
    }

    enum Action: String, Sendable {
        case fix, prepare, signIn

        var title: String {
            switch self {
            case .fix: return "Fix"
            case .prepare: return "Prepare"
            case .signIn: return "Sign in"
            }
        }

        var help: String {
            switch self {
            case .fix: return "The assistant reads this error and the code and corrects the simulated records that caused it, or says the error is not caused by data."
            case .prepare: return "Prepares the simulation rules for the requests nothing could answer, then loads the page again."
            case .signIn: return "Signs the scenario's test user in (a simulated sign-in, no real service) and shows the page after it."
            }
        }
    }

    /// The action that repairs a kind; nil when nothing can.
    static func action(for kind: Kind) -> Action? {
        switch kind {
        case .dataError: return .fix
        case .missingRule: return .prepare
        case .signInRedirect: return .signIn
        case .blockedService, .notData, .noise, .other: return nil
        }
    }

    /// A message of an earlier page generation, such as the answer to a request a page made while it was being replaced. It is what
    /// a reload leaves behind, not a failure.
    static func isNoise(_ text: String) -> Bool {
        text.contains("of an earlier generation")
    }

    /// A third-party service the application's connection policy blocks, or an SDK that did not load for that reason.
    static func isBlockedService(_ text: String) -> Bool {
        text.hasPrefix("blocked:") || text.contains("blocked by the application connection policy") || text.contains("Failed to load Stripe.js")
    }

    /// A row of the Log, by fixed rules. `errorKey` is the page error's identity (`StudioDataFix.key(of:)`) when Fix data may be
    /// offered for the row; `notData` is the set of error keys the assistant judged not caused by data.
    static func classify(kind: StudioLogEntry.Kind, problem: Bool, text: String, errorKey: String?, notData: Set<String> = []) -> Kind {
        if isNoise(text) { return .noise }
        guard problem else { return .other }
        if kind == .navigation, text.contains("(a sign-in page)") { return .signInRedirect }
        if isBlockedService(text) { return .blockedService }
        if let errorKey {
            if notData.contains(errorKey) { return .notData }
            if text.contains("still preparing the simulation rule") { return .missingRule }
            return .dataError
        }
        if kind == .preparation { return .missingRule }
        if kind == .notice, text.contains("without a simulation rule") { return .missingRule }
        return .other
    }

    /// One problem of the page as it is now, with what repairs it.
    struct Item: Equatable, Sendable, Identifiable {
        var kind: Kind
        /// The error's key, the sign-in page's path, or the request's contract.
        var key: String
        var text: String
        var id: String { kind.rawValue + "\u{1}" + key }
    }

    /// Repairs in the order that helps: nothing works behind a sign-in page, a request without a rule makes the data look wrong, and
    /// only then is a data error worth the assistant's time. Items of one kind keep their order.
    static func ordered(_ items: [Item]) -> [Item] {
        let rank: [Kind: Int] = [.signInRedirect: 0, .missingRule: 1, .dataError: 2]
        return items.filter { rank[$0.kind] != nil }
            .enumerated()
            .sorted { (rank[$0.element.kind]!, $0.offset) < (rank[$1.element.kind]!, $1.offset) }
            .map(\.element)
    }
}

/// What came of the repairs of one open, so that nothing loops and nothing is asked twice for nothing (REQ-020).
struct StudioRepairLedger: Equatable, Sendable {
    enum Outcome: String, Sendable {
        /// The corrections were saved; the page reloaded on them.
        case fixed
        /// The assistant found the error was not caused by data.
        case notData
        /// MarkView refused the assistant's corrections.
        case refused
        /// The assistant did not answer, or the run could not finish.
        case failed
    }

    struct Record: Equatable, Sendable {
        var attempts = 0
        var outcome: Outcome?
    }

    static let maxAttemptsPerError = 2
    static let maxAutomaticPerOpen = 3

    private var records: [String: Record] = [:]
    private(set) var automaticRuns = 0

    static func identity(kind: StudioProblem.Kind, scenario: String, key: String) -> String {
        kind.rawValue + "\u{1}" + scenario + "\u{1}" + key
    }

    /// Whether a repair of this problem may start. The person's own click always may; an automatic repair never repeats an error
    /// judged not data or refused, makes at most `maxAttemptsPerError` attempts at one error, and at most `maxAutomaticPerOpen` in all.
    func mayRun(_ identity: String, automatic: Bool) -> Bool {
        guard automatic else { return true }
        guard automaticRuns < Self.maxAutomaticPerOpen else { return false }
        let record = records[identity] ?? Record()
        if record.outcome == .notData || record.outcome == .refused { return false }
        return record.attempts < Self.maxAttemptsPerError
    }

    mutating func record(_ identity: String, outcome: Outcome, automatic: Bool) {
        var record = records[identity] ?? Record()
        record.attempts += 1
        record.outcome = outcome
        records[identity] = record
        if automatic { automaticRuns += 1 }
    }

    /// The page errors of this scenario the assistant judged not caused by data.
    func notDataKeys(scenario: String) -> Set<String> {
        let prefix = StudioProblem.Kind.dataError.rawValue + "\u{1}" + scenario + "\u{1}"
        return Set(records.compactMap { identity, record in
            record.outcome == .notData && identity.hasPrefix(prefix) ? String(identity.dropFirst(prefix.count)) : nil
        })
    }

    /// A new open of the application: nothing is remembered.
    mutating func reset() {
        records = [:]
        automaticRuns = 0
    }
}

/// What Undo needs of an automatic fix: the corrections as they were applied, and the scenario they were made in.
struct StudioRepairUndo: Equatable, Sendable {
    var summary: String
    var scenarioID: String
    var applied: [StudioDataFix.Applied]
    /// Made by Studio on its own (REQ-020), not by the person's click.
    var automatic = false
    /// The page error the fix was for. Undoing it is the person's decision: Studio does not repair that error again by itself.
    var errorKey = ""
}

extension StudioDataFix {
    /// The page errors of a scenario, from every page generation, one per message, the latest first. A row of an earlier page still
    /// carries its action while the scenario is the same (a fix or a reload starts a new page, not a new scenario).
    static func latest(_ seen: [Seen], key: String) -> PageError? {
        for event in seen.reversed() where isFixable(kind: event.kind, detail: event.detail) && Self.key(of: event.detail) == key {
            return PageError(key: key, kind: event.kind, detail: event.detail, date: event.date)
        }
        return nil
    }

    /// The records of `seed` and of the scenario's own data with the corrections written back, field by field: the values that were
    /// there before `applied` made them. A record that is no longer there is left alone. Not checked on purpose: the old values are
    /// the ones the person had, even if they were what caused the error.
    static func revert(_ applied: [Applied], spec: StudioEnvironmentSpec, seed: [String: [StudioJSON]],
                       scenarioData: [String: [StudioJSON]]?) -> (seed: [String: [StudioJSON]], scenarioData: [String: [StudioJSON]]?) {
        var seed = seed
        var own = scenarioData
        for change in applied.reversed() {
            guard let entity = spec.entity(change.entity) else { continue }
            func write(_ records: inout [String: [StudioJSON]]?, _ enabled: Bool) {
                guard enabled, var list = records?[entity.name],
                      let index = list.firstIndex(where: { $0[entity.idField]?.identityKey == change.id }),
                      var record = list[index].objectValue else { return }
                record[change.field] = change.old
                list[index] = .object(record)
                records?[entity.name] = list
            }
            var seeded: [String: [StudioJSON]]? = seed
            write(&seeded, change.inSeed)
            seed = seeded ?? seed
            write(&own, change.inScenario)
        }
        return (seed, own)
    }
}
