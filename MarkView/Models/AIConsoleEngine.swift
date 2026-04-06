import Foundation

/// AI Console Engine — runs Claude Code CLI as subprocess
@MainActor
class AIConsoleEngine: ObservableObject {
    enum AIBackend: String, CaseIterable {
        case claude = "Claude Code"
        case codex = "OpenAI Codex"
    }

    @Published var messages: [ConsoleMessage] = []
    @Published var isProcessing = false
    @Published var currentStatus: String?
    @Published var backend: AIBackend = .claude

    let workspaceRoot: URL
    let db: SemanticDatabase?
    private var currentProcess: Process?
    private var hasSessionStarted = false
    private var claudeSessionId: String?
    var onFilesChanged: (([String]) -> Void)?

    static let claudePath = "/Users/boris/.local/bin/claude"
    static let codexPath = "/opt/homebrew/bin/codex"

    /// Full codebase audit prompt — generates comprehensive architecture documentation
    static let codebaseAuditPrompt = """
You are a principal software architect, senior staff engineer, codebase auditor, technical writer, systems analyst, and documentation generator.

Your task is to scan the CURRENT DIRECTORY recursively, analyze the entire codebase, reverse-engineer its architecture, and generate a complete, structured documentation set into a dedicated docs folder inside the project.

Your goal is not to produce a shallow summary. Your goal is to create a documentation system that allows a new senior engineer, architect, or AI agent to understand this project deeply and safely work on it.

PRIMARY OBJECTIVE: Analyze the full codebase and generate comprehensive project documentation including:
1. high-level architecture
2. module-by-module/component-by-component documentation
3. internal interfaces and responsibilities
4. external APIs and third-party integrations
5. data models and schema understanding
6. runtime flows and lifecycle behavior
7. configuration and environment model
8. build, deployment, and operational model
9. risks, issues, technical debt, and weak points
10. missing documentation / ambiguity / inferred areas
11. recommendations for improvement
12. machine-friendly structured index for future AI use

Generate documentation into: ./docs/generated-architecture/

OPERATING MODE: Work as an autonomous architecture and documentation agent.
- Recursively inspect the full directory
- Identify tech stack, project boundaries, subprojects
- Inspect source code, configs, manifests, scripts, infrastructure, tests, Docker, CI/CD, schemas, API specs, migrations
- Infer architecture from real code behavior
- Trace imports, dependencies, service boundaries, data flow
- Distinguish confirmed vs inferred vs unknown
- Generate documentation incrementally and coherently

RULES:
1. Do not invent functionality not supported by code
2. Distinguish: Confirmed from code / Confirmed from config / Confirmed from docs / Inferred from patterns / Unknown
3. Prefer evidence-based documentation
4. Work in phases for large repos
5. Document multiple services separately and as a system
6. Focus on source-of-truth code, deprioritize generated/vendor files
7. Treat tests as evidence of expected behavior
8. Treat CI/CD, Docker, IaC as part of architecture

PHASES:
Phase 1 — Repository Discovery: scan structure, languages, frameworks, package managers, mono/single repo, entry points, build scripts, infrastructure, configs, DB files, API schemas, env files, existing docs, test suites
Phase 2 — Architectural Reconstruction: system purpose, architectural style, components, module boundaries, dependency direction, communication patterns, request/response/async/event flows, persistence, caching, auth, integrations, observability
Phase 3 — Component-Level Analysis: for each component document purpose, responsibility, files, interfaces, classes/functions, inputs/outputs, dependencies, side effects, state, data contracts, lifecycle, error handling, extension points, issues
Phase 4 — External Interfaces: REST/GraphQL/gRPC APIs, webhooks, queues, DB connections, cache, third-party SaaS, payment/auth/cloud providers, analytics, email/SMS, feature flags, file storage
Phase 5 — Data Model and Configuration: entities, DTOs, DB schema, migrations, ORM models, validation, event payloads, config, env vars, feature flags, secrets, runtime modes
Phase 6 — Operational Model: local dev, build pipeline, test workflow, CI/CD, deployment targets, Docker/K8s, migrations, release, rollback, observability
Phase 7 — Risk Analysis: coupling, separation of concerns, implicit/circular dependencies, god modules, duplicated logic, brittle configs, hidden assumptions, missing validation, weak error handling, concurrency hazards, auth/security risks, missing idempotency/timeouts, test gaps, dead code, stale docs, scalability bottlenecks
Phase 8 — Documentation Output: generate full docs structure with index, executive summary, repo map, system overview, architecture, runtime flows, component docs, interfaces, data model, operations, risks, recommendations, appendix, and architecture-index.json

OUTPUT STRUCTURE:
docs/generated-architecture/
  00-index.md, 01-executive-summary.md, 02-repository-map.md, 03-system-overview.md, 04-high-level-architecture.md, 05-runtime-flows.md
  06-components/ (component-<name>.md per component)
  07-interfaces/ (external-apis.md, internal-interfaces.md, events-and-messaging.md)
  08-data/ (domain-model.md, configuration-model.md, persistence-model.md)
  09-operations/ (local-development.md, build-and-release.md, deployment-and-runtime.md, observability.md)
  10-risks/ (technical-debt.md, architecture-risks.md, security-and-reliability-risks.md)
  11-recommendations/ (improvement-roadmap.md, quick-wins.md)
  12-appendix/ (terminology.md, unresolved-questions.md, evidence-and-assumptions.md)
  architecture-index.json

Use Mermaid diagrams, tables, clear headings, evidence-based phrasing. Prefer: "Confirmed in…", "Appears to…", "Likely… based on…", "Could not be confirmed from code", "Needs manual verification".

Now begin by scanning the current directory and building the repository inventory. Then generate the full documentation set.
"""

    /// Full parallel documentation — docs next to code, with metadata and global architecture
    static let fullDocumentationPrompt = """
You are a principal software architect and technical documentation expert.

TASK: Generate COMPLETE documentation for the entire codebase in the current directory.

CRITICAL RULE — DOCUMENTATION PLACEMENT:
Documentation must be placed PARALLEL to the code it documents:
- For a module at src/auth/ → create src/auth/AUTH.md
- For a service at services/payment/ → create services/payment/PAYMENT.md
- For a component at components/Button/ → create components/Button/BUTTON.md
- For the entire project → create docs/ARCHITECTURE.md at root

Each .md file MUST have YAML frontmatter metadata:
```yaml
---
type: module | service | component | library | config | api | infrastructure
name: Human-readable name
path: relative/path/to/code
dependencies: [list, of, dependencies]
layer: presentation | application | domain | infrastructure | external
status: active | deprecated | experimental
last_analyzed: 2026-03-31
confidence: high | medium | low
---
```

DOCUMENTATION STRUCTURE:

1. FOR EACH MODULE/DIRECTORY with source code, create a .md file IN THAT DIRECTORY:
   - Purpose and responsibility
   - Public API / interfaces
   - Key files and what they do
   - Internal architecture
   - Dependencies (imports, external services)
   - Configuration needed
   - Data models owned
   - Error handling approach
   - Test coverage notes
   - Known issues / technical debt
   - Mermaid diagram of internal structure

2. ROOT docs/ folder — GLOBAL documentation:

   docs/ARCHITECTURE.md — Complete system architecture:
   - System overview with Mermaid C4 diagram (%%INTERACTIVE)
   - All layers with components
   - All external integrations
   - Data flow between services
   - Authentication/authorization flow

   docs/PIPELINE.md — Processing pipelines:
   - Request lifecycle
   - Data processing pipelines
   - Background job flows
   - Event-driven flows
   - Mermaid sequence diagrams

   docs/DATA-LAYER.md — Data architecture:
   - All databases and their purpose
   - Schema overview with Mermaid ER diagram (%%INTERACTIVE)
   - Migrations strategy
   - Caching layers
   - Data ownership boundaries

   docs/API-REFERENCE.md — All APIs:
   - REST endpoints
   - GraphQL schemas
   - gRPC services
   - WebSocket events
   - Internal service APIs

   docs/INFRASTRUCTURE.md — Deployment and ops:
   - Docker/container setup
   - CI/CD pipeline
   - Environment configuration
   - Secrets management
   - Monitoring/logging

   docs/DEPENDENCIES.md — External dependency map:
   - All third-party libraries with versions
   - External services/APIs
   - Mermaid dependency graph (%%INTERACTIVE)

   docs/INDEX.md — Master index:
   - Links to ALL generated documentation files
   - Project summary
   - Quick navigation by layer
   - Architecture decision log

   docs/architecture-index.json — Machine-readable index of all docs

RULES:
- Scan EVERY file and directory recursively
- Be THOROUGH — document everything, no shortcuts
- Use Mermaid diagrams with %%INTERACTIVE for all architecture visualizations
- Include code examples where helpful
- Mark confidence levels: confirmed from code / inferred / unknown
- Cross-link between documents using relative markdown links
- Create the docs/ folder and all module-level .md files

Begin scanning the current directory now and generate all documentation.
"""

    init(workspaceRoot: URL, db: SemanticDatabase?) {
        self.workspaceRoot = workspaceRoot
        self.db = db
    }

    // MARK: - Message Model

    struct ConsoleMessage: Identifiable {
        let id = UUID()
        let role: Role
        var content: String
        let timestamp = Date()
        var cost: Double?

        enum Role { case user, assistant, system, error }
    }

    // MARK: - Send Message

    func sendMessage(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isProcessing else { return }

        messages.append(ConsoleMessage(role: .user, content: text))
        isProcessing = true
        currentStatus = backend == .claude ? "Claude is starting..." : "Codex is starting..."

        // Add empty assistant message that we'll update incrementally
        let assistantMsg = ConsoleMessage(role: .assistant, content: "")
        messages.append(assistantMsg)
        let msgIndex = messages.count - 1

        let root = workspaceRoot
        let beforeSnapshot = snapshotFiles(in: root)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            func debugLog(_ msg: String) {
                let line = "\(ISO8601DateFormatter().string(from: Date())) [Console] \(msg)\n"
                let p = NSHomeDirectory() + "/markview_debug.log"
                if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
                else { try? line.write(toFile: p, atomically: true, encoding: .utf8) }
            }

            let process = Process()
            let currentBackend = self.backend
            switch currentBackend {
            case .claude:
                process.executableURL = URL(fileURLWithPath: Self.claudePath)
                var args = ["-p", text, "--dangerously-skip-permissions", "--verbose", "--output-format", "stream-json"]
                if let sessionId = self.claudeSessionId {
                    args.append(contentsOf: ["--resume", sessionId])
                }
                process.arguments = args
            case .codex:
                process.executableURL = URL(fileURLWithPath: Self.codexPath)
                if self.hasSessionStarted {
                    process.arguments = ["exec", "resume", "--last", "--full-auto", "--skip-git-repo-check", text]
                } else {
                    process.arguments = ["exec", "--full-auto", "--skip-git-repo-check", text]
                }
            }
            process.currentDirectoryURL = root
            debugLog("Launching \(currentBackend.rawValue): \(process.executableURL?.path ?? "?") \(process.arguments ?? [])")
            debugLog("CWD: \(root.path)")

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(NSHomeDirectory())/.local/bin"
            process.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            var fullText = ""
            var lineBuffer = ""

            // Stream stdout line by line
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                debugLog("stdout chunk (\(data.count) bytes): \(chunk.prefix(200))")

                lineBuffer += chunk
                while let newlineRange = lineBuffer.range(of: "\n") {
                    let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
                    lineBuffer = String(lineBuffer[newlineRange.upperBound...])

                    // Codex: plain text output — accumulate directly
                    if currentBackend == .codex {
                        if !line.isEmpty {
                            fullText += line + "\n"
                            DispatchQueue.main.async {
                                if msgIndex < self.messages.count {
                                    self.messages[msgIndex] = ConsoleMessage(role: .assistant, content: fullText)
                                    self.objectWillChange.send()
                                }
                                self.currentStatus = "Codex is working..."
                            }
                        }
                        continue
                    }

                    // Claude: parse JSON line
                    guard let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let type = json["type"] as? String else { continue }

                    DispatchQueue.main.async {
                        switch type {
                        case "system":
                            // Capture session_id from init event
                            if json["subtype"] as? String == "init",
                               let sid = json["session_id"] as? String {
                                self.claudeSessionId = sid
                            }

                        case "assistant":
                            if let message = json["message"] as? [String: Any],
                               let content = message["content"] as? [[String: Any]] {
                                for block in content {
                                    if let text = block["text"] as? String {
                                        fullText = text
                                        if msgIndex < self.messages.count {
                                            self.messages[msgIndex] = ConsoleMessage(role: .assistant, content: fullText)
                                            self.objectWillChange.send()
                                        }
                                    }
                                }
                            }
                            self.currentStatus = "Claude is writing..."

                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let text = delta["text"] as? String {
                                fullText += text
                                if msgIndex < self.messages.count {
                                    self.messages[msgIndex] = ConsoleMessage(role: .assistant, content: fullText)
                                    self.objectWillChange.send()
                                }
                            }

                        case "result":
                            if let result = json["result"] as? String {
                                fullText = result
                                if msgIndex < self.messages.count {
                                    self.messages[msgIndex] = ConsoleMessage(role: .assistant, content: fullText,
                                        cost: json["cost_usd"] as? Double ?? json["total_cost_usd"] as? Double)
                                    self.objectWillChange.send()
                                }
                            }
                            self.currentStatus = nil

                        case "system":
                            // System messages (tool use, file operations, etc.)
                            if let subtype = json["subtype"] as? String {
                                self.currentStatus = subtype
                            }

                        default:
                            break
                        }
                    }
                }
            }

            var errorData = Data()
            var codexLog = ""
            var codexRecentLines: [String] = []
            let skipPrefixes = ["OpenAI Codex v", "workdir:", "provider:", "approval:",
                                "sandbox:", "reasoning", "session id:", "tokens used"]
            var skipNextLine = false
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    errorData.append(data)
                    if currentBackend == .codex, let text = String(data: data, encoding: .utf8) {
                        let lines = text.components(separatedBy: "\n")
                        for line in lines {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty || trimmed == "--------" { continue }
                            if skipPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
                            if trimmed == "user" { skipNextLine = true; continue }
                            if skipNextLine { skipNextLine = false; continue }

                            codexLog += trimmed + "\n"
                            // Keep only last 3 lines for the compact display
                            codexRecentLines.append(trimmed)
                            if codexRecentLines.count > 3 { codexRecentLines.removeFirst() }
                            let display = codexRecentLines.joined(separator: "\n")
                            DispatchQueue.main.async {
                                if msgIndex < self.messages.count {
                                    self.messages[msgIndex] = ConsoleMessage(role: .assistant, content: display)
                                    self.objectWillChange.send()
                                }
                                self.currentStatus = "Codex is working..."
                            }
                        }
                    }
                }
            }

            do {
                try process.run()
                self.currentProcess = process
                debugLog("Process launched, PID: \(process.processIdentifier)")
                if currentBackend == .codex {
                    DispatchQueue.main.async { self.currentStatus = "Codex is working..." }
                }
            } catch {
                debugLog("Process LAUNCH FAILED: \(error)")
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.currentStatus = nil
                    self.messages.append(ConsoleMessage(role: .error, content: error.localizedDescription))
                }
                return
            }

            process.waitUntilExit()
            let exitCode = process.terminationStatus
            let stderrText = String(data: errorData, encoding: .utf8) ?? ""
            debugLog("Process exited: \(exitCode), fullText=\(fullText.count) chars, lineBuffer=\(lineBuffer.count) chars")
            debugLog("stderr: \(stderrText.prefix(500))")

            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil

            // Read any remaining stdout data after process exits
            let remaining = stdout.fileHandleForReading.readDataToEndOfFile()
            if let extra = String(data: remaining, encoding: .utf8), !extra.isEmpty {
                lineBuffer += extra
            }
            // Process any remaining text in lineBuffer (last line without trailing \n)
            let leftover = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !leftover.isEmpty {
                fullText += leftover + "\n"
            }

            DispatchQueue.main.async {
                self.currentProcess = nil
                self.isProcessing = false
                self.currentStatus = nil

                let finalText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)

                if currentBackend == .codex {
                    // Remove the compact activity bubble
                    if msgIndex < self.messages.count {
                        self.messages.remove(at: msgIndex)
                    }
                    // Show final answer (or error from stderr if no stdout)
                    if !finalText.isEmpty {
                        self.messages.append(ConsoleMessage(role: .assistant, content: finalText))
                    } else if !codexLog.isEmpty {
                        // Extract just the last meaningful response from the log
                        let logLines = codexLog.trimmingCharacters(in: .whitespacesAndNewlines)
                            .components(separatedBy: "\n")
                        // Find the last "codex" block — that's the actual response
                        if let lastCodexIdx = logLines.lastIndex(where: { $0 == "codex" }) {
                            let response = logLines.suffix(from: logLines.index(after: lastCodexIdx))
                                .joined(separator: "\n")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !response.isEmpty {
                                self.messages.append(ConsoleMessage(role: .assistant, content: response))
                            }
                        }
                    }
                } else {
                    // Claude: fullText was built from streaming JSON
                    if !finalText.isEmpty {
                        if msgIndex < self.messages.count {
                            self.messages[msgIndex] = ConsoleMessage(role: .assistant, content: finalText)
                        }
                    } else if msgIndex < self.messages.count && self.messages[msgIndex].content.isEmpty {
                        self.messages.remove(at: msgIndex)
                    }
                }

                // Mark session as started on success
                if process.terminationStatus == 0 && (!fullText.isEmpty || !codexLog.isEmpty) {
                    self.hasSessionStarted = true
                }

                if process.terminationStatus != 0 {
                    let errText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                    self.messages.append(ConsoleMessage(role: .error, content: errText))
                }

                // Detect file changes and auto-open/refresh them
                let afterSnapshot = self.snapshotFiles(in: root)
                let changed = self.detectChanges(before: beforeSnapshot, after: afterSnapshot)
                if !changed.isEmpty {
                    for file in changed {
                        self.messages.append(ConsoleMessage(role: .system, content: "File: \(file)"))
                    }
                    self.onFilesChanged?(changed)
                }
            }
        }
    }

    // MARK: - Initial File Read

    func readCurrentFile(_ url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let preview = String(content.prefix(8000))
        let fileName = url.lastPathComponent
        messages.append(ConsoleMessage(role: .system, content: "Opened: \(fileName) (\(content.count) chars)"))

        // Don't send to Claude automatically — just show context message
        // User will ask questions about the file
    }

    // MARK: - CLAUDE.md Generation

    func generateSkillFile() {
        guard let db = db else { return }

        var md = "# Project Context — Auto-generated by MarkView DDE\n"
        md += "# Do NOT edit manually. Regenerated on workspace open.\n\n"

        // Workspace info
        md += "## Workspace\n"
        md += "- Root: \(workspaceRoot.path)\n"

        // File listing
        let fm = FileManager.default
        var fileNames: [String] = []
        if let enumerator = fm.enumerator(at: workspaceRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.lowercased() == "md" {
                    fileNames.append(url.lastPathComponent)
                }
            }
        }
        md += "- Total files: \(fileNames.count)\n"
        md += "- Files: \(fileNames.joined(separator: ", "))\n\n"

        // Components from DB
        let modules = db.allModules()
        let contentModules = modules.filter { $0.id.hasPrefix("cmod_") }

        if !contentModules.isEmpty {
            // Group by type
            var byType: [String: [(name: String, desc: String)]] = [:]
            for mod in contentModules {
                let symbols = db.symbolsForModule(mod.id)
                let typeSymbol = symbols.first(where: { $0.kind == "component" })
                let typeName: String
                let desc: String
                if let ctx = typeSymbol?.context, ctx.hasPrefix("["), let end = ctx.firstIndex(of: "]") {
                    typeName = String(ctx[ctx.index(after: ctx.startIndex)..<end])
                    desc = String(ctx[ctx.index(after: end)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    typeName = "component"
                    desc = ""
                }
                byType[typeName, default: []].append((name: mod.name, desc: desc))
            }

            md += "## Semantic Database Export\n\n"
            md += "### Components (\(contentModules.count) total)\n"
            for (type, comps) in byType.sorted(by: { $0.key < $1.key }) {
                md += "\n#### [\(type)] (\(comps.count))\n"
                for comp in comps {
                    md += "- \(comp.name): \(comp.desc)\n"
                }
            }

            // Relations
            var relations: [String] = []
            for mod in contentModules {
                let rels = db.relationsForModule(mod.id)
                for rel in rels {
                    relations.append("- \(mod.name) → \(rel.targetId) (\(rel.type))")
                }
            }
            if !relations.isEmpty {
                md += "\n### Dependencies (\(relations.count) relations)\n"
                for rel in relations.prefix(100) {
                    md += "\(rel)\n"
                }
                if relations.count > 100 { md += "- ... and \(relations.count - 100) more\n" }
            }
        }

        // Headings outline
        let dirModules = modules.filter { !$0.id.hasPrefix("cmod_") }
        if !dirModules.isEmpty {
            md += "\n### Document Structure\n"
            for mod in dirModules {
                let headings = db.symbolsForModule(mod.id).filter { $0.kind == "heading" }
                if !headings.isEmpty {
                    md += "- \(mod.name)/: \(headings.prefix(10).map { $0.name }.joined(separator: ", "))\n"
                }
            }
        }

        md += "\n## Instructions for Claude Code\n"
        md += "- This is a documentation workspace analyzed by MarkView DDE\n"
        md += "- The above data comes from the SQLite semantic database\n"
        md += "- When asked about architecture, use the Components and Dependencies sections\n"
        md += "- When creating .md files, use proper markdown formatting with headings\n"
        md += "- When editing existing files, preserve their structure\n"
        md += "- Follow user instructions precisely regarding language. If the user asks to write a document in a specific language, write it in that language regardless of which language the instruction was given in.\n"

        // Write to workspace
        let claudeDir = workspaceRoot.appendingPathComponent(".claude")
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claudeMdURL = claudeDir.appendingPathComponent("CLAUDE.md")
        try? md.write(to: claudeMdURL, atomically: true, encoding: .utf8)
        NSLog("[AIConsole] Generated CLAUDE.md (\(md.count) chars, \(contentModules.count) components)")
    }

    // MARK: - Claude CLI (streaming is handled in sendMessage)

    // MARK: - File Change Detection

    private func snapshotFiles(in dir: URL) -> [String: Date] {
        var snapshot: [String: Date] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                              options: [.skipsHiddenFiles]) else { return snapshot }
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md" else { continue }
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                let relative = url.path.replacingOccurrences(of: dir.path + "/", with: "")
                snapshot[relative] = date
            }
        }
        return snapshot
    }

    private func detectChanges(before: [String: Date], after: [String: Date]) -> [String] {
        var changed: [String] = []
        for (file, date) in after {
            if let beforeDate = before[file] {
                if date > beforeDate { changed.append(file) }
            } else {
                changed.append(file) // new file
            }
        }
        return changed
    }

    // MARK: - Stop

    func stop() {
        currentProcess?.terminate()
        currentProcess = nil
        isProcessing = false
        currentStatus = nil
    }

    func clearHistory() {
        messages.removeAll()
        hasSessionStarted = false
        claudeSessionId = nil
    }
}
