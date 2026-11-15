import Foundation

/// Shared path facts for source scanning, Code and Logical views. They are
/// available before any assistant has named components.
enum CodePathTags {
    private static let tagFolders: [String: Set<String>] = [
        "tests": ["test", "tests", "__tests__", "spec", "specs", "testing", "e2e", "uitests", "unittests", "fixtures", "__mocks__", "mocks"],
        "docs": ["docs", "doc", "documentation"],
        "config": ["config", "configs", ".github", ".vscode", ".idea", "settings"],
        "build": ["build", "dist", "out", ".build", "target", "deploy", "docker", "ci"],
        "generated": ["generated", "__generated__", "gen", "vendor", "third_party", "thirdparty"],
        "scripts": ["scripts", "script", "tools", "tooling", "bin"],
        "examples": ["examples", "example", "samples", "sample", "demo", "demos"],
    ]

    /// Kind tags of a folder or file from its path alone — deterministic, so hiding works
    /// the same with or without an AI analysis. A test file next to code counts as a test.
    static func tags(_ path: String, isFile: Bool, language: String?) -> [String] {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        let folders = Set(isFile ? Array(parts.dropLast()) : parts)
        let name = isFile ? (parts.last ?? "") : ""
        var tags: [String] = []
        for (tag, names) in tagFolders.sorted(by: { $0.key < $1.key }) where !folders.isDisjoint(with: names) { tags.append(tag) }
        if isFile {
            if Self.isTestPath(path), !tags.contains("tests") { tags.append("tests") }
            if language == "markdown", !tags.contains("docs") { tags.append("docs") }
            if name.contains(".generated.") || name.hasSuffix(".g.dart") || name.hasSuffix(".pb.go") || name.hasSuffix(".min.js"),
               !tags.contains("generated") { tags.append("generated") }
            let isConfig = name.hasPrefix(".") || name.contains(".config.") || name.hasSuffix("config.json") || name.hasSuffix("rc")
                || ["package.json", "tsconfig.json", "project.yml", "podfile", "gemfile", "cargo.toml", "go.mod", "pyproject.toml"].contains(name)
            if isConfig, !tags.contains("config") { tags.append("config") }
            if ["dockerfile", "makefile", "procfile", "jenkinsfile"].contains(name) || name.hasSuffix(".gradle"),
               !tags.contains("build") { tags.append("build") }
        }
        return tags
    }

    static func isTestPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").dropLast()
        if parts.contains(where: { ["test", "tests", "__tests__", "spec", "specs", "testing", "e2e", "uitests", "unittests"].contains(String($0)) }) {
            return true
        }
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let lowerName = name.lowercased()
        return lowerName.hasPrefix("test_") || stem.lowercased().hasSuffix("_test") || lowerName.contains(".test.")
            || lowerName.contains(".spec.") || stem.hasSuffix("Tests") || stem.hasSuffix("Test") || stem.hasSuffix("Spec")
    }

}
