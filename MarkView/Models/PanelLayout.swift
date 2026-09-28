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
    /// Right panel: Contents, Search, Git, Terminal or Feature.
    @Published var navigatorTab: TOCView.Tab {
        didSet { remember(navigatorTab.rawValue, TOCView.Tab.storageKey) }
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
        navigatorTab = defaults.string(forKey: TOCView.Tab.storageKey).flatMap(TOCView.Tab.init) ?? .contents
        leftPanel = defaults.string(forKey: Self.leftPanelKey) ?? "files"
        issuesFeature = defaults.string(forKey: Self.issuesFeatureKey) ?? ""
        gitSection = defaults.string(forKey: Self.gitSectionKey).flatMap(GitSection.init) ?? .changes
        featureStage = defaults.string(forKey: FeatureStage.storageKey).flatMap(FeatureStage.init) ?? .explore
    }

    private func remember(_ value: String, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
