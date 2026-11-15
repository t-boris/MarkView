import Foundation

/// Typed UserDefaults key descriptor (`AR-18`).
public struct DefaultsKey<Value: Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value
    public let isPerProject: Bool

    public init(_ name: String, default defaultValue: Value, isPerProject: Bool = false) {
        self.name = name
        self.defaultValue = defaultValue
        self.isPerProject = isPerProject
    }
}

/// Centralised registry of MarkView settings keys and defaults (`AR-18`).
public enum SettingsRegistry {
    public static let appFontScalePercent = DefaultsKey<Int>("appFontScalePercent", default: 100)
    public static let editorTextSizeMirror = DefaultsKey<Double>("editorTextSizeMirror", default: 13.0)
    public static let aiBackend = DefaultsKey<String>("settings.ai.backend", default: "claude")
    public static let projectAIChoice = DefaultsKey<String>("project.ai", default: "", isPerProject: true)
    public static let gitHubEnabled = DefaultsKey<Bool>("settings.github.enabled", default: false)
    public static let workspaceLastFolder = DefaultsKey<String>("workspace.lastFolder", default: "")
    public static let workspaceRecentProjects = DefaultsKey<[String]>("workspace.recentProjects", default: [])
    public static let layoutWorkspaceArea = DefaultsKey<String>("layout.workspaceArea", default: "Files")
    public static let layoutWorkSection = DefaultsKey<String>("layout.workSection", default: "Tasks")
    public static let layoutNavigatorTab = DefaultsKey<String>("layout.navigatorTab", default: "Contents")
    public static let layoutLeftPanel = DefaultsKey<String>("layout.leftPanel", default: "files")
    public static let layoutGitSection = DefaultsKey<String>("layout.gitSection", default: "Changes")
    public static let layoutWelcomeBackdrop = DefaultsKey<String>("layout.welcomeBackdrop", default: "none")
    public static let layoutPreset = DefaultsKey<String>("layout.preset", default: "writing")

    public static let allKeyNames: Set<String> = [
        appFontScalePercent.name,
        editorTextSizeMirror.name,
        aiBackend.name,
        projectAIChoice.name,
        gitHubEnabled.name,
        workspaceLastFolder.name,
        workspaceRecentProjects.name,
        layoutWorkspaceArea.name,
        layoutWorkSection.name,
        layoutNavigatorTab.name,
        layoutLeftPanel.name,
        layoutGitSection.name,
        layoutWelcomeBackdrop.name,
        layoutPreset.name,
    ]

    public static func string(_ key: DefaultsKey<String>, in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key.name) ?? key.defaultValue
    }

    public static func set(_ value: String, for key: DefaultsKey<String>, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key.name)
    }

    public static func int(_ key: DefaultsKey<Int>, in defaults: UserDefaults = .standard) -> Int {
        (defaults.object(forKey: key.name) as? Int) ?? key.defaultValue
    }

    public static func set(_ value: Int, for key: DefaultsKey<Int>, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key.name)
    }

    public static func bool(_ key: DefaultsKey<Bool>, in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: key.name) as? Bool) ?? key.defaultValue
    }

    public static func set(_ value: Bool, for key: DefaultsKey<Bool>, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key.name)
    }
}
