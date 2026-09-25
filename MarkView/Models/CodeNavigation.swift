import Foundation

/// Code navigation across the project without a language server: where a symbol is
/// defined and where it is used. One `git grep -w` pass finds every line with the
/// word (a directory walk when the folder is not a git work tree); declaration
/// patterns shared by the common languages tell definitions from usages.
enum CodeNavigator {
    struct Location: Codable, Hashable {
        var path: String
        var line: Int
        var column: Int
        /// The line's text, trimmed and clipped.
        var text: String
        /// definition | extension | usage
        var kind: String
    }

    struct Found {
        var definitions: [Location]
        var usages: [Location]
        /// More lines matched than were read.
        var truncated: Bool
    }

    private static let maxMatches = 4000

    /// Words that are never symbols worth navigating to.
    private static let keywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
        "func", "function", "def", "class", "struct", "enum", "protocol", "interface", "let", "var",
        "const", "val", "import", "from", "export", "public", "private", "fileprivate", "internal",
        "static", "self", "Self", "this", "super", "true", "false", "nil", "null", "None", "True",
        "False", "new", "try", "catch", "throw", "throws", "async", "await", "guard", "in", "is", "as",
        "and", "or", "not", "pass", "with", "yield", "lambda", "type", "extension", "override", "final",
        "void", "int", "string", "bool", "fn", "pub", "mut", "impl", "use", "mod", "package", "go",
    ]

    static func isNavigable(_ name: String) -> Bool {
        guard name.count >= 2, name.count <= 120, !keywords.contains(name),
              let first = name.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" || first == "$" else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }
    }

    /// Every line of the project that contains `name` as a word, split into definitions
    /// and usages. Runs git or reads files: call it off the main thread.
    static func find(_ name: String, root: URL) -> Found {
        guard isNavigable(name) else { return Found(definitions: [], usages: [], truncated: false) }
        var hits: [(path: String, line: Int, text: String)] = []
        var truncated = false
        if let output = gitGrep(name, root: root) {
            for row in output.split(separator: "\n", omittingEmptySubsequences: true) {
                // path\0line\0text  (-z separates the fields with NUL)
                let fields = row.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
                guard fields.count == 3, let line = Int(fields[1]) else { continue }
                if hits.count >= maxMatches { truncated = true; break }
                hits.append((String(fields[0]), line, String(fields[2])))
            }
        } else {
            (hits, truncated) = walk(name, root: root)
        }
        let common = definitionPattern(name, family: .common)
        let cStyle = definitionPattern(name, family: .cStyle)
        let cFunctions = definitionPattern(name, family: .c)
        let extensionPattern = extensionPattern(name)
        let word = wordPattern(name)
        var definitions: [Location] = []
        var usages: [Location] = []
        for hit in hits where hit.text.count <= 1000 {   // longer lines are minified code
            let text = hit.text
            let range = NSRange(text.startIndex..., in: text)
            let column = word.firstMatch(in: text, range: range).map { $0.range.location + 1 } ?? 1
            let clipped = String(text.trimmingCharacters(in: .whitespaces).prefix(200))
            let ext = (hit.path as NSString).pathExtension.lowercased()
            let isDefinition = common.firstMatch(in: text, range: range) != nil
                || (Self.cStyleExtensions.contains(ext) && cStyle.firstMatch(in: text, range: range) != nil)
                || (Self.cExtensions.contains(ext) && cFunctions.firstMatch(in: text, range: range) != nil)
            if isDefinition {
                definitions.append(Location(path: hit.path, line: hit.line, column: column, text: clipped, kind: "definition"))
            } else if extensionPattern.firstMatch(in: text, range: range) != nil {
                definitions.append(Location(path: hit.path, line: hit.line, column: column, text: clipped, kind: "extension"))
            } else {
                usages.append(Location(path: hit.path, line: hit.line, column: column, text: clipped, kind: "usage"))
            }
        }
        return Found(definitions: definitions, usages: usages, truncated: truncated)
    }

    /// Definitions first by kind (a declaration before an extension), then the file
    /// the user is in, the same language, and the nearest folder.
    static func rank(_ locations: [Location], from path: String) -> [Location] {
        let family = languageFamily(path)
        let folder = (path as NSString).deletingLastPathComponent
        func score(_ l: Location) -> (Int, Int, Int, Int, Int) {
            let sameFile = l.path == path ? 0 : 1
            let sameLanguage = languageFamily(l.path) == family ? 0 : 1
            let shared = commonPrefix(folder, (l.path as NSString).deletingLastPathComponent)
            // Test doubles declare the same names; the real definition comes first.
            let isTest = isTestPath(l.path) ? 1 : 0
            return (l.kind == "definition" ? 0 : 1, sameFile, isTest, sameLanguage, -shared)
        }
        return locations.sorted { a, b in
            let (x, y) = (score(a), score(b))
            return x != y ? x < y : (a.path, a.line) < (b.path, b.line)
        }
    }

    /// Usages grouped by file: the file the user is in first, then by path.
    static func sortUsages(_ locations: [Location], from path: String) -> [Location] {
        locations.sorted { a, b in
            if (a.path == path) != (b.path == path) { return a.path == path }
            return (a.path, a.line) < (b.path, b.line)
        }
    }

    /// Tests, specs, mocks and fixtures: they redeclare names as test doubles.
    static func isTestPath(_ path: String) -> Bool {
        path.lowercased().range(of: #"(^|[/._-])(tests?|spec|mocks?|__tests__|__mocks__|fixtures?)([/._-]|$)"#,
                                options: .regularExpression) != nil
    }

    /// JS and TS (and their JSX forms) count as one language; so do C and C++ headers.
    private static func languageFamily(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": return "js"
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm": return "c"
        case "kt", "kts": return "kotlin"
        case let ext: return ext
        }
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a.split(separator: "/"), b.split(separator: "/")).prefix { $0 == $1 }.count
    }

    // MARK: - Patterns

    private static func escaped(_ name: String) -> String { NSRegularExpression.escapedPattern(for: name) }

    private static func wordPattern(_ name: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?<![\w$])"# + escaped(name) + #"(?![\w$])"#)
    }

    /// Languages whose methods are declared as `name(args) {` (no keyword).
    private static let cStyleExtensions: Set<String> = [
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "java", "kt", "kts", "cs", "dart", "php", "scala", "groovy",
        "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm",
    ]
    /// Languages whose functions are declared as `type name(args)`.
    private static let cExtensions: Set<String> = ["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm"]

    private enum Family { case common, cStyle, c }

    /// A line that declares `name`: a type, function, method, constant or variable in the
    /// common languages (Swift, TS/JS, Python, Go, Rust, Kotlin, Java, C#, Ruby, PHP, C/C++).
    /// `cStyle` and `c` patterns hold only for those languages (elsewhere they match calls).
    private static func definitionPattern(_ name: String, family: Family) -> NSRegularExpression {
        let n = escaped(name)
        let end = #"(?![\w$])"#
        let notStatement = #"(?!\s*(?:return|await|try|throw|yield|new|else|case|delete|typeof|echo|print)\b)"#
        switch family {
        case .cStyle:
            // Methods: name(args) {  with optional modifiers and return type
            return try! NSRegularExpression(pattern: #"^"# + notStatement + #"\s*(?:(?:public|private|protected|internal|static|async|override|readonly|abstract|final|virtual|get|set|export|default|suspend|open)\s+)*(?:[\w<>\[\],.?]+\s+)?"# + n + #"\s*(?:<[^>]*>)?\s*\([^;]*\)\s*(?::\s*[^={;]+)?\s*(?:throws\s+[\w.,\s]+)?\{"#)
        case .c:
            // Functions: type name(args) {  (at least one type word before the name)
            return try! NSRegularExpression(pattern: #"^"# + notStatement + #"\s*[A-Za-z_][\w:<>,]*(?:[\s\*&]+[A-Za-z_][\w:<>,]*)*[\s\*&]+"# + n + #"\s*\([^;]*\)\s*(?:const\s*)?\{?\s*$"#)
        case .common:
            break
        }
        let patterns = [
            // Keyword declarations: func name, class name, def name, type name…
            #"(?:^|[^\w.$])(?:func|function\*?|def|class|struct|enum|protocol|interface|trait|type|typealias|actor|fn|fun|object|record|module|mod|namespace|macro|associatedtype|union)\s+"# + n + end,
            // Go methods: func (r *Recv) name(
            #"^\s*func\s*\([^)]*\)\s*"# + n + #"\s*[\[(]"#,
            // Variables and constants at declaration: let/var/const/val name
            #"(?:^|[^\w.$])(?:let|var|const|val|static\s+let|static\s+var)\s+(?:mut\s+)?"# + n + end,
            // Swift enum cases: case name
            #"^\s*(?:indirect\s+)?case\s+(?:[\w$]+\s*(?:\([^)]*\))?\s*,\s*)*"# + n + #"(?![\w$])(?!\s*[:.])"#,
            // Object / class property functions: name = (…) =>, name: function
            n + #"\s*[:=]\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*(?::\s*[^=]+)?=>|[\w$]+\s*=>)"#,
            // Python and Ruby module level assignment: name = …
            #"^"# + n + #"\s*(?::\s*[\w\[\], .]+)?\s*=[^=]"#,
            // PHP/Ruby methods
            #"^\s*(?:(?:public|private|protected|static|abstract|final)\s+)*function\s+&?"# + n + end,
        ]
        return try! NSRegularExpression(pattern: patterns.map { "(?:" + $0 + ")" }.joined(separator: "|"))
    }

    /// Extends a type declared elsewhere: `extension Name`, `impl Name`, `impl Trait for Name`.
    private static func extensionPattern(_ name: String) -> NSRegularExpression {
        let n = escaped(name)
        return try! NSRegularExpression(pattern: #"(?:^|[^\w.])(?:extension|impl(?:<[^>]*>)?(?:\s+[\w:<>]+\s+for)?)\s+"# + n + #"(?![\w$])"#)
    }

    // MARK: - Search

    private static func gitGrep(_ name: String, root: URL) -> String? {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
                || ArchitectureScanner.runTool("/usr/bin/env", ["git", "-C", root.path, "rev-parse", "--is-inside-work-tree"]) != nil else {
            return nil
        }
        // -I skips binaries; --untracked includes new files; exclude bundled and generated code.
        let excludes = ["node_modules", "build", "dist", "DerivedData", ".build", "Pods", ".next", "coverage",
                        ".dde", ".markview-insight"]
            .map { ":(exclude,glob)**/\($0)/**" } + [":(exclude,glob)**/*.min.js", ":(exclude,glob)**/*.map"]
        let arguments = ["git", "-C", root.path, "grep", "-n", "-I", "-w", "-F", "-z", "--untracked",
                         "--max-count", "400", "-e", name, "--", "."] + excludes
        // No match exits with status 1: an empty result, not a failure.
        return ArchitectureScanner.runTool("/usr/bin/env", arguments) ?? ""
    }

    private static func walk(_ name: String, root: URL) -> ([(path: String, line: Int, text: String)], Bool) {
        let word = wordPattern(name)
        var hits: [(path: String, line: Int, text: String)] = []
        for path in ArchitectureScanner.listFiles(root: root) {
            let url = root.appendingPathComponent(path)
            guard FileType.codeLanguage(for: url) != nil || url.pathExtension.lowercased() == "md",
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size < 1_000_000,
                  let text = try? String(contentsOf: url, encoding: .utf8), text.contains(name) else { continue }
            for (index, line) in text.editorLines.enumerated() where line.contains(name) {
                let string = String(line)
                guard word.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil else { continue }
                if hits.count >= maxMatches { return (hits, true) }
                hits.append((path, index + 1, string))
            }
        }
        return (hits, false)
    }
}

/// Navigation state of the code viewer: back/forward history of jumps and the AI
/// answers about selected code. Results reach the viewer through `.codeNavEvent`.
@MainActor
final class CodeNavigationStore {
    struct Place: Equatable { var url: URL; var line: Int }

    private(set) var back: [Place] = []
    private(set) var forward: [Place] = []
    private var answers: [String: Task<Void, Never>] = [:]

    // MARK: - Symbols

    /// ⌘-click / F12: the definition of `name`; several → a list to choose from. On a
    /// declaration itself, its usages (as in other editors).
    func goToDefinition(name: String, line: Int, url: URL, path: String, root: URL, open: @escaping (URL, Int) -> Void) {
        Task {
            let found = await Task.detached(priority: .userInitiated) { CodeNavigator.find(name, root: root) }.value
            let ranked = CodeNavigator.rank(found.definitions, from: path)
            let onDeclaration = ranked.contains { $0.path == path && $0.line == line && $0.kind == "definition" }
            if onDeclaration || ranked.isEmpty {
                let usages = CodeNavigator.sortUsages(found.usages, from: path)
                send(url: url, [
                    "type": "usages", "name": name, "results": encode(usages), "truncated": found.truncated,
                    "note": ranked.isEmpty ? "No definition found in the project — usages:" : "",
                ])
                return
            }
            // One real declaration (test doubles aside): go straight there.
            let declarations = ranked.filter { $0.kind == "definition" }
            let real = declarations.filter { !CodeNavigator.isTestPath($0.path) || CodeNavigator.isTestPath(path) }
            if let only = declarations.count == 1 ? declarations.first : real.count == 1 ? real.first : nil {
                jump(from: Place(url: url, line: line), to: root.appendingPathComponent(only.path), line: only.line, open: open)
                return
            }
            send(url: url, ["type": "definitions", "name": name, "results": encode(ranked), "truncated": found.truncated])
        }
    }

    /// ⌥⌘-click / ⇧F12: every usage of `name`, definitions listed first.
    func findUsages(name: String, url: URL, path: String, root: URL) {
        Task {
            let found = await Task.detached(priority: .userInitiated) { CodeNavigator.find(name, root: root) }.value
            let results = CodeNavigator.rank(found.definitions, from: path) + CodeNavigator.sortUsages(found.usages, from: path)
            send(url: url, ["type": "usages", "name": name, "results": encode(results), "truncated": found.truncated, "note": ""])
        }
    }

    /// Open a result from the viewer's list, remembering where the user was.
    func jump(from: Place, to target: URL, line: Int, open: (URL, Int) -> Void) {
        back.append(from)
        if back.count > 100 { back.removeFirst(back.count - 100) }
        forward.removeAll()
        open(target, line)
        sendState(url: target)
    }

    func goBack(current: Place, open: (URL, Int) -> Void) {
        guard let place = back.popLast() else { return }
        forward.append(current)
        open(place.url, place.line)
        sendState(url: place.url)
    }

    func goForward(current: Place, open: (URL, Int) -> Void) {
        guard let place = forward.popLast() else { return }
        back.append(current)
        open(place.url, place.line)
        sendState(url: place.url)
    }

    /// Whether the viewer's ◀ ▶ buttons are enabled (sent whenever a file opens).
    func sendState(url: URL) {
        send(url: url, ["type": "state", "back": !back.isEmpty, "forward": !forward.isEmpty])
    }

    func reset() {
        back.removeAll()
        forward.removeAll()
        answers.values.forEach { $0.cancel() }
        answers.removeAll()
    }

    // MARK: - AI on a selection

    /// Ask the AI about lines `start`…`end` of `path`. `history` holds the earlier
    /// questions and answers of the same conversation. The answer streams to the viewer.
    func ask(id: String, question: String, snippet: String, start: Int, end: Int, path: String, language: String?,
             history: [[String: String]], url: URL, root: URL, db: SemanticDatabase?) {
        answers[id]?.cancel()
        let conversation = history.suffix(6).map { turn in
            "Q: \(turn["q"] ?? "")\nA: \(turn["a"] ?? "")"
        }.joined(separator: "\n\n")
        var request = CLICompletion.Request(
            prompt: """
            File: \(path), lines \(start)-\(end)\(language.map { " (\($0))" } ?? "")
            ```
            \(String(snippet.prefix(40_000)))
            ```
            \(conversation.isEmpty ? "" : "\nEarlier in this conversation:\n\(conversation)\n")
            Question: \(question)
            """,
            systemPrompt: """
            You help an engineer understand a piece of code they selected in their project. The project \
            is the working directory: read other files (Read, Grep, Glob) when the answer depends on how \
            the selected code is called or what it calls, but never modify anything. Answer the question \
            directly and concretely, referring to names and lines of the selection (`path:line` for other \
            files). Use short Markdown: a few paragraphs or bullets and small code blocks only when they help. \
            If you point out a bug or a risk, say how it would show up and how to fix it.
            """ + "\n\n" + ActionOutputLanguage.explanationLine(),
            readableFolder: root)
        request.timeout = 600
        send(url: url, ["type": "answer", "id": id, "text": "", "done": false, "activity": "Thinking…"])
        answers[id] = Task { [weak self] in
            let buffer = AnswerBuffer()
            do {
                let result = try await CLICompletion.run(request, onDelta: { delta in
                    Task { @MainActor in
                        guard let self, !Task.isCancelled else { return }
                        if buffer.append(delta) { self.send(url: url, ["type": "answer", "id": id, "text": buffer.text, "done": false]) }
                    }
                }, onActivity: { activity in
                    let label: String?
                    switch activity {
                    case .read(let file): label = "Reading " + (file.hasPrefix(root.path + "/") ? String(file.dropFirst(root.path.count + 1)) : file)
                    case .search(let pattern): label = "Searching “\(pattern.prefix(50))”"
                    case .run(let command): label = "Running " + String(command.prefix(50))
                    default: label = nil
                    }
                    guard let label else { return }
                    Task { @MainActor in
                        self?.send(url: url, ["type": "answer", "id": id, "text": buffer.text, "done": false, "activity": label])
                    }
                })
                result.record(in: db)
                guard !Task.isCancelled else { return }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.send(url: url, ["type": "answer", "id": id, "text": text.isEmpty ? buffer.text : text, "done": true])
            } catch is CancellationError {
                self?.send(url: url, ["type": "answer", "id": id, "text": buffer.text, "done": true, "stopped": true])
            } catch {
                self?.send(url: url, ["type": "answer", "id": id, "text": buffer.text, "done": true,
                                      "error": error.localizedDescription])
            }
            self?.answers[id] = nil
        }
    }

    func stopAnswer(id: String) {
        answers[id]?.cancel()
    }

    // MARK: - To the viewer

    private func encode(_ locations: [CodeNavigator.Location]) -> [[String: Any]] {
        locations.prefix(600).map {
            ["path": $0.path, "line": $0.line, "column": $0.column, "text": $0.text, "kind": $0.kind]
        }
    }

    private func send(url: URL, _ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        NotificationCenter.default.post(name: .codeNavEvent, object: nil,
                                        userInfo: ["url": url.standardizedFileURL, "json": json])
    }
}

/// Streamed answer text, forwarded at most every 150 ms.
private final class AnswerBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    private var lastSent = Date.distantPast

    var text: String { lock.lock(); defer { lock.unlock() }; return value }

    /// Append `delta`; true when enough time passed to send the text again.
    func append(_ delta: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        value += delta
        guard Date().timeIntervalSince(lastSent) > 0.15 else { return false }
        lastSent = Date()
        return true
    }
}

extension Notification.Name {
    /// A code navigation result or AI answer for the code viewer (userInfo: url, json).
    static let codeNavEvent = Notification.Name("MarkView.codeNavEvent")
}
