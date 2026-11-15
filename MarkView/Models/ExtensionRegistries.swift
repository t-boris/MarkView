import Foundation

// MARK: - Tool Registry (AR-31, DEC-001)

/// Surfaces where a singleton workspace tool can appear (`AR-31`).
struct ToolSurface: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let toolbar        = ToolSurface(rawValue: 1 << 0)
    static let viewMenu       = ToolSurface(rawValue: 1 << 1)
    static let welcomeTile    = ToolSurface(rawValue: 1 << 2)
    static let sessionRestore = ToolSurface(rawValue: 1 << 3)

    static let all: ToolSurface = [.toolbar, .viewMenu, .welcomeTile, .sessionRestore]
}

/// Declarative descriptor for a singleton workspace tool tab (`AR-31`, `DEC-001`).
struct ToolDescriptor: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let icon: String
    let shortcutKey: String?
    let sentinelPrefix: String
    let surfaces: ToolSurface
    let summary: String
}

/// Single source of truth for singleton workspace tools (`AR-31`, `DEC-001`).
enum ToolRegistry {
    static let all: [ToolDescriptor] = [
        ToolDescriptor(
            id: "git",
            title: "Git",
            icon: "arrow.triangle.branch",
            shortcutKey: "g",
            sentinelPrefix: ".markview-git",
            surfaces: [.toolbar, .viewMenu, .welcomeTile, .sessionRestore],
            summary: "Branches, local changes, pull requests, and commit history"
        ),
        ToolDescriptor(
            id: "deployments",
            title: "Deployments",
            icon: "server.rack",
            shortcutKey: "d",
            sentinelPrefix: ".markview-deployments",
            surfaces: [.toolbar, .viewMenu, .welcomeTile, .sessionRestore],
            summary: "Environments, live status checks, logs, and database queries"
        ),
        ToolDescriptor(
            id: "workflow",
            title: "Workflow",
            icon: "point.3.connected.trianglepath.dotted",
            shortcutKey: "w",
            sentinelPrefix: ".markview-workflow",
            surfaces: [.toolbar, .viewMenu, .welcomeTile, .sessionRestore],
            summary: "Project lifecycle stages, transitions, and Definition of Done"
        ),
        ToolDescriptor(
            id: "qa",
            title: "End-to-End QA",
            icon: "checkmark.shield",
            shortcutKey: "q",
            sentinelPrefix: ".markview-qa",
            surfaces: [.toolbar, .viewMenu, .welcomeTile, .sessionRestore],
            summary: "Automated browser and API verification scenarios and runs"
        ),
        ToolDescriptor(
            id: "uiStudio",
            title: "UI Studio",
            icon: "paintbrush.pointed",
            shortcutKey: "u",
            sentinelPrefix: ".markview-ui-studio",
            surfaces: [.toolbar, .viewMenu, .welcomeTile],
            summary: "Live web interface inspection, comparison, and element editing"
        ),
        ToolDescriptor(
            id: "prototype",
            title: "Prototype Studio",
            icon: "rectangle.3.group",
            shortcutKey: "p",
            sentinelPrefix: ".markview-prototype",
            surfaces: [.toolbar, .viewMenu, .welcomeTile],
            summary: "Interactive multi-screen HTML/CSS/JS prototypes from specs or code"
        ),
        ToolDescriptor(
            id: "cockpit",
            title: "Cockpit",
            icon: "gauge.with.dots.needle.67percent",
            shortcutKey: "k",
            sentinelPrefix: ".markview-cockpit",
            surfaces: [.toolbar, .viewMenu, .welcomeTile],
            summary: "Durable multi-step autonomous agent execution over Temporal"
        ),
        ToolDescriptor(
            id: "architecture",
            title: "Architecture",
            icon: "cpu",
            shortcutKey: "a",
            sentinelPrefix: ".markview-architecture",
            surfaces: [.toolbar, .viewMenu, .welcomeTile, .sessionRestore],
            summary: "Project X-Ray architecture map, dependency graph, and PR impact"
        ),
        ToolDescriptor(
            id: "researchMap",
            title: "Research Map",
            icon: "map",
            shortcutKey: "r",
            sentinelPrefix: ".markview-research-map",
            surfaces: [.toolbar, .viewMenu, .welcomeTile, .sessionRestore],
            summary: "Knowledge synthesis graph of topics, sources, and claims"
        ),
        ToolDescriptor(
            id: "discussions",
            title: "Discussions",
            icon: "bubble.left.and.bubble.right",
            shortcutKey: "i",
            sentinelPrefix: ".markview-discussions",
            surfaces: [.toolbar, .viewMenu, .welcomeTile, .sessionRestore],
            summary: "Exploratory questions and design notes before a feature exists"
        ),
    ]

    private static let byID: [String: ToolDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func descriptor(for id: String) -> ToolDescriptor? {
        byID[id]
    }

    static var toolbarTools: [ToolDescriptor] {
        all.filter { $0.surfaces.contains(.toolbar) }
    }

    static var menuTools: [ToolDescriptor] {
        all.filter { $0.surfaces.contains(.viewMenu) }
    }

    static var welcomeTools: [ToolDescriptor] {
        all.filter { $0.surfaces.contains(.welcomeTile) }
    }

    static var sessionRestorableTools: [ToolDescriptor] {
        all.filter { $0.surfaces.contains(.sessionRestore) }
    }
}

// MARK: - Data-Driven Themes & User Theme Loader (AR-32, DEC-003)

/// Web CSS custom property token set for a theme (`AR-32`, `DEC-003`).
struct ThemeWebTokens: Codable, Equatable, Sendable {
    var bgColor: String
    var textColor: String
    var headingColor: String
    var linkColor: String
    var codeBg: String
    var borderColor: String
    var blockquoteColor: String
    var tableStripe: String
    var highlightBg: String

    func cssVariables(accentOverride: ThemeColor? = nil) -> [String: String] {
        let link = accentOverride?.hex ?? linkColor
        return [
            "--bg-color": bgColor,
            "--text-color": textColor,
            "--heading-color": headingColor,
            "--link-color": link,
            "--code-bg": codeBg,
            "--border-color": borderColor,
            "--blockquote-color": blockquoteColor,
            "--table-stripe": tableStripe,
            "--highlight-bg": highlightBg,
        ]
    }
}

/// JSON-serializable theme definition supporting both built-in presets and user theme files
/// in `~/Library/Application Support/MarkView/themes/*.json` (`AR-32`, `DEC-003`).
struct ThemeDefinition: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var summary: String
    var isDark: Bool
    var bg: ThemeColor
    var bgSidebar: ThemeColor
    var bgInput: ThemeColor
    var bgHover: ThemeColor
    var bgActive: ThemeColor
    var bgBanner: ThemeColor
    var text: ThemeColor
    var textDim: ThemeColor
    var textBright: ThemeColor
    var border: ThemeColor
    var accent: ThemeColor
    var green: ThemeColor
    var orange: ThemeColor
    var yellow: ThemeColor
    var purple: ThemeColor
    var red: ThemeColor
    var cyan: ThemeColor
    var webTokens: ThemeWebTokens?

    /// Derives web CSS tokens automatically when a theme specifies only native colours (`DEC-003`).
    var effectiveWebTokens: ThemeWebTokens {
        if let webTokens { return webTokens }
        let readableAccent = accent.adjusted(toContrast: ThemePalette.readableContrast, against: [bg, bgSidebar])
        let stripe = bg.mixed(with: bgSidebar, fraction: 0.6)
        let highlight = bg.mixed(with: yellow, fraction: isDark ? 0.25 : 0.30)
        return ThemeWebTokens(
            bgColor: bg.hex,
            textColor: text.hex,
            headingColor: textBright.hex,
            linkColor: readableAccent.hex,
            codeBg: bgSidebar.hex,
            borderColor: border.hex,
            blockquoteColor: textDim.hex,
            tableStripe: stripe.hex,
            highlightBg: highlight.hex
        )
    }

    /// Builds a validated `ThemePalette` from this definition, enforcing WCAG contrast (`AR-32`).
    func makePalette(accentOverride: ThemeColor? = nil) -> ThemePalette {
        let chosenAccent = accentOverride ?? accent
        let readableBody = text.adjusted(toContrast: ThemePalette.readableContrast, against: [bg])
        let readableBlue = chosenAccent.adjusted(toContrast: ThemePalette.readableContrast, against: [bg, bgSidebar])
        let selection = bg.mixed(with: chosenAccent, fraction: isDark ? 0.38 : 0.24)
        let mappedTheme = AppTheme(rawValue: id) ?? (isDark ? .darcula : .paper)
        return ThemePalette(
            theme: mappedTheme,
            isDark: isDark,
            bg: bg,
            bgSidebar: bgSidebar,
            bgInput: bgInput,
            bgHover: bgHover,
            bgActive: bgActive,
            bgBanner: bgBanner,
            text: readableBody,
            textDim: textDim,
            textBright: textBright,
            border: border,
            selection: selection,
            accent: chosenAccent,
            defaultAccent: accent,
            onAccent: chosenAccent.readableText,
            blue: readableBlue,
            green: green,
            orange: orange,
            yellow: yellow,
            purple: purple,
            red: red,
            cyan: cyan,
            badge: chosenAccent
        )
    }
}

enum ThemeRegistry {
    static var defaultUserThemesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("MarkView/themes", isDirectory: true)
    }

    /// Converts every built-in `AppTheme` (excluding `.system`) into its declarative `ThemeDefinition`.
    static let builtIn: [ThemeDefinition] = AppTheme.allCases.filter { $0 != .system }.map { theme in
        let p = ThemePalette.make(theme)
        return ThemeDefinition(
            id: theme.rawValue,
            displayName: theme.displayName,
            summary: theme.summary,
            isDark: p.isDark,
            bg: p.bg,
            bgSidebar: p.bgSidebar,
            bgInput: p.bgInput,
            bgHover: p.bgHover,
            bgActive: p.bgActive,
            bgBanner: p.bgBanner,
            text: p.text,
            textDim: p.textDim,
            textBright: p.textBright,
            border: p.border,
            accent: p.defaultAccent,
            green: p.green,
            orange: p.orange,
            yellow: p.yellow,
            purple: p.purple,
            red: p.red,
            cyan: p.cyan,
            webTokens: nil
        )
    }

    /// Loads and validates user theme JSON files from `directory` (`~/Library/Application Support/MarkView/themes/`).
    /// Malformed files or files with empty `id`/`displayName` are skipped safely (`AR-32`, `DEC-003`).
    static func loadUserThemes(from directory: URL = defaultUserThemesDirectory) -> [ThemeDefinition] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        var loaded: [ThemeDefinition] = []
        var seenIDs = Set<String>()
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let def = try? decoder.decode(ThemeDefinition.self, from: data) else {
                continue
            }
            let cleanID = def.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanName = def.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty, !cleanName.isEmpty, seenIDs.insert(cleanID).inserted else {
                continue
            }
            loaded.append(def)
        }
        return loaded
    }

    static func allThemes(userDirectory: URL = defaultUserThemesDirectory) -> [ThemeDefinition] {
        var result = builtIn
        let existingIDs = Set(result.map(\.id))
        for userTheme in loadUserThemes(from: userDirectory) where !existingIDs.contains(userTheme.id) {
            result.append(userTheme)
        }
        return result
    }
}

// MARK: - Layout Presets (AR-33, DEC-002)

/// Named window layout preset applied only on explicit user choice (`AR-33`, `DEC-002`).
struct LayoutPreset: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let workspaceArea: WorkspaceArea
    let workSection: WorkSection
    let navigatorTab: NavigatorTab
    let leftPanel: String
    let showFileTree: Bool
    let showNavigator: Bool
    let centerToolId: String?

    static let writing = LayoutPreset(
        id: "writing",
        title: "Writing",
        symbol: "doc.text",
        summary: "Focused document editing with file tree and document outline",
        workspaceArea: .files,
        workSection: .features,
        navigatorTab: .contents,
        leftPanel: "files",
        showFileTree: true,
        showNavigator: true,
        centerToolId: nil
    )

    static let review = LayoutPreset(
        id: "review",
        title: "Review",
        symbol: "arrow.triangle.branch",
        summary: "Code and specification review with Git changes and tasks",
        workspaceArea: .work,
        workSection: .git,
        navigatorTab: .git,
        leftPanel: "issues",
        showFileTree: true,
        showNavigator: true,
        centerToolId: "git"
    )

    static let qa = LayoutPreset(
        id: "qa",
        title: "QA",
        symbol: "checkmark.shield",
        summary: "End-to-End QA scenarios and browser verification workspace",
        workspaceArea: .work,
        workSection: .features,
        navigatorTab: .feature,
        leftPanel: "issues",
        showFileTree: false,
        showNavigator: true,
        centerToolId: "qa"
    )

    static let cockpit = LayoutPreset(
        id: "cockpit",
        title: "Cockpit",
        symbol: "gauge.with.dots.needle.67percent",
        summary: "Autonomous agent flight path, instruments, and terminal monitor",
        workspaceArea: .work,
        workSection: .terminal,
        navigatorTab: .terminal,
        leftPanel: "issues",
        showFileTree: false,
        showNavigator: true,
        centerToolId: "cockpit"
    )

    static let builtIn: [LayoutPreset] = [writing, review, qa, cockpit]

    static func preset(id: String) -> LayoutPreset? {
        builtIn.first { $0.id == id }
    }
}

// MARK: - Backdrop Registry (AR-34)

struct BackdropDescriptor: Identifiable, Equatable {
    var id: String { backdrop.rawValue }
    let backdrop: WelcomeBackdrop
    let title: String
    let symbol: String
    let isAnimatedScene: Bool
}

enum BackdropRegistry {
    static let all: [BackdropDescriptor] = WelcomeBackdrop.allCases.map { backdrop in
        BackdropDescriptor(
            backdrop: backdrop,
            title: backdrop.title,
            symbol: backdrop.symbol,
            isAnimatedScene: WelcomeBackdrop.animated.contains(backdrop)
        )
    }

    private static let byBackdrop: [WelcomeBackdrop: BackdropDescriptor] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.backdrop, $0) }
    )

    static func descriptor(for backdrop: WelcomeBackdrop) -> BackdropDescriptor {
        byBackdrop[backdrop] ?? BackdropDescriptor(
            backdrop: backdrop,
            title: backdrop.title,
            symbol: backdrop.symbol,
            isAnimatedScene: WelcomeBackdrop.animated.contains(backdrop)
        )
    }
}

// MARK: - MCP Tool Handler Registry (Section 7.5)

struct MCPToolDescriptor: Identifiable, Equatable, Sendable {
    let name: String
    let category: String
    let isMutating: Bool
    let requiredArguments: [String]
    var id: String { name }
}

enum MCPToolRegistry {
    static let all: [MCPToolDescriptor] = [
        MCPToolDescriptor(name: "markview_guide", category: "guide", isMutating: false, requiredArguments: []),
        MCPToolDescriptor(name: "markview_project", category: "project", isMutating: false, requiredArguments: []),
        MCPToolDescriptor(name: "markview_list_features", category: "features", isMutating: false, requiredArguments: []),
        MCPToolDescriptor(name: "markview_get_feature", category: "features", isMutating: false, requiredArguments: ["name"]),
        MCPToolDescriptor(name: "markview_list_bugs", category: "bugs", isMutating: false, requiredArguments: []),
        MCPToolDescriptor(name: "markview_get_bug", category: "bugs", isMutating: false, requiredArguments: ["id"]),
        MCPToolDescriptor(name: "markview_list_prototypes", category: "prototypes", isMutating: false, requiredArguments: []),
        MCPToolDescriptor(name: "markview_get_prototype", category: "prototypes", isMutating: false, requiredArguments: ["slug"]),
        MCPToolDescriptor(name: "markview_create_feature", category: "features", isMutating: true, requiredArguments: ["name", "title", "problem", "goal"]),
        MCPToolDescriptor(name: "markview_add_requirement", category: "features", isMutating: true, requiredArguments: ["feature", "title", "statement", "acceptance_criteria"]),
        MCPToolDescriptor(name: "markview_add_decision", category: "features", isMutating: true, requiredArguments: ["feature", "title", "decision", "rationale"]),
        MCPToolDescriptor(name: "markview_add_question", category: "features", isMutating: true, requiredArguments: ["feature", "question"]),
        MCPToolDescriptor(name: "markview_create_bug", category: "bugs", isMutating: true, requiredArguments: ["title", "symptom"]),
        MCPToolDescriptor(name: "markview_set_status", category: "lifecycle", isMutating: true, requiredArguments: ["feature", "status"]),
        MCPToolDescriptor(name: "markview_set_bug_status", category: "lifecycle", isMutating: true, requiredArguments: ["id", "status"]),
        MCPToolDescriptor(name: "markview_issue_context", category: "lifecycle", isMutating: false, requiredArguments: ["issue"]),
        MCPToolDescriptor(name: "markview_attach_issue", category: "lifecycle", isMutating: true, requiredArguments: ["issue", "session"]),
        MCPToolDescriptor(name: "markview_confirm_delivery", category: "lifecycle", isMutating: true, requiredArguments: ["issue", "environment", "summary"]),
        MCPToolDescriptor(name: "markview_get_workflow", category: "workflow", isMutating: false, requiredArguments: []),
        MCPToolDescriptor(name: "markview_propose_workflow", category: "workflow", isMutating: true, requiredArguments: ["workflow"]),
        MCPToolDescriptor(name: "markview_update_feature", category: "features", isMutating: true, requiredArguments: ["name"]),
        MCPToolDescriptor(name: "markview_update_object", category: "features", isMutating: true, requiredArguments: ["feature", "id"]),
        MCPToolDescriptor(name: "markview_answer_question", category: "features", isMutating: true, requiredArguments: ["feature", "id", "answer"]),
        MCPToolDescriptor(name: "markview_add_source", category: "features", isMutating: true, requiredArguments: ["feature", "title"]),
        MCPToolDescriptor(name: "markview_add_discussion_note", category: "features", isMutating: true, requiredArguments: ["feature", "heading", "body"]),
        MCPToolDescriptor(name: "markview_update_bug", category: "bugs", isMutating: true, requiredArguments: ["id"]),
        MCPToolDescriptor(name: "markview_answer_bug_question", category: "bugs", isMutating: true, requiredArguments: ["id", "question_id", "answer"]),
        MCPToolDescriptor(name: "markview_link_issue", category: "lifecycle", isMutating: true, requiredArguments: ["issue"]),
        MCPToolDescriptor(name: "markview_open_questions", category: "features", isMutating: false, requiredArguments: []),
        MCPToolDescriptor(name: "markview_discussions", category: "discussions", isMutating: false, requiredArguments: []),
        MCPToolDescriptor(name: "markview_get_discussion", category: "discussions", isMutating: false, requiredArguments: ["id"]),
        MCPToolDescriptor(name: "markview_create_discussion", category: "discussions", isMutating: true, requiredArguments: ["question"]),
        MCPToolDescriptor(name: "markview_discussion_item", category: "discussions", isMutating: true, requiredArguments: ["id", "item_id"]),
        MCPToolDescriptor(name: "markview_deployments", category: "deployments", isMutating: false, requiredArguments: []),
        MCPToolDescriptor(name: "markview_deployments_propose", category: "deployments", isMutating: true, requiredArguments: ["environment", "command"]),
        MCPToolDescriptor(name: "markview_deployments_status", category: "deployments", isMutating: false, requiredArguments: ["environment"]),
        MCPToolDescriptor(name: "markview_deployments_run", category: "deployments", isMutating: true, requiredArguments: ["environment", "operation"]),
        MCPToolDescriptor(name: "markview_deployments_logs", category: "deployments", isMutating: false, requiredArguments: ["environment"]),
        MCPToolDescriptor(name: "markview_deployments_db", category: "deployments", isMutating: false, requiredArguments: ["environment", "query"]),
        MCPToolDescriptor(name: "markview_cockpit_report_progress", category: "cockpit", isMutating: true, requiredArguments: ["summary"]),
        MCPToolDescriptor(name: "markview_cockpit_complete_step", category: "cockpit", isMutating: true, requiredArguments: ["summary"]),
        MCPToolDescriptor(name: "markview_cockpit_ask", category: "cockpit", isMutating: true, requiredArguments: ["question"]),
    ]

    private static let byName: [String: MCPToolDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    static func descriptor(for name: String) -> MCPToolDescriptor? {
        byName[name]
    }
}

// MARK: - File Type Descriptor Table (Section 7.6)

struct FileTypeDescriptor: Equatable, Sendable {
    let kind: String
    let extensions: Set<String>
    let symbol: String
    let colorName: String
    let viewerMode: String
}

enum FileTypeRegistry {
    static let all: [FileTypeDescriptor] = [
        FileTypeDescriptor(
            kind: "markdown",
            extensions: ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "txt"],
            symbol: "doc.text.fill",
            colorName: "blue",
            viewerMode: "editor"
        ),
        FileTypeDescriptor(
            kind: "code",
            extensions: ["swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "cs", "php", "sh", "bash", "zsh", "yml", "yaml", "json", "toml", "xml", "html", "css", "scss", "sql", "graphql", "proto", "dockerfile", "makefile"],
            symbol: "chevron.left.forwardslash.chevron.right",
            colorName: "purple",
            viewerMode: "code"
        ),
        FileTypeDescriptor(
            kind: "data",
            extensions: ["csv", "tsv", "parquet", "xlsx", "xls", "sqlite", "sqlite3", "db", "jsonl", "ndjson", "log"],
            symbol: "tablecells.fill",
            colorName: "green",
            viewerMode: "data"
        ),
        FileTypeDescriptor(
            kind: "image",
            extensions: ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff", "heic"],
            symbol: "photo.fill",
            colorName: "orange",
            viewerMode: "image"
        ),
        FileTypeDescriptor(
            kind: "pdf",
            extensions: ["pdf"],
            symbol: "doc.richtext.fill",
            colorName: "red",
            viewerMode: "pdf"
        ),
        FileTypeDescriptor(
            kind: "archive",
            extensions: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z"],
            symbol: "doc.zipper",
            colorName: "yellow",
            viewerMode: "archive"
        ),
    ]

    static func descriptor(forExtension ext: String) -> FileTypeDescriptor? {
        let lower = ext.lowercased()
        return all.first { $0.extensions.contains(lower) }
    }
}
