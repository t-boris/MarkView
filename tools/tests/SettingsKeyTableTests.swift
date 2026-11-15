import Foundation

// AR-18: every persisted setting has a typed key in the registry (`Setting`), and the name of every key is the name an earlier build
// of the app wrote. The person's preferences file is the contract: a key that changes name loses what the person chose.
//
// The table below is written from the keys the app used before the registry existed (the old constants and the string literals
// passed to UserDefaults, @AppStorage and @WindowStorage), one row each:
//   - the old name, the descriptor the registry must give it (scope, value type, default), and a sample value;
//   - behavior: a value an earlier build left under the old name is read through the key; a value written through the key lands
//     under the old name; with nothing stored the key's default applies.
// A family of keys (one per assistant, per project, per folder) has a row for an instance and the pattern it stands for.
//
// Completeness: every key literal in SettingsKeys.swift (argument 1) must be a row's pattern, so a key added to the registry
// without a row fails here. Run through tools/tests/settings-key-table-tests.sh.
setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
var rows = 0
func check(_ ok: Bool, _ message: String) {
    if !ok { failures += 1; print("FAIL \(message)") }
}

let registrySource = CommandLine.arguments[1]

/// A glob where `*` stands for the part a family fills in (an assistant id, a project token, a path).
func matches(_ name: String, _ pattern: String) -> Bool {
    let parts = pattern.components(separatedBy: "*")
    if parts.count == 1 { return name == pattern }
    guard name.hasPrefix(parts.first!), name.hasSuffix(parts.last!), name.count >= parts.joined().count else { return false }
    var rest = Substring(name.dropFirst(parts.first!.count))
    for middle in parts.dropFirst().dropLast() {
        guard let found = rest.range(of: middle) else { return false }
        rest = rest[found.upperBound...]
    }
    return true
}

var patterns: [String] = []
var seenNames: [String: String] = [:]

func freshDefaults() -> (UserDefaults, () -> Void) {
    let suite = "settings-key-table-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (defaults, { defaults.removePersistentDomain(forName: suite) })
}

func same(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSObject, let b = b as? NSObject else { return a == nil && b == nil }
    return a.isEqual(b)
}

/// One row. `pattern` is the registry literal this row stands for (the name itself for a key that is not a family).
func row<V: SettingsValue>(_ old: String, _ key: SettingsKey<V>, _ scope: SettingsScope, _ type: String, default text: String,
                           sample: V, pattern: String? = nil) {
    rows += 1
    let shown = key.erased
    check(shown.name == old, "name: \(old) is now \(shown.name)")
    check(shown.scope == scope, "scope of \(old): \(shown.scope) instead of \(scope)")
    check(shown.valueType == type, "type of \(old): \(shown.valueType) instead of \(type)")
    check(String(describing: key.defaultValue) == text, "default of \(old): \(String(describing: key.defaultValue)) instead of \(text)")
    if let other = seenNames[old] { check(false, "\(old) is the name of two keys (also \(other))") }
    seenNames[old] = String(describing: V.self)
    patterns.append(pattern ?? old)
    check(matches(old, pattern ?? old), "\(old) does not match its pattern \(pattern ?? old)")

    let (defaults, cleanup) = freshDefaults()
    defer { cleanup() }
    let settings = Settings(defaults)
    check(same(settings.stored(key), nil) && same(settings.value(key), key.defaultValue), "nothing stored: the default applies for \(old)")
    // A value an earlier build wrote under the old name.
    defaults.set(sample, forKey: old)
    check(same(settings.value(key), sample), "a value stored under \(old) by an earlier build is read through the key")
    defaults.removeObject(forKey: old)
    // A value written through the key lands under the old name.
    settings.set(sample, for: key)
    check(same(defaults.object(forKey: old), sample), "a value written through the key lands under \(old)")
    settings.remove(key)
    check(defaults.object(forKey: old) == nil, "removing the key removes \(old)")
}

let dictSample: [String: Any] = ["k": "v"]

// MARK: AI assistants

row("settings.ai.backend", Setting.aiBackend, .app, "String", default: "", sample: "codex")
row("settings.cli.claudeModel", Setting.cliModel("claude"), .app, "String", default: "", sample: "opus", pattern: "settings.cli.*Model")
row("settings.cli.antigravityModel", Setting.cliModel("antigravity"), .app, "String", default: "", sample: "flash", pattern: "settings.cli.*Model")
row("settings.xray.claudeModel", Setting.xrayModel("claude", fallback: "sonnet"), .app, "String", default: "sonnet", sample: "haiku", pattern: "settings.xray.*Model")
row("settings.cli.codexPath", Setting.cliPath("codex"), .app, "String", default: "", sample: "/opt/bin/codex", pattern: "settings.cli.*Path")
row("settings.cli.clineModels", Setting.cliModelList("cline"), .app, "Data", default: "0 bytes", sample: Data([1, 2, 3]), pattern: "settings.cli.*Models")
row("settings.cli.extraPATH", Setting.extraPATH, .app, "String", default: "", sample: "/opt/homebrew/bin")
row("xray.autoAnalyze", Setting.autoAnalyze, .app, "Bool", default: "true", sample: false)
row("actions.outputLanguage", Setting.outputLanguage, .app, "String", default: "document", sample: "Russian")
row("ai.customFilters", Setting.customFilters, .app, "Data", default: "0 bytes", sample: Data([9]))
row("project.ai", Setting.projectAI, .project, "Dictionary<String, Any>", default: "[:]", sample: dictSample)
row("research.timeoutMinutes", Setting.researchTimeoutMinutes, .app, "Int", default: "20", sample: 45)
row("research.webDisabled.abc123def456", Setting.researchWebDisabled(project: "abc123def456"), .project, "Bool", default: "false", sample: true, pattern: "research.webDisabled.*")
row("lifecycle.models", Setting.lifecycleModels, .app, "Array<String>", default: "[]", sample: ["opus", "sonnet"])
row("cockpit.plannerAgent.abc123def456", Setting.cockpitPlannerAgent(project: "abc123def456"), .project, "String", default: "", sample: "claude", pattern: "cockpit.plannerAgent.*")
row("cockpit.plannerModel.abc123def456", Setting.cockpitPlannerModel(project: "abc123def456"), .project, "String", default: "", sample: "opus", pattern: "cockpit.plannerModel.*")

// MARK: Agent usage and dictation

row("settings.usage.claude.hidden", Setting.usageHidden("claude"), .app, "Bool", default: "false", sample: true, pattern: "settings.usage.*.hidden")
row("settings.usage.antigravity.limit", Setting.usageLimit("antigravity"), .app, "Data", default: "0 bytes", sample: Data([7]), pattern: "settings.usage.*.limit")
row("com.markview.dde.openai.apikey", Setting.legacyOpenAIKey, .app, "String", default: "", sample: "legacy")
row("settings.whisper.model", Setting.whisperModel, .app, "String", default: "whisper-1", sample: "gpt-4o-transcribe")
row("settings.dictation.locale", Setting.dictationLanguage, .app, "String", default: "", sample: "ru-RU")

// MARK: GitHub and the browser

row("settings.github.enabled", Setting.gitHubEnabled, .app, "Bool", default: "false", sample: true)
row("settings.github.idleInterval", Setting.gitHubIdleInterval, .app, "Double", default: "300.0", sample: 600.0)
row("settings.github.activeInterval", Setting.gitHubActiveInterval, .app, "Double", default: "30.0", sample: 15.0)
row("settings.github.notifyRuns", Setting.gitHubNotifyRuns, .app, "Bool", default: "true", sample: false)
row("settings.github.autoReview", Setting.gitHubAutoReview, .app, "Bool", default: "true", sample: false)
row("settings.github.configDirectory", Setting.gitHubConfigDirectory, .app, "String", default: "", sample: "/Users/x/.config/gh-work")
row("browser.agentTools.codex", Setting.browserAgentTools("codex"), .app, "Bool", default: "true", sample: false, pattern: "browser.agentTools.*")
row("browser.openTerminalLinksInApp", Setting.openTerminalLinksInApp, .app, "Bool", default: "true", sample: false)
row("browserNeverSavePasswordHosts", Setting.neverSavePasswordHosts, .app, "Array<String>", default: "[]", sample: ["example.com"])

// MARK: Appearance

row("appFontScalePercent", Setting.fontScalePercent, .app, "Int", default: "100", sample: 120)
row("theme.lastChanged.v1", Setting.themeLastChanged, .app, "Data", default: "0 bytes", sample: Data([5]))
row("theme", Setting.legacyTheme, .app, "String", default: "", sample: "light")
row("project.colors", Setting.projectColors, .project, "Dictionary<String, Any>", default: "[:]", sample: dictSample)
row("project.colors.byFolderName", Setting.projectColorsByName, .app, "Bool", default: "false", sample: true)
row("project.workspaceTransparency", Setting.projectTransparency, .project, "Dictionary<String, Any>", default: "[:]", sample: dictSample)
row("pdfExport.theme", Setting.pdfTheme, .app, "String", default: "paper", sample: "midnight")
row("pdfExport.paper", Setting.pdfPaper, .app, "String", default: "a4", sample: "letter")

// MARK: Workspace

row("workspace.recentProjects", Setting.recentProjects, .app, "Array<String>", default: "[]", sample: ["/work/one"])
row("workspace.lastFolder", Setting.lastFolder, .app, "String", default: "", sample: "/work/one")
row("fileTree.sortField", Setting.fileTreeSortField, .app, "String", default: "", sample: "modified")
row("fileTree.sortAscending", Setting.fileTreeSortAscending, .app, "Bool", default: "true", sample: false)
row("layout.showTOC.v3", Setting.showTOC, .app, "Bool", default: "false", sample: true)
row("excludedFolders./work/one", Setting.excludedFolders(path: "/work/one"), .project, "Array<String>", default: "[]", sample: ["build"], pattern: "excludedFolders.*")
row("excludedFolders.one", Setting.excludedFoldersByName("one"), .project, "Array<String>", default: "[]", sample: ["dist"], pattern: "excludedFolders.*")
row("project.linkedFolders", Setting.linkedFolders, .project, "Dictionary<String, Any>", default: "[:]", sample: dictSample)
row("aiTerminals.abc123def456", Setting.aiTerminals(folder: "abc123def456"), .project, "Dictionary<String, Any>", default: "[:]", sample: dictSample, pattern: "aiTerminals.*")
row("newProject.parentFolder", Setting.newProjectParentFolder, .app, "String", default: "", sample: "/work")

// MARK: Per project

row("features.active.abc123def456", Setting.featureActive(project: "abc123def456"), .project, "String", default: "", sample: "login", pattern: "features.active.*")
row("features.issues.filter.abc123def456", Setting.issueFilter(project: "abc123def456"), .project, "Array<String>", default: "[]", sample: ["open"], pattern: "features.issues.filter.*")
row("features.issues.sort.abc123def456", Setting.issueSort(project: "abc123def456"), .project, "String", default: "", sample: "date:desc", pattern: "features.issues.sort.*")
row("projectOperations.fingerprints.abc123def456", Setting.operationFingerprints(project: "abc123def456"), .project, "Dictionary<String, Any>", default: "[:]", sample: dictSample, pattern: "projectOperations.fingerprints.*")
row("projectOperations.rejected.abc123def456", Setting.operationsRejected(project: "abc123def456"), .project, "Array<String>", default: "[]", sample: ["h"], pattern: "projectOperations.rejected.*")

// MARK: QA and remote

row("qaRecordVideo", Setting.qaRecordVideo, .app, "Bool", default: "true", sample: false)
row("qaReviewDepth", Setting.qaReviewDepth, .app, "String", default: "screens", sample: "steps")
row("remote.relayURL", Setting.remoteRelayURL, .app, "String", default: "", sample: "https://relay.example")
row("remote.deviceID", Setting.remoteDeviceID, .app, "String", default: "", sample: "6F9619FF-8B86-D011-B42D-00C04FC964FF")

// MARK: A window's own interface state (these seed the next new window; a window keeps its own value)

row("layout.workspaceArea", Setting.layoutWorkspaceArea, .window, "String", default: "Files", sample: "Work")
row("layout.workSection", Setting.layoutWorkSection, .window, "String", default: "Tasks", sample: "Git")
row("layout.navigatorTab", Setting.layoutNavigatorTab, .window, "String", default: "Contents", sample: "Feature")
row("layout.leftPanel", Setting.layoutLeftPanel, .window, "String", default: "files", sample: "issues")
row("layout.issuesFeature", Setting.layoutIssuesFeature, .window, "String", default: "", sample: "login")
row("layout.gitSection", Setting.layoutGitSection, .window, "String", default: "Changes", sample: "PRs")
row("feature.stage", Setting.featureStage, .window, "String", default: "Explore", sample: "Build")
row("welcomeBackdrop", Setting.welcomeBackdrop, .window, "String", default: "matrix", sample: "aurora")
row("layout.leftPanelWidth", Setting.leftPanelWidth, .window, "Double", default: "0.0", sample: 300.0)
row("layout.rightPanelWidth", Setting.rightPanelWidth, .window, "Double", default: "0.0", sample: 520.0)
row("layout.agentsWidth", Setting.agentsWidth, .window, "Double", default: "650.0", sample: 700.0)
row("layout.agentsHeight", Setting.agentsHeight, .window, "Double", default: "600.0", sample: 500.0)
row("layout.agentsOffsetX", Setting.agentsOffsetX, .window, "Double", default: "0.0", sample: 12.0)
row("layout.agentsOffsetY", Setting.agentsOffsetY, .window, "Double", default: "0.0", sample: 24.0)
row("editorTextSizeMirror", Setting.editorTextSizeMirror, .window, "Double", default: "13.0", sample: 16.0)
row("editor.markview-font-size", Setting.editorPref("markview-font-size"), .window, "String", default: "", sample: "16", pattern: "editor.*")
row("prototypeChatWidth", Setting.prototypeChatWidth, .window, "Double", default: "340.0", sample: 360.0)
row("prototypePickScreenshot", Setting.prototypePickScreenshot, .window, "Bool", default: "true", sample: false)
row("qa.panel", Setting.qaPanel, .window, "String", default: "branches", sample: "run")
row("qa.inspectorWidth", Setting.qaInspectorWidth, .window, "Double", default: "380.0", sample: 400.0)
row("qa.showApps", Setting.qaShowApps, .window, "Bool", default: "true", sample: false)
row("qa.showPlayers", Setting.qaShowPlayers, .window, "Bool", default: "true", sample: false)
row("qa.showEnvironments", Setting.qaShowEnvironments, .window, "Bool", default: "true", sample: false)
row("qa.showBaseline", Setting.qaShowBaseline, .window, "Bool", default: "false", sample: true)
row("uiStudioInspectorWidth", Setting.uiStudioInspectorWidth, .window, "Double", default: "380.0", sample: 420.0)
row("uiStudioSelectionExpanded", Setting.uiStudioSelectionExpanded, .window, "Bool", default: "true", sample: false)
row("contents.infoExpanded", Setting.contentsInfoExpanded, .window, "Bool", default: "true", sample: false)
row("fileBrowser.viewMode", Setting.fileBrowserViewMode, .window, "String", default: "list", sample: "tree")
row("fileBrowser.showHidden", Setting.fileBrowserShowHidden, .window, "Bool", default: "false", sample: true)
row("fileBrowser.hideIgnored", Setting.fileBrowserHideIgnored, .window, "Bool", default: "false", sample: true)
row("fileBrowser.category", Setting.fileBrowserCategory, .window, "String", default: "all", sample: "folders")
row("imageSlideshowSeconds", Setting.imageSlideshowSeconds, .window, "Double", default: "4.0", sample: 8.0)
row("search.panelMode", Setting.searchPanelMode, .window, "String", default: "Project", sample: "Documents")

// MARK: The registry source and this table agree

guard let source = try? String(contentsOfFile: registrySource, encoding: .utf8) else {
    print("FAIL cannot read \(registrySource)")
    exit(1)
}
var literals: [String] = []
let marker = try! NSRegularExpression(pattern: #"SettingsKey(?:<[^>]*>)?\("((?:[^"\\]|\\.)*)""#)
for match in marker.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
    guard let range = Range(match.range(at: 1), in: source) else { continue }
    // An interpolation stands for what a family fills in.
    var text = String(source[range])
    while let open = text.range(of: #"\("#), let close = text[open.upperBound...].firstIndex(of: ")") {
        text.replaceSubrange(open.lowerBound...close, with: "*")
    }
    literals.append(text)
}
check(literals.count >= 60, "the registry source was read (\(literals.count) key literals)")
for literal in literals where !patterns.contains(literal) {
    check(false, "the registry has a key named \(literal) that this table has no row for")
}
for pattern in Set(patterns) where !literals.contains(pattern) {
    check(false, "this table has a row for \(pattern), which the registry no longer has")
}

print(failures == 0 ? "All \(rows) setting key rows passed (\(literals.count) registry names)" : "\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
