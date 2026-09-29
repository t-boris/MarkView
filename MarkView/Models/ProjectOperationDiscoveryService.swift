import CryptoKit
import Foundation

struct ProjectOperationUnknown: Codable {
    var label: String
    var kind: String
    var environment: String?
    var reason: String
    var investigated: String
}

struct ProjectOperationDiscoveryReport: Codable {
    var proposals: [ProjectOperation]
    var notDetermined: [ProjectOperationUnknown]
    var externalFolders: [String]
    var rejectedReferences: [String]
    var webSources: [String]
    var webSearched: Bool
    var message: String
}

enum ProjectOperationDiscoveryService {
    private struct Candidate: Decodable {
        var id: String
        var label: String
        var kind: String
        var environment: String
        var target: String
        var command: String
        var cwd: String
        var nodeNames: [String]
        var prerequisites: [String]
        var sources: [ProjectOperation.Source]
        var remoteTrigger: Bool
    }

    private struct Unknown: Decodable {
        var label: String
        var kind: String
        var environment: String
        var reason: String
        var investigated: String
    }

    private struct Answer: Decodable {
        var operations: [Candidate]
        var notDetermined: [Unknown]
    }

    struct Result {
        var operations: [ProjectOperation]
        var report: ProjectOperationDiscoveryReport
        var sourceFingerprints: [String: String]
    }

    static func discover(root: URL, existing: [ProjectOperation], deploymentNodes: [ProjectOperation.Node],
                         phase: @escaping @Sendable (String) -> Void) async throws -> Result {
        phase("project files")
        let inputs = await Task.detached(priority: .userInitiated) {
            ProjectOperationDiscovery.scan(root: root)
        }.value
        try Task.checkCancellation()
        phase(inputs.grantedFolders.isEmpty ? "project files" : "external folders")
        let localRequest = request(root: root, inputs: inputs, existing: existing, nodes: deploymentNodes,
                                   unknowns: [], web: false)
        let local = try parse(await CLICompletion.run(localRequest))
        try Task.checkCancellation()
        var candidates = local.operations.map { ($0, false) }
        var unknowns = local.notDetermined
        let tool = AIAssistantPreferences.backend
        let canSearchWeb = tool == .claude || tool == .codex
        var webSearched = false
        if canSearchWeb && !unknowns.isEmpty {
            phase("web")
            let webRequest = request(root: root, inputs: inputs, existing: existing, nodes: deploymentNodes,
                                     unknowns: unknowns, web: true)
            let web = try parse(await CLICompletion.run(webRequest))
            try Task.checkCancellation()
            webSearched = true
            candidates += web.operations.map { ($0, true) }
            unknowns = web.notDetermined
        }

        var usedIDs = Set(existing.map(\.id))
        var operations: [ProjectOperation] = []
        var proposals: [ProjectOperation] = []
        var webSources: [String] = []
        var invalid: [ProjectOperationUnknown] = []
        for (candidate, webAllowed) in candidates {
            guard ProjectOperation.kinds.contains(candidate.kind),
                  !candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !candidate.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let sourceFiles = candidate.sources.compactMap { source -> (ProjectOperation.Source, ProjectOperationDiscovery.InputFile?)? in
                if webAllowed && source.location.hasPrefix("https://") {
                    webSources.append(source.location)
                    return (ProjectOperation.Source(kind: "web", location: source.location, line: source.line), nil)
                }
                guard let file = inputs.files.first(where: { $0.location == source.location || $0.url.path == source.location }) else {
                    return nil
                }
                let location = file.external ? ProjectOperationsStore.storedPath(file.url, root: root) : file.location
                return (ProjectOperation.Source(kind: file.external ? "external" : "project",
                                                location: location, line: source.line), file)
            }
            let cwdURL = ProjectOperationDiscovery.canonical(ProjectOperationsStore.resolve(
                candidate.cwd.isEmpty ? "." : candidate.cwd, root: root))
            if sourceFiles.isEmpty || sourceFiles.count != candidate.sources.count {
                invalid.append(ProjectOperationUnknown(label: candidate.label, kind: candidate.kind,
                    environment: candidate.environment.isEmpty ? nil : candidate.environment,
                    reason: "The proposed command has no verifiable source",
                    investigated: candidate.sources.map(\.location).joined(separator: ", ")))
                continue
            }
            let canonicalRoot = ProjectOperationDiscovery.canonical(root)
            let outside = !cwdURL.path.hasPrefix(canonicalRoot.path + "/") && cwdURL != canonicalRoot
            let permittedOutside = inputs.grantedFolders.contains { cwdURL.path == $0 || cwdURL.path.hasPrefix($0 + "/") }
            if outside && !permittedOutside {
                invalid.append(ProjectOperationUnknown(label: candidate.label, kind: candidate.kind,
                    environment: candidate.environment.isEmpty ? nil : candidate.environment,
                    reason: "Proposed working directory is outside the investigated folders",
                    investigated: candidate.cwd))
                continue
            }
            let cwd = ProjectOperationsStore.storedPath(cwdURL, root: root)
            let environment = candidate.environment.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = candidate.target.trimmingCharacters(in: .whitespacesAndNewlines)
            let tupleMatches = existing.filter { $0.kind == candidate.kind && ($0.environment ?? "") == environment
                && ($0.target ?? "") == target }
            let matching = existing.first { !candidate.id.isEmpty && $0.id == candidate.id }
                ?? (tupleMatches.count == 1 ? tupleMatches.first : nil)
                ?? existing.first { $0.command == candidate.command && $0.cwd == cwd }
            if matching?.deleted == true { continue }
            let id: String
            if let matching { id = matching.id }
            else {
                let raw = [candidate.kind, environment, target].filter { !$0.isEmpty }.joined(separator: "-")
                let slug = (raw.isEmpty ? candidate.label : raw).lowercased()
                    .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                let base = slug.isEmpty ? "operation" : slug
                var next = base, suffix = 2
                while usedIDs.contains(next) { next = "\(base)-\(suffix)"; suffix += 1 }
                id = next
            }
            usedIDs.insert(id)
            let verbatimProject = sourceFiles.contains { source, file in
                source.kind == "project" && (file?.text.contains(candidate.command) ?? false)
            }
            let verbatimExternal = sourceFiles.contains { source, file in
                source.kind == "external" && (file?.text.contains(candidate.command) ?? false)
            }
            let hasWeb = sourceFiles.contains { $0.0.kind == "web" }
            let hasExternal = sourceFiles.contains { $0.0.kind == "external" } || outside
            let confidence = hasWeb ? "low" : verbatimProject && !hasExternal ? "high"
                : verbatimExternal || !hasExternal ? "medium" : "low"
            let nodes = deploymentNodes.filter { candidate.nodeNames.contains($0.name) || candidate.nodeNames.contains($0.id) }
            let operation = ProjectOperation(id: id, label: candidate.label, kind: candidate.kind,
                environment: environment.isEmpty ? nil : environment, target: target.isEmpty ? nil : target,
                nodes: nodes, command: candidate.command, cwd: cwd, origin: "discovered",
                discovered: .init(command: candidate.command, cwd: cwd), confidence: confidence,
                prerequisites: candidate.prerequisites, provenance: sourceFiles.map(\.0),
                remoteTrigger: candidate.remoteTrigger)
            if hasWeb || hasExternal { proposals.append(operation) }
            else { operations.append(operation) }
        }
        let notDetermined = unknowns.filter { ProjectOperation.kinds.contains($0.kind) }.map {
            ProjectOperationUnknown(label: $0.label, kind: $0.kind,
                environment: $0.environment.isEmpty ? nil : $0.environment,
                reason: $0.reason, investigated: $0.investigated)
        } + invalid
        let report = ProjectOperationDiscoveryReport(proposals: proposals, notDetermined: notDetermined,
            externalFolders: inputs.grantedFolders, rejectedReferences: inputs.rejectedReferences,
            webSources: Array(Set(webSources)).sorted(), webSearched: webSearched,
            message: canSearchWeb ? "Discovery completed." : "Discovery completed. This assistant did not search the web.")
        let fingerprints = Dictionary(uniqueKeysWithValues: inputs.files.map { file in
            let path = ProjectOperationsStore.storedPath(file.url, root: root)
            let digest = SHA256.hash(data: Data(file.text.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return (path, digest)
        })
        return Result(operations: operations, report: report, sourceFingerprints: fingerprints)
    }

    private static func parse(_ result: CLICompletion.Result) throws -> Answer {
        guard let structured = result.structured,
              JSONSerialization.isValidJSONObject(structured),
              let data = try? JSONSerialization.data(withJSONObject: structured),
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw ProjectOperationError.invalid("Assistant returned invalid operation discovery JSON. Re-discover to try again.")
        }
        return answer
    }

    private static func request(root: URL, inputs: ProjectOperationDiscovery.Inputs,
                                existing: [ProjectOperation], nodes: [ProjectOperation.Node],
                                unknowns: [Unknown], web: Bool) -> CLICompletion.Request {
        let schema: [String: Any] = [
            "type": "object", "properties": [
                "operations": ["type": "array", "items": ["type": "object", "properties": [
                    "id": ["type": "string"], "label": ["type": "string"],
                    "kind": ["type": "string", "enum": ["deploy", "install", "build", "clean", "restart", "other"]],
                    "environment": ["type": "string"], "target": ["type": "string"],
                    "command": ["type": "string"], "cwd": ["type": "string"],
                    "nodeNames": ["type": "array", "items": ["type": "string"]],
                    "prerequisites": ["type": "array", "items": ["type": "string"]],
                    "sources": ["type": "array", "items": ["type": "object", "properties": [
                        "kind": ["type": "string"], "location": ["type": "string"],
                        "line": ["type": "integer"]], "required": ["kind", "location", "line"]]],
                    "remoteTrigger": ["type": "boolean"],
                ], "required": ["id", "label", "kind", "environment", "target", "command", "cwd",
                                 "nodeNames", "prerequisites", "sources", "remoteTrigger"]]],
                "notDetermined": ["type": "array", "items": ["type": "object", "properties": [
                    "label": ["type": "string"], "kind": ["type": "string"],
                    "environment": ["type": "string"], "reason": ["type": "string"],
                    "investigated": ["type": "string"]],
                    "required": ["label", "kind", "environment", "reason", "investigated"]]],
            ], "required": ["operations", "notDetermined"]]
        let known = existing.map { "\($0.id) | \($0.kind) | \($0.environment ?? "") | \($0.target ?? "") | \($0.command)" }
            .joined(separator: "\n")
        let nodeList = nodes.map { "\($0.id) | \($0.name)" }.joined(separator: "\n")
        let prompt = web ? """
            Investigate only these unresolved operational procedures on the web, and return a command only with a source URL.
            \(unknowns.map { "- \($0.label) (\($0.kind), \($0.environment)): \($0.reason)" }.joined(separator: "\n"))

            Project context and local evidence:
            \(inputs.prompt(limit: 60_000))
            """ : """
            Discover every runnable operational command supported by this project: deploy for each environment and target,
            install, build, clean, restart, and other procedures such as migrations. Inspect the provided file excerpts only.
            Do not run commands, invent commands, or infer a command without evidence. For an unknown tool or procedure,
            return a notDetermined item, which may be investigated on the web in a second pass. A workflow_dispatch
            workflow is a remote trigger: propose a gh workflow run command, one per fixed environment choice, and
            mark remoteTrigger true. Other required workflow inputs belong in prerequisites.

            Existing operations (reuse their ids when they match):
            \(known)

            Deployment nodes (nodeNames must use these ids or names):
            \(nodeList)

            Project files followed by referenced external folders:
            \(inputs.prompt())
            """
        var request = CLICompletion.Request(prompt: prompt, systemPrompt: """
            Return only the requested JSON. Discovery is read-only. Never execute project commands or modify files.
            A source location must be an exact [FILE] path supplied above, or an HTTPS URL you consulted during web research.
            Put a one-based line number when available, otherwise 0. Use empty strings for absent environment, target or id.
            The command must be the exact runnable shell text you propose. Never include secrets. Use cwd '.' for the project root.
            The web may be used only in the web phase; local project and referenced folders have already been examined first.
            """, jsonSchema: schema)
        request.timeout = web ? 300 : 600
        // The X-Ray model at low effort: a compact answer in seconds instead of minutes.
        request.model = AIAssistantPreferences.xrayModel(for: request.tool)
        request.effort = "low"
        request.allowWeb = web
        request.readableFolder = nil
        return request
    }
}
