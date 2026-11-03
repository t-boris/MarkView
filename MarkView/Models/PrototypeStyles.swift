import Foundation

/// The app's own stylesheets for a code-mode prototype, copied unchanged (BUG-050).
///
/// Writing a design system from scratch gave a StrikeDesk prototype 8 KB of generic CSS against the original's
/// 43 files and 385 KB. The planner names the stylesheets the interface loads; this copies them, with the fonts
/// and images their `url()` and `@import` rules name, into `site/original/` under the same folder layout, so
/// every relative reference keeps working and the screens can use the original class names. No assistant is
/// involved: what is copied is exactly what the project holds. Pure file-system work; the caller keeps it off
/// the main thread.
enum PrototypeStyles {
    /// One stylesheet, one font or one image past these sizes is left out and reported as a gap.
    static let maxStyleBytes = 1_500_000
    static let maxAssetBytes = 3_000_000
    /// Everything copied for one prototype, and the number of files.
    static let maxTotalBytes = 8_000_000
    static let maxFiles = 250
    /// `@import` chains deeper than this are cut.
    static let maxImportDepth = 6
    /// Fonts and images a stylesheet may pull in; anything else (scripts, archives) is never copied.
    static let assetExtensions: Set<String> = ["woff2", "woff", "ttf", "otf", "eot", "png", "jpg", "jpeg", "gif", "webp", "avif",
                                               "svg", "ico"]

    struct Copied: Equatable, Sendable {
        /// Paths under `site/original/` of every stylesheet copied, in the order they were copied (each listed one, then what it imports).
        var stylesheets: [String] = []
        /// Paths under `site/original/` of the fonts and images copied.
        var assets: [String] = []
        /// What `index.html` links, relative to `site/`, in order: the listed stylesheets that were copied, each preceded by
        /// the package stylesheets it imports.
        var links: [String] = []
        /// What could not be copied or resolved, one sentence each, for the manifest.
        var gaps: [String] = []

        var isEmpty: Bool { stylesheets.isEmpty }
        var totalFiles: Int { stylesheets.count + assets.count }
    }

    /// The local targets of the `url(...)` and `@import` rules of `css`, as written, query and fragment removed, in order
    /// of appearance and without repeats. `data:` URLs, fragments and variables are not targets.
    static func references(in css: String) -> [String] {
        var found: [String] = []
        func add(_ raw: String) {
            var target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cut = target.firstIndex(where: { $0 == "?" || $0 == "#" }) { target = String(target[..<cut]) }
            let lower = target.lowercased()
            guard !target.isEmpty, !lower.hasPrefix("data:"), !lower.hasPrefix("var("), !lower.hasPrefix("about:"),
                  !found.contains(target) else { return }
            found.append(target)
        }
        let range = { NSRange(css.startIndex..., in: css) }
        let patterns = ["url\\(\\s*(?:\"([^\"]*)\"|'([^']*)'|([^)\"'\\s]*))\\s*\\)", "@import\\s+(?:\"([^\"]*)\"|'([^']*)')"]
        var hits: [(Int, String)] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: css, range: range()) {
                for group in 1..<match.numberOfRanges {
                    if let r = Range(match.range(at: group), in: css), !css[r].isEmpty { hits.append((match.range.location, String(css[r]))) }
                }
            }
        }
        for (_, target) in hits.sorted(by: { $0.0 < $1.0 }) { add(target) }
        return found
    }

    /// Whether a reference leaves the project: a network address or a protocol-relative one.
    static func isExternal(_ reference: String) -> Bool {
        let lower = reference.lowercased()
        return lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//")
    }

    /// One `<link rel="stylesheet">` line per href, spaces and other path characters percent-encoded; empty for no hrefs.
    static func linkTags(_ hrefs: [String]) -> String {
        hrefs.map { href -> String in
            let encoded = href.split(separator: "/", omittingEmptySubsequences: false)
                .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            return "<link rel=\"stylesheet\" href=\"\(encoded)\">\n"
        }.joined()
    }

    /// `<link>` lines for `hrefs`, put before the prototype's own `styles.css` link so the foundation can override them, or
    /// before `</head>` when there is none. Nil when the page has neither place; unchanged when there is nothing to link.
    static func insertLinks(into html: String, hrefs: [String]) -> String? {
        guard !hrefs.isEmpty else { return html }
        let tags = linkTags(hrefs)
        if let regex = try? NSRegularExpression(pattern: "<link\\b[^>]*href\\s*=\\s*[\"']styles\\.css[\"'][^>]*>", options: [.caseInsensitive]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)), let r = Range(match.range, in: html) {
            return html.replacingCharacters(in: r.lowerBound..<r.lowerBound, with: tags)
        }
        if let r = html.range(of: "</head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: r.lowerBound..<r.lowerBound, with: tags)
        }
        return nil
    }

    /// A file to copy: where it is, and where it goes under `site/original/`.
    private struct Source {
        var url: URL
        /// The destination relative to `site/original/`. The project-relative path for the project's own files; for a
        /// stylesheet of an installed package, `node_modules/<specifier>`, so a pnpm store path is never reproduced.
        var destination: String
        /// True for a package stylesheet: references inside it are placed relative to its destination.
        var virtual = false
    }

    /// `a/b/../c` as `a/c`; nil when the path climbs out of its root.
    private static func normalised(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() } else { parts.append(part) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// Copies the listed stylesheets of the project at `root` to `site/original/`, and everything they import or load: the
    /// stylesheets, fonts and images named by relative paths, and the stylesheets a bare `@import 'package/file.css'` names,
    /// found the way a bundler finds them (`node_modules` of the stylesheet's folder or any folder above it, inside the
    /// project). A package stylesheet is linked before the listed one that imports it, because the `@import` in the copy
    /// cannot reach it. A path that is not a plain `.css` file inside the project, a file past the limits and a reference
    /// that cannot be found are reported in `gaps`; nothing here throws, so a bad entry costs only that entry.
    static func copy(styles: [String], root: URL, site: URL, fileManager fm: FileManager = .default) -> Copied {
        var result = Copied()
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let basePrefix = base.path + "/"
        let storage = PrototypeFiles.storage(root: base).path + "/"
        let target = site.appendingPathComponent(PrototypeFiles.originalFolder, isDirectory: true)
        var copied = Set<String>()
        var total = 0
        var limitReported = false
        /// Package stylesheets met while following the current listed stylesheet, dependencies first.
        var packageLinks: [String] = []

        func gap(_ text: String) { if !result.gaps.contains(text) { result.gaps.append(text) } }

        /// A project path is usable when it is inside the project, not the prototypes themselves and not hidden. What
        /// follows a `node_modules` folder is the package manager's own layout (pnpm keeps packages in `.pnpm`).
        func usable(_ url: URL) -> String? {
            guard url.path.hasPrefix(basePrefix), !url.path.hasPrefix(storage) else { return nil }
            let projectRelative = String(url.path.dropFirst(basePrefix.count))
            var parts = projectRelative.split(separator: "/")
            if let installed = parts.firstIndex(of: "node_modules") { parts = Array(parts[..<installed]) }
            guard !parts.contains(where: { $0.hasPrefix(".") }) else { return nil }
            return projectRelative
        }

        /// A project file named by a path relative to `folder`.
        func resolve(_ reference: String, from folder: URL) -> Source? {
            let url = folder.appendingPathComponent(reference).standardizedFileURL.resolvingSymlinksInPath()
            guard let relative = usable(url) else { return nil }
            return Source(url: url, destination: relative)
        }

        /// A stylesheet named by a package specifier, found in the `node_modules` of `folder` or of a folder above it.
        func resolvePackage(_ specifier: String, from folder: URL) -> Source? {
            var name = specifier
            if name.hasPrefix("~") { name.removeFirst() }
            guard name.lowercased().hasSuffix(".css"), let clean = normalised(name), clean == name,
                  !name.hasPrefix("."), !name.contains(":") else { return nil }
            var directory = folder.standardizedFileURL.resolvingSymlinksInPath()
            while directory.path == base.path || directory.path.hasPrefix(basePrefix) {
                let candidate = directory.appendingPathComponent("node_modules/" + name).standardizedFileURL.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                if usable(candidate) != nil, fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    return Source(url: candidate, destination: "node_modules/" + name, virtual: true)
                }
                if directory.path == base.path { break }
                directory = directory.deletingLastPathComponent()
            }
            return nil
        }

        /// Copies one file; false (with a gap) when a limit stops it. A file already copied counts as done.
        func place(_ file: Source, limit: Int) -> Bool {
            if copied.contains(file.destination) { return true }
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= limit else { gap("\(file.destination) is \(size / 1024) KB, over the \(limit / 1024) KB limit; not copied."); return false }
            guard total + size <= maxTotalBytes, copied.count < maxFiles else {
                if !limitReported { gap("The copy of the original styles stopped at its size limit; later files, starting with \(file.destination), are missing."); limitReported = true }
                return false
            }
            let destination = target.appendingPathComponent(file.destination)
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: file.url, to: destination)
            } catch {
                gap("\(file.destination) could not be copied: \(error.localizedDescription)")
                return false
            }
            copied.insert(file.destination)
            total += size
            return true
        }

        func follow(_ css: Source, depth: Int) {
            guard let text = try? String(contentsOf: css.url, encoding: .utf8) else { return }
            let folder = css.url.deletingLastPathComponent()
            var missing: [String] = []
            var external = 0
            for reference in references(in: text) {
                if isExternal(reference) { external += 1; continue }
                if reference.hasPrefix("/") { missing.append(reference); continue }
                // A name written with %20 is found by what it decodes to.
                let name = reference.removingPercentEncoding ?? reference
                var found: Source?
                var viaPackage = false
                if let local = resolve(name, from: folder), fm.fileExists(atPath: local.url.path) {
                    found = local
                    if css.virtual {
                        // Inside a package the copy keeps the package's own layout, whatever the store path is.
                        let joined = (css.destination as NSString).deletingLastPathComponent + "/" + name
                        guard let place = normalised(joined), place.hasPrefix("node_modules/") else { missing.append(reference); continue }
                        found?.destination = place
                        found?.virtual = true
                    }
                } else if let package = resolvePackage(name, from: folder) {
                    found = package
                    viaPackage = true
                }
                guard let file = found else { missing.append(reference); continue }
                let ext = file.url.pathExtension.lowercased()
                if ext == "css" {
                    // A bare name cannot be reached from the copy, even when the package's own files already pulled the file in.
                    let link = PrototypeFiles.originalFolder + "/" + file.destination
                    if !copied.contains(file.destination), depth < maxImportDepth, place(file, limit: maxStyleBytes) {
                        result.stylesheets.append(file.destination)
                        follow(file, depth: depth + 1)
                    }
                    if viaPackage, copied.contains(file.destination), !packageLinks.contains(link) { packageLinks.append(link) }
                } else if assetExtensions.contains(ext) {
                    if !copied.contains(file.destination), place(file, limit: maxAssetBytes) { result.assets.append(file.destination) }
                }
            }
            if !missing.isEmpty {
                let shown = missing.prefix(3).joined(separator: ", ")
                gap("\(css.destination) refers to \(missing.count) file\(missing.count == 1 ? "" : "s") that could not be found in the project (\(shown)\(missing.count > 3 ? ", …" : "")).")
            }
            if external > 0 {
                gap("\(css.destination) loads \(external) resource\(external == 1 ? "" : "s") from the network; they stay as written and need a connection.")
            }
        }

        var listed: [String] = []
        for raw in styles {
            var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, !path.hasPrefix("/"), !listed.contains(path) else { continue }
            listed.append(path)
            guard let file = resolve(path, from: base) else { gap("Stylesheet \(path) named by the plan is not inside the project; not copied."); continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: file.url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                gap("Stylesheet \(path) named by the plan was not found in the project."); continue
            }
            guard file.url.pathExtension.lowercased() == "css" else {
                gap("Stylesheet \(path) is not plain CSS (it needs a build step); not copied."); continue
            }
            guard place(file, limit: maxStyleBytes) else { continue }
            if !result.stylesheets.contains(file.destination) { result.stylesheets.append(file.destination) }
            packageLinks = []
            follow(file, depth: 0)
            for link in packageLinks where !result.links.contains(link) { result.links.append(link) }
            result.links.append(PrototypeFiles.originalFolder + "/" + file.destination)
        }
        return result
    }
}
