import Foundation

/// A context change proposed by the UI Studio assistant (REQ-013, DEC-009): what the view shows — the simulated records,
/// the test user, per-rule overrides (error, empty, loading, latency), the route, restoration steps that open a dialog or
/// fill a form, the clock, locale, time zone and theme — never the source code. It is read from the edit plan's `context`
/// object, where records, the user and bodies arrive as JSON text so that the schema stays strict for every assistant;
/// `StudioContextValidator` checks it against the environment before a new scenario is derived from the current one.
struct StudioContextPlan: Equatable {
    var name = ""
    var description = ""
    /// The in-app path to load; empty keeps the current route.
    var route = ""
    /// Records by entity that replace those entities' baseline records; nil keeps every record.
    var data: [String: [StudioJSON]]? = nil
    /// Records by entity added to those entities' records ("add test packages to every category"); nil adds none.
    var addedData: [String: [StudioJSON]]? = nil
    /// The role's test user; nil keeps it.
    var user: StudioJSON? = nil
    /// The new scenario's overrides, all of them.
    var overrides: [StudioOverride] = []
    /// The new scenario's restoration steps, all of them, in order.
    var steps: [StudioStep] = []
    var testTime: Date? = nil
    /// Empty keeps the current one (also `timeZone`).
    var locale = ""
    var timeZone = ""
    var theme: StudioScenario.Theme? = nil
    /// What the assistant could not do; reported in the turn, never faked.
    var unsupported: [String] = []
    /// What could not be read from the answer: JSON text that is not JSON, an unknown step action, a date that is not ISO 8601.
    var parseProblems: [String] = []
}

extension StudioContextPlan {
    /// The plan in an edit plan's `context` object. Empty strings, zeros and `false` mean "not given".
    init(structured: Any?) {
        self.init()
        guard let object = structured as? [String: Any] else {
            parseProblems = ["The answer has no `context` object."]
            return
        }
        func text(_ value: Any?) -> String { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func number(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        name = text(object["name"])
        description = text(object["description"])
        route = text(object["route"])
        locale = text(object["locale"])
        timeZone = text(object["timeZone"])
        unsupported = ((object["unsupported"] as? [Any]) ?? []).map(text).filter { !$0.isEmpty }

        data = records(text(object["data"]), field: "data")
        addedData = records(text(object["addData"]), field: "addData")
        let userText = text(object["userJSON"])
        if !userText.isEmpty {
            if let value = StudioJSON(text: userText), value.objectValue != nil { user = value } else {
                parseProblems.append("`userJSON` is not JSON text of an object.")
            }
        }

        for (index, item) in ((object["overrides"] as? [Any]) ?? []).enumerated() {
            guard let item = item as? [String: Any] else {
                parseProblems.append("Override \(index + 1) is not an object.")
                continue
            }
            var override = StudioOverride()
            override.ruleId = text(item["ruleId"]).nonEmpty
            override.method = text(item["method"]).nonEmpty?.uppercased()
            override.path = text(item["path"]).nonEmpty
            override.status = number(item["status"]).flatMap { $0 == 0 ? nil : $0 }
            if let body = text(item["body"]).nonEmpty {
                if let json = StudioJSON(text: body) { override.body = json } else {
                    parseProblems.append("Override \(index + 1): `body` is not JSON text.")
                }
            }
            override.empty = item["empty"] as? Bool == true ? true : nil
            override.hang = item["hang"] as? Bool == true ? true : nil
            override.delayMs = number(item["delayMs"]).flatMap { $0 == 0 ? nil : $0 }
            overrides.append(override)
        }

        for (index, item) in ((object["steps"] as? [Any]) ?? []).enumerated() {
            guard let item = item as? [String: Any] else {
                parseProblems.append("Step \(index + 1) is not an object.")
                continue
            }
            let action = text(item["action"])
            guard let parsed = StudioStep.Action(rawValue: action) else {
                parseProblems.append("Step \(index + 1): unknown action \"\(action)\" (click, type, wait, navigate or press).")
                continue
            }
            // A typed or pressed text keeps its spaces.
            let typed = (item["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            steps.append(StudioStep(action: parsed, selector: text(item["selector"]).nonEmpty, text: typed,
                                    ms: number(item["ms"]).flatMap { $0 == 0 ? nil : $0 }))
        }

        let time = text(object["testTime"])
        if !time.isEmpty {
            if let date = Self.date(time) { testTime = date } else {
                parseProblems.append("`testTime` \"\(time)\" is not an ISO 8601 date and time.")
            }
        }
        let themeText = text(object["theme"])
        if !themeText.isEmpty {
            if let parsed = StudioScenario.Theme(rawValue: themeText) { theme = parsed } else {
                parseProblems.append("`theme` must be light, dark or empty, not \"\(themeText)\".")
            }
        }
    }

    /// Records by entity in JSON text of `{"<entity>": [records]}`; nil when the text is empty or not of that form (a
    /// parse problem then says why).
    private mutating func records(_ text: String, field: String) -> [String: [StudioJSON]]? {
        guard !text.isEmpty else { return nil }
        guard text.count <= StudioValidator.maxSize else {
            parseProblems.append("`\(field)` is too large (\(text.count) characters).")
            return nil
        }
        guard let groups = StudioJSON(text: text)?.objectValue else {
            parseProblems.append("`\(field)` is not JSON text of an object {\"<entity>\": [records]}.")
            return nil
        }
        var records: [String: [StudioJSON]] = [:]
        for (entity, value) in groups {
            guard let list = value.arrayValue else {
                parseProblems.append("`\(field)`.\(entity) is not an array of records.")
                continue
            }
            records[entity] = list
        }
        return records.isEmpty ? nil : records
    }

    /// The baseline records the plan leaves: `current` with the replaced entities' records, then the added records.
    func baseline(from current: [String: [StudioJSON]]) -> [String: [StudioJSON]] {
        var next = current
        for (name, list) in data ?? [:] { next[name] = list }
        for (name, list) in addedData ?? [:] { next[name, default: []] += list }
        return next
    }

    /// Whether the plan replaces or adds records.
    var changesRecords: Bool { !(data ?? [:]).isEmpty || !(addedData ?? [:]).isEmpty }

    /// The entities whose records the plan replaces or adds to.
    var recordEntities: Set<String> { Set((data ?? [:]).keys).union((addedData ?? [:]).keys) }

    /// An ISO 8601 date and time, with or without fractional seconds, or a date alone (midnight UTC).
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// An override in the plan's own form, for the prompt, so the assistant can copy the overrides that stay.
    static func planObject(_ override: StudioOverride) -> [String: Any] {
        ["ruleId": override.ruleId ?? "", "method": override.method ?? "", "path": override.path ?? "", "status": override.status ?? 0,
         "body": override.body?.text ?? "", "empty": override.empty ?? false, "hang": override.hang ?? false, "delayMs": override.delayMs ?? 0]
    }

    /// A restoration step in the plan's own form, for the prompt.
    static func planObject(_ step: StudioStep) -> [String: Any] {
        ["action": step.action.rawValue, "selector": step.selector ?? "", "text": step.text ?? "", "ms": step.ms ?? 0]
    }

    static func jsonLine(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// The checks of a context plan against the environment and the scenario it is derived from (REQ-013): records of the
/// environment's entities that pass its field checks (types, enumerations, references), overrides of rules that exist, and
/// steps that can be replayed. A plan with any problem is not applied at all, never half of it.
enum StudioContextValidator {
    static let maxSteps = 40, maxOverrides = 60, maxDelayMs = 60_000, maxWaitMs = 10_000, maxText = 2_000, maxUser = 20_000

    /// Everything wrong with `plan`; empty when it may be applied.
    static func problems(_ plan: StudioContextPlan, current: StudioScenario, spec: StudioEnvironmentSpec) -> [String] {
        var problems = plan.parseProblems
        if plan.changesRecords { problems += recordProblems(plan, current: current, spec: spec) }
        if let user = plan.user, user.text.count > maxUser { problems.append("The test user is too large (\(user.text.count) characters).") }
        problems += overrideProblems(plan.overrides, spec: spec)
        problems += stepProblems(plan.steps)
        if !plan.route.isEmpty, !isPath(plan.route) {
            problems.append("The route \"\(plan.route)\" is not an in-app path such as /bookings.")
        }
        if !plan.locale.isEmpty, plan.locale.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$"#, options: .regularExpression) == nil {
            problems.append("The locale \"\(plan.locale)\" is not a language tag such as de-DE.")
        }
        if !plan.timeZone.isEmpty, TimeZone(identifier: plan.timeZone) == nil {
            problems.append("The time zone \"\(plan.timeZone)\" is not a time zone identifier such as Europe/Berlin.")
        }
        return problems
    }

    /// Records must be of the environment's entities and pass its checks against the baseline they will form, with every id
    /// used once (added records next to the kept ones too); records the plan keeps must not be left pointing at replaced
    /// records that are gone.
    static func recordProblems(_ plan: StudioContextPlan, current: StudioScenario, spec: StudioEnvironmentSpec) -> [String] {
        var problems: [String] = []
        let baseline = current.data ?? spec.seed
        let next = plan.baseline(from: baseline)
        let count = next.values.reduce(0) { $0 + $1.count }
        if count > StudioValidator.maxRecords { problems.append("Too many records (\(count) > \(StudioValidator.maxRecords)).") }
        let known = spec.entities.map(\.name).sorted()
        let changed = plan.recordEntities
        for name in changed.sorted() {
            guard let entity = spec.entity(name) else {
                problems.append("Records for the unknown entity \(name); the environment's entities are "
                                + (known.isEmpty ? "none" : known.joined(separator: ", ")) + ".")
                continue
            }
            // Only the records the plan brings are checked; kept records of the entity were valid before.
            let brought = (plan.data?[name] ?? []) + (plan.addedData?[name] ?? [])
            for record in brought { problems += StudioValidator.problems(record: record, entity: entity, state: next, spec: spec) }
            var ids = Set<String>()
            for record in next[name] ?? [] {
                if let key = record[entity.idField]?.identityKey, !ids.insert(key).inserted { problems.append("\(name): id \(key) is used twice") }
            }
        }
        let replaced = Set((plan.data ?? [:]).keys)
        for entity in spec.entities where !replaced.contains(entity.name)
            && entity.fields.contains(where: { $0.references.map(replaced.contains) ?? false }) {
            let before = Set((baseline[entity.name] ?? []).flatMap { StudioValidator.problems(record: $0, entity: entity, state: baseline, spec: spec) })
            for record in next[entity.name] ?? [] {
                problems += StudioValidator.problems(record: record, entity: entity, state: next, spec: spec).filter { !before.contains($0) }
            }
        }
        return problems
    }

    /// An override names a rule that exists, once, and changes its answer.
    static func overrideProblems(_ overrides: [StudioOverride], spec: StudioEnvironmentSpec) -> [String] {
        var problems: [String] = []
        if overrides.count > maxOverrides { problems.append("Too many overrides (\(overrides.count) > \(maxOverrides)).") }
        let ruleList = spec.rules.prefix(20).map(\.id).joined(separator: ", ") + (spec.rules.count > 20 ? ", …" : "")
        var seen = Set<String>()
        for (index, override) in overrides.enumerated() {
            let label = "Override \(index + 1)"
            var rule: StudioRule?
            if let id = override.ruleId {
                rule = spec.rules.first { $0.id == id }
                if rule == nil { problems.append("\(label) names the rule \(id), which does not exist (rules: \(ruleList.isEmpty ? "none" : ruleList)).") }
            } else if let method = override.method, let path = override.path {
                rule = spec.rules.first { $0.method.uppercased() == method.uppercased() && $0.path == path }
                if rule == nil { problems.append("\(label) names \(method) \(path), which no rule serves (rules: \(ruleList.isEmpty ? "none" : ruleList)).") }
            } else {
                problems.append("\(label) names no rule: give its ruleId, or its method and path.")
            }
            if let rule, !seen.insert(rule.id).inserted { problems.append("\(label): the rule \(rule.id) has two overrides.") }
            if let status = override.status, !(100...599).contains(status) { problems.append("\(label): \(status) is not an HTTP status.") }
            if override.body != nil, override.status == nil { problems.append("\(label): a body needs a status.") }
            if let rule, let body = override.body, let status = override.status, (200..<300).contains(status) {
                problems += shapeProblems(body, rule: rule, label: label)
            }
            if let delay = override.delayMs, !(0...maxDelayMs).contains(delay) {
                problems.append("\(label): delayMs must be between 0 and \(maxDelayMs).")
            }
            if override.status == nil, override.body == nil, override.empty != true, override.hang != true, (override.delayMs ?? 0) == 0 {
                problems.append("\(label) changes nothing: give a status, empty, hang or delayMs.")
            }
        }
        return problems
    }

    /// A new successful body of a fixed-answer rule keeps the shape of the rule's answer (BUG-084): the same kind of value,
    /// and for an object every key the answer has, so the page finds what it reads. Values and list lengths may change.
    static func shapeProblems(_ body: StudioJSON, rule: StudioRule, label: String) -> [String] {
        guard rule.operation == .respond, let current = rule.response?.body,
              (200..<300).contains(rule.response?.status ?? 200) else { return [] }
        switch (current, body) {
        case (.object(let answer), .object(let new)):
            let missing = answer.keys.filter { new[$0] == nil }.sorted()
            guard !missing.isEmpty else { return [] }
            return ["\(label): the body of \(rule.id) leaves out keys of its current answer (\(missing.joined(separator: ", "))). "
                    + "Keep every key and change the values."]
        case (.object, _):
            return ["\(label): the body of \(rule.id) must be a JSON object, like its current answer."]
        case (.array, .array):
            return []
        case (.array, _):
            return ["\(label): the body of \(rule.id) must be a JSON list, like its current answer."]
        default:
            return []
        }
    }

    /// A step that acts on an element names it; a wait is bounded; a navigation stays in the application.
    static func stepProblems(_ steps: [StudioStep]) -> [String] {
        var problems: [String] = []
        if steps.count > maxSteps { problems.append("Too many steps (\(steps.count) > \(maxSteps)).") }
        for (index, step) in steps.enumerated() {
            let label = "Step \(index + 1) (\(step.action.rawValue))"
            if let text = step.text, text.count > maxText { problems.append("\(label): the text is too long.") }
            switch step.action {
            case .click, .type, .press:
                guard let selector = step.selector else {
                    problems.append("\(label) needs the CSS selector of an element.")
                    continue
                }
                if selector.count > 500 || selector.contains(where: \.isNewline) { problems.append("\(label): \"\(selector.prefix(80))\" is not a CSS selector.") }
            case .wait:
                if !(1...maxWaitMs).contains(step.ms ?? 0) { problems.append("\(label) needs ms between 1 and \(maxWaitMs).") }
            case .navigate:
                if !isPath(step.text ?? "") { problems.append("\(label) needs an in-app path such as /bookings in `text`.") }
            }
        }
        return problems
    }

    /// A path of the application: it starts with one slash and has no spaces or control characters.
    static func isPath(_ text: String) -> Bool {
        text.hasPrefix("/") && !text.hasPrefix("//") && text.count <= 2_000
            && !text.contains(where: { $0.isWhitespace || $0 == "\\" || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } })
    }

    /// What the plan cannot show although it is valid: records of an entity that no rule serves never reach the page.
    static func notes(_ plan: StudioContextPlan, spec: StudioEnvironmentSpec) -> [String] {
        plan.recordEntities.sorted().compactMap { name in
            guard spec.entity(name) != nil else { return nil }
            let served = spec.rules.contains { $0.entity == name || ($0.include ?? []).contains { $0.entity == name } }
            return served ? nil : "\(name): no simulation rule serves these records yet, so the page does not show them."
        }
    }

    /// The new scenario derived from `current`: a new id and a unique name, kind custom, the request as its description, and
    /// the plan's records (replacing those entities only), user, overrides, route, steps, clock, locale, time zone and theme.
    static func scenario(_ plan: StudioContextPlan, from current: StudioScenario, spec: StudioEnvironmentSpec, request: String,
                         taken: [StudioScenario], now: Date = Date()) -> StudioScenario {
        var next = current
        let unique = uniqueName(plan.name.isEmpty ? request : plan.name, taken: taken)
        next.id = unique.id
        next.name = unique.name
        next.kind = .custom
        next.description = String(request.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        next.revision = 1
        next.updated = now
        if plan.changesRecords { next.data = plan.baseline(from: current.data ?? spec.seed) }
        if let user = plan.user { next.role.user = user }
        next.overrides = plan.overrides
        if !plan.route.isEmpty { next.route = plan.route }
        next.steps = plan.steps
        if let time = plan.testTime { next.testTime = time }
        if !plan.locale.isEmpty { next.locale = plan.locale }
        if !plan.timeZone.isEmpty { next.timeZone = plan.timeZone }
        if let theme = plan.theme { next.theme = theme }
        next.contractFingerprint = StudioScenarioCompatibility.fingerprint(next, spec: spec)
        return next
    }

    /// A name no other scenario has, and its file id; never a built-in id.
    static func uniqueName(_ wanted: String, taken: [StudioScenario]) -> (name: String, id: String) {
        let line = wanted.split(whereSeparator: \.isNewline).first.map(String.init) ?? wanted
        var base = String(line.trimmingCharacters(in: .whitespaces).prefix(48)).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Scenario" }
        let names = Set(taken.map { $0.name.lowercased() }), ids = Set(taken.map(\.id))
        func id(_ name: String) -> String {
            let slug = StudioStore.safeID(name)
            return slug.hasPrefix("builtin") ? "scenario-" + slug : slug
        }
        var name = base
        var number = 2
        while names.contains(name.lowercased()) || ids.contains(id(name)) {
            name = "\(base) \(number)"
            number += 1
            if number > 999 {
                name = "\(base) \(UUID().uuidString.prefix(6).lowercased())"
                break
            }
        }
        return (name, id(name))
    }

    /// What changed from `previous` to `next`, in words, with what could not be done.
    static func change(from previous: StudioScenario, to next: StudioScenario, spec: StudioEnvironmentSpec,
                       unsupported: [String]) -> StudioContextChange {
        var change = StudioContextChange(previousScenarioId: previous.id, previousScenarioName: previous.name, previous: previous,
                                         scenarioId: next.id, scenarioName: next.name)
        let before = previous.data ?? spec.seed, after = next.data ?? spec.seed
        for name in Set(before.keys).union(after.keys) where before[name] != after[name] {
            change.records[name] = after[name]?.count ?? 0
            change.recordsBefore[name] = before[name]?.count ?? 0
        }
        if next.overrides != previous.overrides { change.overrides = next.overrides.map(describe) }
        if next.route != previous.route { change.route = next.route }
        if next.steps != previous.steps { change.steps = next.steps.map(describe) }
        if next.role.user != previous.role.user {
            let user = next.role.user
            let label = [user["name"], user["email"], user["id"]].compactMap { $0?.identityKey }.first ?? "changed"
            change.other.append("Test user: \(label)")
        }
        if next.testTime != previous.testTime { change.other.append("Clock: " + ISO8601DateFormatter().string(from: next.testTime)) }
        if next.locale != previous.locale { change.other.append("Locale: \(next.locale)") }
        if next.timeZone != previous.timeZone { change.other.append("Time zone: \(next.timeZone ?? "the Mac's")") }
        if next.theme != previous.theme { change.other.append("Theme: \(next.theme.rawValue)") }
        change.unsupported = unsupported
        return change
    }

    static func describe(_ override: StudioOverride) -> String {
        let rule = override.ruleId ?? [override.method, override.path].compactMap { $0 }.joined(separator: " ")
        var parts: [String] = []
        if override.hang == true { parts.append("never answers (loading)") }
        if let status = override.status { parts.append("status \(status)") }
        if override.body != nil { parts.append("a new answer") }
        if override.empty == true { parts.append("empty") }
        if let delay = override.delayMs, delay > 0 { parts.append("after \(delay) ms") }
        return rule + ": " + parts.joined(separator: ", ")
    }

    static func describe(_ step: StudioStep) -> String {
        switch step.action {
        case .click: return "click \(step.selector ?? "?")"
        case .type: return "type \"\(step.text ?? "")\" into \(step.selector ?? "?")"
        case .press: return "press \(step.text ?? "Enter") in \(step.selector ?? "?")"
        case .wait: return "wait \(step.ms ?? 0) ms"
        case .navigate: return "navigate to \(step.text ?? "/")"
        }
    }

    /// Whether the project's sources are the same in both snapshots. MarkView's own `.markview/studio/` and `.dde/studio/`
    /// files do not count: a context change is saved there, and rules prepared and captures taken meanwhile are kept there.
    static func sameSources(_ a: StudioWorkingSnapshot, _ b: StudioWorkingSnapshot) -> Bool {
        func sources(_ snapshot: StudioWorkingSnapshot) -> [String: String?] {
            snapshot.files.filter { !$0.key.hasPrefix(".markview/studio/") && !$0.key.hasPrefix(".dde/studio/") }
        }
        return a.head == b.head && sources(a) == sources(b) && a.editorBuffers == b.editorBuffers
    }
}
