import CoreGraphics
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif
/// The plan of a build: what the screens are, and the whole plan as JSON for the later runs.
struct PrototypePlan {
    var json: String
    var title: String
    var summary: String
    var assumptions: [String]
    /// Code mode: behaviour the prototype cannot reproduce and the plan components that have no source
    /// file. Any mode: the screens dropped past `maxScreens`.
    var gaps: [String]
    var screens: [PrototypeAI.PlannedScreen]
    /// Code mode: the original stylesheets the interface loads, project-relative and in import order; empty otherwise.
    var styles: [String]
    /// Code mode: the ids of the themes the original switches between and the one it starts with; empty otherwise.
    var themes: [String] = []
    var defaultTheme = ""

    static let maxScreens = 10
    /// A reconstruction of a window of docked widgets needs one entry per widget (BUG-050).
    static let maxCodeScreens = 40

    /// In `.code` mode the planner's gaps are kept and each screen's components are kept only when
    /// `sourceExists` finds their file, the others becoming gaps, so no link is invented (REQ-007). In
    /// `.requirements` mode there is no original to fall short of or link to: gaps and components the
    /// planner filled in anyway are dropped.
    init(structured: Any?, mode: PrototypeFiles.Mode = .requirements, sourceExists: (String) -> Bool = { _ in true }) throws {
        guard let object = structured as? [String: Any],
              let raw = object["screens"] as? [[String: Any]], !raw.isEmpty else {
            throw CLICompletion.Failure.invalidOutput(AssistantProviderRegistry.defaultTool, "the plan has no screens")
        }
        var seen = Set<String>()
        var screens: [PrototypeAI.PlannedScreen] = []
        var missing: [String] = []
        let limit = mode == .code ? Self.maxCodeScreens : Self.maxScreens
        var normalised = raw.prefix(limit).map { $0 }
        for (index, item) in normalised.enumerated() {
            let name = item["name"] as? String ?? "Screen \(index + 1)"
            var id = Self.slug(item["id"] as? String ?? name)
            if id.isEmpty { id = "screen-\(index + 1)" }
            var unique = id, n = 2
            while seen.contains(unique) { unique = "\(id)-\(n)"; n += 1 }
            seen.insert(unique)
            normalised[index]["id"] = unique
            let evidence = (item["evidence"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // Component paths are normalised here, so the screen writer marks exactly what the manifest records.
            var components: [String] = []
            if mode == .code {
                for raw in item["components"] as? [String] ?? [] {
                    guard let path = PrototypeFiles.componentPath(raw), !components.contains(path) else { continue }
                    if sourceExists(path) {
                        components.append(path)
                    } else if !missing.contains(path) {
                        missing.append(path)
                    }
                }
            }
            normalised[index]["components"] = components
            // Widgets and hosts exist in code mode only; a host's list is cut to the entries that exist, below.
            let embedded = mode == .code && item["embedded"] as? Bool == true
            normalised[index]["embedded"] = embedded
            screens.append(PrototypeAI.PlannedScreen(id: unique, name: name, route: item["route"] as? String ?? "/" + unique,
                                         purpose: item["purpose"] as? String ?? "", evidence: evidence, components: components,
                                         embedded: embedded, hosts: mode == .code ? (item["hosts"] as? [String] ?? []) : []))
        }
        let known = Set(screens.map(\.id))
        for index in screens.indices {
            var hosted: [String] = []
            for raw in screens[index].hosts {
                let id = Self.slug(raw)
                if known.contains(id), id != screens[index].id, !hosted.contains(id) { hosted.append(id) }
            }
            screens[index].hosts = hosted
            normalised[index]["hosts"] = hosted
        }
        // The planner's gaps belong to a reconstruction only; the writers see the same list as the manifest.
        let planned = mode == .code
            ? (object["gaps"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            : []
        var plan = object
        plan["screens"] = normalised
        plan["gaps"] = planned
        var listed: [String] = []
        if mode == .code {
            for raw in object["styles"] as? [String] ?? [] {
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, !listed.contains(path) { listed.append(path) }
            }
        }
        plan["styles"] = listed
        styles = listed
        var themeIDs: [String] = []
        if mode == .code {
            for raw in object["themes"] as? [String] ?? [] {
                let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty, !themeIDs.contains(id) { themeIDs.append(id) }
            }
        }
        themes = themeIDs
        defaultTheme = mode == .code ? (object["defaultTheme"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        plan["themes"] = themeIDs
        plan["defaultTheme"] = defaultTheme
        let data = try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys])
        json = String(decoding: data, as: UTF8.self)
        title = object["title"] as? String ?? "Prototype"
        summary = object["summary"] as? String ?? ""
        assumptions = object["assumptions"] as? [String] ?? []
        var gaps = planned + missing.map { "Component \($0) named by the plan was not found in the sources" }
        if raw.count > limit {
            // A plan past the cap is cut without asking; the reviewer must know what is missing.
            let dropped = raw.dropFirst(limit).enumerated().map { pair -> String in
                pair.element["name"] as? String ?? "screen \(limit + pair.offset + 1)"
            }
            gaps.append("The plan listed \(raw.count) screens and only the first \(limit) are built; not built: " +
                        dropped.joined(separator: ", ") + ".")
        }
        self.gaps = gaps
        self.screens = screens
    }

    /// Lowercase words joined by dashes: safe as the name of `screens/<id>.js`.
    static func slug(_ text: String) -> String {
        text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
            .split(separator: "-").prefix(5).joined(separator: "-")
    }
}
