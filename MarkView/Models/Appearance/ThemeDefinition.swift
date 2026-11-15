import Foundation

// A theme as data (architecture review AR-32, DEC-001, DEC-003): one JSON file per theme, either bundled in `Resources/Themes/` or placed
// by a person in `~/Library/Application Support/MarkView/themes/`. This file holds the value a file becomes (`ThemeDefinition`), the rules a
// file must satisfy, and the derivation of everything a file leaves out. Foundation only, so `tools/tests/theme-model-tests.sh` compiles it
// without the app. Loading from folders is `ThemeLibrary` (ThemeCatalog.swift).
//
// The file format (schema 1). Only `schema`, `id`, `name` and four native colours are required; the rest is derived:
//
//   {
//     "schema": 1,
//     "id": "nord",                       // lower-case letters, digits and hyphens; equals the file name without ".json"
//     "name": "Nord", "summary": "Arctic blue-grey with frost cyan",
//     "order": 70,                        // position in the picker (built-ins 10...100; the default 1000 lists after them)
//     "picker": "listed",                 // or "whileActive": shown in the picker only while it is the window's theme
//     "native": {                         // colours the native views draw with, "#RRGGBB"
//       "bg", "bgSidebar", "text", "accent"            required
//       "bgInput", "bgHover", "bgActive", "bgBanner", "textDim", "textBright", "border",
//       "green", "orange", "yellow", "purple", "red", "cyan"   optional, derived from the required four
//       "selection", "badge", "accentText"             optional: used while the accent is the theme's own, derived from the accent otherwise
//     },
//     "web": {                            // optional: tokens of the web pages (editor, discussion, terminal); derived from "native"
//       "t": {...}, "syn": {...}, "struct": {...}, "term": {...},   // allow-listed keys, "#RRGGBB" values
//       "chart": [8 colours], "mermaid": "tokens" | "builtin",
//       "vars", "ownAccentVars"           // exact CSS custom properties: built-in themes only (a user file with them is ignored)
//     }
//   }
//
// Whether a theme is dark follows from its background (`isDark`). Nothing in a file is CSS text: keys come from fixed lists and every
// value is parsed as a colour (the built-in `vars` as a colour, a shadow of colours or a number) and written back from the parsed value.

// MARK: - Problems

/// Why a theme file cannot be used; shown to the person, so it names the file's own words.
struct ThemeProblem: Error, Equatable, Sendable {
    let reason: String
}

// MARK: - Definition

struct ThemeDefinition: Equatable, Sendable {
    static let currentSchema = 1
    /// A user file larger than this is not read.
    static let maxFileSize = 65_536
    /// The least contrast of body text on every surface, and of the accent on the window background.
    static let textContrast = 4.5
    static let accentContrast = 3.0

    enum Source: Equatable, Sendable { case builtIn, user(file: String) }
    enum Picker: String, Sendable { case listed, whileActive }

    /// The colours native views draw with. Optional members are the ones a theme may pin; see the format above.
    struct Native: Equatable, Sendable {
        var bg, bgSidebar, bgInput, bgHover, bgActive, bgBanner: ThemeColor
        var text, textDim, textBright, border: ThemeColor
        var accent: ThemeColor
        var green, orange, yellow, purple, red, cyan: ThemeColor
        var selection, badge, accentText: ThemeColor?
    }

    /// What the web pages get. Every token group is complete (a file's own values win, derivation fills the rest), except `term`, whose
    /// background, foreground, cursor and selection follow the accent and are worked out by the page.
    struct Web: Equatable, Sendable {
        var t, syn, structure, term: [String: ThemeColor]
        /// Exact custom properties of a look that must stay value for value (the Classic themes), and the ones that follow the accent.
        var vars, ownAccentVars: [String: String]
        var chart: [ThemeColor]?
        var mermaidBuiltIn: Bool
    }

    let id: String
    let name: String
    let summary: String
    let order: Int
    let picker: Picker
    let source: Source
    let native: Native
    let web: Web
    /// The definition as the pages receive it: JSON with colours as lower-case `#rrggbb`.
    let webPayload: String

    var isDark: Bool { Self.isDark(background: native.bg) }

    /// Dark when white text reads better on the background than black text.
    static func isDark(background: ThemeColor) -> Bool { background.readableText.rgb == 0xFFFFFF }
}

// MARK: - The format

enum ThemeSchema {
    static let nativeRequired = ["bg", "bgSidebar", "text", "accent"]
    static let nativeDerived = ["bgInput", "bgHover", "bgActive", "bgBanner", "textDim", "textBright", "border",
                                "green", "orange", "yellow", "purple", "red", "cyan"]
    static let nativePinned = ["selection", "badge", "accentText"]
    static let nativeKeys = Set(nativeRequired + nativeDerived + nativePinned)

    /// The token groups of `web` and the keys each may carry.
    static let groups: [String: [String]] = [
        "t": ["tertiary", "textSecondary", "textTertiary", "border", "borderLight", "secondary", "danger", "success", "warning", "hover",
              "h2", "h3", "codeBg", "preBg", "preBorder", "preText"],
        "syn": ["comment", "punct", "property", "number", "string", "operator", "func", "keyword", "regex"],
        "struct": ["key", "string", "number", "boolean", "null", "bracket", "tag", "attrName", "attrValue", "comment", "count"],
        "term": ["background", "foreground", "cursor", "selectionBackground", "black", "red", "green", "yellow", "blue", "magenta", "cyan",
                 "white", "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"],
    ]
    static let webKeys: Set<String> = ["t", "syn", "struct", "term", "chart", "mermaid", "vars", "ownAccentVars"]
    static let chartCount = 8
    static let topKeys: Set<String> = ["schema", "id", "name", "summary", "order", "picker", "native", "web"]
    static let maxNameLength = 40
    static let maxSummaryLength = 80

    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil && id.count <= 40
    }
}

extension ThemeDefinition {
    /// The theme a file holds. `id` is the file name without `.json`; a file whose own id differs is rejected, so a copy under another
    /// name is a mistake that is reported, not a second theme with a stale id. `allowsExactVars` is true for the bundled themes only.
    static func parse(_ data: Data, id: String, source: Source) -> Result<ThemeDefinition, ThemeProblem> {
        let builtIn = source == .builtIn
        guard data.count <= maxFileSize else { return fail("the file is larger than \(maxFileSize / 1024) KB") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return fail("the file is not a JSON object") }
        guard let schema = root["schema"] as? Int else { return fail("the file has no schema version") }
        if schema > currentSchema { return fail("schema \(schema) is newer than this app understands (\(currentSchema)); update MarkView") }
        guard schema == currentSchema else { return fail("schema \(schema) is not a known version") }
        if let unknown = root.keys.filter({ !ThemeSchema.topKeys.contains($0) }).sorted().first { return fail("unknown key \"\(unknown)\"") }

        guard let own = root["id"] as? String, ThemeSchema.isValidID(own) else {
            return fail("\"id\" must be lower-case letters, digits and hyphens")
        }
        guard own == id else { return fail("\"id\" is \"\(own)\" but the file is named \"\(id).json\"") }
        guard let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.count <= ThemeSchema.maxNameLength, !name.contains(where: \.isNewline) else {
            return fail("\"name\" must be one line of 1 to \(ThemeSchema.maxNameLength) characters")
        }
        var summary = ""
        if let value = root["summary"] {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= ThemeSchema.maxSummaryLength,
                  !text.contains(where: \.isNewline) else { return fail("\"summary\" must be one line of at most \(ThemeSchema.maxSummaryLength) characters") }
            summary = text
        }
        var order = 1000
        if let value = root["order"] {
            guard let number = value as? Int, (0...10_000).contains(number) else { return fail("\"order\" must be a whole number from 0 to 10000") }
            order = number
        }
        var picker = Picker.listed
        if let value = root["picker"] {
            guard let text = value as? String, let known = Picker(rawValue: text) else { return fail("\"picker\" must be \"listed\" or \"whileActive\"") }
            picker = known
        }

        guard let nativeObject = root["native"] as? [String: Any] else { return fail("\"native\" is missing") }
        let native: Native
        switch parseNative(nativeObject) {
        case .success(let value): native = value
        case .failure(let problem): return .failure(problem)
        }
        if let problem = contrastProblem(native) { return .failure(problem) }

        var explicit = ExplicitWeb()
        if let value = root["web"] {
            guard let object = value as? [String: Any] else { return fail("\"web\" must be an object") }
            switch parseWeb(object, allowsExactVars: builtIn) {
            case .success(let parsed): explicit = parsed
            case .failure(let problem): return .failure(problem)
            }
        }
        let web = complete(explicit, native: native)
        return .success(ThemeDefinition(id: id, name: name, summary: summary, order: order, picker: picker, source: source,
                                        native: native, web: web))
    }

    private static func fail<T>(_ reason: String) -> Result<T, ThemeProblem> { .failure(ThemeProblem(reason: reason)) }

    private init(id: String, name: String, summary: String, order: Int, picker: Picker, source: Source, native: Native, web: Web) {
        self.id = id; self.name = name; self.summary = summary; self.order = order; self.picker = picker; self.source = source
        self.native = native; self.web = web
        self.webPayload = Self.payload(id: id, native: native, web: web)
    }

    // MARK: Native colours

    private static func colour(_ value: Any, _ path: String) -> Result<ThemeColor, ThemeProblem> {
        guard let text = value as? String, text.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil,
              let colour = ThemeColor(hex: text) else {
            return fail("\(path) must be a colour written as #RRGGBB")
        }
        return .success(colour)
    }

    private static func parseNative(_ object: [String: Any]) -> Result<Native, ThemeProblem> {
        if let unknown = object.keys.filter({ !ThemeSchema.nativeKeys.contains($0) }).sorted().first { return fail("unknown key \"\(unknown)\" in \"native\"") }
        var given: [String: ThemeColor] = [:]
        for key in object.keys.sorted() {
            switch colour(object[key] as Any, "\"native.\(key)\"") {
            case .success(let value): given[key] = value
            case .failure(let problem): return .failure(problem)
            }
        }
        for key in ThemeSchema.nativeRequired where given[key] == nil { return fail("\"native.\(key)\" is missing") }
        let bg = given["bg"]!, text = given["text"]!, sidebar = given["bgSidebar"]!, accent = given["accent"]!
        let dark = isDark(background: bg)
        let backgrounds = [bg, sidebar]

        /// A surface between the background and the text; it moves back towards the background while the text would not read on it.
        func surface(_ fraction: Double) -> ThemeColor {
            var amount = fraction
            var candidate = bg.mixed(with: text, fraction: amount)
            while amount > 0.01, ThemeColor.contrast(text, candidate) < textContrast {
                amount -= 0.02
                candidate = bg.mixed(with: text, fraction: max(amount, 0))
            }
            return candidate
        }
        func hue(_ degrees: Double) -> ThemeColor {
            ThemeColor.hsl(hue: degrees, saturation: dark ? 0.45 : 0.65, lightness: dark ? 0.68 : 0.30)
                .adjusted(toContrast: textContrast, against: backgrounds)
        }
        let dim = given["textDim"] ?? text.mixed(with: bg, fraction: 0.3).adjusted(toContrast: textContrast, against: backgrounds)
        return .success(Native(
            bg: bg, bgSidebar: sidebar,
            bgInput: given["bgInput"] ?? surface(0.12), bgHover: given["bgHover"] ?? surface(0.07), bgActive: given["bgActive"] ?? surface(0.16),
            bgBanner: given["bgBanner"] ?? (dark ? bg.mixed(with: ThemeColor(0x000000), fraction: 0.18) : bg.mixed(with: text, fraction: 0.03)),
            text: text, textDim: dim, textBright: given["textBright"] ?? (dark ? ThemeColor(0xFFFFFF) : ThemeColor(0x000000)),
            border: given["border"] ?? bg.mixed(with: text, fraction: 0.22),
            accent: accent,
            green: given["green"] ?? hue(135), orange: given["orange"] ?? hue(28), yellow: given["yellow"] ?? hue(48),
            purple: given["purple"] ?? hue(285), red: given["red"] ?? hue(4), cyan: given["cyan"] ?? hue(188),
            selection: given["selection"], badge: given["badge"], accentText: given["accentText"]))
    }

    /// The least a theme must meet to be usable: body text on every surface, and the accent on the window background.
    private static func contrastProblem(_ native: Native) -> ThemeProblem? {
        let surfaces: [(String, ThemeColor)] = [("bg", native.bg), ("bgSidebar", native.bgSidebar), ("bgInput", native.bgInput),
                                                ("bgHover", native.bgHover), ("bgActive", native.bgActive)]
        for (name, surface) in surfaces {
            for (label, colour) in [("text", native.text), ("textBright", native.textBright)] {
                let ratio = ThemeColor.contrast(colour, surface)
                if ratio < textContrast {
                    return ThemeProblem(reason: "\"\(label)\" on \"\(name)\" has contrast \(format(ratio)):1; at least \(format(textContrast)):1 is needed")
                }
            }
        }
        // A theme that pins its accent text opted out of the accent rule: it keeps a look value for value.
        if native.accentText == nil {
            for (name, surface) in [("bg", native.bg), ("bgSidebar", native.bgSidebar)] {
                let ratio = ThemeColor.contrast(native.accent, surface)
                if ratio < accentContrast {
                    return ThemeProblem(reason: "\"accent\" on \"\(name)\" has contrast \(format(ratio)):1; at least \(format(accentContrast)):1 is needed")
                }
            }
        }
        return nil
    }

    private static func format(_ value: Double) -> String { String(format: "%.1f", value) }

    // MARK: Web tokens as written

    private struct ExplicitWeb {
        var groups: [String: [String: ThemeColor]] = [:]
        var vars: [String: String] = [:]
        var ownAccentVars: [String: String] = [:]
        var chart: [ThemeColor]?
        var mermaidBuiltIn = false
    }

    private static func parseWeb(_ object: [String: Any], allowsExactVars: Bool) -> Result<ExplicitWeb, ThemeProblem> {
        if let unknown = object.keys.filter({ !ThemeSchema.webKeys.contains($0) }).sorted().first { return fail("unknown key \"\(unknown)\" in \"web\"") }
        var result = ExplicitWeb()
        for (group, allowed) in ThemeSchema.groups.sorted(by: { $0.key < $1.key }) {
            guard let value = object[group] else { continue }
            guard let tokens = value as? [String: Any] else { return fail("\"web.\(group)\" must be an object") }
            var parsed: [String: ThemeColor] = [:]
            for key in tokens.keys.sorted() {
                guard allowed.contains(key) else { return fail("unknown key \"\(key)\" in \"web.\(group)\"") }
                switch colour(tokens[key] as Any, "\"web.\(group).\(key)\"") {
                case .success(let value): parsed[key] = value
                case .failure(let problem): return .failure(problem)
                }
            }
            result.groups[group] = parsed
        }
        if let value = object["chart"] {
            guard let list = value as? [Any], list.count == ThemeSchema.chartCount else { return fail("\"web.chart\" must list \(ThemeSchema.chartCount) colours") }
            var colours: [ThemeColor] = []
            for (index, item) in list.enumerated() {
                switch colour(item, "\"web.chart[\(index)]\"") {
                case .success(let value): colours.append(value)
                case .failure(let problem): return .failure(problem)
                }
            }
            result.chart = colours
        }
        if let value = object["mermaid"] {
            guard let text = value as? String, text == "tokens" || text == "builtin" else { return fail("\"web.mermaid\" must be \"tokens\" or \"builtin\"") }
            result.mermaidBuiltIn = text == "builtin"
        }
        for (key, keep) in [("vars", \ExplicitWeb.vars), ("ownAccentVars", \ExplicitWeb.ownAccentVars)] {
            guard let value = object[key] else { continue }
            guard allowsExactVars else { return fail("\"web.\(key)\" is only allowed in the themes that ship with the app") }
            guard let table = value as? [String: Any] else { return fail("\"web.\(key)\" must be an object") }
            var parsed: [String: String] = [:]
            for name in table.keys.sorted() {
                guard name.range(of: #"^--[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil, name.count <= 48 else {
                    return fail("\"web.\(key)\" has a property name that is not a CSS custom property: \(name)")
                }
                guard let text = table[name] as? String, let value = CSSValue.normalized(text) else {
                    return fail("\"web.\(key).\(name)\" is not a colour, a shadow of colours or a number")
                }
                parsed[name] = value
            }
            result[keyPath: keep] = parsed
        }
        return .success(result)
    }

    // MARK: Derivation of the web tokens

    /// Every token group complete: a file's values win, the rest is worked out from the native colours.
    private static func complete(_ explicit: ExplicitWeb, native n: Native) -> Web {
        let dark = isDark(background: n.bg)
        let surfaces = [n.bg, n.bgSidebar, n.bgInput, n.bgActive, n.bgBanner, n.bg.mixed(with: n.accent, fraction: dark ? 0.24 : 0.18)]
        func legible(_ colour: ThemeColor, extra: [ThemeColor] = []) -> ThemeColor {
            colour.adjusted(toContrast: textContrast, against: surfaces + extra)
        }
        func group(_ name: String, _ derived: [String: ThemeColor]) -> [String: ThemeColor] {
            derived.merging(explicit.groups[name] ?? [:]) { _, own in own }
        }
        let readableAccent = legible(n.accent)
        let preBg = dark ? n.bg.mixed(with: ThemeColor(0x000000), fraction: 0.3) : n.bg.mixed(with: n.text, fraction: 0.04)
        let codeBg = (explicit.groups["t"]?["codeBg"]) ?? n.bgInput
        let secondary = legible(n.textDim, extra: [codeBg, preBg])
        let tertiary = legible(n.textDim.mixed(with: n.bg, fraction: 0.25), extra: [codeBg, preBg])
        let cyan = legible(n.cyan, extra: [codeBg, preBg]), green = legible(n.green, extra: [codeBg, preBg])
        let orange = legible(n.orange, extra: [codeBg, preBg]), red = legible(n.red, extra: [codeBg, preBg])
        let yellow = legible(n.yellow, extra: [codeBg, preBg]), purple = legible(n.purple, extra: [codeBg, preBg])
        let accentOnCode = legible(n.accent, extra: [codeBg, preBg])
        let t = group("t", [
            "tertiary": n.bgInput, "textSecondary": secondary, "textTertiary": tertiary,
            "border": n.border, "borderLight": n.bg.mixed(with: n.border, fraction: 0.55),
            "secondary": cyan, "danger": red, "success": green, "warning": orange, "hover": n.bgActive,
            "h2": accentOnCode, "h3": purple, "codeBg": codeBg, "preBg": preBg, "preBorder": n.border, "preText": n.text,
        ])
        let syn = group("syn", [
            "comment": tertiary, "punct": legible(n.text.mixed(with: n.bg, fraction: 0.2), extra: [codeBg, preBg]), "property": red,
            "number": orange, "string": green, "operator": cyan, "func": accentOnCode, "keyword": purple, "regex": yellow,
        ])
        let structure = group("struct", [
            "key": accentOnCode, "string": green, "number": orange, "boolean": purple, "null": tertiary, "bracket": secondary,
            "tag": red, "attrName": yellow, "attrValue": green, "comment": tertiary, "count": tertiary,
        ])
        func brighter(_ colour: ThemeColor) -> ThemeColor {
            colour.mixed(with: dark ? ThemeColor(0xFFFFFF) : ThemeColor(0x000000), fraction: 0.22)
        }
        let ansi = [
            "black": dark ? n.bg.mixed(with: n.text, fraction: 0.25) : n.text, "red": red, "green": green, "yellow": yellow,
            "blue": readableAccent, "magenta": purple, "cyan": cyan, "white": dark ? n.text : n.textDim,
            "brightBlack": tertiary, "brightRed": brighter(red), "brightGreen": brighter(green), "brightYellow": brighter(yellow),
            "brightBlue": brighter(readableAccent), "brightMagenta": brighter(purple), "brightCyan": brighter(cyan),
            "brightWhite": dark ? n.textBright : n.textDim,
        ]
        // The colour that stands for the background itself (black on a dark theme, white on a light one) is not made to read on it.
        let blends = dark ? ["black"] : ["white", "brightWhite"]
        let term = group("term", Dictionary(uniqueKeysWithValues: ansi.map { key, colour in (key, blends.contains(key) ? colour : legible(colour)) }))
        return Web(t: t, syn: syn, structure: structure, term: term, vars: explicit.vars, ownAccentVars: explicit.ownAccentVars,
                   chart: explicit.chart, mermaidBuiltIn: explicit.mermaidBuiltIn)
    }

    // MARK: What the pages receive

    private static func payload(id: String, native n: Native, web: Web) -> String {
        func strings(_ group: [String: ThemeColor]) -> [String: String] { group.mapValues { $0.cssHex } }
        var object: [String: Any] = [
            "id": id, "mode": isDark(background: n.bg) ? "dark" : "light",
            "base": ["bg": n.bg.cssHex, "panel": n.bgSidebar.cssHex, "text": n.text.cssHex, "accent": n.accent.cssHex],
            "t": strings(web.t), "syn": strings(web.syn), "struct": strings(web.structure), "term": strings(web.term),
            "mermaid": web.mermaidBuiltIn ? "builtin" : "tokens",
        ]
        if !web.vars.isEmpty { object["vars"] = web.vars }
        if !web.ownAccentVars.isEmpty { object["ownAccentVars"] = web.ownAccentVars }
        if let chart = web.chart { object["chart"] = chart.map(\.cssHex) }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - CSS values of the exact custom properties

/// The only CSS text a theme file can carry (and only the bundled ones): a colour, a shadow made of lengths and a colour, or a number.
/// A value is accepted when it matches one of three fixed shapes and is written back normalised, never passed through as it came.
enum CSSValue {
    private static let number = #"-?\d+(?:\.\d+)?"#
    private static let hex = #"#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})"#
    private static let channels = #"\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*"#
    private static let alpha = #"\s*,\s*(?:0|1|0?\.\d+|1\.0+)\s*"#
    private static let colour = "(?:\(hex)|rgb\\(\(channels)\\)|rgba\\(\(channels)\(alpha)\\))"
    private static let length = "(?:0|-?\\d+(?:\\.\\d+)?px)"

    static func normalized(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value.count <= 120 else { return nil }
        func matches(_ pattern: String) -> Bool { value.range(of: "^" + pattern + "$", options: .regularExpression) != nil }
        if matches(number) || matches(colour) { return value }
        if matches("\(length)(?: \(length)){1,3} \(colour)") { return value }
        return nil
    }
}

// MARK: - Colours

extension ThemeColor {
    /// `#rrggbb`, the form CSS and the pages use.
    var cssHex: String { hex.lowercased() }

    /// A colour from hue (degrees), saturation and lightness (0...1).
    static func hsl(hue: Double, saturation: Double, lightness: Double) -> ThemeColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = lightness - c / 2
        func byte(_ value: Double) -> UInt32 { UInt32(((value + m) * 255).rounded()) }
        return ThemeColor(byte(r) << 16 | byte(g) << 8 | byte(b))
    }
}
