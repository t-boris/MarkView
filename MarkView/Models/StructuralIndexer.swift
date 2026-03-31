import Foundation

/// Deterministic structural indexer — no LLM.
/// Scans directory tree, parses markdown, builds module graph, indexes FTS5.
@MainActor
class StructuralIndexer {
    let db: SemanticDatabase
    let rootURL: URL
    let providerClient: AIProviderClient?
    var progress: ((String) -> Void)?

    init(db: SemanticDatabase, rootURL: URL, providerClient: AIProviderClient? = nil) {
        self.db = db
        self.rootURL = rootURL
        self.providerClient = providerClient
    }

    // MARK: - Full Index

    /// Index the entire folder — skips if already indexed and no files changed
    func indexAll() {
        // Check if already indexed by looking for modules
        let existingModules = db.allModules()
        if !existingModules.isEmpty {
            // Already indexed — check if any files changed since last index
            let fm = FileManager.default
            var hasChanges = false

            if let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                while let url = enumerator.nextObject() as? URL {
                    guard url.pathExtension.lowercased() == "md", !url.path.contains(".dde") else { continue }
                    let docId = url.lastPathComponent
                    if let hash = db.getDocumentHash(docId) {
                        // Compute current hash
                        if let content = try? String(contentsOf: url, encoding: .utf8) {
                            var h: UInt32 = 0x811c9dc5
                            for byte in content.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
                            if hash != String(h, radix: 16) { hasChanges = true; break }
                        }
                    } else {
                        hasChanges = true; break // New file
                    }
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
        indexModules()
        progress?("Parsing markdown files...")
        indexDocuments()
        progress?("Indexing complete")
    }

    /// Extract content-based modules using Haiku (cheap, fast)
    /// Call AFTER indexAll() — runs in background, enriches modules with LLM-derived components
    func extractContentModules() async {
        guard let client = providerClient, client.hasAPIKey else { return }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }

        var files: [(url: URL, content: String)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md", !url.path.contains(".dde") else { continue }
            if let content = try? String(contentsOf: url, encoding: .utf8), content.count > 50 {
                files.append((url, content))
            }
        }

        progress?("Extracting modules from \(files.count) files (Haiku)...")

        var globalSeen = Set<String>() // Deduplicate across files

        for (i, file) in files.enumerated() {
            progress?("Analyzing \(i+1)/\(files.count): \(file.url.lastPathComponent)")

            let docId = file.url.lastPathComponent

            // Check if already extracted for this file
            if db.hasExtractedComponents(forDocument: docId) { continue }

            do {
                let modules = try await extractModulesFromFile(content: String(file.content.prefix(15000)), fileName: docId, client: client)

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
        guard let apiKey = client.apiKeyValue else { throw AIProviderError.noAPIKey }

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
            db.addUsage(inputTokens: inp, outputTokens: out, costCents: Double(inp) * 0.0001 + Double(out) * 0.0005)
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

    private func indexModules() {
        let fm = FileManager.default
        let rootId = moduleId(for: rootURL)

        // Root module
        let rootFiles = countMarkdownFiles(in: rootURL)
        db.upsertModule(id: rootId, name: rootURL.lastPathComponent, path: rootURL.path,
                        parentId: nil, level: 0, fileCount: rootFiles)

        // Recursive subdirectories
        guard let enumerator = fm.enumerator(at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }

        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard url.lastPathComponent != ".dde" else { enumerator.skipDescendants(); continue }

            let modId = moduleId(for: url)
            let parentId = moduleId(for: url.deletingLastPathComponent())
            let level = url.pathComponents.count - rootURL.pathComponents.count
            let files = countMarkdownFiles(in: url)

            if files > 0 || hasSubdirectories(url) {
                db.upsertModule(id: modId, name: url.lastPathComponent, path: url.path,
                                parentId: parentId, level: level, fileCount: files)
            }
        }
    }

    // MARK: - Step 2: Documents (parse markdown)

    private func indexDocuments() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }

        var fileCount = 0
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md" else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if url.path.contains(".dde") { continue }

            let docId = url.lastPathComponent
            let modId = moduleId(for: url.deletingLastPathComponent())
            fileCount += 1
            progress?("Parsing \(fileCount): \(docId)")

            // Ensure document record exists (FK constraint requires it for symbols)
            var h: UInt32 = 0x811c9dc5
            for byte in content.utf8 { h ^= UInt32(byte); h = h &* 0x01000193 }
            try? db.upsertDocument(id: docId, projectId: rootURL.lastPathComponent,
                                   filePath: url.path, fileName: docId, fileExt: "md",
                                   contentHash: String(h, radix: 16))

            // Parse symbols (headings, links, code blocks)
            parseSymbols(content: content, documentId: docId, moduleId: modId, fileURL: url)

            // Index for FTS5 search
            db.indexDocumentFTS(documentId: docId, title: docId.replacingOccurrences(of: ".md", with: ""), content: content)
        }

        NSLog("[StructuralIndexer] Indexed \(fileCount) files")
    }

    // MARK: - Symbol Parsing

    private func parseSymbols(content: String, documentId: String, moduleId: String, fileURL: URL) {
        let lines = content.components(separatedBy: "\n")
        var headingStack: [String] = []

        for (i, line) in lines.enumerated() {
            let lineNum = i + 1

            // Headings → symbols
            if let match = line.range(of: #"^(#{1,6})\s+(.+)"#, options: .regularExpression) {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)

                while headingStack.count >= level { headingStack.removeLast() }
                headingStack.append(text)

                let symId = "sym_h_\(fnv1a("\(documentId):\(lineNum):\(text)"))"
                db.insertSymbol(id: symId, moduleId: moduleId, documentId: documentId,
                               name: text, kind: "heading", lineStart: lineNum, lineEnd: lineNum,
                               context: headingStack.joined(separator: " > "))
            }

            // Markdown links [text](target) → relations
            let linkPattern = #"\[([^\]]+)\]\(([^)]+)\)"#
            if let regex = try? NSRegularExpression(pattern: linkPattern) {
                let nsLine = line as NSString
                let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))

                for match in matches {
                    guard match.numberOfRanges >= 3 else { continue }
                    let linkText = nsLine.substring(with: match.range(at: 1))
                    let target = nsLine.substring(with: match.range(at: 2))

                    // Skip external URLs and anchors
                    if target.hasPrefix("http") || target.hasPrefix("#") || target.hasPrefix("mailto:") { continue }

                    // This is a link to another file → relation
                    let targetFile = URL(fileURLWithPath: target, relativeTo: fileURL.deletingLastPathComponent()).lastPathComponent
                    let relId = "rel_\(fnv1a("\(documentId)→\(targetFile)"))"
                    db.insertRelation(id: relId, sourceId: documentId, targetId: targetFile,
                                      type: "links_to", sourceDoc: documentId, evidence: linkText)

                    // Also create a symbol for the link
                    let symId = "sym_l_\(fnv1a("\(documentId):\(lineNum):\(target)"))"
                    db.insertSymbol(id: symId, moduleId: moduleId, documentId: documentId,
                                   name: linkText, kind: "link", lineStart: lineNum, lineEnd: lineNum,
                                   context: target)
                }
            }

            // Code blocks → symbols
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let lang = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !lang.isEmpty && !lang.hasPrefix("```") {
                    let symId = "sym_c_\(fnv1a("\(documentId):\(lineNum)"))"
                    db.insertSymbol(id: symId, moduleId: moduleId, documentId: documentId,
                                   name: lang, kind: "code_block", lineStart: lineNum, lineEnd: nil, context: nil)
                }
            }
        }
    }

    // MARK: - Helpers

    private func moduleId(for url: URL) -> String {
        let relative = url.path.replacingOccurrences(of: rootURL.path, with: "")
        return "mod_\(fnv1a(relative.isEmpty ? "/" : relative))"
    }

    private func fnv1a(_ str: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in str.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
        return String(hash, radix: 16)
    }

    private func countMarkdownFiles(in directory: URL) -> Int {
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension.lowercased() == "md" }.count ?? 0
    }

    private func hasSubdirectories(_ directory: URL) -> Bool {
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]))?
            .contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? false
    }
}
