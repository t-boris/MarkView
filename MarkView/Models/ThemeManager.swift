import Foundation
import SwiftUI
import Combine

/// Available theme options
enum Theme: String, CaseIterable {
    case light = "light"
    case dark = "dark"
    case system = "system"

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }
}

/// Manages application theme state and preferences
@MainActor
class ThemeManager: ObservableObject {
    @AppStorage("theme") var theme: Theme = .system
    @Published var effectiveTheme: Theme = .light

    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        updateEffectiveTheme()
        setupObservers()
    }

    /// Determines the actual theme based on system settings
    private func updateEffectiveTheme() {
        if theme == .system {
            let appearance = NSApp.effectiveAppearance
            effectiveTheme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        } else {
            effectiveTheme = theme
        }
    }

    /// Set up observers for system appearance changes via KVO
    private func setupObservers() {
        // Observe system appearance changes via KVO on NSApp
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.updateEffectiveTheme()
                self?.notifyThemeChange()
            }
        }
    }

    /// Apply the current theme to the app
    func applyTheme() {
        updateEffectiveTheme()

        switch theme {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil
        }

        notifyThemeChange()
    }

    /// Notify WebView bridge about theme change
    private func notifyThemeChange() {
        NotificationCenter.default.post(name: .themeDidChange, object: effectiveTheme)
    }

    /// Toggle between light and dark theme
    func toggleTheme() {
        switch effectiveTheme {
        case .light:
            theme = .dark
        case .dark:
            theme = .light
        case .system:
            theme = .light
        }
        applyTheme()
    }

    /// Get the CSS class name for the current theme
    var cssThemeClass: String {
        effectiveTheme == .dark ? "dark-theme" : "light-theme"
    }

    /// Get color values for the current theme
    var backgroundColor: Color {
        effectiveTheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : .white
    }

    var foregroundColor: Color {
        effectiveTheme == .dark ? .white : .black
    }

    var secondaryBackgroundColor: Color {
        effectiveTheme == .dark ? Color(red: 0.17, green: 0.17, blue: 0.18) : Color(red: 0.96, green: 0.96, blue: 0.97)
    }
}
