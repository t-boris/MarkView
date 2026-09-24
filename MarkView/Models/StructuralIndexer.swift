import Foundation

/// Deterministic structural indexer — no LLM.
/// Scans directory tree, parses markdown, records per-folder rows, indexes FTS5.
/// Heavy file I/O runs off the main thread; DB writes hop back to @MainActor.
class StructuralIndexer: @unchecked Sendable {
    let db: SemanticDatabase
    let rootURL: URL
    var progress: (@Sendable (String) -> Void)?

    init(db: SemanticDatabase, rootURL: URL) {
        self.db = db
        self.rootURL = rootURL
    }

    // MARK: - Full Index

    /// Index the entire folder — skips if already indexed and no files changed.
    /// Runs file I/O on a background thread, DB writes on MainActor.
    func indexAll() async {
        // Batch-fetch stored state up front — ONE main-thread hop instead of one per file.
        // (The old-scheme DB reset happens cheaply in SemanticDatabase.init by discarding
        // the whole file, so by here the DB is always the current scheme.)
        let existingModules = await MainActor.run { db.allModules() }
        let storedMeta = await MainActor.run { db.allDocumentMeta() }
        let isFirstIndex = existingModules.isEmpty

        // SINGLE tree walk: builds the module graph and classifies every markdown file
        // as changed/new (read + parsed) or unchanged (skipped via mtime match).
        progress?("Scanning directory tree...")
        let scan = await scanTree(storedMeta: storedMeta)

        // Incremental fast path: nothing changed and nothing deleted → leave the index as-is.
        if !isFirstIndex && scan.changedDocs.isEmpty {
            let deleted = Set(storedMeta.keys).subtracting(scan.seenDocIds)
            if deleted.isEmpty {
                progress?("Index up to date")
                NSLog("[StructuralIndexer] Skipping — already indexed, no changes")
                return
            }
        }

        progress?("Indexing \(scan.changedDocs.count) changed files...")
        await writeModules(scan.modules)
        await writeChangedDocs(scan.changedDocs)
        progress?("Indexing complete")
        NSLog("[StructuralIndexer] Indexed \(scan.changedDocs.count) changed of \(scan.seenDocIds.count) files")
    }

    // MARK: - Single-pass scan

    private struct ModuleRow {
        let url: URL
        let modId: String
        let parentId: String?
        let name: String
        let level: Int
        let fileCount: Int
    }
    private struct ParsedSymbol {
        let id: String
        let moduleId: String
        let documentId: String
        let name: String
        let kind: String
        let lineStart: Int?
        let lineEnd: Int?
        let context: String?
    }
    private struct ParsedRelation {
        let id: String
        let sourceId: String
        let targetId: String
        let type: String
        let sourceDoc: String
        let evidence: String
    }
    private struct ParsedDoc {
        let docId: String
        let moduleId: String
        let filePath: String
        let contentHash: String
        let content: String
        let mtime: Int?
        let symbols: [ParsedSymbol]
        let relations: [ParsedRelation]
        let ftsTitle: String
    }
    private struct ScanResult {
        let modules: [ModuleRow]
        let changedDocs: [ParsedDoc]
        let seenDocIds: Set<String>
    }

    /// Walk the tree exactly once: derive the module graph from the directories
    /// encountered and classify each markdown file as unchanged (mtime match →
    /// skipped) or changed/new (read + parsed). All file I/O stays on a utility
    /// queue — no per-file hops to the main thread.
    private func scanTree(storedMeta: [String: (hash: String, mtime: Int?)]) async -> ScanResult {
        let rootName = rootURL.lastPathComponent
        let rootURLCapture = rootURL

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(at: rootURLCapture,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]) else {
                    continuation.resume(returning: ScanResult(modules: [], changedDocs: [], seenDocIds: []))
                    return
                }

                // Cheap pre-count of .md files (no reads) so footer progress can show N/M.
                var totalMd = 0
                if let counter = fm.enumerator(at: rootURLCapture, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    while let u = counter.nextObject() as? URL {
                        if u.pathExtension.lowercased() == "md", !u.path.contains("/.dde/") { totalMd += 1 }
                    }
                }

                var relDirSet: Set<String> = [""]       // workspace-relative dirs ("" == root)
                var relDirMdCount: [String: Int] = [:]  // direct .md children per relative dir
                var changedDocs: [ParsedDoc] = []
                var seenDocIds: Set<String> = []
                var fileCount = 0

                while let url = enumerator.nextObject() as? URL {
                    guard url.pathExtension.lowercased() == "md", !url.path.contains("/.dde/") else { continue }

                    // Everything below is derived from docId (the workspace-relative
                    // path) with pure "/" string ops — no absolute-path matching, so
                    // Unicode/symlink normalization can't desync the module tree.
                    let docId = SemanticDatabase.documentId(for: url, root: rootURLCapture)
                    let relDir = (docId as NSString).deletingLastPathComponent  // "" == workspace root
                    relDirMdCount[relDir, default: 0] += 1
                    // Register relDir and every ancestor so intermediate dirs (that
                    // only contain subfolders) still become modules.
                    var anc = relDir
                    while true {
                        relDirSet.insert(anc)
                        if anc.isEmpty { break }
                        anc = (anc as NSString).deletingLastPathComponent
                    }
                    seenDocIds.insert(docId)
                    fileCount += 1
                    // Tick every 20 scanned files (changed or not) → smooth footer N/M.
                    if fileCount % 20 == 0 { self.progress?("\(fileCount)/\(totalMd)") }

                    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        .map { Int($0.timeIntervalSince1970) }

                    // Unchanged: known docId with a matching mtime → already in the DB, skip read+parse.
                    if let stored = storedMeta[docId], let storedMtime = stored.mtime,
                       let mtime = mtime, storedMtime == mtime {
                        continue
                    }

                    // Changed/new (or mtime unknown) → read and parse.
                    guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

                    // Module id for this file's directory. "/" + relDir reproduces the
                    // legacy absolute-minus-root form so symbol/module ids stay consistent.
                    let modId = "mod_\(self.fnv1aSync(relDir.isEmpty ? "/" : "/" + relDir))"

                    // Content hash
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
                                let targetURL = URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
                                let targetId = SemanticDatabase.documentId(for: targetURL, root: rootURLCapture)
                                let relId = "rel_\(self.fnv1aSync("\(docId)→\(targetId)"))"
                                relations.append(ParsedRelation(id: relId, sourceId: docId, targetId: targetId,
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

                    changedDocs.append(ParsedDoc(docId: docId, moduleId: modId, filePath: url.path,
                                                 contentHash: contentHash, content: content, mtime: mtime,
                                                 symbols: symbols, relations: relations,
                                                 ftsTitle: url.deletingPathExtension().lastPathComponent))
                }

                // Derive the module graph from the relative-dir set (every entry is
                // the root "" or a directory on a path to .md files — all real modules).
                // modId = fnv1a("/" + relDir) matches the per-file symbol modId above.
                func modIdFor(_ rel: String) -> String { "mod_\(self.fnv1aSync(rel.isEmpty ? "/" : "/" + rel))" }
                var modules: [ModuleRow] = []
                for relDir in relDirSet {
                    let files = relDirMdCount[relDir] ?? 0
                    if relDir.isEmpty {
                        modules.append(ModuleRow(url: rootURLCapture, modId: modIdFor(""), parentId: nil,
                                                 name: rootName, level: 0, fileCount: files))
                        continue
                    }
                    let parentRel = (relDir as NSString).deletingLastPathComponent
                    let level = relDir.split(separator: "/").count
                    modules.append(ModuleRow(url: rootURLCapture.appendingPathComponent(relDir),
                                             modId: modIdFor(relDir), parentId: modIdFor(parentRel),
                                             name: (relDir as NSString).lastPathComponent, level: level, fileCount: files))
                }
                // Parent-before-child order: modules.parent_module_id has a FK to
                // modules(module_id), so a child inserted before its parent is rejected.
                modules.sort { $0.level < $1.level }

                self.progress?("Writing \(changedDocs.count) files to index...")
                NSLog("[StructuralIndexer] Scanned \(fileCount) files, \(changedDocs.count) changed")
                continuation.resume(returning: ScanResult(modules: modules, changedDocs: changedDocs, seenDocIds: seenDocIds))
            }
        }
    }

    /// Upsert the module graph on the main thread (cheap — one batch).
    private func writeModules(_ modules: [ModuleRow]) async {
        await MainActor.run {
            for mod in modules {
                db.upsertModule(id: mod.modId, name: mod.name, path: mod.url.path,
                                parentId: mod.parentId, level: mod.level, fileCount: mod.fileCount)
            }
        }
    }

    // MARK: - Write changed documents

    /// Write changed/new documents in MainActor chunks, yielding between batches
    /// so the UI stays responsive. Unchanged documents are never touched.
    private func writeChangedDocs(_ docs: [ParsedDoc]) async {
        let rootName = rootURL.lastPathComponent
        let chunkSize = 50
        for chunkStart in stride(from: 0, to: docs.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, docs.count)
            let chunk = docs[chunkStart..<chunkEnd]

            await MainActor.run {
                for doc in chunk {
                    try? db.upsertDocument(id: doc.docId, projectId: rootName,
                                           filePath: doc.filePath, fileName: (doc.filePath as NSString).lastPathComponent, fileExt: "md",
                                           contentHash: doc.contentHash, fileMtime: doc.mtime)
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

        NSLog("[StructuralIndexer] Wrote \(docs.count) changed documents")
    }

    // MARK: - Helpers

    private func fnv1aSync(_ str: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in str.utf8 { hash ^= UInt32(byte); hash = hash &* 0x01000193 }
        return String(hash, radix: 16)
    }
}
