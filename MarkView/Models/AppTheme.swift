import Foundation

// The theme model of a workspace window: which appearance it uses, the accent each appearance remembers,
// the colours the native views draw with, and how a new window gets its starting value. Foundation only, so
// `tools/tests/theme-model-tests.sh` checks it without the app. Views read the palette from the SwiftUI
// environment (`WindowTheme.swift`); the web pages receive the appearance id and the accent
// (`markview-themes.js` holds their tokens, and the checks compare the base colours of both sides).

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

/// The appearance choices of a window. `classicDark` and `classicLight` are the look before themes existed
/// (DEC-004): kept until the person chooses System or a preset, listed only while active.
enum AppTheme: String, CaseIterable, Codable {
    case system, classicDark, classicLight, darcula, midnight, graphite, tokyoNight, carbonRed, paper

    var displayName: String {
        switch self {
        case .system: return "System"
        case .classicDark: return "Classic Dark"
        case .classicLight: return "Classic Light"
        case .darcula: return "Darcula"
        case .midnight: return "Midnight"
        case .graphite: return "Graphite"
        case .tokyoNight: return "Tokyo Night"
        case .carbonRed: return "Carbon Red"
        case .paper: return "Paper"
        }
    }

    /// One line shown in the picker under the name.
    var summary: String {
        switch self {
        case .system: return "Follows the macOS appearance"
        case .classicDark: return "The dark look before themes"
        case .classicLight: return "The light look before themes"
        case .darcula: return "IntelliJ-inspired warm dark grey"
        case .midnight: return "Deep blue-black with sky blue"
        case .graphite: return "Neutral dark with violet"
        case .tokyoNight: return "Indigo night with lavender and cyan"
        case .carbonRed: return "Soft black with coral and warm ivory"
        case .paper: return "Warm light paper with blue ink"
        }
    }

    var isPreset: Bool { [.darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .paper].contains(self) }
    var isClassic: Bool { self == .classicDark || self == .classicLight }

    /// Whether the window is drawn dark; `systemIsDark` decides for System.
    func isDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .system: return systemIsDark
        case .classicLight, .paper: return false
        case .classicDark, .darcula, .midnight, .graphite, .tokyoNight, .carbonRed: return true
        }
    }

    /// The appearance that is actually drawn: System becomes Classic Dark or Classic Light.
    func resolved(systemIsDark: Bool) -> AppTheme {
        self == .system ? (systemIsDark ? .classicDark : .classicLight) : self
    }

    /// Identifier of a resolved appearance in the web pages ("classic-dark", "darcula", ...).
    var webID: String {
        switch self {
        case .system: return "system"
        case .classicDark: return "classic-dark"
        case .classicLight: return "classic-light"
        case .darcula: return "darcula"
        case .midnight: return "midnight"
        case .graphite: return "graphite"
        case .tokyoNight: return "tokyo-night"
        case .carbonRed: return "carbon-red"
        case .paper: return "paper"
        }
    }

    /// The choices a window's picker lists: System and the presets, preceded by Classic only while it is active.
    static func pickerChoices(current: AppTheme) -> [AppTheme] {
        (current.isClassic ? [current] : []) + [.system, .darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .paper]
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

    private struct Base {
        let bg, bgSidebar, bgInput, bgHover, bgActive, bgBanner: UInt32
        let text, textDim, textBright: UInt32
        let border, selection: UInt32
        let accent: UInt32
        let green, orange, yellow, purple, red, cyan: UInt32
        /// Classic keeps its own badge and selection colours; the presets derive them from the accent.
        let badge: UInt32?
        let literalBlue: UInt32?
    }

    private static func base(_ theme: AppTheme) -> Base {
        switch theme {
        case .system, .classicDark:
            return Base(bg: 0x1E1E1E, bgSidebar: 0x252526, bgInput: 0x3C3C3C, bgHover: 0x2A2D2E, bgActive: 0x37373D, bgBanner: 0x1B1B1F,
                        text: 0xD4D4D4, textDim: 0x808080, textBright: 0xFFFFFF, border: 0x3C3C3C, selection: 0x264F78,
                        accent: 0x569CD6, green: 0x4EC9B0, orange: 0xCE9178, yellow: 0xDCDCAA, purple: 0xC586C0, red: 0xF44747,
                        cyan: 0x9CDCFE, badge: 0x007ACC, literalBlue: 0x569CD6)
        case .classicLight:
            return Base(bg: 0xFFFFFF, bgSidebar: 0xF3F3F3, bgInput: 0xE8E8E8, bgHover: 0xE8E8E8, bgActive: 0xDCDCDC, bgBanner: 0xF0F0F0,
                        text: 0x1E1E1E, textDim: 0x6E7681, textBright: 0x000000, border: 0xD4D4D4, selection: 0xADD6FF,
                        accent: 0x569CD6, green: 0x4EC9B0, orange: 0xCE9178, yellow: 0xDCDCAA, purple: 0xC586C0, red: 0xF44747,
                        cyan: 0x0070C1, badge: 0x007ACC, literalBlue: 0x569CD6)
        case .darcula:
            return Base(bg: 0x2B2B2B, bgSidebar: 0x323232, bgInput: 0x3C3F41, bgHover: 0x3A3A3A, bgActive: 0x464646, bgBanner: 0x262626,
                        text: 0xE0E0E0, textDim: 0xA3A3A3, textBright: 0xFFFFFF, border: 0x484848, selection: 0,
                        accent: 0xE6A15C, green: 0x8DC278, orange: 0xE0884A, yellow: 0xE3C86F, purple: 0xC39BD9, red: 0xFF6B68,
                        cyan: 0x6DC3D6, badge: nil, literalBlue: nil)
        case .midnight:
            return Base(bg: 0x151C2B, bgSidebar: 0x1D2738, bgInput: 0x27344B, bgHover: 0x223048, bgActive: 0x2C3B58, bgBanner: 0x111726,
                        text: 0xE5EBF5, textDim: 0x93A1BA, textBright: 0xFFFFFF, border: 0x303F5A, selection: 0,
                        accent: 0x79B8FF, green: 0x7FD6A4, orange: 0xF2A36B, yellow: 0xE9D08A, purple: 0xB79CFF, red: 0xFF7B86,
                        cyan: 0x5CD3E6, badge: nil, literalBlue: nil)
        case .graphite:
            return Base(bg: 0x202124, bgSidebar: 0x2A2C30, bgInput: 0x36383D, bgHover: 0x303338, bgActive: 0x3E4147, bgBanner: 0x1B1C1F,
                        text: 0xE8EAED, textDim: 0x9AA0A6, textBright: 0xFFFFFF, border: 0x40434A, selection: 0,
                        accent: 0xB39DDB, green: 0x81C995, orange: 0xF6AE5F, yellow: 0xF2D675, purple: 0xD58FE0, red: 0xF28B82,
                        cyan: 0x78D9EC, badge: nil, literalBlue: nil)
        case .tokyoNight:
            return Base(bg: 0x1A1B26, bgSidebar: 0x202233, bgInput: 0x2B2F45, bgHover: 0x292D42, bgActive: 0x353B55, bgBanner: 0x151620,
                        text: 0xD5DAF0, textDim: 0xA0A9CB, textBright: 0xF2F4FF, border: 0x414763, selection: 0,
                        accent: 0xB49AFF, green: 0x9ECE6A, orange: 0xFFAD77, yellow: 0xE0C583, purple: 0xBB9AF7, red: 0xFF879D,
                        cyan: 0x7DCFFF, badge: nil, literalBlue: nil)
        case .carbonRed:
            return Base(bg: 0x171719, bgSidebar: 0x212124, bgInput: 0x2C2B30, bgHover: 0x302C30, bgActive: 0x403139, bgBanner: 0x121214,
                        text: 0xEDE8E6, textDim: 0xB4A6A6, textBright: 0xFFF7F1, border: 0x484046, selection: 0,
                        accent: 0xFF6B81, green: 0xA3C991, orange: 0xEFA975, yellow: 0xE7CD92, purple: 0xC8A4D4, red: 0xFF929C,
                        cyan: 0x8DCBD0, badge: nil, literalBlue: nil)
        case .paper:
            return Base(bg: 0xFFFCF5, bgSidebar: 0xF2EDE3, bgInput: 0xE8E1D3, bgHover: 0xEBE5D8, bgActive: 0xDDD5C4, bgBanner: 0xF7F2E8,
                        text: 0x292724, textDim: 0x655F55, textBright: 0x000000, border: 0xD6CEBE, selection: 0,
                        accent: 0x315E9B, green: 0x287030, orange: 0xA05000, yellow: 0x7F6400, purple: 0x7B3FA0, red: 0xB3261E,
                        cyan: 0x00707E, badge: nil, literalBlue: nil)
        }
    }

    /// The base colours the web token file repeats for each appearance: editor background, panel background, text, accent.
    static func webBase(_ theme: AppTheme) -> (bg: ThemeColor, panel: ThemeColor, text: ThemeColor, accent: ThemeColor) {
        let b = base(theme.resolved(systemIsDark: true))
        return (ThemeColor(b.bg), ThemeColor(b.bgSidebar), ThemeColor(b.text), ThemeColor(b.accent))
    }

    /// The default accent of an appearance.
    static func defaultAccent(of theme: AppTheme) -> ThemeColor {
        webBase(theme).accent
    }

    /// The palette of an appearance. `theme` must be resolved; `accent` is the person's override, if any.
    static func make(_ theme: AppTheme, accent override: ThemeColor? = nil) -> ThemePalette {
        let theme = theme.resolved(systemIsDark: true)
        let b = base(theme)
        let bg = ThemeColor(b.bg), sidebar = ThemeColor(b.bgSidebar)
        let defaultAccent = ThemeColor(b.accent)
        let accent = override ?? defaultAccent
        let readable = accent.adjusted(toContrast: readableContrast, against: [bg, sidebar])
        let isDark = theme.isDark(systemIsDark: true)

        let usesLiterals = theme.isClassic && override == nil
        let blue = usesLiterals ? ThemeColor(b.literalBlue ?? b.accent) : readable
        let badge = usesLiterals ? ThemeColor(b.badge ?? b.accent) : accent
        let selection = usesLiterals
            ? ThemeColor(b.selection)
            : bg.mixed(with: accent, fraction: isDark ? 0.38 : 0.24)
        return ThemePalette(theme: theme, isDark: isDark,
                            bg: bg, bgSidebar: sidebar, bgInput: ThemeColor(b.bgInput), bgHover: ThemeColor(b.bgHover),
                            bgActive: ThemeColor(b.bgActive), bgBanner: ThemeColor(b.bgBanner),
                            text: ThemeColor(b.text), textDim: ThemeColor(b.textDim), textBright: ThemeColor(b.textBright),
                            border: ThemeColor(b.border), selection: selection,
                            accent: accent, defaultAccent: defaultAccent, onAccent: badge.readableText, blue: blue,
                            green: ThemeColor(b.green), orange: ThemeColor(b.orange), yellow: ThemeColor(b.yellow),
                            purple: ThemeColor(b.purple), red: ThemeColor(b.red), cyan: ThemeColor(b.cyan), badge: badge)
    }
}

// MARK: - Settings of one window

/// The appearance a window uses and the accent each appearance remembers in it (DEC-002).
/// Decoding never fails on bad content: an unknown appearance becomes Classic Dark and unreadable accents are dropped.
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
        theme = AppTheme(rawValue: name) ?? .classicDark
        var kept: [AppTheme: ThemeColor] = [:]
        if let raw = try? container.decode([String: String].self, forKey: .accents) {
            for (key, value) in raw {
                if let theme = AppTheme(rawValue: key), let color = ThemeColor(hex: value) { kept[theme] = color }
            }
        }
        accents = kept
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(theme.rawValue, forKey: .theme)
        try container.encode(Dictionary(uniqueKeysWithValues: accents.map { ($0.key.rawValue, $0.value.hex) }), forKey: .accents)
    }

    /// The accent the person set for `theme` in this window.
    func accentOverride(for theme: AppTheme) -> ThemeColor? { accents[theme] }

    /// The accent override of the active appearance.
    var activeOverride: ThemeColor? { accents[theme] }

    /// Choose an appearance; every appearance keeps its own accent.
    mutating func select(_ theme: AppTheme) { self.theme = theme }

    /// Set (or, with nil, reset) the accent of the active appearance.
    mutating func setAccent(_ color: ThemeColor?) { accents[theme] = color }

    /// Resolved palette for the window.
    func palette(systemIsDark: Bool) -> ThemePalette {
        ThemePalette.make(theme.resolved(systemIsDark: systemIsDark), accent: activeOverride)
    }

    /// The accent in use: the override, or the appearance's default.
    func effectiveAccent(systemIsDark: Bool) -> ThemeColor {
        activeOverride ?? ThemePalette.defaultAccent(of: theme.resolved(systemIsDark: systemIsDark))
    }
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

    /// A stored record is used only when it is a JSON object naming a known appearance; anything else counts as missing.
    private static func isReadable(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["theme"] as? String else { return false }
        return AppTheme(rawValue: name) != nil
    }
}
