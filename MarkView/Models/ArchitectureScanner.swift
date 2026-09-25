import Foundation
import CryptoKit

/// Deterministic architecture scan of a project folder — no AI.
///
/// Produces the Modules view (folders → files, file-level dependency edges, external
/// packages), the Docs view (markdown files and the links between them), per-file
/// documentation coverage and the list of deployment config files. Runs off the main
/// thread; call `run()` from a detached task.
struct ArchitectureScanner {
    let root: URL
    /// Progress for large folders: (phase, done, total); total 0 = no count for the phase.
    /// Called from the scanning thread, at most every few dozen files.
    var onProgress: (@Sendable (String, Int, Int) -> Void)? = nil

    static let maxParseBytes = 512 * 1024

    struct Result {
        var modules: ArchView
        var docs: ArchView
        var coverage: [String: CoverageEntry]
        var metrics: [String: FileMetrics]
        var coverageReport: String?
        var deploymentHints: [String]
        var deploymentSignature: String
        var gitHead: String?
        var sourceFileCount: Int
    }

    /// Languages drawn in the Modules view; config and plain text are left out.
    private static let nonGraphLanguages: Set<String> = ["", "properties", "diff", "toml", "cmake", "dockerfile"]
    /// Languages whose files depend on each other through type names, not imports.
    private static let typeReferenceLanguages: Set<String> = ["swift", "java", "kotlin", "scala", "csharp", "dart", "objectivec", "objectivecpp"]
    private static let skippedDirectories: Set<String> = [
        "node_modules", "build", "dist", "out", "target", "Pods", "DerivedData", ".build",
        "venv", ".venv", "__pycache__", "coverage", ".next", ".nuxt", ".dde", ".git",
        ".markview-insight", ".idea", ".vscode", "bower_components",
    ]
    static let manifestNames: Set<String> = [
        "package.json", "Package.swift", "go.mod", "Cargo.toml", "pyproject.toml", "setup.py",
        "pom.xml", "build.gradle", "build.gradle.kts", "Gemfile", "composer.json", "project.yml",
    ]

    func run() -> Result {
        onProgress?("Listing files", 0, 0)
        let allFiles = listFiles()
        onProgress?("Reading git history", 0, 0)
        let git = gitHistory()

        // Source files for the Modules view.
        var sources: [(path: String, language: String)] = []
        var docs: [String] = []
        var hints: [String] = []
        for path in allFiles {
            let url = root.appendingPathComponent(path)
            let name = url.lastPathComponent
            if FileType.markdownExtensions.contains(url.pathExtension.lowercased()) {
                docs.append(path)
                continue
            }
            if Self.isDeploymentHint(path) { hints.append(path) }
            guard let language = FileType.codeLanguage(for: url),
                  !Self.nonGraphLanguages.contains(language),
                  !["Makefile", "GNUmakefile", "Procfile"].contains(name),
                  !Self.isGeneratedBundle(name: name, url: url) else { continue }
            sources.append((path, language))
        }

        var contents: [String: String] = [:]
        for (index, source) in sources.enumerated() {
            contents[source.path] = read(source.path)
            if index % 50 == 0 { onProgress?("Reading files", index, sources.count) }
        }
        // Documents are project content too (a notes vault is mostly markdown): they join
        // the Structure and Logical views. Metrics that only mean something for code
        // (complexity, tests, doc coverage) still use `sources` alone.
        for (index, doc) in docs.enumerated() {
            contents[doc] = read(doc)
            if index % 50 == 0 { onProgress?("Reading documents", index, docs.count) }
        }
        onProgress?("Building the structure", 0, 0)

        let manifests = Set(allFiles.filter { Self.manifestNames.contains(($0 as NSString).lastPathComponent) })
        // A project's own top-level folders are never external dependencies.
        let topLevel = Set(allFiles.compactMap { $0.split(separator: "/").first.map { String($0).lowercased() } })
        let declaredDeps = declaredDependencies(manifests: manifests).filter { !topLevel.contains($0.lowercased()) }
        var modules = buildModulesView(sources: sources + docs.map { ($0, "markdown") }, contents: contents,
                                       manifests: manifests, declaredDeps: declaredDeps)
        let (docsView, docRefs) = buildDocsView(docs: docs, sourcePaths: Set(sources.map(\.path)), contents: contents)
        // Links between documents are their dependencies.
        let docSet = Set(docs)
        for edge in docsView.edges where edge.kind == "links" {
            let from = String(edge.source.dropFirst(2)), to = String(edge.target.dropFirst(2))
            guard docSet.contains(from), docSet.contains(to), from != to else { continue }
            modules.edges.append(ArchEdge(source: "m:" + from, target: "m:" + to, kind: "links", weight: edge.weight))
        }
        let coverage = computeCoverage(sources: sources.map(\.path), docRefs: docRefs, times: git.times)
        let report = lineCoverageReport(sourcePaths: Set(sources.map(\.path)))
        onProgress?("Measuring complexity", 0, sources.count)
        var metrics = computeMetrics(sources: sources, contents: contents, modules: modules, git: git, lineCoverage: report.coverage)
        // Documents get history facts too, so Freshness also colours the Docs view.
        for doc in docs {
            metrics["m:" + doc] = FileMetrics(loc: contents[doc].map { $0.editorLines.count } ?? 0, complexity: 0, commits: git.commits[doc] ?? 0, bugfixes: 0, isTest: false,
                                              tested: false, testFiles: [], lineCoverage: nil,
                                              lastChanged: git.times[doc] ?? modificationTime(doc))
        }

        return Result(modules: modules, docs: docsView, coverage: coverage, metrics: metrics,
                      coverageReport: report.name, deploymentHints: hints.sorted(),
                      deploymentSignature: Self.signature(of: hints.sorted().map { fileSignature($0) }),
                      gitHead: git.head, sourceFileCount: sources.count)
    }

    // MARK: - Files

    /// Tracked and untracked-but-not-ignored files when the folder is a git work
    /// tree (so .gitignore is honoured); a filtered directory walk otherwise.
    private func listFiles() -> [String] { Self.listFiles(root: root) }

    /// The project's files, relative to `root` (see `listFiles()`); also used by the topic lens.
    static func listFiles(root: URL) -> [String] {
        if let output = Self.runTool("/usr/bin/env", ["git", "-C", root.path, "ls-files", "-co", "--exclude-standard", "-z"]),
           !output.isEmpty {
            return output.split(separator: "\0").map(String.init).filter { path in
                !path.split(separator: "/").dropLast().contains { Self.skippedDirectories.contains(String($0)) }
            }
        }
        var result: [String] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        let base = root.standardizedFileURL.path + "/"
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if Self.skippedDirectories.contains(name) || (name.hasPrefix(".") && name != ".github") {
                    enumerator.skipDescendants()
                }
                continue
            }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            result.append(String(full.dropFirst(base.count)))
        }
        return result
    }

    private func read(_ path: String) -> String {
        let url = root.appendingPathComponent(path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: Self.maxParseBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    struct GitHistory {
        var times: [String: Int] = [:]
        var commits: [String: Int] = [:]
        var bugfixes: [String: Int] = [:]
        var head: String?
    }

    private static let fixSubject = try! NSRegularExpression(
        pattern: #"\b(fix(e[sd])?|bug(fix)?|hotfix|regression|crash(es)?|defect)\b"#, options: [.caseInsensitive])

    /// Latest commit time, commit count and fix-commit count per path, plus HEAD,
    /// from one `git log` pass.
    private func gitHistory() -> GitHistory {
        var history = GitHistory()
        history.head = Self.runTool("/usr/bin/env", ["git", "-C", root.path, "rev-parse", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let log = Self.runTool("/usr/bin/env", ["git", "-C", root.path, "log", "-n", "20000",
                                                      "--format=>%ct\u{1f}%s", "--name-only", "--no-renames", "--relative"]) else {
            return history
        }
        var current = 0
        var isFix = false
        for line in log.split(separator: "\n") {
            if line.hasPrefix(">") {
                let parts = line.dropFirst().split(separator: "\u{1f}", maxSplits: 1)
                current = Int(parts.first ?? "") ?? 0
                let subject = parts.count > 1 ? String(parts[1]) : ""
                isFix = Self.fixSubject.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
            } else {
                let path = String(line)
                if history.times[path] == nil { history.times[path] = current }   // newest first
                history.commits[path, default: 0] += 1
                if isFix { history.bugfixes[path, default: 0] += 1 }
            }
        }
        return history
    }

    fileprivate func fileSignature(_ path: String) -> String {
        let values = try? root.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(path):\(values?.fileSize ?? 0):\(Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0))"
    }

    static func signature(of parts: [String]) -> String {
        var hasher = SHA256()
        for part in parts { hasher.update(data: Data(part.utf8)); hasher.update(data: Data([0])) }
        return hasher.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Run a command and return stdout, or nil on failure. Reads the pipe to EOF
    /// before waiting so a large output cannot deadlock.
    static func runTool(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A folder that is a software project: a build manifest at its root, or at
    /// least ten source files within the first few levels.
    static func looksLikeCodeProject(_ root: URL) -> Bool {
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: root.path),
           names.contains(where: { manifestNames.contains($0) || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".sln") }) {
            return true
        }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        var code = 0, seen = 0
        while let url = enumerator.nextObject() as? URL, seen < 2000 {
            seen += 1
            if skippedDirectories.contains(url.lastPathComponent) || enumerator.level > 4 {
                enumerator.skipDescendants(); continue
            }
            if let language = FileType.codeLanguage(for: url), !nonGraphLanguages.contains(language) {
                code += 1
                if code >= 10 { return true }
            }
        }
        return false
    }

    /// Minified or bundled third-party code (and anything over the parse limit)
    /// is not part of the project's own architecture.
    static func isGeneratedBundle(name: String, url: URL) -> Bool {
        let lower = name.lowercased()
        if lower.contains(".min.") || lower.contains(".bundle.") || lower.contains(".bundled.") { return true }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > maxParseBytes
    }

    static func isDeploymentHint(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        if name.hasPrefix("dockerfile") || name.hasPrefix("containerfile") { return true }
        if name.hasPrefix("docker-compose") || name.hasPrefix("compose.") { return true }
        if ["procfile", "fly.toml", "vercel.json", "netlify.toml", "serverless.yml", "serverless.yaml",
            "app.yaml", "render.yaml", "railway.json", "skaffold.yaml", "chart.yaml", "project.yml",
            "info.plist", "cloudbuild.yaml", "buildspec.yml", "nginx.conf", "makefile"].contains(name) { return true }
        if name.hasSuffix(".tf") || name.hasSuffix(".entitlements") || name.hasSuffix(".xcconfig") { return true }
        if lower.hasPrefix(".github/workflows/") { return true }
        let parts = lower.split(separator: "/")
        if parts.contains(where: { ["k8s", "kubernetes", "helm", "charts", "deploy", "deployment", "infra", "terraform"].contains(String($0)) })
            && (name.hasSuffix(".yml") || name.hasSuffix(".yaml") || name.hasSuffix(".json")) { return true }
        return false
    }

    // MARK: - Modules view

    private func buildModulesView(sources: [(path: String, language: String)], contents: [String: String],
                                  manifests: Set<String>, declaredDeps: Set<String>) -> ArchView {
        let fileSet = Set(sources.map(\.path))
        let language = Dictionary(sources.map { ($0.path, $0.language) }, uniquingKeysWith: { a, _ in a })
        var byBasename: [String: [String]] = [:]
        for path in fileSet { byBasename[(path as NSString).lastPathComponent, default: []].append(path) }

        // Folder tree, compressed so a chain of single-child folders becomes one node.
        var dirChildren: [String: Set<String>] = [:]     // dir → child dirs
        var dirFiles: [String: [String]] = [:]           // dir → files
        for path in fileSet {
            let dir = (path as NSString).deletingLastPathComponent
            dirFiles[dir, default: []].append(path)
            var child = dir
            while !child.isEmpty {
                let parent = (child as NSString).deletingLastPathComponent
                dirChildren[parent, default: []].insert(child)
                child = parent
            }
        }
        let manifestDirs = Set(manifests.map { ($0 as NSString).deletingLastPathComponent })

        var nodes: [ArchNode] = []
        let projectName = root.lastPathComponent
        nodes.append(ArchNode(id: "m:", parent: nil, kind: "root", name: projectName, path: ""))
        var fileNode: [String: String] = [:]   // path → node id (always "m:" + path)

        func loc(_ path: String) -> Int { contents[path].map { $0.editorLines.count } ?? 0 }

        /// Emit `dir` under `parentId`, merging single-child chains. Returns (files, loc).
        @discardableResult
        func emit(_ dir: String, parentId: String, prefix: String) -> (Int, Int) {
            let childDirs = dirChildren[dir] ?? []
            let files = dirFiles[dir] ?? []
            if files.isEmpty && childDirs.count == 1 && !manifestDirs.contains(dir), let only = childDirs.first {
                let label = prefix.isEmpty ? (dir as NSString).lastPathComponent : prefix + "/" + (dir as NSString).lastPathComponent
                return emit(only, parentId: parentId, prefix: label)
            }
            let name = prefix.isEmpty ? (dir as NSString).lastPathComponent : prefix + "/" + (dir as NSString).lastPathComponent
            let id = "m:" + dir
            let index = nodes.count
            nodes.append(ArchNode(id: id, parent: parentId, kind: manifestDirs.contains(dir) ? "package" : "dir",
                                  name: name, path: dir))
            var totalFiles = 0, totalLoc = 0
            for child in childDirs.sorted() {
                let (f, l) = emit(child, parentId: id, prefix: "")
                totalFiles += f; totalLoc += l
            }
            for file in files.sorted() {
                let lines = loc(file)
                var node = ArchNode(id: "m:" + file, parent: id, kind: "file",
                                    name: (file as NSString).lastPathComponent, path: file,
                                    language: language[file], loc: lines, files: 1)
                node.signature = Self.signature(of: [fileSignature(file)])
                nodes.append(node)
                fileNode[file] = "m:" + file
                totalFiles += 1; totalLoc += lines
            }
            nodes[index].files = totalFiles
            nodes[index].loc = totalLoc
            let childSignatures = nodes[(index + 1)...].filter { $0.parent == id }.compactMap(\.signature)
            nodes[index].signature = Self.signature(of: childSignatures)
            return (totalFiles, totalLoc)
        }

        var rootFiles = 0, rootLoc = 0
        for child in (dirChildren[""] ?? []).sorted() {
            let (f, l) = emit(child, parentId: "m:", prefix: "")
            rootFiles += f; rootLoc += l
        }
        for file in (dirFiles[""] ?? []).sorted() {
            let lines = loc(file)
            nodes.append(ArchNode(id: "m:" + file, parent: "m:", kind: "file", name: file, path: file,
                                  language: language[file], loc: lines, files: 1))
            fileNode[file] = "m:" + file
            rootFiles += 1; rootLoc += lines
        }
        nodes[0].files = rootFiles
        nodes[0].loc = rootLoc
        nodes[0].signature = Self.signature(of: nodes.filter { $0.parent == "m:" }.compactMap(\.signature))

        // Dependencies.
        var edges: [String: ArchEdge] = [:]
        var externals: Set<String> = []
        func link(_ from: String, _ to: String, _ kind: String) {
            guard from != to else { return }
            let key = from + "→" + to
            if edges[key] != nil { edges[key]!.weight += 1 } else { edges[key] = ArchEdge(source: from, target: to, kind: kind) }
        }
        func linkExternal(_ from: String, _ package: String) {
            guard declaredDeps.contains(package) else { return }
            externals.insert(package)
            link("m:" + from, "x:" + package, "uses")
        }

        let resolver = ImportResolver(fileSet: fileSet, byBasename: byBasename, goModules: goModulePaths(manifests: manifests))
        for (path, lang) in sources {
            guard let text = contents[path] else { continue }
            for target in resolver.resolve(path: path, language: lang, text: text) {
                switch target {
                case .file(let other): link("m:" + path, "m:" + other, "imports")
                case .directory(let dir):
                    if let id = nearestNodeId(for: dir, nodes: fileNode) { link("m:" + path, id, "imports") }
                case .package(let name): linkExternal(path, name)
                }
            }
        }

        // Type references for languages without file-level imports.
        let typeFiles = sources.filter { Self.typeReferenceLanguages.contains($0.language) }
        if !typeFiles.isEmpty {
            var declared: [String: Set<String>] = [:]
            let declaration = try! NSRegularExpression(pattern: #"\b(?:class|struct|enum|protocol|actor|interface|record|object|trait|typealias)\s+([A-Z][A-Za-z0-9_]*)"#)
            for (path, _) in typeFiles {
                guard let text = contents[path] else { continue }
                for name in Self.matches(declaration, in: text) { declared[name, default: []].insert(path) }
            }
            let unique = declared.compactMapValues { $0.count == 1 ? $0.first : nil }
            let identifier = try! NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]{2,}\b"#)
            for (path, _) in typeFiles {
                guard let text = contents[path] else { continue }
                for name in Set(Self.matches(identifier, in: text, group: 0)) {
                    if let owner = unique[name], owner != path { link("m:" + path, "m:" + owner, "references") }
                }
            }
        }

        if !externals.isEmpty {
            nodes.append(ArchNode(id: "x:", parent: nil, kind: "externalGroup", name: "External"))
            for name in externals.sorted() {
                nodes.append(ArchNode(id: "x:" + name, parent: "x:", kind: "external", name: name))
            }
        }
        return ArchView(id: "modules", nodes: nodes, edges: Array(edges.values))
    }

    private func nearestNodeId(for dir: String, nodes fileNode: [String: String]) -> String? {
        // Directory targets (Go packages): point at the folder node when it exists,
        // otherwise at the first file inside it.
        if let file = fileNode.keys.first(where: { ($0 as NSString).deletingLastPathComponent == dir }) {
            return fileNode[file]
        }
        return nil
    }

    static func matches(_ regex: NSRegularExpression, in text: String, group: Int = 1) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > group, let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }

    // MARK: - Declared dependencies

    /// Package names declared in manifests. Imports of anything else that does not
    /// resolve inside the project (standard libraries, system frameworks) are ignored.
    private func declaredDependencies(manifests: Set<String>) -> Set<String> {
        var names: Set<String> = []
        for manifest in manifests {
            let text = read(manifest)
            switch (manifest as NSString).lastPathComponent {
            case "package.json":
                if let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for key in ["dependencies", "devDependencies", "peerDependencies"] {
                        (json[key] as? [String: Any])?.keys.forEach { names.insert($0) }
                    }
                }
            case "go.mod":
                for line in text.split(separator: "\n") {
                    let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                    if let first = parts.first, first.contains(".") && first.contains("/") { names.insert(String(first)) }
                    if parts.count >= 2, parts[0] == "require" { names.insert(String(parts[1])) }
                }
            case "Cargo.toml":
                var inDeps = false
                for line in text.split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("[") { inDeps = t.contains("dependencies"); continue }
                    if inDeps, let eq = t.firstIndex(of: "=") {
                        names.insert(t[..<eq].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "_"))
                    }
                }
            case "Package.swift":
                let product = try! NSRegularExpression(pattern: #"\.product\(\s*name:\s*"([^"]+)""#)
                let package = try! NSRegularExpression(pattern: #"\.package\([^)]*?url:\s*"[^"]*/([^"/]+?)(?:\.git)?""#)
                Self.matches(product, in: text).forEach { names.insert($0) }
                Self.matches(package, in: text).forEach { names.insert($0) }
            case "pyproject.toml", "setup.py":
                let dep = try! NSRegularExpression(pattern: #"["']([A-Za-z0-9_.\-]+)\s*(?:[<>=~!;\[]|["'])"#)
                Self.matches(dep, in: text).forEach { names.insert($0.lowercased().replacingOccurrences(of: "-", with: "_")) }
            default:
                break
            }
        }
        // requirements*.txt next to the manifests or at the root.
        for candidate in ["requirements.txt", "requirements-dev.txt"] {
            for line in read(candidate).split(separator: "\n") {
                let name = line.split(whereSeparator: { "<>=~![; ".contains($0) }).first.map(String.init) ?? ""
                if !name.isEmpty, !name.hasPrefix("#"), !name.hasPrefix("-") {
                    names.insert(name.lowercased().replacingOccurrences(of: "-", with: "_"))
                }
            }
        }
        return names
    }

    private func goModulePaths(manifests: Set<String>) -> [(module: String, dir: String)] {
        manifests.filter { ($0 as NSString).lastPathComponent == "go.mod" }.compactMap { manifest in
            let line = read(manifest).split(separator: "\n").first { $0.hasPrefix("module ") }
            guard let module = line?.dropFirst("module ".count).trimmingCharacters(in: .whitespaces) else { return nil }
            return (module, (manifest as NSString).deletingLastPathComponent)
        }
    }

    // MARK: - Docs view and coverage

    private func buildDocsView(docs: [String], sourcePaths: Set<String>, contents: [String: String])
        -> (ArchView, [String: Set<String>]) {
        var nodes: [ArchNode] = [ArchNode(id: "d:", parent: nil, kind: "root", name: "Documentation", path: "")]
        var dirIds: Set<String> = ["d:"]
        func ensureDir(_ dir: String) -> String {
            if dir.isEmpty { return "d:" }
            let id = "d:" + dir + "/"
            if !dirIds.contains(id) {
                let parent = ensureDir((dir as NSString).deletingLastPathComponent)
                nodes.append(ArchNode(id: id, parent: parent, kind: "dir", name: (dir as NSString).lastPathComponent, path: dir))
                dirIds.insert(id)
            }
            return id
        }

        let docSet = Set(docs)
        var sourceBasenames: [String: [String]] = [:]
        for path in sourcePaths { sourceBasenames[(path as NSString).lastPathComponent, default: []].append(path) }
        let sourceDirs = Set(sourcePaths.flatMap { path -> [String] in
            var dirs: [String] = []
            var dir = (path as NSString).deletingLastPathComponent
            while !dir.isEmpty { dirs.append(dir); dir = (dir as NSString).deletingLastPathComponent }
            return dirs
        })

        let link = try! NSRegularExpression(pattern: #"\]\(([^)#\s]+)(?:#[^)]*)?\)"#)
        // Anchored at the start of a token, so matching does not restart inside every word.
        let pathToken = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_\-./])(?:[A-Za-z0-9_\-.]*[A-Za-z0-9_\-]/[A-Za-z0-9_\-./]+|[A-Za-z0-9_\-]+\.[A-Za-z0-9]{1,6})"#)
        var edges: [String: ArchEdge] = [:]
        var refs: [String: Set<String>] = [:]   // doc path → referenced source files/dirs ("f:" / "d:" prefixed)

        // Reading each document is independent: do it on every core, assemble in order.
        struct DocFacts { var lines = 0; var sections: [(line: Int, title: String)] = []; var links: [String] = []; var tokens: [String] = [] }
        let sortedDocs = docs.sorted()
        var facts = [DocFacts](repeating: DocFacts(), count: sortedDocs.count)
        facts.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: sortedDocs.count) { i in
                let text = contents[sortedDocs[i]] ?? read(sortedDocs[i])
                results[i] = DocFacts(lines: text.editorLines.count, sections: Self.sections(of: text),
                                      links: Self.matches(link, in: text),
                                      tokens: sourcePaths.isEmpty ? [] : Self.matches(pathToken, in: text, group: 0))
            }
        }

        for (index, doc) in sortedDocs.enumerated() {
            let fact = facts[index]
            let lines = fact.lines
            nodes.append(ArchNode(id: "d:" + doc, parent: ensureDir((doc as NSString).deletingLastPathComponent),
                                  kind: "doc", name: (doc as NSString).lastPathComponent, path: doc, loc: lines, files: 1))
            // H1/H2 sections, so zooming into a document shows its outline.
            let sections = fact.sections
            if sections.count > 1 {
                for (index, section) in sections.enumerated() {
                    let end = index + 1 < sections.count ? sections[index + 1].line - 1 : lines
                    nodes.append(ArchNode(id: "d:\(doc)#L\(section.line)", parent: "d:" + doc, kind: "section",
                                          name: section.title, path: doc, loc: max(1, end - section.line + 1)))
                }
            }
            let base = (doc as NSString).deletingLastPathComponent

            for target in fact.links where !target.contains("://") {
                let resolved = Self.normalize(base.isEmpty ? target : base + "/" + target)
                if docSet.contains(resolved) {
                    let key = doc + "→" + resolved
                    if edges[key] == nil { edges[key] = ArchEdge(source: "d:" + doc, target: "d:" + resolved, kind: "links") }
                    else { edges[key]!.weight += 1 }
                } else if sourcePaths.contains(resolved) {
                    refs[doc, default: []].insert("f:" + resolved)
                }
            }
            for raw in fact.tokens {
                var token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
                if token.hasPrefix("./") { token.removeFirst(2) }
                if sourcePaths.contains(token) {
                    refs[doc, default: []].insert("f:" + token)
                } else if sourceDirs.contains(token) {
                    refs[doc, default: []].insert("d:" + token)
                } else if !token.contains("/"), let candidates = sourceBasenames[token], candidates.count == 1 {
                    refs[doc, default: []].insert("f:" + candidates[0])
                }
            }
        }
        // Folder sizes for the Docs view.
        var counts: [String: (Int, Int)] = [:]
        let parentOf = Dictionary(nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        for node in nodes where node.kind == "doc" {
            var parent = node.parent
            while let p = parent {
                counts[p, default: (0, 0)].0 += 1
                counts[p, default: (0, 0)].1 += node.loc
                parent = parentOf[p] ?? nil
            }
        }
        for i in nodes.indices where nodes[i].kind == "dir" || nodes[i].kind == "root" {
            nodes[i].files = counts[nodes[i].id]?.0 ?? 0
            nodes[i].loc = counts[nodes[i].id]?.1 ?? 0
        }
        return (ArchView(id: "docs", nodes: nodes, edges: Array(edges.values)), refs)
    }

    /// Level-1 and level-2 headings outside code fences, with 1-based line numbers.
    static func sections(of text: String) -> [(line: Int, title: String)] {
        var result: [(Int, String)] = []
        var inFence = false
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, line.hasPrefix("#") else { continue }
            let level = line.prefix(while: { $0 == "#" }).count
            guard level <= 2, line.dropFirst(level).first == " " else { continue }
            let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { result.append((index + 1, title)) }
        }
        return result
    }

    /// Resolve `a/./b/../c` without touching the file system.
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// none: no document mentions the file or a folder containing it.
    /// fresh: a mentioning document changed at or after the file's last commit.
    /// stale: every mentioning document is older than the file's last change.
    private func computeCoverage(sources: [String], docRefs: [String: Set<String>], times: [String: Int])
        -> [String: CoverageEntry] {
        // Mentioning a broad folder ("services/", "apps/") does not document what is
        // inside it; only specific folders (≤ 25 source files) count.
        var filesInDir: [String: Int] = [:]
        for file in sources {
            var dir = (file as NSString).deletingLastPathComponent
            while !dir.isEmpty { filesInDir[dir, default: 0] += 1; dir = (dir as NSString).deletingLastPathComponent }
        }
        var docsForFile: [String: [String]] = [:]
        var docsForDir: [String: [String]] = [:]
        for (doc, targets) in docRefs {
            for target in targets {
                if target.hasPrefix("f:") {
                    docsForFile[String(target.dropFirst(2)), default: []].append(doc)
                } else if (filesInDir[String(target.dropFirst(2))] ?? 0) <= 25 {
                    docsForDir[String(target.dropFirst(2)), default: []].append(doc)
                }
            }
        }
        func time(_ path: String) -> Int {
            if let t = times[path] { return t }
            let url = root.appendingPathComponent(path)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Int(date.timeIntervalSince1970)
        }
        var coverage: [String: CoverageEntry] = [:]
        for file in sources {
            var docs = docsForFile[file] ?? []
            var dir = (file as NSString).deletingLastPathComponent
            while !dir.isEmpty {
                docs += docsForDir[dir] ?? []
                dir = (dir as NSString).deletingLastPathComponent
            }
            let unique = Array(Set(docs)).sorted()
            let status: String
            if unique.isEmpty {
                status = "none"
            } else {
                let codeTime = time(file)
                status = unique.contains { time($0) >= codeTime } ? "fresh" : "stale"
            }
            coverage["m:" + file] = CoverageEntry(status: status, docs: unique)
        }
        return coverage
    }

    // MARK: - Metrics

    private static let decisionPoint = try! NSRegularExpression(
        pattern: #"\b(if|for|while|case|catch|guard|elif|except|when|foreach|switch|until|unless)\b|&&|\|\||\s\?\s"#)

    /// Function declarations per language family; group 1 is the name when available.
    private static let functionPatterns: [String: NSRegularExpression] = {
        func r(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }
        let cFamily = r(#"^[ \t]*(?:[\w\*&:<>,\[\]]+[ \t]+)+\**(\w+)(?:::\w+)?[ \t]*\([^;{}]*\)[ \t\w]*\{"#)
        let javaLike = r(#"^[ \t]*(?:(?:public|private|protected|internal|static|final|override|abstract|async|virtual|sealed|open|suspend|synchronized)[ \t]+)*[\w<>\[\],.? ]+[ \t]+(\w+)[ \t]*\([^;{}]*\)[^;{}]*\{"#)
        return [
            "swift": r(#"\bfunc[ \t]+(\w+)|\b(init)[ \t]*[?!]?[ \t]*\(|\b(deinit)\b"#),
            "javascript": r(#"\bfunction\*?[ \t]*(\w*)|(\w+)[ \t]*(?::[^=\n]+)?=[ \t]*(?:async[ \t]*)?(?:\([^()]*\)|\w+)[ \t]*(?::[^=\n]+)?=>|^[ \t]*(?:async[ \t]+)?(\w+)[ \t]*\([^()]*\)[ \t]*\{"#),
            "python": r(#"^[ \t]*(?:async[ \t]+)?def[ \t]+(\w+)"#),
            "go": r(#"^func[ \t]+(?:\([^)]*\)[ \t]*)?(\w+)"#),
            "rust": r(#"\bfn[ \t]+(\w+)"#),
            "kotlin": r(#"\bfun[ \t]+(?:<[^>]*>[ \t]*)?(?:\w+\.)?(\w+)"#),
            "scala": r(#"\bdef[ \t]+(\w+)"#),
            "ruby": r(#"^[ \t]*def[ \t]+([\w.?!]+)"#),
            "php": r(#"\bfunction[ \t]+(\w+)"#),
            "lua": r(#"\bfunction[ \t]*([\w.:]*)"#),
            "shell": r(#"^[ \t]*(?:function[ \t]+)?(\w+)[ \t]*\(\)[ \t]*\{"#),
            "java": javaLike, "csharp": javaLike, "dart": javaLike,
            "c": cFamily, "cpp": cFamily, "objectivec": cFamily, "objectivecpp": cFamily,
        ]
    }()

    /// Per-function cyclomatic complexity (1 + decision points in the body). Each
    /// decision point belongs to the innermost function whose body contains it;
    /// bodies are found by brace matching (indentation for Python and Ruby).
    /// Declarations without a body (interfaces, `.d.ts`) are not functions.
    static func functionComplexity(_ text: String, language: String)
        -> (count: Int, max: Int, maxName: String?, over10: Int, decisions: Int) {
        let family = language == "typescript" ? "javascript" : language
        let chars = Array(text.utf16)
        let range = NSRange(text.startIndex..., in: text)
        let decisions = decisionPoint.matches(in: text, range: range)

        guard let pattern = functionPatterns[family] else {
            let c = decisions.count + 1
            return (0, c, nil, c > 10 ? 1 : 0, decisions.count)
        }
        let keywords: Set<String> = ["if", "for", "while", "switch", "catch", "return", "else", "guard", "when", "do"]
        let indentBased = family == "python" || family == "ruby"

        var bodies: [(start: Int, end: Int, name: String)] = []
        for match in pattern.matches(in: text, range: range) {
            var name = ""
            for group in 1..<match.numberOfRanges {
                if let r = Range(match.range(at: group), in: text), !text[r].isEmpty { name = String(text[r]); break }
            }
            if keywords.contains(name) { continue }
            let start = match.range.location
            if indentBased {
                bodies.append((start, indentedBlockEnd(chars, from: start), name.isEmpty ? "anonymous" : name))
            } else if let end = braceBlockEnd(chars, from: start + match.range.length - 1) {
                bodies.append((start, end, name.isEmpty ? "anonymous" : name))
            }
        }
        guard !bodies.isEmpty else {
            // No functions: top-level code is one unit; enum `case` lines are not branches.
            let branches = decisions.filter { m in
                guard let r = Range(m.range, in: text) else { return true }
                return text[r] != "case"
            }.count
            let c = branches + 1
            return (0, c, nil, c > 10 ? 1 : 0, decisions.count)
        }
        var counts = Array(repeating: 1, count: bodies.count)
        for decision in decisions {
            let location = decision.range.location
            var best: Int?
            for (i, body) in bodies.enumerated() where body.start <= location && location < body.end {
                if best == nil || body.end - body.start < bodies[best!].end - bodies[best!].start { best = i }
            }
            if let best { counts[best] += 1 }
        }
        let maxIndex = counts.indices.max { counts[$0] < counts[$1] } ?? 0
        return (bodies.count, counts[maxIndex], bodies[maxIndex].name, counts.filter { $0 > 10 }.count, decisions.count)
    }

    /// End (UTF-16 offset) of the `{…}` block whose opening brace is the first one at
    /// or after `from` before a `;` — nil for declarations without a body.
    private static func braceBlockEnd(_ chars: [UInt16], from: Int) -> Int? {
        let open: UInt16 = 123, close: UInt16 = 125, semicolon: UInt16 = 59, newline: UInt16 = 10
        var i = max(0, from)
        var lines = 0
        while i < chars.count, chars[i] != open {
            if chars[i] == semicolon { return nil }
            if chars[i] == newline { lines += 1; if lines > 6 { return nil } }
            i += 1
        }
        guard i < chars.count else { return nil }
        var depth = 0
        var quote: UInt16 = 0
        while i < chars.count {
            let c = chars[i]
            if quote != 0 {
                if c == 92 { i += 2; continue }           // backslash escape
                if c == quote || c == newline { quote = 0 }
            } else if c == 34 || c == 39 || c == 96 {      // " ' `
                quote = c
            } else if c == 47, i + 1 < chars.count, chars[i + 1] == 47 {   // // comment
                while i < chars.count, chars[i] != newline { i += 1 }
                continue
            } else if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return chars.count
    }

    /// End of an indentation block (Python / Ruby) starting at the line of `from`.
    private static func indentedBlockEnd(_ chars: [UInt16], from: Int) -> Int {
        let newline: UInt16 = 10, space: UInt16 = 32, tab: UInt16 = 9
        var lineStart = from
        while lineStart > 0, chars[lineStart - 1] != newline { lineStart -= 1 }
        var indent = 0
        while lineStart + indent < chars.count, chars[lineStart + indent] == space || chars[lineStart + indent] == tab { indent += 1 }
        var i = from
        while i < chars.count, chars[i] != newline { i += 1 }
        while i < chars.count {
            let next = i + 1
            var j = next, width = 0
            while j < chars.count, chars[j] == space || chars[j] == tab { j += 1; width += 1 }
            let blank = j >= chars.count || chars[j] == newline
            if !blank && width <= indent { return next }
            i = j
            while i < chars.count, chars[i] != newline { i += 1 }
        }
        return chars.count
    }

    static func isTestPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").dropLast()
        if parts.contains(where: { ["test", "tests", "__tests__", "spec", "specs", "testing", "e2e", "uitests", "unittests"].contains(String($0)) }) {
            return true
        }
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let lowerName = name.lowercased()
        return lowerName.hasPrefix("test_") || stem.lowercased().hasSuffix("_test") || lowerName.contains(".test.")
            || lowerName.contains(".spec.") || stem.hasSuffix("Tests") || stem.hasSuffix("Test") || stem.hasSuffix("Spec")
    }

    /// The name a test file is about: `FooTests.swift`, `test_foo.py`, `foo.spec.ts` → "foo".
    private static func testedStem(_ path: String) -> String {
        var stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        for suffix in [".test", ".spec", "_test", "Tests", "Test", "Spec"] where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        if stem.lowercased().hasPrefix("test_") { stem = String(stem.dropFirst(5)) }
        return stem.lowercased()
    }

    private func computeMetrics(sources: [(path: String, language: String)], contents: [String: String],
                                modules: ArchView, git: GitHistory, lineCoverage: [String: Double]) -> [String: FileMetrics] {
        let tests = Set(sources.map(\.path).filter(Self.isTestPath))
        var testedBy: [String: Set<String>] = [:]
        // A test file that imports or references a file tests it…
        for edge in modules.edges where edge.source.hasPrefix("m:") && edge.target.hasPrefix("m:") {
            let from = String(edge.source.dropFirst(2)), to = String(edge.target.dropFirst(2))
            if tests.contains(from), !tests.contains(to) { testedBy[to, default: []].insert(from) }
        }
        // …and so does one named after it.
        var byStem: [String: [String]] = [:]
        for (path, _) in sources where !tests.contains(path) {
            byStem[(((path as NSString).lastPathComponent as NSString).deletingPathExtension).lowercased(), default: []].append(path)
        }
        for test in tests {
            for candidate in byStem[Self.testedStem(test)] ?? [] { testedBy[candidate, default: []].insert(test) }
        }

        // The regex work dominates the scan; files are independent, so use every core.
        typealias Complexity = (count: Int, max: Int, maxName: String?, over10: Int, decisions: Int)
        var complexity = [Complexity](repeating: (0, 0, nil, 0, 0), count: sources.count)
        let finished = ProgressCounter()
        complexity.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: sources.count) { i in
                results[i] = Self.functionComplexity(contents[sources[i].path] ?? "", language: sources[i].language)
                let done = finished.increment()
                if done % 50 == 0 { onProgress?("Measuring complexity", done, sources.count) }
            }
        }

        var metrics: [String: FileMetrics] = [:]
        for (index, (path, _)) in sources.enumerated() {
            let text = contents[path] ?? ""
            let perFunction = complexity[index]
            let decisions = perFunction.decisions
            let testers = testedBy[path] ?? []
            let coverage = lineCoverage[path]
            metrics["m:" + path] = FileMetrics(
                loc: text.isEmpty ? 0 : text.editorLines.count,
                complexity: decisions,
                commits: git.commits[path] ?? 0,
                bugfixes: git.bugfixes[path] ?? 0,
                isTest: tests.contains(path),
                tested: !testers.isEmpty || (coverage ?? 0) > 0,
                testFiles: testers.sorted(),
                lineCoverage: coverage,
                lastChanged: git.times[path] ?? modificationTime(path),
                functions: perFunction.count,
                maxFunctionComplexity: perFunction.max,
                maxFunctionName: perFunction.maxName,
                complexFunctions: perFunction.over10)
        }
        return metrics
    }

    private func modificationTime(_ path: String) -> Int {
        let date = try? root.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return Int(date?.timeIntervalSince1970 ?? 0)
    }

    /// Line coverage per source file from an lcov or Cobertura report, if the
    /// project has one in a usual place (reports are normally git-ignored).
    private func lineCoverageReport(sourcePaths: Set<String>) -> (coverage: [String: Double], name: String?) {
        let candidates = ["coverage/lcov.info", "lcov.info", "coverage/lcov/lcov.info", "build/coverage/lcov.info",
                          "coverage.xml", "coverage/cobertura-coverage.xml", "cobertura.xml", "coverage/coverage.xml"]
        func match(_ reported: String) -> String? {
            let clean = reported.hasPrefix(root.path + "/") ? String(reported.dropFirst(root.path.count + 1)) : reported
            if sourcePaths.contains(clean) { return clean }
            return sourcePaths.first { clean.hasSuffix("/" + $0) || $0.hasSuffix("/" + clean) }
        }
        for candidate in candidates {
            let text = read(candidate)
            guard !text.isEmpty else { continue }
            var result: [String: Double] = [:]
            if candidate.hasSuffix(".info") {
                var file: String?, found = 0, hit = 0
                for line in text.split(separator: "\n") {
                    if line.hasPrefix("SF:") { file = match(String(line.dropFirst(3))); found = 0; hit = 0 }
                    else if line.hasPrefix("LF:") { found = Int(line.dropFirst(3)) ?? 0 }
                    else if line.hasPrefix("LH:") { hit = Int(line.dropFirst(3)) ?? 0 }
                    else if line == "end_of_record", let f = file, found > 0 { result[f] = Double(hit) / Double(found) }
                }
            } else {
                let cls = try! NSRegularExpression(pattern: #"<class[^>]*filename="([^"]+)"[^>]*line-rate="([0-9.]+)""#)
                let range = NSRange(text.startIndex..., in: text)
                for m in cls.matches(in: text, range: range) {
                    guard let fr = Range(m.range(at: 1), in: text), let rr = Range(m.range(at: 2), in: text),
                          let file = match(String(text[fr])), let rate = Double(text[rr]) else { continue }
                    result[file] = rate
                }
            }
            if !result.isEmpty { return (result, candidate) }
        }
        return ([:], nil)
    }
}

// MARK: - Dependency changes in a diff

extension ArchitectureScanner {
    /// Links between project files that a change adds or removes: imports resolved from
    /// its added and removed lines. `lines` maps a changed file to its (added, removed) text.
    static func dependencyChanges(lines: [String: (added: String, removed: String)],
                                  projectFiles: [String]) -> [(source: String, target: String, added: Bool)] {
        let fileSet = Set(projectFiles)
        var byBasename: [String: [String]] = [:]
        for path in projectFiles { byBasename[(path as NSString).lastPathComponent, default: []].append(path) }
        let resolver = ImportResolver(fileSet: fileSet, byBasename: byBasename, goModules: [])
        var out: [(String, String, Bool)] = []
        for (path, text) in lines.sorted(by: { $0.key < $1.key }) {
            guard let language = FileType.codeLanguage(for: URL(fileURLWithPath: path)) else { continue }
            // A package import (Go, Python, Swift modules) names a folder: it counts as a link
            // to that folder's first file, so it can be drawn between files.
            func targets(_ source: String) -> Set<String> {
                Set(resolver.resolve(path: path, language: language, text: source).compactMap { target -> String? in
                    switch target {
                    case .file(let file): return file != path ? file : nil
                    case .directory(let dir):
                        let first = projectFiles.filter { ($0 as NSString).deletingLastPathComponent == dir }.min()
                        return first != path ? first : nil
                    case .package: return nil
                    }
                })
            }
            let added = targets(text.added), removed = targets(text.removed)
            for target in added.subtracting(removed).sorted() { out.append((path, target, true)) }
            for target in removed.subtracting(added).sorted() { out.append((path, target, false)) }
        }
        return out
    }
}

// MARK: - Import resolution

/// Resolves import statements to project files, folders or external packages.
private struct ImportResolver {
    enum Target { case file(String), directory(String), package(String) }

    let fileSet: Set<String>
    let byBasename: [String: [String]]
    let goModules: [(module: String, dir: String)]

    private static let jsImport = try! NSRegularExpression(
        pattern: #"(?:import|export)\s[^'"`;]*?from\s*['"]([^'"]+)['"]|import\s*['"]([^'"]+)['"]|(?:require|import)\(\s*['"]([^'"]+)['"]\s*\)"#)
    private static let pyFrom = try! NSRegularExpression(pattern: #"(?m)^\s*from\s+(\.*[\w.]*)\s+import\s"#)
    private static let pyImport = try! NSRegularExpression(pattern: #"(?m)^\s*import\s+([\w.]+(?:\s*,\s*[\w.]+)*)"#)
    private static let goImport = try! NSRegularExpression(pattern: #"(?m)^\s*(?:import\s+)?(?:[\w.]+\s+)?"([^"]+)"\s*$"#)
    private static let rustUse = try! NSRegularExpression(pattern: #"(?m)^\s*(?:pub\s+)?use\s+([\w:]+)"#)
    private static let rustMod = try! NSRegularExpression(pattern: #"(?m)^\s*(?:pub\s+)?mod\s+(\w+)\s*;"#)
    private static let cInclude = try! NSRegularExpression(pattern: #"(?m)^\s*#\s*(?:include|import)\s*"([^"]+)""#)
    private static let rubyRequire = try! NSRegularExpression(pattern: #"(?m)^\s*require(_relative)?\s+['"]([^'"]+)['"]"#)
    private static let swiftImport = try! NSRegularExpression(pattern: #"(?m)^\s*(?:@\w+\s+)*import\s+(?:class\s+|struct\s+|enum\s+|func\s+)?(\w+)"#)

    func resolve(path: String, language: String, text: String) -> [Target] {
        let dir = (path as NSString).deletingLastPathComponent
        switch language {
        case "javascript", "typescript", "html":
            return ArchitectureScanner.matches(Self.jsImport, in: text, group: 0).compactMap { statement in
                guard let spec = Self.firstQuoted(statement) else { return nil }
                if spec.hasPrefix(".") || spec.hasPrefix("/") {
                    return resolveJS(ArchitectureScanner.normalize(spec.hasPrefix("/") ? spec : dir + "/" + spec)).map(Target.file)
                }
                if spec.hasPrefix("@/") || spec.hasPrefix("~/") {
                    for base in ["src", "app", ""] {
                        let candidate = ArchitectureScanner.normalize(base + "/" + spec.dropFirst(2))
                        if let hit = resolveJS(candidate) { return .file(hit) }
                    }
                    return nil
                }
                let parts = spec.split(separator: "/")
                let name = spec.hasPrefix("@") && parts.count > 1 ? parts[0] + "/" + parts[1] : parts.first.map(String.init) ?? spec
                return .package(String(name))
            }
        case "python":
            var modules = ArchitectureScanner.matches(Self.pyFrom, in: text)
            for group in ArchitectureScanner.matches(Self.pyImport, in: text) {
                modules += group.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            return modules.compactMap { resolvePython($0, from: dir) }
        case "go":
            return ArchitectureScanner.matches(Self.goImport, in: text).compactMap { spec in
                for (module, moduleDir) in goModules where spec == module || spec.hasPrefix(module + "/") {
                    let rel = String(spec.dropFirst(module.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return .directory(ArchitectureScanner.normalize(moduleDir + "/" + rel))
                }
                return spec.contains(".") ? .package(spec.split(separator: "/").prefix(3).joined(separator: "/")) : nil
            }
        case "rust":
            var targets: [Target] = ArchitectureScanner.matches(Self.rustMod, in: text).compactMap { name in
                firstExisting([dir + "/" + name + ".rs", dir + "/" + name + "/mod.rs"]).map(Target.file)
            }
            for use in ArchitectureScanner.matches(Self.rustUse, in: text) {
                let parts = use.split(separator: ":").filter { !$0.isEmpty }.map(String.init)
                guard let head = parts.first else { continue }
                if head == "crate" || head == "super" || head == "self" {
                    let base = head == "crate" ? crateRoot(for: path) : dir
                    var segments = Array(parts.dropFirst())
                    while !segments.isEmpty {
                        let rel = base + "/" + segments.joined(separator: "/")
                        if let hit = firstExisting([rel + ".rs", rel + "/mod.rs"]) { targets.append(.file(hit)); break }
                        segments.removeLast()
                    }
                } else {
                    targets.append(.package(head))
                }
            }
            return targets
        case "c", "cpp", "objectivec", "objectivecpp":
            return ArchitectureScanner.matches(Self.cInclude, in: text).compactMap { spec in
                if let hit = firstExisting([ArchitectureScanner.normalize(dir + "/" + spec), spec]) { return .file(hit) }
                if let candidates = byBasename[(spec as NSString).lastPathComponent], candidates.count == 1 { return .file(candidates[0]) }
                return nil
            }
        case "ruby":
            let range = NSRange(text.startIndex..., in: text)
            return Self.rubyRequire.matches(in: text, range: range).compactMap { match in
                guard let specRange = Range(match.range(at: 2), in: text) else { return nil }
                let spec = String(text[specRange])
                let relative = match.range(at: 1).location != NSNotFound
                let candidate = ArchitectureScanner.normalize((relative ? dir + "/" : "") + spec)
                if let hit = firstExisting([candidate + ".rb", candidate, "lib/" + candidate + ".rb"]) { return .file(hit) }
                return relative ? nil : .package(spec.split(separator: "/").first.map(String.init) ?? spec)
            }
        case "swift":
            return ArchitectureScanner.matches(Self.swiftImport, in: text).map { .package($0) }
        default:
            return []
        }
    }

    private static func firstQuoted(_ statement: String) -> String? {
        guard let open = statement.firstIndex(where: { $0 == "'" || $0 == "\"" }) else { return nil }
        let rest = statement[statement.index(after: open)...]
        guard let close = rest.firstIndex(of: statement[open]) else { return nil }
        return String(rest[..<close])
    }

    private func firstExisting(_ candidates: [String]) -> String? {
        candidates.first { fileSet.contains(ArchitectureScanner.normalize($0)) }.map(ArchitectureScanner.normalize)
    }

    private func resolveJS(_ base: String) -> String? {
        if fileSet.contains(base) { return base }
        let extensions = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "vue", "svelte"]
        for ext in extensions where fileSet.contains(base + "." + ext) { return base + "." + ext }
        for ext in extensions where fileSet.contains(base + "/index." + ext) { return base + "/index." + ext }
        // `./foo.js` written in a TS project that compiles to JS.
        if base.hasSuffix(".js") {
            let stem = String(base.dropLast(3))
            for ext in ["ts", "tsx"] where fileSet.contains(stem + "." + ext) { return stem + "." + ext }
        }
        return nil
    }

    private func resolvePython(_ module: String, from dir: String) -> Target? {
        guard !module.isEmpty else { return nil }
        if module.hasPrefix(".") {
            var base = dir
            let dots = module.prefix(while: { $0 == "." }).count
            for _ in 1..<max(dots, 1) { base = (base as NSString).deletingLastPathComponent }
            let rest = module.dropFirst(dots).replacingOccurrences(of: ".", with: "/")
            let candidate = rest.isEmpty ? base : base + "/" + rest
            return firstExisting([candidate + ".py", candidate + "/__init__.py"]).map(Target.file)
        }
        let rel = module.replacingOccurrences(of: ".", with: "/")
        // Search every folder that could be a source root (the file's ancestors,
        // the project root and common `src` layouts).
        var roots = [""]
        var ancestor = dir
        while !ancestor.isEmpty { roots.append(ancestor); ancestor = (ancestor as NSString).deletingLastPathComponent }
        roots += ["src", "lib", "app"]
        for base in roots {
            let candidate = base.isEmpty ? rel : base + "/" + rel
            if let hit = firstExisting([candidate + ".py", candidate + "/__init__.py"]) { return .file(hit) }
        }
        return .package(module.split(separator: ".").first.map { String($0).lowercased() } ?? module)
    }

    private func crateRoot(for path: String) -> String {
        var dir = (path as NSString).deletingLastPathComponent
        while !dir.isEmpty {
            if (dir as NSString).lastPathComponent == "src" { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return "src"
    }
}

/// Thread-safe count of finished items for progress reports from concurrent work.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
