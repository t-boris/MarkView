import AppKit
import Combine
import SwiftUI

/// The macOS appearance, observed once for every window that follows it (System).
@MainActor
final class SystemAppearance: ObservableObject {
    static let shared = SystemAppearance()

    @Published private(set) var isDark: Bool
    private var observation: NSKeyValueObservation?

    private init() {
        let app = NSApplication.shared
        isDark = Self.isDark(app.effectiveAppearance)
        observation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        let dark = Self.isDark(NSApplication.shared.effectiveAppearance)
        if dark != isDark { isDark = dark }
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// The theme of one workspace window: its appearance, the accent each appearance remembers in it, the palette the
/// window's views draw with, and the web payload. Every window owns one (through its WorkspaceManager), so a change
/// in one window leaves the others alone; the change is also remembered as the starting value of windows opened later.
@MainActor
final class WindowTheme: ObservableObject {
    @Published private(set) var settings: WindowThemeSettings
    @Published private(set) var palette: AppPalette
    /// Whether the picker popover of this window is open (the menu item and the header button set it).
    @Published var showsPicker = false
    /// The themes this window can draw; shared by every window.
    let catalog: ThemeCatalog

    /// The theme that is drawn: the chosen one, or Classic Dark / Light for System and for an id that no theme has now.
    private var definition: ThemeDefinition
    private let store: ThemeSettingsStore
    private let system: SystemAppearance
    /// The windows that show this theme: the workspace window, and the settings window while it shows this workspace.
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var systemObservation: AnyCancellable?
    private var catalogObservation: AnyCancellable?

    init(settings: WindowThemeSettings? = nil, store: ThemeSettingsStore = ThemeSettingsStore(),
         system: SystemAppearance? = nil, catalog: ThemeCatalog? = nil) {
        let system = system ?? SystemAppearance.shared
        let catalog = catalog ?? ThemeCatalog.shared
        let start = settings ?? store.startingSettings()
        let drawn = catalog.resolve(start.theme, systemIsDark: system.isDark)
        self.store = store
        self.system = system
        self.catalog = catalog
        self.settings = start
        self.definition = drawn
        self.palette = AppPalette(ThemePalette.make(drawn, accent: start.activeOverride))
        systemObservation = system.$isDark.dropFirst().sink { [weak self] _ in
            // The new value is read from the published property after it is set.
            DispatchQueue.main.async { self?.refresh() }
        }
        // A theme file added while the app runs can be the one this window had stored: draw it as soon as it is there.
        catalogObservation = catalog.$library.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    var isDark: Bool { palette.isDark }

    /// What the web pages of this window receive: the id of the theme that is drawn and the accent the person chose (nil = its own).
    var webID: String { definition.id }
    var webAccent: String? { settings.activeOverride?.hex }

    /// The accent shown as selected in the picker, and the appearance's own.
    var effectiveAccent: ThemeColor { palette.model.accent }
    var defaultAccent: ThemeColor { palette.model.defaultAccent }

    /// How `choice` looks in this window (with the accent this window remembers for it), for the picker's miniatures.
    func previewPalette(for choice: AppTheme) -> AppPalette {
        let drawn = catalog.library.resolve(choice, systemIsDark: system.isDark).definition
        return AppPalette(ThemePalette.make(drawn, accent: settings.accentOverride(for: choice)))
    }

    func select(_ theme: AppTheme) {
        guard theme != settings.theme else { return }
        settings.select(theme)
        commit()
    }

    func setAccent(_ color: ThemeColor?) {
        guard color != settings.activeOverride else { return }
        settings.setAccent(color)
        commit()
    }

    /// Apply the settings this window had when it was saved; not a change anyone made, so not remembered for new windows.
    func restore(_ saved: WindowThemeSettings) {
        guard saved != settings else { return }
        settings = saved
        refresh()
    }

    /// Give `window` the appearance of this theme: fixed light or dark for an appearance of its own, the system's for System.
    func attach(_ window: NSWindow) {
        windows.add(window)
        applyWindowAppearance(to: window)
    }

    /// Stop managing `window` (the settings window moves to another workspace).
    func detach(_ window: NSWindow) {
        windows.remove(window)
    }

    private func commit() {
        refresh()
        store.remember(settings)
    }

    private func refresh() {
        definition = catalog.resolve(settings.theme, systemIsDark: system.isDark)
        palette = AppPalette(ThemePalette.make(definition, accent: settings.activeOverride))
        applyWindowAppearance()
    }

    private func applyWindowAppearance() {
        for window in windows.allObjects { applyWindowAppearance(to: window) }
    }

    private func applyWindowAppearance(to window: NSWindow) {
        let wanted: NSAppearance? = settings.theme.isSystem ? nil : NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        if window.appearance?.name != wanted?.name { window.appearance = wanted }
    }
}

// MARK: - Web pages

extension WindowTheme {
    /// The arguments of the pages' theme functions (`setTheme`, `mvSetTheme`): the id of the drawn theme, the accent or null, and the
    /// theme itself (`ThemeDefinition.webPayload`), so a page needs no table of themes of its own.
    var webArguments: String { "'\(webID)', \(webAccent.map { "'\($0)'" } ?? "null"), \(definition.webPayload)" }

    /// The attributes of a page's <html> element that draw it right from the first paint, before its scripts run: the id, the mode,
    /// the accent, and the theme's tokens. Values are ids, `#RRGGBB` colours and the payload JSON, which is escaped where it is written.
    private var htmlAttributePairs: [(name: String, value: String)] {
        var pairs = [("data-preset", webID), ("data-theme", isDark ? "dark" : "light")]
        if let accent = webAccent { pairs.append(("data-accent", accent)) }
        pairs.append(("data-theme-tokens", definition.webPayload))
        return pairs
    }

    /// The same attributes as page text, for a page loaded from a string (the editor).
    var htmlAttributes: String {
        htmlAttributePairs.map { "\($0.name)=\"\(Self.htmlEscaped($0.value))\"" }.joined(separator: " ")
    }

    /// The same attributes as a script for `WKUserScript` at document start, for a page loaded from a file
    /// (discussion, terminal): they are on <html> before the page's own scripts run.
    var firstPaintScript: String {
        htmlAttributePairs.map { "document.documentElement.setAttribute('\($0.name)', \(Self.scriptLiteral($0.value)));" }.joined(separator: " ")
    }

    private static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `text` as a JavaScript string literal.
    private static func scriptLiteral(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }
}
