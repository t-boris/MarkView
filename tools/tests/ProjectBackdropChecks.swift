import Foundation

@main
struct ProjectBackdropChecks {
    static var failures = 0
    static func check(_ label: String, _ value: Bool) {
        print("\(value ? "ok" : "FAIL")  \(label)")
        if !value { failures += 1 }
    }
    static func main() async throws {
        var context = ProjectBackdropContext(identity: "/projects/mobile", signals: .init(platform: .ios, inspected: true), openBugs: 0, criticalBugs: 0, features: 4, completedFeatures: 1)
        check("iOS projects become a device blueprint", context.scene == .blueprint)
        context.openBugs = 9
        check("many open bugs override the platform", context.scene == .bugs && context.reason.contains("9 open bugs"))
        context.openBugs = 2; context.criticalBugs = 2
        check("multiple critical bugs surface even in a small backlog", context.scene == .bugs)
        context.criticalBugs = 0; context.openBugs = 0; context.signals.platform = .backend
        check("a backend has circuit flow", context.scene == .circuit)
        context.signals.platform = .web
        check("a web application has circuit flow", context.scene == .circuit)
        context.signals.sourceFiles = 220
        check("many moving parts form an orbital system", context.scene == .orbit)
        context.signals.platform = .ios
        check("a large mobile project keeps its device identity", context.scene == .blueprint)
        context.signals = .init(inspected: true); context.completedFeatures = 4
        check("completed work with no open bugs launches", context.scene == .launch)
        context.completedFeatures = 1
        check("a growing project has a code garden", context.scene == .garden)
        context.issuesKnown = false
        check("unloaded issues are not reported as zero bugs", !context.summary.contains("bugs"))
        let seed = context.seed
        context.openBugs = 10000; context.features = 20000
        check("project composition survives changing issue counts", context.seed == seed && context.detail == 4)
        context.identity = "/projects/other"
        check("another project has its own composition", context.seed != seed)
        check("By Project resolves to the current evidence", WelcomeBackdrop.project.scene(pick: 1, project: context) == context.scene)
        check("an empty window has a usable project-mode fallback", WelcomeBackdrop.project.scene(pick: 1) == .garden)
        check("all five new scenes can be restored", ["orbit", "blueprint", "circuit", "garden", "launch", "project"].allSatisfy { WelcomeBackdrop.stored($0).rawValue == $0 })

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("project.yml", "targets:\n  App:\n    platform: iOS\n")
        try write("App/Scene.swift", "import UIKit\n")
        var found = ProjectBackdropScanner.scan(root)
        check("scanner detects an iOS XcodeGen target", found.platform == .ios && found.sourceFiles == 1 && found.inspected)
        try write("project.yml", "targets:\n  App:\n    platform: macOS\n")
        found = ProjectBackdropScanner.scan(root)
        check("macOS does not become iOS merely because Swift is present", found.platform == .macOS)
        try FileManager.default.removeItem(at: root.appendingPathComponent("project.yml"))
        try write("package.json", #"{"dependencies":{"react":"1"}}"#)
        check("web manifests are detected", ProjectBackdropScanner.scan(root).platform == .web)
        try write("package.json", #"{"dependencies":{"express":"1"}}"#)
        check("backend manifests are detected", ProjectBackdropScanner.scan(root).platform == .backend)
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        try write("node_modules/react-native/package.json", #"{"name":"react-native"}"#)
        try write("build/ios/Generated.swift", "")
        try write("Tests/Fixtures/ios/Scene.swift", "")
        let outside = root.appendingPathComponent("../outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("ios"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        found = ProjectBackdropScanner.scan(root)
        check("dependencies, generated output, tests and symlinks do not classify the project", found.platform == .unknown && found.sourceFiles == 1)
        try write("package.json", String(repeating: " ", count: 33000) + #"{"dependencies":{"react":"1"}}"#)
        check("manifest reads are bounded", ProjectBackdropScanner.scan(root).platform == .unknown)
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        for index in 0..<2700 { try write("Sources/f\(index).swift", "") }
        found = ProjectBackdropScanner.scan(root)
        check("large trees stop at the entry budget and disclose sampling", found.sampled && found.sourceFiles <= ProjectBackdropScanner.entryLimit && found.inspected)
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return ProjectBackdropScanner.scan(root)
        }.value
        check("cancelled scanning stops without publishing a completed inspection", !cancelled.inspected && cancelled.sourceFiles == 0)
        print("Project backdrop checks: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
