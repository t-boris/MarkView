import Foundation

enum WorkspaceArea: String, CaseIterable, Identifiable {
    case files = "Files"
    case projectMap = "Project Map"
    case work = "Work"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .files: return "folder"
        case .projectMap: return "viewfinder"
        case .work: return "checklist"
        }
    }
}

enum WorkSection: String, CaseIterable, Identifiable {
    case features = "Tasks"
    case git = "Git"
    case terminal = "Terminal"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .features: return "checklist"
        case .git: return "arrow.triangle.branch"
        case .terminal: return "terminal"
        }
    }
}

/// Legacy right-panel navigator tab selection kept in Models (`AR-22`).
enum NavigatorTab: String, CaseIterable {
    case contents = "Contents"
    case search = "Search"
    case git = "Git"
    case terminal = "Terminal"
    case feature = "Feature"

    static let storageKey = "layout.navigatorTab"

    /// What the tab is called. The raw values are stored in saved layouts and stay as they were.
    var title: String {
        switch self {
        case .terminal: return "Agents"
        case .feature: return "Tasks"
        default: return rawValue
        }
    }
}

/// The tab or section each panel of one window shows. Every window owns one through its
/// WorkspaceManager, so switching a tab in one window leaves the others alone (BUG-004).
/// A change is written to UserDefaults only as the starting value for the next window and for
/// relaunch; no view observes those keys (as @AppStorage would, in every window at once).
@MainActor
final class PanelLayout: ObservableObject {
    @Published var workspaceArea: WorkspaceArea {
        didSet { remember(workspaceArea.rawValue, Self.workspaceAreaKey) }
    }
    @Published var workSection: WorkSection {
        didSet { remember(workSection.rawValue, Self.workSectionKey) }
    }
    /// Legacy right-panel selection kept for compatibility with saved layouts.
    @Published var navigatorTab: NavigatorTab {
        didSet { remember(navigatorTab.rawValue, NavigatorTab.storageKey) }
    }
    /// Left panel: "files" or "issues".
    @Published var leftPanel: String {
        didSet { remember(leftPanel, Self.leftPanelKey) }
    }
    /// The feature opened from the Issues list ("" = the list).
    @Published var issuesFeature: String {
        didSet { remember(issuesFeature, Self.issuesFeatureKey) }
    }
    /// Git tab: local changes or a GitHub section.
    @Published var gitSection: GitSection {
        didSet { remember(gitSection.rawValue, Self.gitSectionKey) }
    }
    /// Stage shown in the Feature tab.
    @Published var featureStage: FeatureStage {
        didSet { remember(featureStage.rawValue, FeatureStage.storageKey) }
    }

    /// Background of this window's welcome screen (BUG-120). The stored value is only the starting choice of the next window.
    @Published var welcomeBackdrop: WelcomeBackdrop {
        didSet { remember(welcomeBackdrop.rawValue, WelcomeBackdrop.storageKey) }
    }

    static let leftPanelKey = "layout.leftPanel"
    static let workspaceAreaKey = "layout.workspaceArea"
    static let workSectionKey = "layout.workSection"
    static let issuesFeatureKey = "layout.issuesFeature"
    static let gitSectionKey = "layout.gitSection"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workspaceArea = defaults.string(forKey: Self.workspaceAreaKey).flatMap(WorkspaceArea.init) ?? .files
        workSection = defaults.string(forKey: Self.workSectionKey).flatMap(WorkSection.init) ?? .features
        let storedNavigator = defaults.string(forKey: NavigatorTab.storageKey).flatMap(NavigatorTab.init) ?? .contents
        navigatorTab = [.terminal, .git, .search].contains(storedNavigator) ? .contents : storedNavigator
        leftPanel = defaults.string(forKey: Self.leftPanelKey) ?? "files"
        issuesFeature = defaults.string(forKey: Self.issuesFeatureKey) ?? ""
        gitSection = defaults.string(forKey: Self.gitSectionKey).flatMap(GitSection.init) ?? .changes
        featureStage = FeatureStage.stored(defaults.string(forKey: FeatureStage.storageKey))
        welcomeBackdrop = WelcomeBackdrop.stored(defaults.string(forKey: WelcomeBackdrop.storageKey))
    }

    private func remember(_ value: String, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
