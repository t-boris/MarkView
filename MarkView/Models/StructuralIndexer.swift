import Foundation

/// Deterministic structural indexer — no LLM.
/// Scans directory tree, parses markdown, builds module graph, indexes FTS5.
/// Heavy file I/O runs off the main thread; DB writes hop back to @MainActor.
class StructuralIndexer: @unchecked Sendable {
    let db: SemanticDatabase
    let rootURL: URL
    let providerClient: AIProviderClient?
    var progress: (@Sendable (String) -> Void)?

    init(db: SemanticDatabase, rootURL: URL, providerClient: AIProviderClient? = nil) {
        self.db = db
        self.rootURL = rootURL
        self.providerClient = providerClient
    }

    // MARK: - Full Index

    /// Index the entire folder — skips if already indexed and no files changed.
    /// Runs file I/O on a background thread, DB writes on MainActor.
    func indexAll() async {
        // Check if already indexed by looking for modules
        let existingModules = await MainActor.run { db.allModules() }
        if !existingModules.isEmpty {
            // Check if any files changed since last index — heavy I/O, run off main
            let hasChanges: Bool = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    let fm = FileManager.default
                    var changed = false

                    if let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                        while let url = enumerator.nextObject() as? URL {
                            guard url.pathExtension.lowercased() == "md", !url.path.contains(".dde") else { continue }
                            let docId = url.lastPathComponent

                            // Synchronously check hash — we're on a background thread
                            let storedHash: String? = DispatchQueue.main.sync {
                                self.db.getDocumentHash(docId)
                            }

                            if let hash = storedHash {
                                if let content = try? String(contentsOf: url, encoding: .utf8) {
                                    var h: UInt32 = 0x811c9dc5
                                    for byte in content.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
                                    if hash != String(h, radix: 16) { changed = true; break }
                                }
                            } else {
                                changed = true; break // New file
                            }
                        }
                    }
                    continuation.resume(returning: changed)
                }
            }

            if !hasChanges {
                progress?("Index up to date (\(existingModules.count) modules)")
                NSLog("[StructuralIndexer] Skipping — already indexed, no changes")
                return
            }

            progress?("Files changed, re-indexing...")
        }

        progress?("Scanning directory tree...")
        await indexModules()
        progress?("Parsing markdown files...")
        await indexDocuments()
        progress?("Indexing complete")
    }

    /// Extract content-based modules using Haiku (cheap, fast)
    /// Call AFTER indexAll() — runs in background, enriches modules with LLM-derived components
    func extractContentModules() async {
        guard let client = providerClient, client.hasAPIKey else { return }

        // Collect files on background thread
        let files: [(url: URL, content: String)] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continuation.resume(returning: [])
                    return
                }
                var result: [(url: URL, content: String)] = []
                while let url = enumerator.nextObject() as? URL {
                    guard url.pathExtension.lowercased() == "md", !url.path.contains(".dde") else { continue }
                    if let content = try? String(contentsOf: url, encoding: .utf8), content.count > 50 {
                        result.append((url, content))
                    }
                }
                continuation.resume(returning: result)
            }
        }

        progress?("Extracting modules from \(files.count) files (Haiku)...")

        var globalSeen = Set<String>() // Deduplicate across files

        for (i, file) in files.enumerated() {
            progress?("Analyzing \(i+1)/\(files.count): \(file.url.lastPathComponent)")

            let docId = file.url.lastPathComponent

            // Check if already extracted for this file
            let alreadyExtracted = await MainActor.run { db.hasExtractedComponents(forDocument: docId) }
            if alreadyExtracted { continue }

            do {
                let modules = try await extractModulesFromFile(content: String(file.content.prefix(15000)), fileName: docId, client: client)

                await MainActor.run {
                    for mod in modules {
                        // Deduplicate by lowercase name across all files
                        let key = mod.name.lowercased().trimmingCharacters(in: .whitespaces)
                        guard !globalSeen.contains(key) else { continue }
                        globalSeen.insert(key)

                        let modId = "cmod_\(fnv1a("\(docId):\(mod.name)"))"
                        db.upsertModule(id: modId, name: mod.name, path: "\(file.url.deletingLastPathComponent().path)/\(mod.name)",
                                        parentId: moduleId(for: file.url.deletingLastPathComponent()), level: 1, fileCount: 0)

                        // Store as symbol too for searchability
                        db.insertSymbol(id: "sym_cmod_\(fnv1a(modId))", moduleId: modId, documentId: docId,
                                       name: mod.name, kind: "component", lineStart: nil, lineEnd: nil,
                                       context: "[\(mod.type)] \(mod.description)")

                        // Store relations
                        for dep in mod.dependencies {
                            let targetId = "cmod_\(fnv1a("\(docId):\(dep)"))"
                            db.insertRelation(id: "rel_\(fnv1a("\(modId)→\(dep)"))", sourceId: modId, targetId: targetId,
                                              type: "depends_on", sourceDoc: docId, evidence: "\(mod.name) → \(dep)")
                        }
                    }
                }

                NSLog("[StructuralIndexer] \(file.url.lastPathComponent): \(modules.count) modules extracted")
            } catch {
                NSLog("[StructuralIndexer] Haiku error for \(docId): \(error)")
            }
        }

        progress?("Module extraction complete")
    }

    struct ExtractedModule {
        let name: String
        let type: String
        let description: String
        let dependencies: [String]
    }

    private func extractModulesFromFile(content: String, fileName: String, client: AIProviderClient) async throws -> [ExtractedModule] {
        guard let apiKey = await MainActor.run(body: { client.apiKeyValue }) else { throw AIProviderError.noAPIKey }

        // Tool schema for structured output (SGR)
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
                                "name": ["type": "string", "description": "Specific component name"],
                                "type": ["type": "string", "enum": ["service","database","api","queue","system","library","tool","framework","protocol","storage","cache","gateway","worker","scheduler","proxy","broker","sdk","platform","infrastructure","monitoring","testing","module","pipeline","classifier","resolver","analyzer","generator","processor"]],
                                "description": ["type": "string", "description": "One sentence: what it does"],
                                "dependencies": ["type": "array", "items": ["type": "string"], "description": "Names of other components it depends on"]
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
            "system": "Extract ALL named technical components, modules, and architectural elements from this documentation. The document may be in any language. Look for: code modules (*.py, classes), pipeline stages, services, APIs, databases, queues, libraries, frameworks, classifiers, analyzers, resolvers, generators, infrastructure. Extract EVERY named component. Do NOT extract company/people names.",
            "messages": [["role": "user", "content": "File: \(fileName)\n\n\(content)"]],
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "extract_components"]
        ]

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
            throw AIProviderError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0,
                String(data: responseData, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else { return [] }

        // Track cost (Haiku 4.5: $1/1M in, $5/1M out)
        if let usage = json["usage"] as? [String: Any] {
            let inp = usage["input_tokens"] as? Int ?? 0
            let out = usage["output_tokens"] as? Int ?? 0
            await MainActor.run { db.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0001 + Double(out) * 0.0005) }
        }

        // Parse tool_use response
        guard let contentBlocks = json["content"] as? [[String: Any]] else { return [] }

        for block in contentBlocks {
            if block["type"] as? String == "tool_use",
               let input = block["input"] as? [String: Any],
               let components = input["components"] as? [[String: Any]] {
                return components.compactMap { m in
                    guard let name = m["name"] as? String, let type = m["type"] as? String else { return nil }
                    return ExtractedModule(
                        name: name,
                        type: type,
                        description: m["description"] as? String ?? "",
                        dependencies: m["dependencies"] as? [String] ?? []
                    )
                }
            }
        }

        return []
    }

    // MARK: - Step 1: Modules (directories)

    /// Scan directory tree and register modules. Heavy I/O on background thread,
    /// DB writes batched on MainActor.
    private func indexModules() async {
        // Collect directory info on background thread
        struct ModuleInfo {
            let url: URL
            let modId: String
            let parentId: String
            let name: String
            let level: Int
            let fileCount: Int
        }

        let rootId = moduleId(for: rootURL)
        let rootPath = rootURL.path
        let rootComponentCount = rootURL.pathComponents.count
        let rootURLCapture = rootURL

        let (rootFiles, modules): (Int, [ModuleInfo]) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                let fm = FileManager.default
                let rootMdCount = (try? fm.contentsOfDirectory(at: rootURLCapture, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension.lowercased() == "md" }.count ?? 0

                var result: [ModuleInfo] = []
                guard let enumerator = fm.enumerator(at: rootURLCapture,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]) else {
                    continuation.resume(returning: (rootMdCount, []))
                    return
                }

                while let url = enumerator.nextObject() as? URL {
                    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    guard url.lastPathComponent != ".dde" else { enumerator.skipDescendants(); continue }

                    let relative = url.path.replacingOccurrences(of: rootPath, with: "")
                    let modId = "mod_\(self.fnv1aSync(relative.isEmpty ? "/" : relative))"
                    let parentRelative = url.deletingLastPathComponent().path.replacingOccurrences(of: rootPath, with: "")
                    let parentId = "mod_\(self.fnv1aSync(parentRelative.isEmpty ? "/" : parentRelative))"
                    let level = url.pathComponents.count - rootComponentCount
                    let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                        .filter { $0.pathExtension.lowercased() == "md" }.count ?? 0
                    let hasSubs = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]))?
                        .contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? false

                    if files > 0 || hasSubs {
                        result.append(ModuleInfo(url: url, modId: modId, parentId: parentId,
                                                name: url.lastPathComponent, level: level, fileCount: files))
                    }
                }
                continuation.resume(returning: (rootMdCount, result))
            }
        }

        // Batch DB writes on MainActor
        await MainActor.run {
            db.upsertModule(id: rootId, name: rootURL.lastPathComponent, path: rootURL.path,
                            parentId: nil, level: 0, fileCount: rootFiles)
            for mod in modules {
                db.upsertModule(id: mod.modId, name: mod.name, path: mod.url.path,
                                parentId: mod.parentId, level: mod.level, fileCount: mod.fileCount)
            }
        }
    }

    // MARK: - Step 2: Documents (parse markdown)

    /// Parse all markdown files. File I/O on background thread, DB writes batched on MainActor.
    private func indexDocuments() async {
        struct ParsedDoc {
            let docId: String
            let moduleId: String
            let filePath: String
            let contentHash: String
            let content: String
            let symbols: [ParsedSymbol]
            let relations: [ParsedRelation]
            let ftsTitle: String
        }
        struct ParsedSymbol {
            let id: String
            let moduleId: String
            let documentId: String
            let name: String
            let kind: String
            let lineStart: Int?
            let lineEnd: Int?
            let context: String?
        }
        struct ParsedRelation {
            let id: String
            let sourceId: String
            let targetId: String
            let type: String
            let sourceDoc: String
            let evidence: String
        }

        let rootPath = rootURL.path
        let rootName = rootURL.lastPathComponent

        // Parse all files on background thread
        let docs: [ParsedDoc] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(at: rootURL,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                    continuation.resume(returning: [])
                    return
                }

                var result: [ParsedDoc] = []
                var fileCount = 0
                while let url = enumerator.nextObject() as? URL {
                    guard url.pathExtension.lowercased() == "md" else { continue }
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    if url.path.contains(".dde") { continue }

                    let docId = url.lastPathComponent
                    let parentRelative = url.deletingLastPathComponent().path.replacingOccurrences(of: rootPath, with: "")
                    let modId = "mod_\(self.fnv1aSync(parentRelative.isEmpty ? "/" : parentRelative))"
                    fileCount += 1

                    if fileCount % 100 == 0 {
                        self.progress?("Parsing \(fileCount): \(docId)")
                    }

                    // Compute content hash
                    var h: UInt32 = 0x811c9dc5
                    for byte in content.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
                    let contentHash = String(h, radix: 16)

                    // Parse symbols
                    var symbols: [ParsedSymbol] = []
                    var relations: [ParsedRelation] = []
                    let lines = content.components(separatedBy: "\n")
                    var headingStack: [String] = []

                    for (i, line) in lines.enumerated() {
                        let lineNum = i + 1

                        // Headings
                        if line.range(of: #"^(#{1,6})\s+(.+)"#, options: .regularExpression) != nil {
                            let level = line.prefix(while: { $0 == "#" }).count
                            let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                            while headingStack.count >= level { headingStack.removeLast() }
                            headingStack.append(text)
                            let symId = "sym_h_\(self.fnv1aSync("\(docId):\(lineNum):\(text)"))"
                            symbols.append(ParsedSymbol(id: symId, moduleId: modId, documentId: docId,
                                                       name: text, kind: "heading", lineStart: lineNum, lineEnd: lineNum,
                                                       context: headingStack.joined(separator: " > ")))
                        }

                        // Links
                        let linkPattern = #"\[([^\]]+)\]\(([^)]+)\)"#
                        if let regex = try? NSRegularExpression(pattern: linkPattern) {
                            let nsLine = line as NSString
                            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
                            for match in matches {
                                guard match.numberOfRanges >= 3 else { continue }
                                let linkText = nsLine.substring(with: match.range(at: 1))
                                let target = nsLine.substring(with: match.range(at: 2))
                                if target.hasPrefix("http") || target.hasPrefix("#") || target.hasPrefix("mailto:") { continue }
                                let targetFile = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent()).lastPathComponent
                                let relId = "rel_\(self.fnv1aSync("\(docId)→\(targetFile)"))"
                                relations.append(ParsedRelation(id: relId, sourceId: docId, targetId: targetFile,
                                                               type: "links_to", sourceDoc: docId, evidence: linkText))
                                let symId = "sym_l_\(self.fnv1aSync("\(docId):\(lineNum):\(target)"))"
                                symbols.append(ParsedSymbol(id: symId, moduleId: modId, documentId: docId,
                                                           name: linkText, kind: "link", lineStart: lineNum, lineEnd: lineNum,
                                                           context: target))
                            }
                        }

                        // Code blocks
                        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                            let lang = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespaces)
                            if !lang.isEmpty && !lang.hasPrefix("```") {
                                let symId = "sym_c_\(self.fnv1aSync("\(docId):\(lineNum)"))"
                                symbols.append(ParsedSymbol(id: symId, moduleId: modId, documentId: docId,
                                                           name: lang, kind: "code_block", lineStart: lineNum, lineEnd: nil, context: nil))
                            }
                        }
                    }

                    result.append(ParsedDoc(docId: docId, moduleId: modId, filePath: url.path,
                                           contentHash: contentHash, content: content,
                                           symbols: symbols, relations: relations,
                                           ftsTitle: docId.replacingOccurrences(of: ".md", with: "")))
                }

                self.progress?("Writing \(fileCount) files to index...")
                NSLog("[StructuralIndexer] Parsed \(fileCount) files, writing to DB")
                continuation.resume(returning: result)
            }
        }

        // Batch DB writes on MainActor — process in chunks to yield between batches
        let chunkSize = 50
        for chunkStart in stride(from: 0, to: docs.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, docs.count)
            let chunk = docs[chunkStart..<chunkEnd]

            await MainActor.run {
                for doc in chunk {
                    try? db.upsertDocument(id: doc.docId, projectId: rootName,
                                           filePath: doc.filePath, fileName: doc.docId, fileExt: "md",
                                           contentHash: doc.contentHash)
                    for sym in doc.symbols {
                        db.insertSymbol(id: sym.id, moduleId: sym.moduleId, documentId: sym.documentId,
                                       name: sym.name, kind: sym.kind, lineStart: sym.lineStart, lineEnd: sym.lineEnd,
                                       context: sym.context)
                    }
                    for rel in doc.relations {
                        db.insertRelation(id: rel.id, sourceId: rel.sourceId, targetId: rel.targetId,
                                          type: rel.type, sourceDoc: rel.sourceDoc, evidence: rel.evidence)
                    }
                    db.indexDocumentFTS(documentId: doc.docId, title: doc.ftsTitle, content: doc.content)
                }
            }

            // Yield between chunks so UI stays responsive
            await Task.yield()

            if chunkStart % 200 == 0 {
                progress?("Indexing \(chunkStart)/\(docs.count)...")
            }
        }

        NSLog("[StructuralIndexer] Indexed \(docs.count) files")
    }

    // MARK: - Helpers

    private func moduleId(for url: URL) -> String {
        let relative = url.path.replacingOccurrences(of: rootURL.path, with: "")
        return "mod_\(fnv1aSync(relative.isEmpty ? "/" : relative))"
    }

    /// Thread-safe FNV-1a hash — can be called from any thread
    private func fnv1aSync(_ str: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in str.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
        return String(hash, radix: 16)
    }

    // Keep original name for compatibility
    private func fnv1a(_ str: String) -> String {
        fnv1aSync(str)
    }
}
