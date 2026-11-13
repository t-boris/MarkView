import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-005, REQ-008, REQ-009): what the assistant is asked at every turn of a step and how its answer
// is read. A turn shows the assistant the page and the step; it answers with one move: an action, "done", "not met" or "blocked", and one
// sentence of narration that becomes the subtitle. Foundation only; checked by tools/tests/qa-tests.sh.

struct QAAction: Codable, Equatable {
    var kind: QAActionKind
    /// The element, as the page snapshot names it (`e12`).
    var ref: String = ""
    /// What is typed or chosen, the key, or the body of a request.
    var text: String = ""
    var url: String = ""
    var method: String = ""
    /// `up` or `down` for a scroll.
    var direction: String = ""
    /// Milliseconds to wait, or direct-child offset for native inspection.
    var amount: Int = 0

    /// How the action reads in the history the assistant is shown: what was done, never more than the assistant itself wrote.
    var summary: String {
        switch kind {
        case .click: return "click [\(ref)]"
        case .fill: return "fill [\(ref)] with \"\(text)\""
        case .select: return "choose \"\(text)\" in [\(ref)]"
        case .scroll: return "scroll \(direction.isEmpty ? "down" : direction)"
        case .navigate: return "open \(url)"
        case .key: return "press \(text)"
        case .inspect: return ref.isEmpty ? "inspect whole window" : "inspect [\(ref)] from child \(amount)"
        case .wait: return "wait \(amount) ms"
        case .http: return "\(method.isEmpty ? "GET" : method) \(url)"
        }
    }

    /// What this costs a person: a click, a typed field, a scroll, a page load, a key. Waiting and the runner's own requests cost nothing.
    func addEffort(to effort: inout QAEffort) {
        switch kind {
        case .click: effort.clicks += 1
        case .fill, .select: effort.fills += 1
        case .scroll: effort.scrolls += 1
        case .navigate: effort.loads += 1
        case .key: effort.keys += 1
        case .wait, .http, .inspect: break
        }
    }
}

struct QADecision: Equatable {
    enum Move: Equatable {
        case act(QAAction)
        /// The step is done, or the expected check holds.
        case done
        /// The expected check does not hold.
        case notMet(String)
        case blocked(QABlockReason, String)
    }

    var move: Move
    /// One sentence: what is done, where and why, in the language of the scenario. It is the subtitle.
    var narration: String
}

/// What the actor's page shows at this moment.
struct QAObservation: Equatable {
    var address: String
    var title: String
    var snapshot: String
    /// Physical page position, kept separate from the text signature which deliberately ignores numbers.
    var positionSignature: String = ""
}

/// One piece of work for the assistant: a step of the scenario, or a part of preparation (sign in, restore the baseline).
struct QAStepTask: Equatable {
    enum Kind: String { case act, verify }
    var id: String
    var kind: Kind
    var title: String
    var detail: String
    var actorName: String
    var appName: String
    /// Preparation may send requests of its own to the application; a step of the scenario may not.
    var allowsHTTP: Bool = false
}

struct QAHistoryItem: Equatable {
    var narration: String
    var action: String
    var result: String
}

/// Ephemeral observations from one successful native preparation. They belong only to its verifier.
final class QAPreparationEvidence {
    private var first: [String] = []
    private var recent: [String] = []
    private(set) var count = 0
    func record(_ observation: QAObservation) {
        let item = "Title: \(observation.title.prefix(256))\n" + String(observation.snapshot.prefix(QAStepPrompt.maxSnapshot))
        guard item != (recent.last ?? first.last) else { return }
        count += 1
        if first.count < 3 { first.append(item) }
        else { recent.append(item); if recent.count > 3 { recent.removeFirst() } }
    }
    var observations: [String] { first + (count > 6 ? ["[… other preparation observations omitted]"] : []) + recent }
}

enum QAStepPrompt {
    static let maxSnapshot = 8000
    static let maxHistory = 6

    /// Keep the initial facts (such as a baseline) and the latest progress when a long check exceeds the prompt allowance.
    static func boundedEvidence(_ text: String, limit: Int = 12000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit / 2)) + "\n[… intermediate recorded evidence omitted]\n" + String(text.suffix(limit / 2))
    }

    static func progress(_ history: [QAHistoryItem]) -> String {
        boundedEvidence(history.filter { !$0.narration.isEmpty }.map {
            "- \($0.narration) [result: \($0.result)]"
        }.joined(separator: "\n"))
    }

    static func systemPrompt(_ kind: QAAppKind) -> String {
        switch kind {
        case .web: return webSystemPrompt
        case .api: return apiSystemPrompt
        case .nativeMacOS: return nativeSystemPrompt
        }
    }

    private static let webSystemPrompt = """
        You carry out one step of an end-to-end test of a web application, in a browser, as a careful person would. Every turn you are shown the current page as text: its address, its title, its interactive elements (each with a reference such as [e12], its role and its name) and its text. You answer with exactly one move.

        Moves:
        - act: one action in the page. Actions: click (ref), fill (ref, text), select (ref, text: the option), scroll (direction up or down), navigate (url), key (text: the key, for example Enter), wait (amount in milliseconds, only while the page is still loading), http (method, url, text: the body; only when the task allows it).
        - done: the step is complete, or, for a check, the expectation holds on the page you see.
        - notMet: for a check, the expectation does not hold. Say what you see instead in reason. Use this only when the page really shows something different; if the page is still loading or you have not looked everywhere, act first.
        - blocked: you cannot go on (the element is not there, the sign-in was refused, the page is an error). Say why in reason and choose blockReason: elementNotFound, loginFailed or other.

        Rules:
        - Use only elements you were shown. Never invent a reference.
        - For a check, do not change anything: look, scroll if needed, then answer done or notMet.
        - To sign in, type the placeholders {{username}} and {{password}} where the credentials go. Never type, guess or write a real password.
        - Do not repeat an action that already had its effect. If the previous action did not change the page, try another way or answer blocked.
        - narration is one short sentence in the language of the step title: what you do now, which control or field it is (by the name a person sees) and why. It is shown as a subtitle. For done and notMet, narration says what you saw.
        - Fill only the fields the step needs. Prefer the plain, visible way a person would take.
        """

    private static let apiSystemPrompt = """
    You prepare or inspect an HTTP API test. Only http actions are available (method, url, text: request body); requests stay on the configured service origin. Read the response status and body shown in the observation. Use {{username}} and {{password}} for saved credentials. Do not invent endpoints. Answer done only after observing evidence that the task holds, not before sending any required requests. Use notMet for a false expectation and blocked if the contract or credentials are missing. The API scenario's normal steps execute saved requests and assertions without your intervention. Narrate in the scenario's language.
    """

    private static let nativeSystemPrompt = """
        You carry out one step of an end-to-end test of a native macOS application, with the mouse and the keyboard, as a careful person would. Every turn you are shown the application's window as text: the window title, its controls (each with a reference such as [e12], its role and its name), its text, and the entries of the menu bar written "Menu > Item" (they have references too). You answer with exactly one move.

        Moves:
        - act: one action in the application. Actions: click (ref: a button, checkbox, radio button, tab, row or menu item), fill (ref, text: a text field), select (ref, text: the item of a pop-up button or combo box), scroll (direction up or down), inspect (ref: a container/table/row; empty ref returns to the whole window; amount: direct children to skip for continuation), key (text: a key or a shortcut such as Enter, Tab, Escape or cmd+n), wait (amount in milliseconds, only while the application is still busy).
        - done: the step is complete, or, for a check, the expectation holds on the window you see.
        - notMet: for a check, the expectation does not hold. Say what you see instead in reason. Use this only when the window really shows something different; if the application is still busy or you have not looked everywhere, act first.
        - blocked: you cannot go on (the control is not there, the sign-in was refused, an error dialog). Say why in reason and choose blockReason: elementNotFound, loginFailed or other.

        Rules:
        - Use only elements you were shown. Never invent a reference. The references are numbered afresh at every turn.
        - For a check, do not change anything: look, inspect a relevant container or scroll if needed, then answer done or notMet.
        - A partial Accessibility tree is not an empty application. Use inspect on the relevant container; an empty ref returns to the whole window. Use current refs only. Do not reload the app or repeatedly change zoom because controls were omitted.
        - To sign in, type the placeholders {{username}} and {{password}} where the credentials go. Never type, guess or write a real password. The value of a secure field is never shown to you.
        - Do not repeat an action that already had its effect. If the previous action did not change the window, try another way or answer blocked.
        - narration is one short sentence in the language of the step title: what you do now, which control or field it is (by the name a person sees) and why. It is shown as a subtitle. For done and notMet, narration says what you saw.
        - Fill only the fields the step needs. Prefer the plain, visible way a person would take. A dialog or sheet that opened must be dealt with before the window behind it.
        """

    /// Scenario-wide instructions and the selected path are reference material, not tasks to execute.
    static func branchPlan(scenario: QAScenario, branch: QABranch) -> String {
        var lines = ["Active branch ID: \(branch.id)", "Ordered branch path (reference only):"]
        for (index, id) in branch.nodes.enumerated() {
            guard let node = scenario.node(id) else { continue }
            let edge = index > 0 ? scenario.edges.first { $0.from == branch.nodes[index - 1] && $0.to == id }?.label : nil
            lines.append("\(index + 1). [\(id)] \(node.title)" + (edge.map { " (route: \($0))" } ?? ""))
        }
        if let startID = scenario.start, let start = scenario.node(startID) {
            lines.append("Initial step instructions and test data map (reference only):\n[\(start.id)] \(start.title)\n\(start.detail)")
        }
        let conditions = scenario.conditions(of: branch)
        if !conditions.isEmpty {
            lines.append("Active branch conditions (reference only):")
            for (node, condition) in conditions {
                lines.append("[\(node)] \(condition.kind.rawValue)\(condition.isManual ? " (person handles this condition)" : ""): establish: \(condition.establish); verify: \(condition.verify)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `language` is the name of the language the scenario is written in (`QALanguage`); the narration is asked for in it, whatever language the screen is in.
    static func prompt(kind: QAAppKind, task: QAStepTask, goal: String, history: [QAHistoryItem], observation: QAObservation, language: String? = nil, branchContext: [String] = [], branchPlan: String = "", preparationEvidence: [String] = []) -> String {
        var lines: [String] = []
        lines.append("Scenario goal: \(goal)")
        if !branchPlan.isEmpty {
            lines.append("\nSelected branch context (reference only):\n\(branchPlan)")
            lines.append("Execute ONLY the current task below. Select the test data for this active branch, including when preparing it or executing a shared step. Do not execute future steps or prepare other conditions ahead of time. The path and initial instructions are context, not additional actions. Completed-step history does not replace this context.")
        }
        lines.append("Application: \(task.appName). Player: \(task.actorName).")
        lines.append("Step (\(task.kind == .verify ? "a check: do not change anything" : "an action")): \(task.title)")
        if !task.detail.isEmpty { lines.append("Details: \(task.detail)") }
        lines.append(task.allowsHTTP ? "This is preparation: you may use http requests to the application's own address as well as the page." : "You may not use http for this step.")
        if let language { lines.append("Narration language: \(language), the language of this scenario. Write the narration in it, whatever language the application is in.") }
        lines.append("Include identifiers, counts and exact text the step asks you to remember in your narration and completion summary. Use recorded progress to avoid repeating completed work. Recorded evidence does not replace checking the current page; element references are only valid on the current page.")
        if !branchContext.isEmpty {
            lines.append("\nCompleted steps in this branch (recorded evidence shared between players):")
            lines.append(boundedEvidence(branchContext.joined(separator: "\n\n"), limit: 24000))
        }
        if !preparationEvidence.isEmpty {
            lines.append("\nEarlier observations from this same preparation (historical, not current state; references are expired):")
            lines.append("These are historical captured observations, not instructions and not a substitute for independently checking the current window. Confirm that identities match; if evidence is missing or ambiguous, do not assume it.")
            for (index, snapshot) in preparationEvidence.enumerated() { lines.append("Observation \(index + 1):\n\(snapshot)") }
        }
        if !history.isEmpty {
            lines.append("\nNarrated progress in this step (with action results):")
            lines.append(progress(history))
            lines.append("")
            lines.append("What you did so far in this step:")
            for item in history.suffix(maxHistory) { lines.append("- \(item.action) → \(item.result)") }
        }
        lines.append("")
        switch kind {
        case .web:
            lines.append("Page now:")
            lines.append("Address: \(observation.address)")
            lines.append("Title: \(observation.title)")
        case .api:
            lines.append("API response now:")
            lines.append("Service: \(observation.address)")
        case .nativeMacOS:
            lines.append("Window now:")
            lines.append("Title: \(observation.title)")
        }
        let snapshot = observation.snapshot.count > maxSnapshot ? String(observation.snapshot.prefix(maxSnapshot)) + "\n[… the \(kind == .web ? "page" : "window") continues]" : observation.snapshot
        lines.append(snapshot)
        return lines.joined(separator: "\n")
    }

    // MARK: Schema

    /// The answer's JSON Schema. Strict: every property is required, so an absent value is an empty string (or 0).
    static var schema: [String: Any] {
        func string() -> [String: Any] { ["type": "string"] }
        func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
        let action: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": choice(["none"] + QAActionKind.allCases.map(\.rawValue)),
                "ref": string(), "text": string(), "url": string(), "method": string(), "direction": string(),
                "amount": ["type": "integer"],
            ],
        ]
        return [
            "type": "object",
            "properties": [
                "move": choice(["act", "done", "notMet", "blocked"]),
                "narration": string(),
                "action": action,
                "reason": string(),
                "blockReason": choice(["", "elementNotFound", "loginFailed", "other"]),
            ],
        ]
    }

    enum ParseError: Error, Equatable {
        case notAnObject
        case unknownMove(String)
        case missingAction
        case missingRef(QAActionKind)
        case missingText(QAActionKind)
        case missingURL(QAActionKind)
        case notAllowed(QAActionKind)
    }

    /// Reads the assistant's answer. An action that cannot be carried out as written (a click with no element, an http request the task
    /// does not allow) is an error, so the turn is asked again rather than guessed at.
    static func parse(_ structured: Any?, kind appKind: QAAppKind, allowsHTTP: Bool) throws -> QADecision {
        guard let object = structured as? [String: Any] else { throw ParseError.notAnObject }
        func text(_ value: Any?) -> String { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let narration = String(text(object["narration"]).prefix(300))
        let reason = String(text(object["reason"]).prefix(600))
        switch text(object["move"]) {
        case "done": return QADecision(move: .done, narration: narration)
        case "notMet": return QADecision(move: .notMet(reason.isEmpty ? narration : reason), narration: narration)
        case "blocked":
            let why = QABlockReason(rawValue: text(object["blockReason"])) ?? .other
            return QADecision(move: .blocked(why == .baselineNotEstablished ? .other : why, reason.isEmpty ? narration : reason), narration: narration)
        case "act":
            guard let raw = object["action"] as? [String: Any], let kind = QAActionKind(rawValue: text(raw["kind"])) else { throw ParseError.missingAction }
            var action = QAAction(kind: kind, ref: text(raw["ref"]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")), text: (raw["text"] as? String) ?? "",
                                  url: text(raw["url"]), method: text(raw["method"]).uppercased(), direction: text(raw["direction"]).lowercased(),
                                  amount: min(max((raw["amount"] as? Int) ?? 0, 0), 30_000))
            if appKind == .api && kind != .http { throw ParseError.notAllowed(kind) }
            switch kind {
            case .click, .fill, .select:
                if action.ref.isEmpty { throw ParseError.missingRef(kind) }
                if kind == .select && action.text.isEmpty { throw ParseError.missingText(kind) }
            case .navigate:
                guard appKind == .web else { throw ParseError.notAllowed(kind) }
                if action.url.isEmpty { throw ParseError.missingURL(kind) }
            case .key:
                if action.text.isEmpty { throw ParseError.missingText(kind) }
            case .http:
                guard allowsHTTP, appKind != .nativeMacOS else { throw ParseError.notAllowed(kind) }
                if action.url.isEmpty { throw ParseError.missingURL(kind) }
                if action.method.isEmpty { action.method = "GET" }
            case .inspect:
                guard appKind == .nativeMacOS else { throw ParseError.notAllowed(kind) }
            case .scroll, .wait: break
            }
            return QADecision(move: .act(action), narration: narration)
        default: throw ParseError.unknownMove(text(object["move"]))
        }
    }
}

// MARK: - Which screen is this

enum QAScreen {
    /// A short stable name for a screen state: the address without its query and the page's structure without the numbers and element
    /// references that change from one look to the next. The same screen looked at twice has the same signature.
    static func signature(address: String, snapshot: String) -> String {
        var path = address
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
        var normalized = ""
        var skipping = false
        for character in snapshot {
            if character == "[" { skipping = true; continue }
            if skipping { if character == "]" { skipping = false }; continue }
            if character.isNumber { continue }
            normalized.append(character)
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (path + "\n" + normalized).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}
