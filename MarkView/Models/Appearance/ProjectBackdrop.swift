import Foundation

/// Evidence gathered locally for the welcome screen. No document text is retained or sent to an assistant.
struct ProjectBackdropSignals: Equatable, Sendable {
    enum Platform: String, Sendable { case ios = "iOS", macOS, android = "Android", web = "Web", backend = "Backend", unknown = "Project" }
    var platform: Platform = .unknown
    var sourceFiles = 0
    var modules = 0
    var documentationFiles = 0
    var languages: [String: Int] = [:]
    var sampled = false
    var inspected = false
}

struct ProjectBackdropContext: Equatable, Sendable {
    var identity: String
    var signals: ProjectBackdropSignals
    var openBugs: Int
    var criticalBugs: Int
    var features: Int
    var completedFeatures: Int
    var issuesKnown = true

    /// The same project keeps its composition across launches, unlike a freshly shuffled decoration.
    var seed: UInt64 {
        identity.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }

    /// The scene By Project draws: the first registered scene whose rule matches this evidence, else the default scene. The rules are
    /// registered with the scenes (`BackdropDescriptor.project`), not listed here.
    var scene: WelcomeBackdrop {
        BackdropRegistry.projectRules.first { $0.descriptor.project?.matches?(self) == true }.map(WelcomeBackdrop.init) ?? Self.defaultScene
    }

    /// What a window without a project (no evidence at all) and a project no rule matches get.
    static var defaultScene: WelcomeBackdrop { BackdropRegistry.projectDefault.map(WelcomeBackdrop.init) ?? .off }

    /// Bounded visual detail: a busy project looks busier without producing an unbounded layer tree.
    var detail: Int { min(4, max(1, (openBugs + features) / 8 + signals.sourceFiles / 120 + 1)) }

    /// Why this scene was chosen, in the words of the scene that was.
    var reason: String {
        let chosen = scene
        return BackdropRegistry.entry(chosen.rawValue)?.descriptor.project?.reason(self) ?? ""
    }

    var summary: String {
        var parts = [scene.title, signals.platform.rawValue]
        if issuesKnown {
            parts.append("\(openBugs) open bugs" + (criticalBugs > 0 ? " (\(criticalBugs) critical)" : ""))
            parts.append("\(completedFeatures)/\(features) features complete")
        }
        if signals.inspected {
            let prefix = signals.sampled ? "≥" : ""
            parts.append("\(prefix)\(signals.sourceFiles) source files")
            if signals.documentationFiles > 0 { parts.append("\(prefix)\(signals.documentationFiles) docs") }
            let top = signals.languages.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3)
            if !top.isEmpty { parts.append(top.map(\.key).joined(separator: ", ")) }
        }
        if signals.sampled { parts.append("sampled") }
        return parts.joined(separator: " · ")
    }
}

/// A bounded, cancellable scan off the main thread. Dependencies, generated output and symbolic links are excluded.
enum ProjectBackdropScanner {
    static let entryLimit = 2500
    static let ignored: Set<String> = [".git", ".dde", ".markview", ".build", "node_modules", "pods", "carthage", "vendor", "build", "dist", "deriveddata", "venv", ".venv", "__pycache__", "target", "tests", "testfiles", "fixtures"]
    static let sourceExtensions: Set<String> = ["swift", "m", "mm", "h", "kt", "java", "ts", "tsx", "js", "jsx", "py", "rs", "go", "c", "cpp", "cs", "rb", "dart"]

    static func scan(_ root: URL) -> ProjectBackdropSignals {
        var result = ProjectBackdropSignals()
        var ios = false, mac = false, android = false, web = false, backend = false
        var visited = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return result }
        while let file = entries.nextObject() as? URL, !Task.isCancelled {
            visited += 1
            if visited > entryLimit { result.sampled = true; result.inspected = true; return finish() }
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { entries.skipDescendants(); continue }
            let name = file.lastPathComponent, lower = name.lowercased()
            if ignored.contains(lower) { entries.skipDescendants(); continue }
            if values.isDirectory == true {
                if file.pathExtension == "xcodeproj" { mac = true; result.modules += 1 }
                if lower == "ios" { ios = true }
                if lower == "android" { android = true }
                if lower == "sources" || lower == "packages" || lower == "modules" { result.modules += 1 }
                if entries.level >= 5 { entries.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let ext = file.pathExtension.lowercased()
            if sourceExtensions.contains(ext) {
                result.sourceFiles += 1
                let languages = ["swift": "Swift", "m": "Objective-C", "mm": "Objective-C++", "h": "C/C++", "kt": "Kotlin", "java": "Java", "ts": "TypeScript", "tsx": "TypeScript", "js": "JavaScript", "jsx": "JavaScript", "py": "Python", "rs": "Rust", "go": "Go", "c": "C", "cpp": "C++", "cs": "C#", "rb": "Ruby", "dart": "Dart"]
                if let language = languages[ext] { result.languages[language, default: 0] += 1 }
            }
            if ["md", "mdx", "rst", "adoc"].contains(ext) { result.documentationFiles += 1 }
            guard ["package.json", "package.swift", "project.yml", "project.pbxproj", "pyproject.toml", "requirements.txt", "cargo.toml", "go.mod", "pubspec.yaml"].contains(lower) else { continue }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let data = try? handle.read(upToCount: 32_768)
            try? handle.close()
            let text = data.map { String(decoding: $0, as: UTF8.self).lowercased() } ?? ""
            if text.contains("iphoneos") || text.contains("platform: ios") || text.contains(".ios(") || text.contains("react-native") { ios = true }
            if text.contains("platform: macos") || text.contains(".macos(") { mac = true }
            if ["fastapi", "django", "express", "@nestjs", "axum", "gin-gonic", "spring-boot", "rails"].contains(where: text.contains) { backend = true }
            if ["\"react\"", "\"vue\"", "\"next\"", "\"svelte\"", "\"@angular/core\""].contains(where: text.contains) { web = true }
            if lower == "package.swift" || lower == "cargo.toml" || lower == "go.mod" { result.modules += 1 }
        }
        result.inspected = !Task.isCancelled
        return finish()

        func finish() -> ProjectBackdropSignals {
            result.platform = ios ? .ios : android ? .android : backend ? .backend : web ? .web : mac ? .macOS : .unknown
            return result
        }
    }
}
