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
                                            prompt: StudioRealtimePrompts.prompt(StudioPrompts.preparationPrompt(context, spec: spec, appFolder: appFolder),
                                                                                 context: context, spec: spec),
                                            systemPrompt: StudioRealtimePrompts.system(StudioPrompts.preparationSystem),
                                            jsonSchema: StudioRealtimePrompts.schema(StudioPrompts.preparationSchema),
                                            readableFolder: project)
        request.timeout = StudioPreparationLimits().cliTimeout(for: context)
        request.effort = "low"
        request.allowWeb = false
        request.label = "ui-studio:prepare"
        let result = try await CLICompletion.run(request)
        usage(result.inputTokens, result.outputTokens, result.costUSD ?? 0)
        guard let proposal = StudioRealtimePrompts.proposal(StudioPrompts.proposal(from: result.structured), from: result.structured) else {
            throw Unreadable()
        }
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
            notes.append("\(name) renders on the server. When MarkView starts the development server, the requests it makes to the "
                         + "service addresses in its env files and code are simulated too, and it runs on the scenario's clock (see Server "
                         + "connections). Addresses written in the code, databases, and a server started outside MarkView are not simulated.")
        }
        if target.command.contains("manage.py") || target.command.contains("rails") {
            notes.append("Server-rendered pages: when MarkView starts the server, its requests to the service addresses in its "
                         + "environment are simulated; its database is not, and only Node servers follow the scenario's clock.")
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

/// The application map's assistant (REQ-014): the project's CLI, read-only, without the web. The inventory, each group and
/// each refill is one call with a strict schema; its answer is parsed here and validated by the mapper.
struct StudioCLIMapAssistant: StudioMapAssistant {
    let project: URL
    let usage: @Sendable (Int, Int, Double) -> Void

    func inventory(_ request: StudioMapRequest) async throws -> StudioMapInventory {
        let structured = try await run(request, system: StudioMapPrompts.inventorySystem, schema: StudioMapPrompts.inventorySchema)
        guard let inventory = StudioMapParsing.inventory(from: structured) else { throw StudioMapUnreadable(what: "a list of services and endpoints") }
        return inventory
    }

    func prepareGroup(_ request: StudioMapRequest) async throws -> StudioProposal {
        let structured = try await run(request, system: StudioPrompts.preparationSystem, schema: StudioPrompts.preparationSchema)
        guard let proposal = StudioPrompts.proposal(from: structured) else { throw StudioMapUnreadable(what: "a set of rules") }
        return proposal
    }

    func refill(_ request: StudioMapRequest) async throws -> StudioMapRefill {
        let structured = try await run(request, system: StudioMapPrompts.refillSystem, schema: StudioMapPrompts.refillSchema)
        guard let refill = StudioMapPrompts.refill(from: structured) else { throw StudioMapUnreadable(what: "a list of records") }
        return refill
    }

    private func run(_ request: StudioMapRequest, system: String, schema: [String: Any]) async throws -> Any? {
        var completion = CLICompletion.Request(project: project, prompt: request.prompt, systemPrompt: system, jsonSchema: schema,
                                               readableFolder: project)
        completion.timeout = request.timeout
        completion.effort = "low"
        completion.allowWeb = false
        completion.label = request.label
        let result = try await CLICompletion.run(completion)
        usage(result.inputTokens, result.outputTokens, result.costUSD ?? 0)
        return result.structured
    }
}
