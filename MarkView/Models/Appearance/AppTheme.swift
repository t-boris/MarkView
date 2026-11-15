import Foundation

// The theme model of a workspace window: which appearance it uses, the accent each appearance remembers,
// the colours the native views draw with, and how a new window gets its starting value. Foundation only, so
// `tools/tests/theme-model-tests.sh` checks it without the app. A theme itself is data (`ThemeDefinition.swift`, one JSON
// file each); views read the palette from the SwiftUI environment (`WindowTheme.swift`); the web pages receive the theme's
// tokens from the same definition (`markview-themes.js` only turns them into CSS custom properties).

// MARK: - Colour

/// An sRGB colour as 0xRRGGBB, stored in settings as "#RRGGBB".
struct ThemeColor: Equatable, Hashable, Codable {
    let rgb: UInt32

    init(_ rgb: UInt32) { self.rgb = rgb & 0xFFFFFF }

    /// "#RRGGBB" or "RRGGBB"; nil for anything else (a short, long or non-hex string).
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }
        self.rgb = value
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = ThemeColor(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a #RRGGBB colour: \(text)"))
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    var hex: String { String(format: "#%06X", rgb) }
    var red: Double { Double((rgb >> 16) & 0xFF) / 255 }
    var green: Double { Double((rgb >> 8) & 0xFF) / 255 }
    var blue: Double { Double(rgb & 0xFF) / 255 }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio, 1...21.
    static func contrast(_ a: ThemeColor, _ b: ThemeColor) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// `self` moved `fraction` (0...1) of the way to `other`.
    func mixed(with other: ThemeColor, fraction: Double) -> ThemeColor {
        let t = min(max(fraction, 0), 1)
        func channel(_ a: Double, _ b: Double) -> UInt32 { UInt32(((a + (b - a) * t) * 255).rounded()) }
        return ThemeColor(channel(red, other.red) << 16 | channel(green, other.green) << 8 | channel(blue, other.blue))
    }

    /// Black or white, whichever reads better on `self`.
    var readableText: ThemeColor {
        ThemeColor.contrast(self, ThemeColor(0x000000)) >= ThemeColor.contrast(self, ThemeColor(0xFFFFFF))
            ? ThemeColor(0x000000) : ThemeColor(0xFFFFFF)
    }

    /// `self` lightened or darkened (towards white on dark backgrounds, black on light ones) until it reaches
    /// `target` contrast against every background, or as far as it can go.
    func adjusted(toContrast target: Double, against backgrounds: [ThemeColor]) -> ThemeColor {
        func meets(_ c: ThemeColor) -> Bool { backgrounds.allSatisfy { ThemeColor.contrast(c, $0) >= target } }
        if meets(self) { return self }
        let averageLuminance = backgrounds.map(\.luminance).reduce(0, +) / Double(max(backgrounds.count, 1))
        let end = averageLuminance < 0.4 ? ThemeColor(0xFFFFFF) : ThemeColor(0x000000)
        var fraction = 0.0
        while fraction < 1 {
            fraction = min(fraction + 0.02, 1)
            let candidate = mixed(with: end, fraction: fraction)
            if meets(candidate) { return candidate }
        }
        return end
    }
}

// MARK: - Appearances

/// The appearance choice of a window: System, or the id of a theme the catalog knows (a file in `Resources/Themes/` or in the person's
/// themes folder). A value is only a name: what it looks like is in `ThemeDefinition`, found through `ThemeLibrary.resolve`. An id that
/// no theme answers to now (a deleted file) stays as it was stored and is shown as Classic Dark, so the choice comes back with the file.
struct AppTheme: Hashable, Codable, Identifiable, Sendable {
    let id: String

    init(_ id: String) { self.id = id }

    /// Follows the macOS appearance; it is drawn as Classic Dark or Classic Light.
    static let system = AppTheme("system")
    /// The look before themes existed (DEC-004): what an unknown or missing id is shown as.
    static let classicDark = AppTheme("classic-dark")
    static let classicLight = AppTheme("classic-light")

    var isSystem: Bool { self == .system }

    /// An id read from storage; nil when the text cannot be an id. Earlier versions stored the case name of an enum (`tokyoNight`,
    /// `classicDark`); those become the id they stand for (`tokyo-night`, `classic-dark`).
    init?(stored raw: String) {
        var id = ""
        for character in raw {
            if character.isUppercase { id += "-" + character.lowercased() } else { id.append(character) }
        }
        guard ThemeSchema.isValidID(id) else { return nil }
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let theme = AppTheme(stored: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a theme id: \(text)"))
        }
        self = theme
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

// MARK: - Palette

/// The colours native views draw with in one window.
struct ThemePalette: Equatable {
    /// The drawn appearance (never `.system`).
    let theme: AppTheme
    let isDark: Bool

    let bg, bgSidebar, bgInput, bgHover, bgActive, bgBanner: ThemeColor
    let text, textDim, textBright: ThemeColor
    let border, selection: ThemeColor
    /// Links, active items and indicators; the accent the person chose, or the appearance's own.
    let accent: ThemeColor
    let defaultAccent: ThemeColor
    /// Text on a fill drawn in the accent colour.
    let onAccent: ThemeColor
    /// Accent used as text or an icon: the accent moved to be readable on the window's backgrounds.
    let blue: ThemeColor
    let green, orange, yellow, purple, red, cyan: ThemeColor
    /// Fill of counters and badges.
    let badge: ThemeColor

    /// The minimum contrast of body text, and of text and icons in the accent colour, against the backgrounds.
    static let readableContrast = 4.5

    /// The palette of a theme. `accent` is the person's override, if any. A theme that pins `selection`, `badge` or `accentText` (the
    /// Classic looks) keeps them while the accent is its own; once the person picks an accent they follow it like everyone else's.
    static func make(_ definition: ThemeDefinition, accent override: ThemeColor? = nil) -> ThemePalette {
        let n = definition.native
        let defaultAccent = n.accent
        let accent = override ?? defaultAccent
        let readable = accent.adjusted(toContrast: readableContrast, against: [n.bg, n.bgSidebar])
        let isDark = definition.isDark
        let own = override == nil
        let blue = (own ? n.accentText : nil) ?? readable
        let badge = (own ? n.badge : nil) ?? accent
        let selection = (own ? n.selection : nil) ?? n.bg.mixed(with: accent, fraction: isDark ? 0.38 : 0.24)
        return ThemePalette(theme: AppTheme(definition.id), isDark: isDark,
                            bg: n.bg, bgSidebar: n.bgSidebar, bgInput: n.bgInput, bgHover: n.bgHover,
                            bgActive: n.bgActive, bgBanner: n.bgBanner,
                            text: n.text, textDim: n.textDim, textBright: n.textBright,
                            border: n.border, selection: selection,
                            accent: accent, defaultAccent: defaultAccent, onAccent: badge.readableText, blue: blue,
                            green: n.green, orange: n.orange, yellow: n.yellow,
                            purple: n.purple, red: n.red, cyan: n.cyan, badge: badge)
    }
}

// MARK: - Settings of one window

/// The appearance a window uses and the accent each appearance remembers in it (DEC-002).
/// Decoding never fails on bad content: a name that cannot be an id becomes Classic Dark and unreadable accents are dropped. A
/// well-formed id is kept even when no theme has it now (see `AppTheme`).
struct WindowThemeSettings: Equatable, Codable {
    var theme: AppTheme
    private(set) var accents: [AppTheme: ThemeColor]

    static let fallback = WindowThemeSettings(theme: .classicDark)

    init(theme: AppTheme, accents: [AppTheme: ThemeColor] = [:]) {
        self.theme = theme
        self.accents = accents
    }

    private enum CodingKeys: String, CodingKey { case theme, accents }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = (try? container.decode(String.self, forKey: .theme)) ?? ""
        theme = AppTheme(stored: name) ?? .classicDark
        var kept: [AppTheme: ThemeColor] = [:]
        if let raw = try? container.decode([String: String].self, forKey: .accents) {
            for (key, value) in raw {
                if let theme = AppTheme(stored: key), let color = ThemeColor(hex: value) { kept[theme] = color }
            }
        }
        accents = kept
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(theme.id, forKey: .theme)
        try container.encode(Dictionary(uniqueKeysWithValues: accents.map { ($0.key.id, $0.value.hex) }), forKey: .accents)
    }

    /// The accent the person set for `theme` in this window.
    func accentOverride(for theme: AppTheme) -> ThemeColor? { accents[theme] }

    /// The accent override of the active appearance.
    var activeOverride: ThemeColor? { accents[theme] }

    /// Choose an appearance; every appearance keeps its own accent.
    mutating func select(_ theme: AppTheme) { self.theme = theme }

    /// Set (or, with nil, reset) the accent of the active appearance.
    mutating func setAccent(_ color: ThemeColor?) { accents[theme] = color }
}

// MARK: - Where the settings come from

/// The starting settings of a window that has none of its own (a new window, or one restored from before themes
/// existed), and the record of the last change that new windows inherit (DEC-005).
struct ThemeSettingsStore {
    static let lastChangedKey = "theme.lastChanged.v1"
    /// The key the application-wide light / dark / system setting used before themes existed.
    static let legacyKey = "theme"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The settings a new window starts from: the last change anyone made, else the earlier light / dark setting as
    /// Classic (absent, "system" or unreadable -> Classic Dark), never a failure.
    func startingSettings() -> WindowThemeSettings {
        if let data = defaults.data(forKey: Self.lastChangedKey), Self.isReadable(data),
           let settings = try? JSONDecoder().decode(WindowThemeSettings.self, from: data) {
            return settings
        }
        return WindowThemeSettings(theme: Self.legacyTheme(defaults.string(forKey: Self.legacyKey)))
    }

    /// Remember the settings of the window that changed last.
    func remember(_ settings: WindowThemeSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.lastChangedKey) }
    }

    /// The Classic appearance an earlier saved value stands for.
    static func legacyTheme(_ value: String?) -> AppTheme {
        value == "light" ? .classicLight : .classicDark
    }

    /// A stored record is used only when it is a JSON object whose theme can be an id; anything else counts as missing.
    private static func isReadable(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["theme"] as? String else { return false }
        return AppTheme(stored: name) != nil
    }
}
