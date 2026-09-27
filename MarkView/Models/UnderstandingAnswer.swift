import Foundation

/// The transient, cited answer to an I Need to Understand question. Topic filters keep
/// their existing contract; this contract requires meaning and provenance as well as places.
struct UnderstandingAnswer: Codable {
    struct Section: Codable {
        var text: String
        var sources: [String]
    }
    struct Source: Codable {
        enum Kind: String, Codable { case code, document, component, deployment, commit, pr }
        var id: String
        var kind: Kind
        var label: String
        var path: String
        var start: Int
        var end: Int
        /// Component/deployment id, commit hash or PR number.
        var target: String
        var url: String

        var markdownLink: String? {
            if kind == .code || kind == .document {
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                return "../../\(encoded)#L\(start)-L\(end)"
            }
            if !url.isEmpty { return url }
            return nil
        }
    }
    var what: Section
    var why: Section
    var how: Section
    var origin: Section
    var originFound: Bool
    var sources: [Source]

    static let schema: [String: Any] = {
        let section: [String: Any] = ["type": "object", "properties": [
            "text": ["type": "string"], "sources": ["type": "array", "items": ["type": "string"]]
        ], "required": ["text", "sources"]]
        let source: [String: Any] = ["type": "object", "properties": [
            "id": ["type": "string"], "kind": ["type": "string", "enum": ["code", "document", "component", "deployment", "commit", "pr"]],
            "label": ["type": "string"], "path": ["type": "string"], "start": ["type": "integer"], "end": ["type": "integer"],
            "target": ["type": "string"], "url": ["type": "string"]
        ], "required": ["id", "kind", "label", "path", "start", "end", "target", "url"]]
        return ["type": "object", "properties": ["what": section, "why": section, "how": section, "origin": section,
            "originFound": ["type": "boolean"], "sources": ["type": "array", "items": source]],
            "required": ["what", "why", "how", "origin", "originFound", "sources"]]
    }()

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let reason) = self { return reason }
            return nil
        }
    }

    /// Reject incomplete/location-only answers and unreachable evidence rather than
    /// presenting them as a successful answer. File reads run off the main actor.
    static func parse(_ value: Any?, root: URL, components: Set<String>, deployment: Set<String>,
                      commits: Set<String>, pullRequests: Set<String>) throws -> Self {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              var answer = try? JSONDecoder().decode(Self.self, from: data) else {
            throw Failure.invalid("The AI returned an empty or incomplete explanatory answer.")
        }
        var ids = Set<String>()
        for i in answer.sources.indices {
            var source = answer.sources[i]
            guard !source.id.isEmpty, source.id.count <= 32, source.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
                  !source.label.isEmpty, ids.insert(source.id).inserted else {
                throw Failure.invalid("The AI returned missing or duplicate evidence identifiers.")
            }
            switch source.kind {
            case .code, .document:
                guard let path = relativePath(source.path, root: root),
                      let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
                    throw Failure.invalid("The cited file could not be read: \(source.path)")
                }
                source.path = path
                let count = max(1, text.components(separatedBy: "\n").count)
                source.start = min(max(1, source.start), count)
                source.end = min(max(source.start, source.end), count)
                source.url = ""
            case .component:
                guard components.contains(source.target) else { throw Failure.invalid("The cited component is absent from X-Ray: \(source.label)") }
                source.url = ""
            case .deployment:
                guard deployment.contains(source.target) else { throw Failure.invalid("The cited deployment node is absent from X-Ray: \(source.label)") }
                source.url = ""
            case .commit:
                guard commits.contains(source.target) else { throw Failure.invalid("The cited commit was not found in the supplied history: \(source.label)") }
                // A commit without a remote opens locally through git show.
                if !source.url.isEmpty && !isGitHubURL(source.url, kind: .commit, target: source.target) {
                    throw Failure.invalid("The cited commit link is invalid.")
                }
            case .pr:
                guard pullRequests.contains(source.url), isGitHubURL(source.url, kind: .pr, target: source.target) else {
                    throw Failure.invalid("The cited pull request was not found in the supplied history.")
                }
            }
            answer.sources[i] = source
        }
        for section in [answer.what, answer.why, answer.how, answer.origin] {
            guard !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.invalid("The AI omitted a What, Why, How or Origin section.")
            }
            guard section.sources.allSatisfy(ids.contains) else { throw Failure.invalid("The answer cites evidence that was not provided.") }
        }
        if answer.originFound {
            guard answer.sources.contains(where: { answer.origin.sources.contains($0.id) && [.document, .commit, .pr].contains($0.kind) }) else {
                throw Failure.invalid("The AI claimed an origin without citing a document, commit or pull request.")
            }
        }
        return answer
    }

    static func relativePath(_ path: String, root: URL) -> String? {
        let base = root.standardizedFileURL
        let file = base.appendingPathComponent(path).standardizedFileURL
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              file.path.hasPrefix(base.path + "/"),
              file.resolvingSymlinksInPath().path.hasPrefix(base.resolvingSymlinksInPath().path + "/") else { return nil }
        return String(file.path.dropFirst(base.path.count + 1))
    }

    static func isGitHubURL(_ text: String, kind: Source.Kind, target: String) -> Bool {
        guard let url = URL(string: text), url.scheme == "https", url.host == "github.com", url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        return parts.count == 4 && parts[2] == (kind == .pr ? "pull" : "commit") && parts[3] == target
    }

    func markdown(question: String) -> String {
        var body = "# \(String(question.prefix(90)).replacingOccurrences(of: "\n", with: " "))\n\n## Question\n\n\(question)\n"
        for (title, section) in [("What", what), ("Why", why), ("How", how), ("Origin", origin)] {
            body += "\n## \(title)\n\n\(section.text)\n"
            if title == "Origin", !originFound { body += "\nNo origin source found.\n" }
            if !section.sources.isEmpty {
                body += "\nSources: " + section.sources.map { id in
                    sources.first { $0.id == id }?.markdownLink.map { "[\(id)](<\($0)>)" } ?? "[\(id)]"
                }.joined(separator: ", ") + "\n"
            }
        }
        body += "\n## Sources\n"
        for source in sources {
            let label = source.label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            body += "\n### Source \(source.id)\n\n"
            body += source.markdownLink.map { "[\(label)](<\($0)>)" } ?? "**\(label)**"
            body += " — \(source.kind.rawValue)"
            if source.kind == .component || source.kind == .deployment || source.kind == .commit { body += " (`\(source.target)`)" }
            body += "\n"
        }
        return body
    }

    /// Reserve the numeric id exclusively, so concurrent saves/windows cannot share an
    /// id or overwrite another research file. An unsuccessful save leaves no placeholder.
    func save(question: String, root: URL, author: String, date: String, attachments: [URL] = []) throws -> URL {
        let folder = root.appendingPathComponent("docs/research", isDirectory: true)
        guard folder.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw Failure.invalid("The research folder is outside this workspace.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var number = (names.compactMap { name -> Int? in
            guard name.hasPrefix("RES-") else { return nil }
            return Int(name.dropFirst(4).prefix { $0.isNumber })
        }.max() ?? 0) + 1
        while true {
            let id = String(format: "RES-%03d", number)
            let reservation = folder.appendingPathComponent(id + ".reserve")
            do { try Data().write(to: reservation, options: .withoutOverwriting) }
            catch let error as NSError where error.code == NSFileWriteFileExistsError { number += 1; continue }
            defer { try? FileManager.default.removeItem(at: reservation) }
            let title = String(question.prefix(90)).replacingOccurrences(of: "\n", with: " ")
            let slug = String(title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).split(separator: "-").joined(separator: "-")
            let file = folder.appendingPathComponent("\(id)-\(slug.prefix(50)).md")
            // Another writer may have occupied this id after our initial directory read.
            let occupied = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .contains { $0 != reservation.lastPathComponent && ($0 == id + ".md" || $0.hasPrefix(id + "-")) }
            if occupied { number += 1; continue }
            var front = FrontMatter()
            front.set("type", "research"); front.set("id", id); front.set("title", title)
            front.set("question", question); front.set("created", date); front.set("author", author)
            front.set("provenance", "I Need to Understand — X-Ray")
            var body = markdown(question: question)
            let assets = folder.appendingPathComponent("assets/" + id + "-" + UUID().uuidString)
            do {
                if !attachments.isEmpty {
                    let copied = try UnderstandingAttachments.copy(attachments, to: assets, root: root)
                    body += "\n## Question attachments\n\n"
                    for path in copied {
                        let relative = String(path.dropFirst("docs/research/".count))
                        let image = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "heic"].contains((path as NSString).pathExtension.lowercased())
                        body += "\(image ? "!" : "")[\((path as NSString).lastPathComponent)](<\(relative)>)\n\n"
                    }
                }
                try Data(front.join(body: body).utf8).write(to: file, options: .withoutOverwriting)
            } catch {
                if !attachments.isEmpty { try? FileManager.default.removeItem(at: assets) }
                throw error
            }
            return file
        }
    }
}

enum UnderstandingAttachments {
    static func copy(_ files: [URL], to folder: URL, root: URL) throws -> [String] {
        guard folder.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw UnderstandingAnswer.Failure.invalid("The attachment folder is outside this workspace.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            return try files.enumerated().map { index, source in
                let target = folder.appendingPathComponent("\(index + 1)-" + source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: target)
                return String(target.path.dropFirst(root.standardizedFileURL.path.count + 1))
            }
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
