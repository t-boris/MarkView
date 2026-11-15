import Foundation

/// Application surfaces where a registered tool appears (`AR-31`, `FU-02`).
struct ToolSurface: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int

    static let toolbar = ToolSurface(rawValue: 1 << 0)
    static let viewMenu = ToolSurface(rawValue: 1 << 1)
    static let welcomeTile = ToolSurface(rawValue: 1 << 2)
    static let sessionRestore = ToolSurface(rawValue: 1 << 3)
}

/// Canonical metadata for a singleton workspace tool (`AR-31`, `DEC-001`, `FU-02`).
struct ToolDescriptor: Identifiable, Equatable, Hashable, Sendable {
    enum ToolID: String, CaseIterable, Codable, Hashable, Sendable {
        case git
        case deployments
        case workflow
        case qa
        case uiStudio
        case cockpit
        case discussions
        case changeReview
    }

    let id: ToolID
    let title: String
    let help: String
    let icon: String
    let shortcutHint: String?
    let sentinelPath: String
    let surfaces: ToolSurface
    let isPrimaryToolbarItem: Bool

    var rawID: String { id.rawValue }
}

/// Single source of truth for singleton workspace tools, matching the live toolbar,
/// session-restorable tabs, and sentinel paths (`AR-31`, `DEC-001`, `FU-02`).
enum ToolRegistry {
    static let all: [ToolDescriptor] = [
        ToolDescriptor(
            id: .git,
            title: "Git",
            help: "Git",
            icon: "arrow.triangle.branch",
            shortcutHint: nil,
            sentinelPath: ".dde/.markview-git",
            surfaces: [.toolbar, .sessionRestore],
            isPrimaryToolbarItem: true
        ),
        ToolDescriptor(
            id: .deployments,
            title: "Build & Deployment",
            help: "Build & Deployment (⌃⌘D)",
            icon: "server.rack",
            shortcutHint: "⌃⌘D",
            sentinelPath: ".dde/.markview-deployments",
            surfaces: [.toolbar, .viewMenu, .welcomeTile, .sessionRestore],
            isPrimaryToolbarItem: true
        ),
        ToolDescriptor(
            id: .workflow,
            title: "Workflow",
            help: "Workflow",
            icon: "point.3.connected.trianglepath.dotted",
            shortcutHint: nil,
            sentinelPath: ".dde/.markview-workflow",
            surfaces: [.toolbar, .sessionRestore],
            isPrimaryToolbarItem: true
        ),
        ToolDescriptor(
            id: .qa,
            title: "End-to-End QA",
            help: "End-to-End QA (⌘8)",
            icon: "checkmark.shield",
            shortcutHint: "⌘8",
            sentinelPath: ".dde/.markview-qa",
            surfaces: [.toolbar, .viewMenu, .welcomeTile, .sessionRestore],
            isPrimaryToolbarItem: true
        ),
        ToolDescriptor(
            id: .uiStudio,
            title: "UI Studio",
            help: "UI Studio (⌘7)",
            icon: "macwindow.and.cursorarrow",
            shortcutHint: "⌘7",
            sentinelPath: ".dde/.markview-ui-studio-",
            surfaces: [.toolbar, .viewMenu, .welcomeTile],
            isPrimaryToolbarItem: true
        ),
        ToolDescriptor(
            id: .cockpit,
            title: "Copilot Cockpit",
            help: "Copilot Cockpit",
            icon: "airplane",
            shortcutHint: nil,
            sentinelPath: ".dde/.markview-cockpit",
            surfaces: [.toolbar, .viewMenu],
            isPrimaryToolbarItem: true
        ),
        ToolDescriptor(
            id: .discussions,
            title: "Discussions",
            help: "Discussions (⌃⌘I)",
            icon: "bubble.left.and.text.bubble.right",
            shortcutHint: "⌃⌘I",
            sentinelPath: ".dde/.markview-discussions",
            surfaces: [.toolbar, .viewMenu, .sessionRestore],
            isPrimaryToolbarItem: false
        ),
        ToolDescriptor(
            id: .changeReview,
            title: "Change Review",
            help: "Change Review",
            icon: "doc.text.magnifyingglass",
            shortcutHint: nil,
            sentinelPath: ".dde/.markview-file-changes",
            surfaces: [.sessionRestore],
            isPrimaryToolbarItem: false
        )
    ]

    /// The 6 primary tools rendered in the main left-to-right toolbar cluster before Prototype/Browser.
    static let primaryToolbarTools: [ToolDescriptor] = all.filter { $0.isPrimaryToolbarItem && $0.surfaces.contains(.toolbar) }
    /// All tools rendered as tabs in the center toolbar (primary cluster + Discussions).
    static let toolbarTools: [ToolDescriptor] = all.filter { $0.surfaces.contains(.toolbar) }
    static let menuTools: [ToolDescriptor] = all.filter { $0.surfaces.contains(.viewMenu) }
    static let welcomeTools: [ToolDescriptor] = all.filter { $0.surfaces.contains(.welcomeTile) }
    static let restorableTools: [ToolDescriptor] = all.filter { $0.surfaces.contains(.sessionRestore) }

    static func descriptor(for id: ToolDescriptor.ToolID) -> ToolDescriptor? {
        all.first { $0.id == id }
    }

    static func descriptor(id: String) -> ToolDescriptor? {
        guard let toolID = ToolDescriptor.ToolID(rawValue: id) else { return nil }
        return descriptor(for: toolID)
    }

    static func sentinelURL(for id: ToolDescriptor.ToolID, in root: URL, suffix: String = "") -> URL {
        let base = descriptor(for: id)?.sentinelPath ?? ".dde/.markview-\(id.rawValue)"
        return root.appendingPathComponent(base + suffix)
    }
}
