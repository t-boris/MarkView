import Foundation

/// Every setting MarkView keeps in `UserDefaults` (`AR-18`): the one list of names, defaults and scopes.
///
/// A name is the key in the person's preferences file. It never changes, or the value the person chose is lost on the next
/// launch; `SettingsKeyTableTests` pins every name here to the one the app has always written. Reads and writes go through
/// `Settings`, a window's own interface state through `WindowUIState`, and a SwiftUI property through `@AppStorage(key)` or
/// `@WindowStorage(key)`; no other file names a key. A setting that belongs to a project (`SettingsScope.project`) carries the
/// project in its name, so it is a function of the project token its owner derives.
public enum Setting {
    // MARK: AI assistants

    /// The default assistant (a provider id); "" until one is chosen.
    public static let aiBackend = SettingsKey<String>("settings.ai.backend", default: "")
    /// The model an assistant runs by default ("" = the CLI's own default).
    public static func cliModel(_ tool: String) -> SettingsKey<String> { SettingsKey("settings.cli.\(tool)Model", default: "") }
    /// The model X-Ray runs with by default; `fallback` is the assistant's own default when none is stored.
    public static func xrayModel(_ tool: String, fallback: String) -> SettingsKey<String> {
        SettingsKey("settings.xray.\(tool)Model", default: fallback)
    }
    /// The person's explicit path to an assistant's binary ("" = auto-detect).
    public static func cliPath(_ tool: String) -> SettingsKey<String> { SettingsKey("settings.cli.\(tool)Path", default: "") }
    /// The models an ACP assistant's account offered when last listed (JSON); absent until listed.
    public static func cliModelList(_ tool: String) -> SettingsKey<Data> { SettingsKey("settings.cli.\(tool)Models", default: Data()) }
    /// Extra `PATH` entries the person configured (colon- or newline-separated).
    public static let extraPATH = SettingsKey<String>("settings.cli.extraPATH", default: "")
    /// Automatic code analysis of code projects.
    public static let autoAnalyze = SettingsKey<Bool>("xray.autoAnalyze", default: true)
    /// The language everything the AI writes is in ("document" = the document's own).
    public static let outputLanguage = SettingsKey<String>("actions.outputLanguage", default: "document")
    /// The person's own X-Ray filters (JSON).
    public static let customFilters = SettingsKey<Data>("ai.customFilters", default: Data())
    /// One project's assistant, model and X-Ray model choices, by project key (JSON per project).
    public static let projectAI = SettingsKey<[String: Any]>("project.ai", default: [:], scope: .project)
    /// Minutes a research run may take.
    public static let researchTimeoutMinutes = SettingsKey<Int>("research.timeoutMinutes", default: 20)
    /// Web search switched off for one project (`token`: the project's hash).
    public static func researchWebDisabled(project token: String) -> SettingsKey<Bool> {
        SettingsKey("research.webDisabled.\(token)", default: false, scope: .project)
    }
    /// Model names seen in the lifecycle evidence, most recent first.
    public static let lifecycleModels = SettingsKey<[String]>("lifecycle.models", default: [])
    /// A project's planner assistant and model for the Cockpit (`key`: the project key).
    public static func cockpitPlannerAgent(project key: String) -> SettingsKey<String> {
        SettingsKey("cockpit.plannerAgent.\(key)", default: "", scope: .project)
    }
    public static func cockpitPlannerModel(project key: String) -> SettingsKey<String> {
        SettingsKey("cockpit.plannerModel.\(key)", default: "", scope: .project)
    }

    // MARK: Agent usage

    /// The person hid an assistant's usage indicator.
    public static func usageHidden(_ agent: String) -> SettingsKey<Bool> { SettingsKey("settings.usage.\(agent).hidden", default: false) }
    /// The person's fallback usage limit for an assistant (JSON); absent when none is set.
    public static func usageLimit(_ agent: String) -> SettingsKey<Data> { SettingsKey("settings.usage.\(agent).limit", default: Data()) }

    // MARK: Dictation

    /// The OpenAI key a version before the Keychain wrote here; read once to move it, then removed.
    public static let legacyOpenAIKey = SettingsKey<String>("com.markview.dde.openai.apikey", default: "")
    public static let whisperModel = SettingsKey<String>("settings.whisper.model", default: "whisper-1")
    /// The dictation language as a BCP 47 identifier ("" = follow the system).
    public static let dictationLanguage = SettingsKey<String>("settings.dictation.locale", default: "")

    // MARK: GitHub

    public static let gitHubEnabled = SettingsKey<Bool>("settings.github.enabled", default: false)
    /// Seconds between checks while nothing runs.
    public static let gitHubIdleInterval = SettingsKey<Double>("settings.github.idleInterval", default: 300)
    /// Seconds between checks while a run is active.
    public static let gitHubActiveInterval = SettingsKey<Double>("settings.github.activeInterval", default: 30)
    public static let gitHubNotifyRuns = SettingsKey<Bool>("settings.github.notifyRuns", default: true)
    public static let gitHubAutoReview = SettingsKey<Bool>("settings.github.autoReview", default: true)
    /// The `gh` configuration folder the person chose ("" = by project or the default).
    public static let gitHubConfigDirectory = SettingsKey<String>("settings.github.configDirectory", default: "")

    // MARK: Browser

    /// Whether an assistant is told about the browser tools (`browser.agentTools.<assistant>`).
    /// Retained for one-time migration into per-service MCP selections (`mcp.services.<assistant>`).
    public static func browserAgentTools(_ tool: String) -> SettingsKey<Bool> { SettingsKey("browser.agentTools.\(tool)", default: true) }
    /// Per-service MCP selections for an assistant on this Mac (JSON `AgentMCPSelectionRecord`).
    public static func mcpServiceSelections(_ tool: String) -> SettingsKey<Data> { SettingsKey("mcp.services.\(tool)", default: Data()) }
    /// Whether the legacy agent-wide `browser.agentTools.<assistant>` switch has been migrated for this assistant.
    public static func mcpServiceMigrated(_ tool: String) -> SettingsKey<Bool> { SettingsKey("mcp.services.migrated.\(tool)", default: false) }
    public static let openTerminalLinksInApp = SettingsKey<Bool>("browser.openTerminalLinksInApp", default: true)
    /// Hosts the person said never to save a password for.
    public static let neverSavePasswordHosts = SettingsKey<[String]>("browserNeverSavePasswordHosts", default: [])

    // MARK: Appearance

    /// The application font scale, in percent.
    public static let fontScalePercent = SettingsKey<Int>("appFontScalePercent", default: 100)
    /// The theme settings of the window that changed last (JSON): where a new window starts.
    public static let themeLastChanged = SettingsKey<Data>("theme.lastChanged.v1", default: Data())
    /// The light/dark setting from before themes existed.
    public static let legacyTheme = SettingsKey<String>("theme", default: "")
    /// A chosen colour per project key.
    public static let projectColors = SettingsKey<[String: Any]>("project.colors", default: [:], scope: .project)
    /// Set once the colours saved before DEC-014 were dropped.
    public static let projectColorsByName = SettingsKey<Bool>("project.colors.byFolderName", default: false)
    /// Workspace transparency per project key.
    public static let projectTransparency = SettingsKey<[String: Any]>("project.workspaceTransparency", default: [:], scope: .project)
    public static let pdfTheme = SettingsKey<String>("pdfExport.theme", default: "paper")
    public static let pdfPaper = SettingsKey<String>("pdfExport.paper", default: "a4")

    // MARK: Workspace

    /// Recently opened folders, most recent first.
    public static let recentProjects = SettingsKey<[String]>("workspace.recentProjects", default: [])
    /// The folder to reopen at launch.
    public static let lastFolder = SettingsKey<String>("workspace.lastFolder", default: "")
    public static let fileTreeSortField = SettingsKey<String>("fileTree.sortField", default: "")
    public static let fileTreeSortAscending = SettingsKey<Bool>("fileTree.sortAscending", default: true)
    public static let showTOC = SettingsKey<Bool>("layout.showTOC.v3", default: false)
    /// The folders a project leaves out of its file tree (`path`: the project's standardized path).
    public static func excludedFolders(path: String) -> SettingsKey<[String]> {
        SettingsKey("excludedFolders.\(path)", default: [], scope: .project)
    }
    /// The same list as an earlier version kept it, by the folder's name only (read once, then the project has its own).
    public static func excludedFoldersByName(_ name: String) -> SettingsKey<[String]> {
        SettingsKey("excludedFolders.\(name)", default: [], scope: .project)
    }
    /// The folders linked to each project, by project key (JSON per project).
    public static let linkedFolders = SettingsKey<[String: Any]>("project.linkedFolders", default: [:], scope: .project)
    /// The AI terminals of a folder when MarkView last ran (`token`: the folder's hash).
    public static func aiTerminals(folder token: String) -> SettingsKey<[String: Any]> {
        SettingsKey("aiTerminals.\(token)", default: [:], scope: .project)
    }
    public static let newProjectParentFolder = SettingsKey<String>("newProject.parentFolder", default: "")

    // MARK: Projects (the project's token is the hash its owner derives)

    /// The feature open in a project's Tasks tab.
    public static func featureActive(project token: String) -> SettingsKey<String> {
        SettingsKey("features.active.\(token)", default: "", scope: .project)
    }
    public static func issueFilter(project token: String) -> SettingsKey<[String]> {
        SettingsKey("features.issues.filter.\(token)", default: [], scope: .project)
    }
    public static func issueSort(project token: String) -> SettingsKey<String> {
        SettingsKey("features.issues.sort.\(token)", default: "", scope: .project)
    }
    /// The file fingerprints the last operations discovery of a project saw.
    public static func operationFingerprints(project token: String) -> SettingsKey<[String: Any]> {
        SettingsKey("projectOperations.fingerprints.\(token)", default: [:], scope: .project)
    }
    /// The operation proposals the person rejected in a project.
    public static func operationsRejected(project token: String) -> SettingsKey<[String]> {
        SettingsKey("projectOperations.rejected.\(token)", default: [], scope: .project)
    }

    // MARK: QA and remote

    public static let qaRecordVideo = SettingsKey<Bool>("qaRecordVideo", default: true)
    public static let qaReviewDepth = SettingsKey<String>("qaReviewDepth", default: "screens")
    public static let remoteRelayURL = SettingsKey<String>("remote.relayURL", default: "")
    public static let remoteDeviceID = SettingsKey<String>("remote.deviceID", default: "")

    // MARK: A window's own interface state (`SettingsScope.window`)

    // What a window shows of itself. `WindowUIState` keeps each window's own value and writes the stored value only as the
    // starting value of the next new window (`PanelLayout` does the same for the panel choices).
    public static let layoutWorkspaceArea = SettingsKey<String>("layout.workspaceArea", default: "Files", scope: .window)
    public static let layoutWorkSection = SettingsKey<String>("layout.workSection", default: "Tasks", scope: .window)
    public static let layoutNavigatorTab = SettingsKey<String>("layout.navigatorTab", default: "Contents", scope: .window)
    public static let layoutLeftPanel = SettingsKey<String>("layout.leftPanel", default: "files", scope: .window)
    public static let layoutIssuesFeature = SettingsKey<String>("layout.issuesFeature", default: "", scope: .window)
    public static let layoutGitSection = SettingsKey<String>("layout.gitSection", default: "Changes", scope: .window)
    public static let featureStage = SettingsKey<String>("feature.stage", default: "Explore", scope: .window)
    public static let welcomeBackdrop = SettingsKey<String>("welcomeBackdrop", default: "matrix", scope: .window)
    public static let leftPanelWidth = SettingsKey<Double>("layout.leftPanelWidth", default: 0, scope: .window)
    public static let rightPanelWidth = SettingsKey<Double>("layout.rightPanelWidth", default: 0, scope: .window)
    public static let agentsWidth = SettingsKey<Double>("layout.agentsWidth", default: 650, scope: .window)
    public static let agentsHeight = SettingsKey<Double>("layout.agentsHeight", default: 600, scope: .window)
    public static let agentsOffsetX = SettingsKey<Double>("layout.agentsOffsetX", default: 0, scope: .window)
    public static let agentsOffsetY = SettingsKey<Double>("layout.agentsOffsetY", default: 0, scope: .window)
    /// The document text size the editor slider keeps, mirrored for native text.
    public static let editorTextSizeMirror = SettingsKey<Double>("editorTextSizeMirror", default: 13, scope: .window)
    /// One of the few editor page choices a window keeps for itself (`EditorWindowPrefs.keys`).
    public static func editorPref(_ key: String) -> SettingsKey<String> { SettingsKey("editor.\(key)", default: "", scope: .window) }
    public static let prototypeChatWidth = SettingsKey<Double>("prototypeChatWidth", default: 340, scope: .window)
    public static let prototypePickScreenshot = SettingsKey<Bool>("prototypePickScreenshot", default: true, scope: .window)
    public static let qaPanel = SettingsKey<String>("qa.panel", default: "branches", scope: .window)
    public static let qaInspectorWidth = SettingsKey<Double>("qa.inspectorWidth", default: 380, scope: .window)
    public static let qaShowApps = SettingsKey<Bool>("qa.showApps", default: true, scope: .window)
    public static let qaShowPlayers = SettingsKey<Bool>("qa.showPlayers", default: true, scope: .window)
    public static let qaShowEnvironments = SettingsKey<Bool>("qa.showEnvironments", default: true, scope: .window)
    public static let qaShowBaseline = SettingsKey<Bool>("qa.showBaseline", default: false, scope: .window)
    public static let uiStudioInspectorWidth = SettingsKey<Double>("uiStudioInspectorWidth", default: 380, scope: .window)
    public static let uiStudioSelectionExpanded = SettingsKey<Bool>("uiStudioSelectionExpanded", default: true, scope: .window)
    public static let contentsInfoExpanded = SettingsKey<Bool>("contents.infoExpanded", default: true, scope: .window)
    public static let fileBrowserViewMode = SettingsKey<String>("fileBrowser.viewMode", default: "list", scope: .window)
    public static let fileBrowserShowHidden = SettingsKey<Bool>("fileBrowser.showHidden", default: false, scope: .window)
    public static let fileBrowserHideIgnored = SettingsKey<Bool>("fileBrowser.hideIgnored", default: false, scope: .window)
    public static let fileBrowserCategory = SettingsKey<String>("fileBrowser.category", default: "all", scope: .window)
    public static let imageSlideshowSeconds = SettingsKey<Double>("imageSlideshowSeconds", default: 4, scope: .window)
    public static let searchPanelMode = SettingsKey<String>("search.panelMode", default: "Project", scope: .window)
}
