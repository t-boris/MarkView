import Foundation

/// Prepares rules for an unknown request with the project's assistant (SIM-07): read-only access to the project, no web,
/// a strict answer schema. Whatever it proposes is validated before it is registered.
struct StudioCLIPreparer: StudioRulePreparing {
    let project: URL
    let appFolder: String
    let spec: StudioEnvironmentSpec
    let usage: @Sendable (Int, Int, Double) -> Void

    struct Unreadable: LocalizedError {
        var errorDescription: String? { "The assistant's answer was not a set of rules." }
    }

    func prepare(_ context: StudioPreparationContext) async throws -> StudioProposal {
        var request = CLICompletion.Request(project: project,
                                            prompt: StudioPrompts.preparationPrompt(context, spec: spec, appFolder: appFolder),
                                            systemPrompt: StudioPrompts.preparationSystem,
                                            jsonSchema: StudioPrompts.preparationSchema,
                                            readableFolder: project)
        request.timeout = StudioPreparationLimits().deadline + 5
        request.effort = "low"
        request.allowWeb = false
        request.label = "ui-studio:prepare"
        let result = try await CLICompletion.run(request)
        usage(result.inputTokens, result.outputTokens, result.costUSD ?? 0)
        guard let proposal = StudioPrompts.proposal(from: result.structured) else { throw Unreadable() }
        return proposal
    }
}

/// What a target needs that the first release does not provide (REQ-001): disclosed, never a reason to refuse the target.
enum StudioTargetLimits {
    static func disclosures(for target: WebAppTarget) -> [String] {
        var notes: [String] = []
        let package = (try? Data(contentsOf: target.folder.appendingPathComponent("package.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let dependencies = Set(((package["dependencies"] as? [String: Any]) ?? [:]).keys)
            .union(((package["devDependencies"] as? [String: Any]) ?? [:]).keys)
        let rendering = ["next", "nuxt", "@sveltejs/kit", "@remix-run/dev", "@remix-run/react", "astro", "gatsby", "@angular/ssr",
                         "solid-start", "@solidjs/start", "@builder.io/qwik-city", "@react-router/dev"]
        if let name = rendering.first(where: dependencies.contains) {
            notes.append("\(name) renders on the server: requests the development server makes itself (server components, loaders, "
                         + "server-side data) are not simulated. Requests made in the browser are.")
        }
        if target.command.contains("manage.py") || target.command.contains("rails") {
            notes.append("Server-rendered pages: the server's own requests and its database are not simulated; only requests the "
                         + "browser makes are.")
        }
        if target.isElectron {
            notes.append("Electron: the renderer runs as a web page. The main process, preload scripts, IPC and native modules do "
                         + "not run; their globals are stand-ins that do nothing, so scenarios that need them are not simulated.")
        }
        return notes
    }

    /// Names an Electron preload exposes (`contextBridge.exposeInMainWorld('api', …)`), so their stand-ins carry the real names.
    static func electronGlobals(in folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        let skipped: Set<String> = ["node_modules", "dist", "build", "out", "release", ".vite"]
        var names: [String] = []
        var visited = 0
        for case let url as URL in enumerator {
            if skipped.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            visited += 1
            if visited > 4_000 { break }
            let path = url.path.lowercased()
            guard path.contains("preload"), ["js", "ts", "mjs", "cjs", "mts", "cts"].contains(url.pathExtension.lowercased()),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let pattern = #"exposeInMainWorld\(\s*['"]([A-Za-z_$][\w$]*)['"]"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text), !names.contains(String(text[range])) { names.append(String(text[range])) }
            }
        }
        return names
    }
}
