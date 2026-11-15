import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

enum WorkspaceArea: String, CaseIterable, Identifiable, Codable {
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

enum WorkSection: String, CaseIterable, Identifiable, Codable {
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
enum NavigatorTab: String, CaseIterable, Codable {
    case contents = "Contents"
    case search = "Search"
    case git = "Git"
    case terminal = "Terminal"
    case feature = "Feature"

    /// What the tab is called. The raw values are stored in saved layouts and stay as they were.
    var title: String {
        switch self {
        case .terminal: return "Agents"
        case .feature: return "Tasks"
        default: return rawValue
        }
    }
}

/// The stages of a feature (spec §5), kept in Models (`AR-22`).
enum FeatureStage: String, CaseIterable, Codable {
    case explore = "Explore", review = "Review", build = "Build"

    /// A stored stage; the former Resolve stage opens Review.
    static func stored(_ raw: String?) -> FeatureStage {
        raw == "Resolve" ? .review : raw.flatMap(FeatureStage.init) ?? .explore
    }
}

/// Git tab sections kept in Models (`AR-22`).
enum GitSection: String, CaseIterable, Codable {
    case changes = "Changes"
    case pullRequests = "PRs"
    case issues = "Issues"
    case actions = "Actions"
}

/// The tab or section each panel of one window shows. Every window owns one through its
/// WorkspaceManager, so switching a tab in one window leaves the others alone (BUG-004).
/// A change is written to UserDefaults only as the starting value for the next window and for
/// relaunch; no view observes those keys (as @AppStorage would, in every window at once).
@MainActor
final class PanelLayout: ObservableObject {
    @Published var workspaceArea: WorkspaceArea {
        didSet { remember(workspaceArea.rawValue, Setting.layoutWorkspaceArea) }
    }
    @Published var workSection: WorkSection {
        didSet { remember(workSection.rawValue, Setting.layoutWorkSection) }
    }
    /// Legacy right-panel selection kept for compatibility with saved layouts.
    @Published var navigatorTab: NavigatorTab {
        didSet { remember(navigatorTab.rawValue, Setting.layoutNavigatorTab) }
    }
    /// Left panel: "files" or "issues".
    @Published var leftPanel: String {
        didSet { remember(leftPanel, Setting.layoutLeftPanel) }
    }
    /// The feature opened from the Issues list ("" = the list).
    @Published var issuesFeature: String {
        didSet { remember(issuesFeature, Setting.layoutIssuesFeature) }
    }
    /// Git tab: local changes or a GitHub section.
    @Published var gitSection: GitSection {
        didSet { remember(gitSection.rawValue, Setting.layoutGitSection) }
    }
    /// Stage shown in the Feature tab.
    @Published var featureStage: FeatureStage {
        didSet { remember(featureStage.rawValue, Setting.featureStage) }
    }

    /// Background of this window's welcome screen (BUG-120). The stored value is only the starting choice of the next window.
    @Published var welcomeBackdrop: WelcomeBackdrop {
        didSet { remember(welcomeBackdrop.rawValue, Setting.welcomeBackdrop) }
    }

    private let settings: Settings

    init(defaults: UserDefaults = .standard) {
        let settings = Settings(defaults)
        self.settings = settings
        workspaceArea = WorkspaceArea(rawValue: settings.value(Setting.layoutWorkspaceArea)) ?? .files
        workSection = WorkSection(rawValue: settings.value(Setting.layoutWorkSection)) ?? .features
        let storedNavigator = NavigatorTab(rawValue: settings.value(Setting.layoutNavigatorTab)) ?? .contents
        navigatorTab = [.terminal, .git, .search].contains(storedNavigator) ? .contents : storedNavigator
        leftPanel = settings.value(Setting.layoutLeftPanel)
        issuesFeature = settings.value(Setting.layoutIssuesFeature)
        gitSection = GitSection(rawValue: settings.value(Setting.layoutGitSection)) ?? .changes
        featureStage = FeatureStage.stored(settings.stored(Setting.featureStage))
        welcomeBackdrop = WelcomeBackdrop.stored(settings.stored(Setting.welcomeBackdrop))
    }

    private func remember(_ value: String, _ key: SettingsKey<String>) {
        settings.set(value, for: key)
    }
}
