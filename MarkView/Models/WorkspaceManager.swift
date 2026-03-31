import Foundation
import SwiftUI
import Combine

/// Manages the workspace state including open files, tabs, and folder structure
@MainActor
class WorkspaceManager: ObservableObject {
    @Published var rootNode: FileNode?
    @Published var openTabs: [OpenTab] = []
    @Published var activeTabIndex: Int = -1
    @Published var recentFiles: [URL] = []
    @Published var showFileTree: Bool = true {
        didSet { UserDefaults.standard.set(showFileTree, forKey: "layout.showFileTree") }
    }
    @Published var showTOC: Bool = true {
        didSet { UserDefaults.standard.set(showTOC, forKey: "layout.showTOC") }
    }
    @Published var showSemanticPanel: Bool = false {
        didSet { UserDefaults.standard.set(showSemanticPanel, forKey: "layout.showSemanticPanel") }
    }
    @Published var semanticDatabase: SemanticDatabase?
    @Published var incrementalCompiler: IncrementalCompiler?
    @Published var actionEngine: ActionEngine?
    @Published var researchEngine: ResearchEngine?
    @Published var hybridSearch: HybridSearch?
    @Published var embeddingClient = EmbeddingClient()
    @Published var ollamaClient = OllamaClient()
    @Published var gitClient = GitClient()
    @Published var aiConsoleEngine: AIConsoleEngine?
    @Published var implementEngine: ImplementEngine?
    @Published var testGenerator: TestGenerator?
    @Published var graphRAG: GraphRAG?
    @Published var providerRouter: ProviderRouter?
    @Published var indexingProgress: String?
    @Published var analysisStage: String?
    @Published var analysisDetail: String?
    @Published var totalFilesInWorkspace: Int = 0
    @Published var analyzedFiles: Int = 0
    @Published var softwareArchMermaid: String?
    @Published var dataFlowMermaid: String?
    @Published var deploymentMermaid: String?
    @Published var semanticRefreshVersion: Int = 0
    @Published var themeVersion: Int = 0
    @Published var activeDiagramGenerationModes: Set<String> = []
    @Published var diagramPrompts: [String: String] = AIProviderClient.defaultDiagramPrompts

    @Published var excludedFolders: Set<String> = [] // relative paths from root

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var recentFilesURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = appSupport.appendingPathComponent("MarkView", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        recentFilesURL = appDir.appendingPathComponent("recentFiles.json")

        // Restore layout from UserDefaults
        let ud = UserDefaults.standard
        if ud.object(forKey: "layout.showFileTree") != nil {
            showFileTree = ud.bool(forKey: "layout.showFileTree")
        }
        if ud.object(forKey: "layout.showTOC") != nil {
            showTOC = ud.bool(forKey: "layout.showTOC")
        }
        if ud.object(forKey: "layout.showSemanticPanel") != nil {
            showSemanticPanel = ud.bool(forKey: "layout.showSemanticPanel")
        }

        loadRecentFiles()
    }

    /// Open a folder and set it as the root node
    func openFolder(_ url: URL) {
        let node = FileNode.buildTree(from: url)
        self.rootNode = node
        loadExcludedFolders()
        startFileWatcher(for: url)
        addRecentFile(url)
        initDDEWorkspace(at: url)
    }

    /// Initialize .dde/ workspace structure and SQLite database
    private func initDDEWorkspace(at url: URL) {
        let fm = FileManager.default
        let ddeRoot = url.appendingPathComponent(".dde")

        // Create directory structure
        for subdir in ["cache/provider_responses", "cache/embeddings", "cache/indexes", "overlays"] {
            let dir = ddeRoot.appendingPathComponent(subdir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Open/create SQLite database
        do {
            let db = try SemanticDatabase(workspacePath: url)
            let projectId = url.lastPathComponent
            try db.ensureProject(id: projectId, name: url.lastPathComponent, rootPath: url.path)
            self.semanticDatabase = db
            self.incrementalCompiler = IncrementalCompiler(workspacePath: url, database: db)
            let provider = incrementalCompiler!.orchestrator.providerClient
            self.actionEngine = ActionEngine(db: db, providerClient: provider)
            let hs = HybridSearch(db: db, embeddingClient: embeddingClient, workspacePath: url)
            self.hybridSearch = hs
            self.researchEngine = ResearchEngine(db: db, hybridSearch: hs, providerClient: provider)
            self.implementEngine = ImplementEngine(db: db, providerClient: provider)
            self.testGenerator = TestGenerator(db: db, providerClient: provider)
            self.graphRAG = GraphRAG(db: db, providerClient: provider)
            self.providerRouter = ProviderRouter(anthropicClient: provider, embeddingClient: embeddingClient)
            let aiEngine = AIConsoleEngine(workspaceRoot: url, db: db)
            aiEngine.onFilesChanged = { [weak self] files in
                self?.handleClaudeFileChanges(files)
            }
            self.aiConsoleEngine = aiEngine
            // Check Ollama + Git
            Task { await ollamaClient.checkConnection() }
            gitClient.setup(at: url)
            NSLog("[DDE] Workspace initialized: \(ddeRoot.path)")

            // V1: Deterministic structural indexing (instant, no LLM)
            runStructuralIndex(at: url)

            // Legacy AI analysis disabled — user triggers via Refresh button
            // analyzeAllFiles(in: url)
        } catch {
            NSLog("[DDE] Failed to init database: \(error)")
        }
    }

    /// Open a file in a new tab or switch to existing tab
    /// Open or refresh a file — if already open, reload content from disk
    // MARK: - Folder Exclusion

    /// Exclude a folder — removes all its entities from the DB
    func excludeFolder(_ folderURL: URL) {
        guard let root = rootNode?.url else { return }
        let relativePath = folderURL.path.replacingOccurrences(of: root.path + "/", with: "")
        excludedFolders.insert(relativePath)
        saveExcludedFolders()

        // Remove all DB entities for files in this folder
        guard let db = semanticDatabase else { return }
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "md" else { continue }
                let docId = url.lastPathComponent
                db.clearSymbols(forDocument: docId, kind: "heading")
                db.clearSymbols(forDocument: docId, kind: "link")
                db.clearSymbols(forDocument: docId, kind: "code_block")
                db.clearExtractedComponents(forDocument: docId)
                // Remove from FTS
                db.indexDocumentFTS(documentId: docId, title: "", content: "")
            }
        }
        // Remove directory modules for this path
        let modules = db.allModules()
        for mod in modules where mod.path.hasPrefix(folderURL.path) {
            db.clearSymbols(forDocument: mod.name, kind: "heading")
        }

        objectWillChange.send()
        NSLog("[DDE] Excluded folder: \(relativePath)")
    }

    /// Re-include a previously excluded folder
    func includeFolder(_ relativePath: String) {
        excludedFolders.remove(relativePath)
        saveExcludedFolders()
        // Re-index would happen on next Refresh
        objectWillChange.send()
        NSLog("[DDE] Re-included folder: \(relativePath)")
    }

    /// Check if a path is excluded
    func isExcluded(_ url: URL) -> Bool {
        guard let root = rootNode?.url else { return false }
        let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
        return excludedFolders.contains { relativePath.hasPrefix($0) }
    }

    private func saveExcludedFolders() {
        let key = "excludedFolders.\(rootNode?.url.lastPathComponent ?? "default")"
        UserDefaults.standard.set(Array(excludedFolders), forKey: key)
    }

    private func loadExcludedFolders() {
        let key = "excludedFolders.\(rootNode?.url.lastPathComponent ?? "default")"
        if let saved = UserDefaults.standard.stringArray(forKey: key) {
            excludedFolders = Set(saved)
        }
    }

    /// Handle files created/modified by Claude Code — auto-open and refresh tree
    private func handleClaudeFileChanges(_ relativePaths: [String]) {
        guard let root = rootNode?.url ?? aiConsoleEngine?.workspaceRoot else { return }

        // Refresh file tree
        rootNode = FileNode.buildTree(from: root)

        // Open or refresh each changed file
        for relativePath in relativePaths {
            let fileURL = root.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            openOrRefreshFile(fileURL)
        }
    }

    func openOrRefreshFile(_ url: URL) {
        if let index = openTabs.firstIndex(where: { $0.url == url }) {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                openTabs[index].content = content
                openTabs[index].originalContent = content
                openTabs[index].isModified = false
                activeTabIndex = index
            }
        } else {
            openFile(url)
        }
    }

    func openFile(_ url: URL) {
        // Always init workspace for .md files if DB is missing or file is from different dir
        let isMD = url.pathExtension.lowercased() == "md"
        if isMD && !isFileInCurrentWorkspace(url) {
            initSingleFileWorkspace(fileURL: url)
        }

        // Check if file is already open
        if let index = openTabs.firstIndex(where: { $0.url == url }) {
            activeTabIndex = index
            return
        }

        // Load file content
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var tab = OpenTab(url: url, content: content, originalContent: content)

            // Extract headings from markdown
            if url.pathExtension.lowercased() == "md" {
                tab.headings = extractHeadings(from: content)
            }

            openTabs.append(tab)
            activeTabIndex = openTabs.count - 1
            addRecentFile(url)
        } catch {
            NSLog("Error opening file: \(error)")
        }
    }

    /// Check if a file belongs to the currently open workspace
    private func isFileInCurrentWorkspace(_ url: URL) -> Bool {
        guard semanticDatabase != nil else { return false }
        guard let root = rootNode else { return false }
        let filePath = url.standardizedFileURL.path
        let rootPath = root.url.standardizedFileURL.path
        return filePath.hasPrefix(rootPath)
    }

    /// Initialize workspace for a single .md file — DB named after the file, indexes only this file
    private func initSingleFileWorkspace(fileURL: URL) {
        let parentDir = fileURL.deletingLastPathComponent()
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let dbName = "file_\(fileName).db"

        NSLog("[DDE] initSingleFileWorkspace: file=\(fileURL.path) dir=\(parentDir.path) dbName=\(dbName)")

        // Close previous workspace
        semanticDatabase = nil
        researchEngine = nil
        actionEngine = nil
        hybridSearch = nil
        implementEngine = nil
        testGenerator = nil
        graphRAG = nil
        providerRouter = nil
        aiConsoleEngine = nil
        softwareArchMermaid = nil
        dataFlowMermaid = nil
        deploymentMermaid = nil

        do {
            let db = try SemanticDatabase(workspacePath: parentDir, dbName: dbName)
            let projectId = fileName
            try db.ensureProject(id: projectId, name: fileName, rootPath: parentDir.path)
            self.semanticDatabase = db
            self.incrementalCompiler = IncrementalCompiler(workspacePath: parentDir, database: db)
            let provider = incrementalCompiler!.orchestrator.providerClient
            self.actionEngine = ActionEngine(db: db, providerClient: provider)
            let hs = HybridSearch(db: db, embeddingClient: embeddingClient, workspacePath: parentDir)
            self.hybridSearch = hs
            self.researchEngine = ResearchEngine(db: db, hybridSearch: hs, providerClient: provider)
            self.implementEngine = ImplementEngine(db: db, providerClient: provider)
            self.testGenerator = TestGenerator(db: db, providerClient: provider)
            self.graphRAG = GraphRAG(db: db, providerClient: provider)
            self.providerRouter = ProviderRouter(anthropicClient: provider, embeddingClient: embeddingClient)
            let aiEngine = AIConsoleEngine(workspaceRoot: parentDir, db: db)
            aiEngine.onFilesChanged = { [weak self] files in
                self?.handleClaudeFileChanges(files)
            }
            self.aiConsoleEngine = aiEngine
            gitClient.setup(at: parentDir)

            // Build file tree showing just the parent dir
            if rootNode == nil {
                rootNode = FileNode.buildTree(from: parentDir)
            }

            // Index this single file: create root module, parse document, index FTS
            indexSingleFile(fileURL: fileURL, db: db, provider: provider)

            NSLog("[DDE] Single-file workspace initialized: \(fileName) → \(dbName)")
        } catch {
            NSLog("[DDE] Failed to init single-file workspace: \(error)")
        }
    }

    /// Index a single markdown file — structural parse + FTS + Haiku extraction.
    /// Works fully in sandbox: no directory scan, content passed directly.
    private func indexSingleFile(fileURL: URL, db: SemanticDatabase, provider: AIProviderClient?) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            NSLog("[DDE] indexSingleFile: cannot read \(fileURL.path)")
            return
        }

        let docId = fileURL.lastPathComponent
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let modId = "mod_single_file"

        // Root module
        db.upsertModule(id: modId, name: fileName, path: fileURL.deletingLastPathComponent().path,
                        parentId: nil, level: 0, fileCount: 1)

        // FTS index
        db.indexDocumentFTS(documentId: docId, title: fileName, content: content)

        // Content hash
        var h: UInt32 = 0x811c9dc5
        for byte in content.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
        try? db.upsertDocument(id: docId, projectId: fileName, filePath: fileURL.path,
                               fileName: docId, fileExt: "md", contentHash: String(h, radix: 16))

        // Parse symbols inline (headings) — no directory scan
        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let lineNum = i + 1
            if line.range(of: #"^#{1,6}\s+.+"#, options: .regularExpression) != nil {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                let symId = "sym_h_\(singleFileFnv1a("\(docId):\(lineNum):\(text)"))"
                db.insertSymbol(id: symId, moduleId: modId, documentId: docId,
                               name: text, kind: "heading", lineStart: lineNum, lineEnd: lineNum, context: nil)
            }
        }

        NSLog("[DDE] indexSingleFile: parsed \(docId), \(content.count) chars")

        // Haiku component extraction — only on explicit user action (Refresh button), not on file open
        // Skip auto-extraction: user triggers it manually via the ↻ button in modules panel
        let autoExtract = false // Set to true to enable auto-extraction on file open
        if autoExtract, let provider = provider, provider.hasAPIKey {
            // Check content hash — skip if unchanged
            let currentHash = String(h, radix: 16)
            let previousHash = db.getDocumentHash(docId)
            let alreadyExtracted = db.hasExtractedComponents(forDocument: docId)

            if alreadyExtracted && previousHash == currentHash {
                NSLog("[DDE] Skipping extraction — file unchanged, \(db.symbolsForModule("").count) components cached")
                return
            }

            // File changed or never extracted — clear old and re-extract
            if alreadyExtracted {
                db.clearExtractedComponents(forDocument: docId)
            }
            let fullContent = content
            Task {
                indexingProgress = "Extracting components (Haiku)..."
                await extractSingleFileComponents(content: fullContent, docId: docId, db: db, provider: provider)
                indexingProgress = "Extraction complete"
                // Force UI refresh — briefly change indexingProgress so SwiftUI re-reads modules from DB
                try? await Task.sleep(nanoseconds: 500_000_000)
                indexingProgress = nil
                objectWillChange.send()
            }
        }
    }

    /// Extract components from a single file using Haiku — chunks entire document, works in sandbox
    private func extractSingleFileComponents(content: String, docId: String, db: SemanticDatabase, provider: AIProviderClient) async {
        guard let apiKey = provider.apiKeyValue else { return }

        // Split into chunks of ~12000 chars at paragraph boundaries
        let chunks = chunkContent(content, maxChars: 12000)
        NSLog("[DDE] Extracting from \(chunks.count) chunks (\(content.count) chars total)")

        var globalSeen = Set<String>()
        var totalComponents = 0

        for (chunkIdx, chunk) in chunks.enumerated() {
            indexingProgress = "Extracting components (Haiku) chunk \(chunkIdx + 1)/\(chunks.count)..."

            let tool: [String: Any] = [
                "name": "extract_components",
                "description": "Extract all named software components from documentation",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "components": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "name": ["type": "string"],
                                    "type": ["type": "string", "enum": ["service","database","api","queue","system","library","tool","framework","protocol","storage","cache","gateway","worker","scheduler","proxy","broker","sdk","platform","infrastructure","monitoring","testing","module","pipeline","classifier","resolver","analyzer","generator","processor"]],
                                    "description": ["type": "string"],
                                    "dependencies": ["type": "array", "items": ["type": "string"]]
                                ],
                                "required": ["name", "type", "description"]
                            ]
                        ]
                    ],
                    "required": ["components"]
                ]
            ]

            let body: [String: Any] = [
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 8192,
                "system": """
Extract ALL named technical components, modules, and architectural elements from this documentation chunk.
The document may be in any language (including Russian) — extract component names regardless of language.

Look for ALL of these:
- Python/code modules (*.py files, classes, functions mentioned as components)
- Pipeline stages and processing steps
- Services, APIs, databases, queues, caches
- Libraries, frameworks, tools, SDKs
- Classifiers, analyzers, resolvers, generators
- Infrastructure: storage, monitoring, orchestrators
- External systems and integrations

Extract EVERY named component — do NOT skip anything. If a module like 'orchestrator.py' or a stage like 'Document Intake' is mentioned, extract it.
Each component needs a correct type and one-sentence description.
""",
                "messages": [["role": "user", "content": "File: \(docId) (chunk \(chunkIdx + 1)/\(chunks.count))\n\n\(chunk)"]],
                "tools": [tool],
                "tool_choice": ["type": "tool", "name": "extract_components"]
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: body)
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.httpBody = data
                request.timeoutInterval = 60

                let (responseData, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    NSLog("[DDE] Haiku chunk \(chunkIdx + 1) error: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    continue
                }

                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let contentBlocks = json["content"] as? [[String: Any]] else { continue }

                if let usage = json["usage"] as? [String: Any] {
                    let inp = usage["input_tokens"] as? Int ?? 0
                    let out = usage["output_tokens"] as? Int ?? 0
                    db.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0001 + Double(out) * 0.0005)
                }

                for block in contentBlocks {
                    if block["type"] as? String == "tool_use",
                       let input = block["input"] as? [String: Any],
                       let components = input["components"] as? [[String: Any]] {
                        for m in components {
                            guard let name = m["name"] as? String, let type = m["type"] as? String else { continue }
                            let key = name.lowercased().trimmingCharacters(in: .whitespaces)
                            guard !globalSeen.contains(key) else { continue }
                            globalSeen.insert(key)

                            let desc = m["description"] as? String ?? ""
                            let deps = m["dependencies"] as? [String] ?? []
                            let modId = "cmod_\(singleFileFnv1a("\(docId):\(name)"))"

                            db.upsertModule(id: modId, name: name, path: "cmod/\(name)", parentId: "mod_single_file", level: 1, fileCount: 0)
                            db.insertSymbol(id: "sym_cmod_\(singleFileFnv1a(modId))", moduleId: modId, documentId: docId,
                                           name: name, kind: "component", lineStart: nil, lineEnd: nil,
                                           context: "[\(type)] \(desc)")
                            for dep in deps {
                                let targetId = "cmod_\(singleFileFnv1a("\(docId):\(dep)"))"
                                db.insertRelation(id: "rel_\(singleFileFnv1a("\(modId)→\(dep)"))", sourceId: modId, targetId: targetId,
                                                  type: "depends_on", sourceDoc: docId, evidence: "\(name) → \(dep)")
                            }
                            totalComponents += 1
                        }
                        NSLog("[DDE] Chunk \(chunkIdx+1): \(components.count) components")
                    }
                }
            } catch {
                NSLog("[DDE] Chunk \(chunkIdx + 1) extraction error: \(error)")
            }
        }
        NSLog("[DDE] Total: \(totalComponents) unique components from \(chunks.count) chunks")
    }

    /// Split content into chunks at paragraph boundaries
    private func chunkContent(_ content: String, maxChars: Int) -> [String] {
        guard content.count > maxChars else { return [content] }
        var chunks: [String] = []
        var current = ""
        for paragraph in content.components(separatedBy: "\n\n") {
            if current.count + paragraph.count + 2 > maxChars && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n\n" }
            current += paragraph
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Ollama Extraction

    /// Extract components from all files using local Ollama model
    private func extractWithOllama(db: SemanticDatabase, rootURL: URL) async {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }

        var files: [(url: URL, content: String)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md", !url.path.contains(".dde") else { continue }
            if let content = try? String(contentsOf: url, encoding: .utf8), content.count > 50 {
                files.append((url, content))
            }
        }

        var totalComponents = 0
        var globalSeen = Set<String>()

        for (i, file) in files.enumerated() {
            let docId = file.url.lastPathComponent
            indexingProgress = "Ollama: \(i+1)/\(files.count) — \(docId)"

            // Skip if already extracted
            if db.hasExtractedComponents(forDocument: docId) { continue }

            // Chunk and extract
            let chunks = chunkContent(file.content, maxChars: 3000) // smaller chunks for local model
            for chunk in chunks {
                guard let components = await ollamaClient.extractJSON(
                    prompt: "File: \(docId)\n\n\(chunk)",
                    system: OllamaClient.extractionSystemPrompt
                ) else { continue }

                for comp in components {
                    guard let name = comp["name"] as? String, let type = comp["type"] as? String else { continue }
                    let key = name.lowercased().trimmingCharacters(in: .whitespaces)
                    guard !globalSeen.contains(key) else { continue }
                    globalSeen.insert(key)

                    let desc = comp["description"] as? String ?? ""
                    let modId = "cmod_\(singleFileFnv1a("\(docId):\(name)"))"

                    db.upsertModule(id: modId, name: name, path: "cmod/\(name)", parentId: nil, level: 1, fileCount: 0)
                    db.insertSymbol(id: "sym_cmod_\(singleFileFnv1a(modId))", moduleId: modId, documentId: docId,
                                   name: name, kind: "component", lineStart: nil, lineEnd: nil,
                                   context: "[\(type)] \(desc)")
                    totalComponents += 1
                }
            }
        }
        NSLog("[DDE] Ollama extraction: \(totalComponents) components from \(files.count) files")
    }

    private func singleFileFnv1a(_ str: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in str.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
        return String(hash, radix: 16)
    }

    /// Close a tab at the given index
    func closeTab(at index: Int) {
        guard index >= 0 && index < openTabs.count else { return }

        if openTabs[index].isModified {
            let alert = NSAlert()
            alert.messageText = "Save changes?"
            alert.informativeText = "Do you want to save changes to \(openTabs[index].displayName)?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                saveFile(at: index)
            } else if response == .alertThirdButtonReturn {
                return
            }
        }

        openTabs.remove(at: index)

        if activeTabIndex >= openTabs.count {
            activeTabIndex = max(0, openTabs.count - 1)
        }
    }

    /// Save the active tab's file
    func saveActiveFile() {
        guard activeTabIndex >= 0 && activeTabIndex < openTabs.count else { return }
        saveFile(at: activeTabIndex)
    }

    /// Translate document to target language, chunk by chunk, open result in new tab
    func translateDocument(markdown: String, targetLang: String) async {
        guard let provider = incrementalCompiler?.orchestrator.providerClient,
              let apiKey = provider.apiKeyValue else {
            NSLog("[DDE] No API key for translation")
            return
        }

        // Create new tab immediately with placeholder
        let sourceTab = activeTabIndex >= 0 && activeTabIndex < openTabs.count ? openTabs[activeTabIndex] : nil
        let sourceName = sourceTab?.url.deletingPathExtension().lastPathComponent ?? "document"
        let newURL = sourceTab?.url.deletingLastPathComponent()
            .appendingPathComponent("\(sourceName)_\(targetLang.lowercased()).md") ?? URL(fileURLWithPath: "/tmp/translated.md")

        var translatedTab = OpenTab(url: newURL, content: "# Translating to \(targetLang)...\n\nPlease wait...", originalContent: "")
        openTabs.append(translatedTab)
        activeTabIndex = openTabs.count - 1

        // Split markdown into chunks at heading boundaries for better translation
        let chunks = splitForTranslation(markdown, maxChars: 4000)
        var translatedParts: [String] = []
        let tabIndex = openTabs.count - 1

        for (i, chunk) in chunks.enumerated() {
            indexingProgress = "Translating chunk \(i + 1)/\(chunks.count)..."

            let body: [String: Any] = [
                "model": "claude-sonnet-4-6",
                "max_tokens": 8192,
                "system": """
                    You are a professional translator. Translate the following markdown text to \(targetLang).
                    Rules:
                    - Translate ONLY the text content. Keep ALL markdown formatting intact (headings, lists, code blocks, links, tables).
                    - Do NOT translate code inside code blocks (```...```). Keep code exactly as-is.
                    - Do NOT translate URLs, file paths, or technical identifiers.
                    - Keep proper nouns, product names, and acronyms as-is.
                    - Preserve the exact markdown structure — same number of headings, lists, paragraphs.
                    - Return ONLY the translated markdown, no explanations.
                    """,
                "messages": [["role": "user", "content": chunk]]
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: body)
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.httpBody = data
                request.timeoutInterval = 120

                let (responseData, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let content = json["content"] as? [[String: Any]],
                      let text = content.first?["text"] as? String else {
                    translatedParts.append(chunk) // Keep original on failure
                    continue
                }

                // Track cost (Sonnet: $3/1M in, $15/1M out)
                if let usage = json["usage"] as? [String: Any] {
                    let inp = usage["input_tokens"] as? Int ?? 0
                    let out = usage["output_tokens"] as? Int ?? 0
                    semanticDatabase?.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0003 + Double(out) * 0.0015)
                }

                translatedParts.append(text)

                // Update tab content progressively
                if tabIndex < openTabs.count {
                    openTabs[tabIndex].content = translatedParts.joined(separator: "\n\n")
                    openTabs[tabIndex].isModified = true
                }
            } catch {
                NSLog("[DDE] Translation chunk \(i + 1) error: \(error)")
                translatedParts.append(chunk)
            }
        }

        // Final update
        if tabIndex < openTabs.count {
            openTabs[tabIndex].content = translatedParts.joined(separator: "\n\n")
            openTabs[tabIndex].isModified = true
            activeTabIndex = tabIndex
        }
        indexingProgress = nil
        NSLog("[DDE] Translation complete: \(chunks.count) chunks")
    }

    /// Split markdown at heading boundaries for translation
    private func splitForTranslation(_ markdown: String, maxChars: Int) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        var chunks: [String] = []
        var current = ""

        for line in lines {
            let isHeading = line.range(of: #"^#{1,3}\s+"#, options: .regularExpression) != nil
            if isHeading && current.count > maxChars / 2 {
                chunks.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n" }
            current += line

            if current.count > maxChars {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Save a file at the given index
    private func saveFile(at index: Int) {
        guard index >= 0 && index < openTabs.count else { return }

        let tab = openTabs[index]
        do {
            try tab.content.write(to: tab.url, atomically: true, encoding: .utf8)
            openTabs[index].isModified = false
            openTabs[index].originalContent = tab.content // new baseline
        } catch {
            NSLog("Error saving file: \(error)")
        }
    }

    /// Re-index active file: update FTS, headings, re-extract components
    /// Refresh: re-index current file + extraction. Prefers Ollama (free), falls back to Haiku.
    func reindexActiveFile() {
        // If a folder is open, re-run full structural index + extraction
        if let root = rootNode?.url, let db = semanticDatabase {
            indexingProgress = "Re-indexing workspace..."
            runStructuralIndex(at: root)

            Task {
                if ollamaClient.isConnected {
                    // Use Ollama (free, local)
                    indexingProgress = "Extracting modules (Ollama \(ollamaClient.selectedModel))..."
                    await extractWithOllama(db: db, rootURL: root)
                } else if let provider = incrementalCompiler?.orchestrator.providerClient, provider.hasAPIKey {
                    // Fallback to Haiku (cloud, paid)
                    indexingProgress = "Extracting modules (Haiku)..."
                    let indexer = StructuralIndexer(db: db, rootURL: root, providerClient: provider)
                    await indexer.extractContentModules()
                } else {
                    indexingProgress = "No AI available — structural index only"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                indexingProgress = nil
                objectWillChange.send()
            }
            return
        }

        // Single file mode
        guard activeTabIndex >= 0, activeTabIndex < openTabs.count else { return }
        let tab = openTabs[activeTabIndex]
        reindexFile(fileURL: tab.url, content: tab.content)
    }

    private func reindexFile(fileURL: URL, content: String) {
        guard let db = semanticDatabase else { return }
        let docId = fileURL.lastPathComponent

        // Compute new hash
        var h: UInt32 = 0x811c9dc5
        for byte in content.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
        let newHash = String(h, radix: 16)

        NSLog("[DDE] Re-indexing: \(docId)")

        // Update hash
        try? db.upsertDocument(id: docId, projectId: fileURL.deletingPathExtension().lastPathComponent,
                               filePath: fileURL.path, fileName: docId, fileExt: "md",
                               contentHash: newHash)

        // Re-index FTS
        db.indexDocumentFTS(documentId: docId, title: docId.replacingOccurrences(of: ".md", with: ""), content: content)

        // Re-parse headings
        let modId = "mod_single_file"
        db.clearSymbols(forDocument: docId, kind: "heading")

        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let lineNum = i + 1
            if line.range(of: #"^#{1,6}\s+.+"#, options: .regularExpression) != nil {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                let symId = "sym_h_\(singleFileFnv1a("\(docId):\(lineNum):\(text)"))"
                db.insertSymbol(id: symId, moduleId: modId, documentId: docId,
                               name: text, kind: "heading", lineStart: lineNum, lineEnd: lineNum, context: nil)
            }
        }

        // Re-extract components in background
        let provider = incrementalCompiler?.orchestrator.providerClient
        if let provider = provider, provider.hasAPIKey {
            db.clearExtractedComponents(forDocument: docId)
            Task {
                indexingProgress = "Re-extracting components..."
                await extractSingleFileComponents(content: content, docId: docId, db: db, provider: provider)
                indexingProgress = "Re-indexing complete"
                try? await Task.sleep(nanoseconds: 500_000_000)
                indexingProgress = nil
                objectWillChange.send()
            }
        } else {
            objectWillChange.send()
        }
    }

    /// Update the content of the active tab
    func updateActiveTabContent(_ content: String) {
        guard activeTabIndex >= 0 && activeTabIndex < openTabs.count else { return }

        openTabs[activeTabIndex].content = content
        openTabs[activeTabIndex].isModified = (content != openTabs[activeTabIndex].originalContent)
    }

    /// Update the headings for the active tab
    func updateActiveTabHeadings(_ headings: [HeadingItem]) {
        guard activeTabIndex >= 0 && activeTabIndex < openTabs.count else { return }
        openTabs[activeTabIndex].headings = headings
    }

    /// Update the active heading for the active tab
    func updateActiveHeading(_ headingId: String) {
        guard activeTabIndex >= 0 && activeTabIndex < openTabs.count else { return }
        openTabs[activeTabIndex].activeHeadingId = headingId
    }

    // MARK: - File Watching

    private var fileWatchTimer: Timer?

    private func startFileWatcher(for url: URL) {
        fileWatcher?.cancel()
        fileWatchTimer?.invalidate()

        // DispatchSource for root directory
        let fd = open(url.path, O_EVTONLY)
        guard fd != -1 else { return }

        let queue = DispatchQueue.main
        fileWatcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .all,
            queue: queue
        )

        fileWatcher?.setEventHandler { [weak self] in
            self?.reloadFileTree()
        }

        fileWatcher?.setCancelHandler { close(fd) }
        fileWatcher?.resume()

        // Also poll every 3 seconds to catch subdirectory changes
        fileWatchTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkForFileTreeChanges()
        }
    }

    private var lastFileCount: Int = 0

    private func checkForFileTreeChanges() {
        guard let rootURL = rootNode?.url else { return }
        let fm = FileManager.default
        var count = 0
        if let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            while enumerator.nextObject() != nil { count += 1 }
        }
        if count != lastFileCount {
            lastFileCount = count
            reloadFileTree()
        }
    }

    private func reloadFileTree() {
        guard let rootURL = rootNode?.url else { return }
        rootNode = FileNode.buildTree(from: rootURL)
    }

    // MARK: - Recent Files

    private func loadRecentFiles() {
        guard let data = try? Data(contentsOf: recentFilesURL) else { return }
        do {
            let urls = try JSONDecoder().decode([String].self, from: data)
            recentFiles = urls.compactMap { URL(fileURLWithPath: $0) }
        } catch {
            NSLog("Error loading recent files: \(error)")
        }
    }

    private func addRecentFile(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 20 {
            recentFiles = Array(recentFiles.prefix(20))
        }
        saveRecentFiles()
    }

    private func saveRecentFiles() {
        let paths = recentFiles.map { $0.path }
        if let data = try? JSONEncoder().encode(paths) {
            try? data.write(to: recentFilesURL)
        }
    }

    // MARK: - Markdown Parsing

    /// Extract headings from markdown content
    private func extractHeadings(from markdown: String) -> [HeadingItem] {
        var headings: [HeadingItem] = []
        let lines = markdown.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)

                if level >= 1 && level <= 6 && !text.isEmpty {
                    let id = UUID().uuidString
                    headings.append(HeadingItem(id: id, level: level, text: String(text)))
                }
            }
        }

        return headings
    }

    // MARK: - DDE Block Handling

    /// Handle block delta from JS extraction — wrapped in safety guard
    func handleBlocksDelta(_ delta: BlocksDelta) {
        guard activeTabIndex >= 0, activeTabIndex < openTabs.count else { return }
        guard !delta.isEmpty else { return }

        var tab = openTabs[activeTabIndex]

        tab.blocks.removeAll { delta.removed.contains($0.id) }

        for changed in delta.changed {
            if let idx = tab.blocks.firstIndex(where: { $0.id == changed.id }) {
                tab.blocks[idx] = changed
            }
        }

        tab.blocks.append(contentsOf: delta.added)
        tab.blocks.sort { $0.position < $1.position }

        openTabs[activeTabIndex] = tab

        // Persist to SQLite
        if let db = semanticDatabase {
            let docId = tab.url.lastPathComponent
            for block in delta.added + delta.changed {
                try? db.upsertBlock(block, documentId: docId)
            }
            for id in delta.removed {
                try? db.deleteBlock(id: id)
            }
        }

        // Feed delta to incremental compiler
        incrementalCompiler?.compileDelta(delta, forFile: tab.url)
    }

    // MARK: - Background Folder Analysis

    /// V1: Deterministic structural indexing — instant, no LLM
    /// Then V1.5: Haiku-based content module extraction (cheap, fast)
    private func runStructuralIndex(at url: URL) {
        guard let db = semanticDatabase else { return }
        let provider = incrementalCompiler?.orchestrator.providerClient
        let indexer = StructuralIndexer(db: db, rootURL: url, providerClient: provider)
        indexer.progress = { [weak self] msg in
            self?.indexingProgress = msg
        }

        // Step 1: Deterministic (instant)
        indexer.indexAll()
        NSLog("[DDE] Structural index complete")

        // Step 2: Haiku module extraction — disabled by default, user triggers via Refresh button
        if false && provider?.hasAPIKey == true {
            Task {
                indexingProgress = "Extracting modules (Haiku)..."
                await indexer.extractContentModules()
                indexingProgress = nil
                NSLog("[DDE] Content module extraction complete")
            }
        } else {
            indexingProgress = nil
        }
    }

    /// Smart analysis — only processes NEW or CHANGED files. Skips unchanged files entirely.
    private func analyzeAllFiles(in folderURL: URL) {
        // Load cached results IMMEDIATELY so panel has data
        loadCachedResults()
        ensureArchitectureDiagrams()

        // Run analysis in background — does NOT block UI
        Task.detached { [weak self] in
            guard let self else { return }

            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: folderURL,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }

            var mdFiles: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                if url.pathExtension.lowercased() == "md" { mdFiles.append(url) }
            }
            let totalMarkdownFiles = mdFiles.count

            await MainActor.run {
                self.totalFilesInWorkspace = totalMarkdownFiles
                self.analysisStage = "Checking \(totalMarkdownFiles) files..."
            }

            // Check which files changed
            var changedFiles: [(docId: String, url: URL, content: String)] = []
            var skippedCount = 0

            for fileURL in mdFiles {
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                let docId = fileURL.lastPathComponent
                var hash: UInt32 = 0x811c9dc5
                for byte in content.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
                let contentHash = String(hash, radix: 16)

                let skip = await MainActor.run { () -> Bool in
                    guard let db = self.semanticDatabase else { return false }
                    if db.getDocumentHash(docId) == contentHash,
                       !db.documentNeedsReanalysis(docId) {
                        return true
                    }
                    try? db.upsertDocument(id: docId, projectId: folderURL.lastPathComponent,
                        filePath: fileURL.path, fileName: fileURL.deletingPathExtension().lastPathComponent,
                        fileExt: fileURL.pathExtension, contentHash: contentHash)
                    return false
                }

                if skip { skippedCount += 1; continue }
                changedFiles.append((docId, fileURL, content))
            }
            let changedCount = changedFiles.count
            let skippedTotal = skippedCount

            await MainActor.run {
                self.analysisDetail = "\(changedCount) changed, \(skippedTotal) cached"
            }
            NSLog("[DDE] \(changedCount) changed, \(skippedTotal) cached")

            if changedFiles.isEmpty {
                await MainActor.run {
                    self.analysisStage = nil
                    self.analysisDetail = nil
                    self.refreshSemanticViews()
                }
                return
            }

            // Extract changed files
            let changedFilesTotal = changedFiles.count
            for (index, (docId, _, content)) in changedFiles.enumerated() {
                await MainActor.run {
                    self.analyzedFiles = index + 1
                    self.analysisStage = "Extracting \(index + 1)/\(changedFilesTotal): \(docId)"
                }

                let blocks = MarkdownBlockParser.extractBlocks(from: content, documentId: docId)

                await MainActor.run {
                    if let db = self.semanticDatabase {
                        for block in blocks { try? db.upsertBlock(block, documentId: docId) }
                    }
                    if content.count > 20 {
                        // Insert file-level block into DB so FK constraints work for claims
                        let fileBlock = SemanticBlock(
                            id: "file_\(docId)", documentId: docId, type: .document, level: nil,
                            content: content, plainText: content, contentHash: "",
                            headingPath: [], parentBlockId: nil,
                            lineStart: 1, lineEnd: blocks.last?.lineEnd ?? 1,
                            position: 0, language: nil, anchor: nil)
                        // Store the file block in DB so claims can reference it (FK constraint)
                        if let db = self.semanticDatabase {
                            try? db.upsertBlock(fileBlock, documentId: docId)
                        }
                        self.incrementalCompiler?.orchestrator.submitExtraction(
                            block: fileBlock, documentId: docId, file: docId)
                    }
                }
            }

            // Wait for AI (with timeout, non-blocking for UI since we're detached)
            await self.waitForAICompletion()

            await MainActor.run {
                self.loadCachedResults()
                self.incrementalCompiler?.runContradictionDetection()
                self.analysisStage = nil
                self.analysisDetail = nil
                self.ensureArchitectureDiagrams()
                self.refreshSemanticViews()
                let ent = self.incrementalCompiler?.orchestrator.extractedEntities.count ?? 0
                let clm = self.incrementalCompiler?.orchestrator.extractedClaims.count ?? 0
                NSLog("[DDE] Done: \(ent) entities, \(clm) claims")
            }
        }
    }

    /// Load cached diagrams from DB, or generate in background if missing
    func ensureArchitectureDiagrams() {
        // Try loading from DB first
        if let db = semanticDatabase {
            if let cached = db.getDocumentHash("__diagram_software") {
                softwareArchMermaid = cached
            }
            if let cached = db.getDocumentHash("__diagram_dataflow") {
                dataFlowMermaid = cached
            }
            if let cached = db.getDocumentHash("__diagram_deployment") {
                deploymentMermaid = cached
            }
        }

        // Don't auto-generate — diagrams are only generated on explicit user action (Rerun button)
        // This prevents wasting API credits on every folder open
    }

    func refreshSemanticViews() {
        semanticRefreshVersion &+= 1
    }

    /// Get the full prompt = base + user instructions
    func diagramPrompt(for mode: String) -> String {
        let base = AIProviderClient.defaultDiagramPrompt(for: mode)
        let userInstr = diagramPrompts[mode] ?? ""
        if userInstr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return base
        }
        return base + "\n\nAdditional instructions from user:\n" + userInstr
    }

    /// Get only the user's additional instructions (for the editor)
    func diagramUserInstructions(for mode: String) -> String {
        diagramPrompts[mode] ?? ""
    }

    /// Store user's additional instructions
    func updateDiagramPrompt(_ instructions: String, for mode: String) {
        diagramPrompts[mode] = instructions
    }

    func resetDiagramPrompt(for mode: String) {
        diagramPrompts[mode] = ""
    }

    func regenerateArchitectureDiagram(mode: String) {
        Task { await generateArchitectureDiagram(mode: mode, force: true) }
    }

    func navigateToText(filePath: String?, fallbackDocumentId: String? = nil, searchText: String) {
        let trimmedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if let url = resolveWorkspaceFileURL(filePath: filePath, fallbackDocumentId: fallbackDocumentId) {
            openFile(url)
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            NotificationCenter.default.post(name: NSNotification.Name("ScrollToText"), object: trimmedText)
        }
    }

    /// Generate architecture diagrams using AI → Mermaid code (runs in background, doesn't block UI)
    private func generateArchitectureDiagrams(forceModes: Set<String>) async {
        for mode in ["software", "dataflow", "deployment"] {
            let shouldForce = forceModes.contains(mode)
            let hasCachedDiagram = !(currentDiagram(for: mode)?.isEmpty ?? true)
            if shouldForce || !hasCachedDiagram {
                await generateArchitectureDiagram(mode: mode, force: shouldForce)
            }
        }
    }

    /// Load ALL entities and claims from SQLite into orchestrator's @Published arrays
    /// Lazy load — only loads counts, not full data. Panel reads from DB on demand.
    private func loadCachedResults() {
        // Don't load thousands of records into @Published arrays.
        // The SemanticPanelView reads directly from DB when it needs to display.
        NSLog("[DDE] DB ready for lazy loading")
        refreshSemanticViews()
    }

    /// Wait until AI orchestrator finishes all pending jobs
    private func waitForAICompletion() async {
        guard let orch = incrementalCompiler?.orchestrator else { return }
        var waited = 0
        // Poll every 2 seconds, but stop if paused/disabled/timeout (max 5 min)
        while orch.isProcessing && !orch.isDisabled && !orch.isPaused && waited < 150 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            waited += 1
        }
    }

    /// Cursor moved to a different block
    func handleCursorBlockChange(_ blockId: String) {
        guard activeTabIndex >= 0, activeTabIndex < openTabs.count else { return }
        openTabs[activeTabIndex].activeBlockId = blockId
    }

    private func generateArchitectureDiagram(mode: String, force: Bool) async {
        guard let compiler = incrementalCompiler, compiler.orchestrator.hasAPIKey else { return }
        guard force || (currentDiagram(for: mode)?.isEmpty ?? true) else { return }
        guard !activeDiagramGenerationModes.contains(mode) else { return }
        guard let summaries = diagramSummaries() else { return }

        activeDiagramGenerationModes.insert(mode)
        defer { activeDiagramGenerationModes.remove(mode) }

        do {
            let results = try await compiler.orchestrator.providerClient.generateMermaidDiagrams(
                mode: mode,
                entitiesSummary: summaries.entities,
                claimsSummary: summaries.claims,
                customPrompt: diagramPrompt(for: mode)
            )
            // Combine multiple diagrams with separator markers
            let combined = results.map { "%%DIAGRAM_TITLE:\($0.title)\n\($0.mermaid)" }.joined(separator: "\n%%DIAGRAM_SEPARATOR\n")
            setDiagram(combined, for: mode)
            cacheDiagram(combined, for: mode)
            NSLog("[DDE] Generated \(results.count) \(mode) diagrams")
        } catch {
            NSLog("[DDE] Failed \(mode.capitalized) diagram: \(error)")
        }
    }

    private func diagramSummaries() -> (entities: String, claims: String)? {
        guard let db = semanticDatabase else { return nil }

        // Use V1 modules + symbols as primary data source
        let modules = db.allModules()
        let entities = db.uniqueEntities()
        let claims = db.allClaims()

        // Build entity summary from modules (Haiku-extracted) + old entities
        var lines: [String] = []
        for mod in modules where mod.id.hasPrefix("cmod_") {
            let symbols = db.symbolsForModule(mod.id)
            let desc = symbols.first(where: { $0.kind == "component" })?.context ?? ""
            lines.append("- \(mod.name) [\(desc)]")
        }
        for ent in entities {
            lines.append("- \(ent.name) [\(ent.type)]")
        }

        if lines.isEmpty {
            // Fallback: use headings from symbols
            let allSymbols = modules.flatMap { db.symbolsForModule($0.id) }
            let headings = allSymbols.filter { $0.kind == "heading" }
            for h in headings.prefix(50) {
                lines.append("- \(h.name)")
            }
        }

        guard !lines.isEmpty else { return nil }

        let entitySummary = lines.joined(separator: "\n")
        let claimSummary = claims.prefix(80).map { "- [\($0.safeType)] \($0.safeRawText.prefix(100))" }.joined(separator: "\n")

        return (entitySummary, claimSummary.isEmpty ? "No claims extracted" : claimSummary)

        if let compiler = incrementalCompiler {
            let entities = compiler.orchestrator.extractedEntities
            let claims = compiler.orchestrator.extractedClaims
            guard !entities.isEmpty else { return nil }
            let entitySummary = entities
                .map { "- \($0.name) [\($0.type)]" }
                .joined(separator: "\n")
            let claimSummary = claims
                .prefix(80)
                .map { "- [\($0.safeType)] \($0.safeRawText.prefix(100))" }
                .joined(separator: "\n")
            return (entitySummary, claimSummary)
        }

        return nil
    }

    private func currentDiagram(for mode: String) -> String? {
        switch mode {
        case "software":
            return softwareArchMermaid
        case "dataflow":
            return dataFlowMermaid
        case "deployment":
            return deploymentMermaid
        default:
            return nil
        }
    }

    private func setDiagram(_ mermaid: String?, for mode: String) {
        switch mode {
        case "software":
            softwareArchMermaid = mermaid
        case "dataflow":
            dataFlowMermaid = mermaid
        case "deployment":
            deploymentMermaid = mermaid
        default:
            break
        }
    }

    private func cacheDiagram(_ mermaid: String, for mode: String) {
        guard let db = semanticDatabase, let projectId = rootNode?.url.lastPathComponent else { return }
        let documentId = "__diagram_\(mode)"
        try? db.upsertDocument(
            id: documentId,
            projectId: projectId,
            filePath: ".dde/\(documentId).mmd",
            fileName: documentId,
            fileExt: "mmd",
            contentHash: mermaid
        )
    }

    private func resolveWorkspaceFileURL(filePath: String?, fallbackDocumentId: String?) -> URL? {
        let fm = FileManager.default

        if let filePath, !filePath.isEmpty {
            let directURL = URL(fileURLWithPath: filePath)
            if fm.fileExists(atPath: directURL.path) {
                return directURL
            }

            if let rootURL = rootNode?.url {
                let relativeURL = rootURL.appendingPathComponent(filePath)
                if fm.fileExists(atPath: relativeURL.path) {
                    return relativeURL
                }
            }
        }

        guard let rootURL = rootNode?.url,
              let fallbackDocumentId,
              !fallbackDocumentId.isEmpty else { return nil }

        let directURL = rootURL.appendingPathComponent(fallbackDocumentId)
        if fm.fileExists(atPath: directURL.path) {
            return directURL
        }

        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }

        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == fallbackDocumentId {
                return url
            }
        }

        return nil
    }
}
