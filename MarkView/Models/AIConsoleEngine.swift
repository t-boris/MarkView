import Foundation
import AppKit

/// AI Console Engine — runs Claude Code CLI as subprocess
@MainActor
class AIConsoleEngine: ObservableObject {
    @Published var messages: [ConsoleMessage] = []
    @Published var isProcessing = false
    @Published var currentStatus: String?

    let workspaceRoot: URL
    let db: SemanticDatabase?
    private var currentProcess: Process?
    private var hasSessionStarted = false
    private var claudeSessionId: String?
    /// CLI the current session belongs to. The assistant is chosen in
    /// `AIAssistantPreferences` and can change between turns; a session cannot
    /// carry over from one CLI to the other.
    private var sessionBackend: CLITool?
    var onFilesChanged: (([String]) -> Void)?

    // Binary locations are resolved at call time by `CLIToolLocator` — a user
    // override from Settings, then a candidate scan, then a login-shell lookup.
    // They used to be hardcoded here, which silently broke Codex when it was
    // installed via npm/nvm rather than Homebrew.

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

        // Resolve the assistant for this turn on the main actor; the worker below
        // only sees these values.
        let currentBackend = AIAssistantPreferences.backend
        let model = AIAssistantPreferences.model(for: currentBackend)
        if let previous = sessionBackend, previous != currentBackend {
            hasSessionStarted = false
            claudeSessionId = nil
            messages.append(ConsoleMessage(role: .system, content:
                "Switched from \(previous.displayName) to \(currentBackend.displayName) — new session; earlier replies are not in its context."))
        }
        sessionBackend = currentBackend
        let claudeResumeId = claudeSessionId
        let resumeCodex = hasSessionStarted

        messages.append(ConsoleMessage(role: .user, content: text))
        isProcessing = true
        currentStatus = "\(AIAssistantPreferences.summary(tool: currentBackend, model: model ?? "")) is starting..."

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
            let tool = currentBackend

            guard let toolPath = CLIToolLocator.resolve(tool) else {
                // Say exactly what is wrong and where to fix it — a missing binary
                // used to surface only as an opaque NSError from process.run().
                let hint: String
                if let override = CLIToolLocator.override(for: tool) {
                    hint = "The path configured in DDE Settings does not exist or is not executable:\n\(override)"
                } else {
                    hint = "Searched: \(CLIToolLocator.searchDirectories().joined(separator: ", "))"
                }
                let message = "\(tool.displayName) (`\(tool.binaryName)`) was not found.\n\n\(hint)\n\n"
                    + "Open DDE Settings → AI CLI Tools to set the path or run Auto-detect."
                debugLog("Tool not found: \(tool.binaryName). \(hint)")
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.currentStatus = nil
                    self.messages[msgIndex].content = message
                }
                return
            }

            process.executableURL = URL(fileURLWithPath: toolPath)
            switch currentBackend {
            case .claude:
                var args = ["-p", text, "--dangerously-skip-permissions", "--verbose", "--output-format", "stream-json"]
                args.append(contentsOf: tool.modelArgs(model))
                if let sessionId = claudeResumeId {
                    args.append(contentsOf: ["--resume", sessionId])
                }
                process.arguments = args
            case .codex:
                let subcommand = resumeCodex ? ["exec", "resume", "--last"] : ["exec"]
                process.arguments = subcommand + ["--full-auto", "--skip-git-repo-check"]
                    + tool.modelArgs(model) + [text]
            }
            process.currentDirectoryURL = root
            debugLog("Launching \(currentBackend.displayName): \(process.executableURL?.path ?? "?") \(process.arguments ?? [])")
            debugLog("CWD: \(root.path)")

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = CLIToolLocator.subprocessPath(toolPath: toolPath)
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

        // Headings outline, grouped under the indexer's per-folder rows
        let folders = db.allModules().filter { !$0.id.hasPrefix("cmod_") }
        if !folders.isEmpty {
            md += "## Document Structure\n"
            for folder in folders {
                let headings = db.symbolsForModule(folder.id).filter { $0.kind == "heading" }
                if !headings.isEmpty {
                    md += "- \(folder.name)/: \(headings.prefix(10).map { $0.name }.joined(separator: ", "))\n"
                }
            }
        }

        md += "\n## Instructions for Claude Code\n"
        md += "- This is a documentation workspace analyzed by MarkView DDE\n"
        md += "- The document structure above comes from the SQLite index\n"
        md += "- When creating .md files, use proper markdown formatting with headings\n"
        md += "- When editing existing files, preserve their structure\n"
        md += "- Follow user instructions precisely regarding language. If the user asks to write a document in a specific language, write it in that language regardless of which language the instruction was given in.\n"

        // Write to workspace
        let claudeDir = workspaceRoot.appendingPathComponent(".claude")
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claudeMdURL = claudeDir.appendingPathComponent("CLAUDE.md")
        try? md.write(to: claudeMdURL, atomically: true, encoding: .utf8)
        NSLog("[AIConsole] Generated CLAUDE.md (\(md.count) chars)")
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
        sessionBackend = nil
    }
}

// MARK: - CLI Tool Discovery

/// Locates the Claude Code and Codex command-line binaries.
///
/// These used to be hardcoded absolute paths, which broke silently whenever a tool
/// was installed somewhere else — an npm/nvm install of Codex lands in
/// `~/.nvm/versions/node/<version>/bin`, and that path changes on every Node
/// upgrade. Resolution is now: user override from Settings, then a candidate scan
/// (including every installed Node version), then a login-shell lookup.
enum CLITool: String, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Executable name as installed on disk.
    var binaryName: String { rawValue }

    /// UserDefaults key holding the user's explicit path override ("" = auto-detect).
    var overrideKey: String { "settings.cli.\(rawValue)Path" }

    /// Arguments that print the version without touching the network.
    var versionArgs: [String] { ["--version"] }

    /// Arguments that report login state without consuming tokens.
    var authStatusArgs: [String] {
        switch self {
        case .claude: return ["auth", "status"]
        case .codex: return ["login", "status"]
        }
    }

    /// Command the user runs in Terminal to authenticate.
    var loginCommand: String {
        switch self {
        case .claude: return "auth login"
        case .codex: return "login"
        }
    }

    /// Arguments that select `model` for one run.
    func modelArgs(_ model: String?) -> [String] {
        guard let model else { return [] }
        switch self {
        case .claude: return ["--model", model]
        case .codex: return ["-m", model]
        }
    }
}

// MARK: - Assistant & Model Preferences

/// A model the user can pick for a CLI. `id` is passed to the CLI's model flag;
/// an empty `id` means "no flag" — the CLI uses its own configured default.
struct AIModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
}

/// Which CLI answers AI Console requests and which model it runs.
///
/// Stored in UserDefaults so DDE Settings and the console's quick switch edit the
/// same values; views bind to the keys with `@AppStorage`, and the engine reads
/// them at send time.
enum AIAssistantPreferences {
    static let backendKey = "settings.ai.backend"

    static func modelKey(for tool: CLITool) -> String { "settings.cli.\(tool.rawValue)Model" }

    static var backend: CLITool {
        CLITool(rawValue: UserDefaults.standard.string(forKey: backendKey) ?? "") ?? .claude
    }

    /// The selected model, or nil to let the CLI use its own default.
    static func model(for tool: CLITool) -> String? {
        let value = (UserDefaults.standard.string(forKey: modelKey(for: tool)) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: X-Ray

    /// X-Ray has its own model: its answers are large and structured, so a fast model
    /// at low effort matters more there than raw capability.
    static func xrayModelKey(for tool: CLITool) -> String { "settings.xray.\(tool.rawValue)Model" }
    static func defaultXRayModel(for tool: CLITool) -> String {
        switch tool {
        case .claude: return "sonnet"
        case .codex: return "gpt-5.6-luna"
        }
    }
    /// The X-Ray model for `tool`; "" means the assistant's general model.
    static func xrayModel(for tool: CLITool) -> String? {
        let value = UserDefaults.standard.string(forKey: xrayModelKey(for: tool)) ?? defaultXRayModel(for: tool)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? model(for: tool) : trimmed
    }

    /// Short label for the active selection, e.g. "Claude Code · opus".
    static func summary(tool: CLITool, model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        return "\(tool.displayName) · \(trimmed.isEmpty ? "default model" : trimmed)"
    }

    /// Models offered in pickers. Codex reads its own catalog from disk (~350 KB of
    /// JSON), so call this off the main thread.
    static func modelOptions(for tool: CLITool) -> [AIModelOption] {
        switch tool {
        case .claude:
            // Aliases resolve to the newest model of each family, so the list does
            // not go stale when Claude Code ships a new version.
            return [
                AIModelOption(id: "", name: "Default", detail: "Claude Code's configured model"),
                AIModelOption(id: "fable", name: "Fable", detail: "Latest Fable — most capable"),
                AIModelOption(id: "opus", name: "Opus", detail: "Latest Opus"),
                AIModelOption(id: "sonnet", name: "Sonnet", detail: "Latest Sonnet — balanced"),
                AIModelOption(id: "haiku", name: "Haiku", detail: "Latest Haiku — fastest"),
            ]
        case .codex:
            let configured = codexConfiguredModel()
            let fallback = AIModelOption(
                id: "", name: configured.map { "Default (\($0))" } ?? "Default",
                detail: configured.map { "\($0) (from ~/.codex/config.toml)" } ?? "Codex's configured model"
            )
            return [fallback] + codexCatalog()
        }
    }

    private static var codexHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Models Codex itself lists in its picker, from the cache the CLI maintains.
    private static func codexCatalog() -> [AIModelOption] {
        let url = codexHome.appendingPathComponent("models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                guard let slug = model["slug"] as? String, !slug.isEmpty else { return nil }
                return AIModelOption(
                    id: slug,
                    name: model["display_name"] as? String ?? slug,
                    detail: model["description"] as? String ?? ""
                )
            }
    }

    /// Top-level `model = "..."` from Codex's config, used to label "Default".
    private static func codexConfiguredModel() -> String? {
        let url = codexHome.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }  // past the top-level table
            guard line.hasPrefix("model"),
                  let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

enum CLIToolLocator {

    /// Extra `PATH` entries the user configured in Settings (colon- or newline-separated).
    static var extraPathEntries: [String] {
        (UserDefaults.standard.string(forKey: "settings.cli.extraPATH") ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ":\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The user's explicit override, or nil when set to auto-detect.
    static func override(for tool: CLITool) -> String? {
        let value = (UserDefaults.standard.string(forKey: tool.overrideKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func setOverride(_ path: String?, for tool: CLITool) {
        let value = (path ?? "").trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(value, forKey: tool.overrideKey)
    }

    /// Every `bin` directory belonging to an installed Node version, newest first.
    /// This is the directory an `npm install -g codex` actually writes to, and the
    /// one the previous hardcoded `/opt/homebrew/bin` path could never find.
    static func nodeBinDirectories() -> [String] {
        let fm = FileManager.default
        let versionsRoot = NSHomeDirectory() + "/.nvm/versions/node"
        guard let versions = try? fm.contentsOfDirectory(atPath: versionsRoot) else { return [] }
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(versionsRoot)/\($0)/bin" }
    }

    /// Directories searched when no override is set, in priority order.
    static func searchDirectories() -> [String] {
        let home = NSHomeDirectory()
        return extraPathEntries
            + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
               "\(home)/.claude/local", "\(home)/bin", "/usr/bin"]
            + nodeBinDirectories()
    }

    /// Resolve a tool to an executable path, or nil if it cannot be found.
    /// Pure filesystem work — safe to call from the main actor.
    static func resolve(_ tool: CLITool) -> String? {
        if let override = override(for: tool) {
            // An override that no longer exists is reported as "not found" so the
            // user sees the problem instead of a cryptic launch failure.
            return isExecutable(override) ? override : nil
        }
        for directory in searchDirectories() {
            let candidate = "\(directory)/\(tool.binaryName)"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Last-resort lookup through a login shell, which picks up PATH entries set by
    /// nvm/rbenv/etc. in the user's dotfiles. Off-main and time-bounded.
    static func resolveViaLoginShell(_ tool: CLITool) async -> String? {
        let result = await run("/bin/zsh", ["-lc", "command -v \(tool.binaryName)"], timeout: 10)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, isExecutable(path) else { return nil }
        return path
    }

    /// Resolve, falling back to the login shell when the candidate scan comes up empty.
    static func resolveThorough(_ tool: CLITool) async -> String? {
        if let path = resolve(tool) { return path }
        if override(for: tool) != nil { return nil }  // explicit override, don't second-guess it
        return await resolveViaLoginShell(tool)
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        return fm.isExecutableFile(atPath: path)
    }

    /// `PATH` handed to spawned CLIs. Includes the tool's own directory and every
    /// Node bin dir, so a node-based CLI can find its own runtime.
    static func subprocessPath(toolPath: String?) -> String {
        let home = NSHomeDirectory()
        var entries: [String] = []
        if let toolPath { entries.append((toolPath as NSString).deletingLastPathComponent) }
        entries += extraPathEntries
        entries += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                    "/usr/sbin", "/sbin", "\(home)/.local/bin"]
        entries += nodeBinDirectories()
        // Preserve order, drop duplicates.
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    // MARK: - Probing

    struct ProbeResult {
        var path: String?
        var version: String?
        var loggedIn: Bool?
        var error: String?
    }

    /// Check that a tool is present, runnable, and authenticated.
    /// Uses each CLI's own status command — no tokens are spent.
    static func probe(_ tool: CLITool) async -> ProbeResult {
        guard let path = await resolveThorough(tool) else {
            let searched = searchDirectories().prefix(4).joined(separator: ", ")
            if let override = override(for: tool) {
                return ProbeResult(error: "Path set in Settings does not exist or is not executable: \(override)")
            }
            return ProbeResult(error: "\(tool.binaryName) not found. Searched \(searched), … — set the path manually in Settings.")
        }

        let versionRun = await run(path, tool.versionArgs, timeout: 20)
        guard versionRun.exitCode == 0 else {
            let detail = (versionRun.stderr.isEmpty ? versionRun.stdout : versionRun.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ProbeResult(path: path, error: "Could not run \(path): \(detail.prefix(200))")
        }
        let version = versionRun.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let authRun = await run(path, tool.authStatusArgs, timeout: 30)
        let authOutput = authRun.stdout + authRun.stderr
        let loggedIn: Bool?
        switch tool {
        case .claude:
            // `claude auth status` emits JSON with a "loggedIn" boolean.
            if let data = authRun.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let flag = json["loggedIn"] as? Bool {
                loggedIn = flag
            } else {
                loggedIn = authOutput.localizedCaseInsensitiveContains("logged in") ? true : nil
            }
        case .codex:
            // `codex login status` prints e.g. "Logged in using ChatGPT".
            if authOutput.localizedCaseInsensitiveContains("not logged in") {
                loggedIn = false
            } else if authOutput.localizedCaseInsensitiveContains("logged in") {
                loggedIn = true
            } else {
                loggedIn = nil
            }
        }
        return ProbeResult(path: path, version: version, loggedIn: loggedIn)
    }

    // MARK: - Process helper

    struct RunResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    /// Run a command off the main thread, draining both pipes concurrently with the
    /// wait so a full pipe can never deadlock the app (CLAUDE.md process rule), and
    /// terminating it if it outlives `timeout`.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> RunResult {
        let path = subprocessPath(toolPath: executable)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = path
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: RunResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }

                // Read both pipes on their own queues so neither can fill and block.
                var outData = Data()
                var errData = Data()
                let lock = NSLock()
                let group = DispatchGroup()
                for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        lock.lock()
                        if isStdout { outData = data } else { errData = data }
                        lock.unlock()
                        group.leave()
                    }
                }

                // Poll instead of blocking forever, so a hung CLI is terminated
                // rather than pinning this worker. We are already off the main
                // thread and both pipes are draining on their own queues.
                let deadline = Date().addingTimeInterval(timeout)
                var timedOut = false
                while process.isRunning {
                    if Date() > deadline {
                        process.terminate()
                        timedOut = true
                        break
                    }
                    usleep(50_000)
                }
                process.waitUntilExit()
                _ = group.wait(timeout: .now() + 5)

                lock.lock()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                lock.unlock()

                continuation.resume(returning: RunResult(
                    exitCode: timedOut ? -2 : process.terminationStatus,
                    stdout: out,
                    stderr: timedOut ? "Timed out after \(Int(timeout))s. \(err)" : err
                ))
            }
        }
    }

    // MARK: - Terminal login

    /// Write an executable `.command` file and open it, which macOS runs in
    /// Terminal.app. Deliberately avoids NSAppleScript: driving Terminal through
    /// Apple Events would require an automation permission prompt and an
    /// NSAppleEventsUsageDescription entry.
    @discardableResult
    static func openLoginInTerminal(_ tool: CLITool) -> String? {
        guard let toolPath = resolve(tool) else {
            return "\(tool.binaryName) not found — set its path in Settings first."
        }
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MarkView", isDirectory: true)
        let script = directory.appendingPathComponent("login-\(tool.rawValue).command")
        let body = """
            #!/bin/zsh
            export PATH="\(subprocessPath(toolPath: toolPath))"
            echo "Signing in to \(tool.displayName)…"
            "\(toolPath)" \(tool.loginCommand)
            echo
            echo "Done. You can close this window."

            """
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return "Could not prepare the login script: \(error.localizedDescription)"
        }
        NSWorkspace.shared.open(script)
        return nil
    }
}
