import Foundation

/// Widgets and modals of a reconstructed window as screens of their own (BUG-050): the isolated page of such a screen,
/// which needs no assistant, and the coverage figure of a code-mode build. Pure functions and one small log; the
/// caller owns all file and assistant work.
enum PrototypeEmbedded {
    /// The source files the screen and component writers read, as project-relative paths. The side-by-side runs share one.
    final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths = Set<String>()

        func add(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            paths.insert(path)
        }

        var all: Set<String> {
            lock.lock(); defer { lock.unlock() }
            return paths
        }
    }

    // MARK: - Isolated page

    /// `components/<slug>.html` for a component that is an embedded screen: it loads the shared files and mounts the
    /// registered screen alone with `App.renderScreen`, so the reviewer sees the widget or modal on its own and an edit
    /// of `screens/<id>.js` shows in both places. `links` are the original stylesheets as `index.html` links them
    /// (relative to the site root); the page sits one folder below, so they get a `../`.
    static func page(screenID: String, name: String, componentPath: String, links: [String]) -> String {
        let styles = PrototypeStyles.linkTags(links.map { "../" + $0 })
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escaped(name)) · \(escaped(componentPath))</title>
        \(styles)<link rel="stylesheet" href="../styles.css">
        </head>
        <body>
        <p style="margin:8px 12px;font:12px/1.4 system-ui,sans-serif;opacity:.7">Source component: \(escaped(componentPath))</p>
        <main id="component" data-mv-component="\(escaped(componentPath))"></main>
        <script src="../data.js"></script>
        <script src="../app.js"></script>
        <script src="../screens/\(escaped(screenID)).js"></script>
        <script>
        (function () {
          var host = document.getElementById('component');
          try {
            var node = App.renderScreen(\(literal(screenID)));
            if (typeof node === 'string') { host.innerHTML = node; } else if (node) { host.appendChild(node); }
          } catch (error) {
            host.textContent = 'This component could not be shown: ' + (error && error.message ? error.message : error);
          }
        })();
        </script>
        </body>
        </html>

        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A JavaScript string literal for `text`, safe inside a `<script>` element.
    private static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data("[\"\"]".utf8)
        var array = String(decoding: data, as: UTF8.self)
        array.removeFirst(); array.removeLast()
        return array.replacingOccurrences(of: "</", with: "<\\/")
    }

    // MARK: - Coverage

    /// What a code-mode build reproduced of the interface's source (BUG-050): of the UI source files of 2 KB or more
    /// in the scope, how many the plan names as evidence or components or a writer read.
    struct Coverage: Equatable, Sendable {
        var covered: Int
        var total: Int
        var coveredBytes: Int
        var totalBytes: Int
        /// The files nothing named or read, largest first.
        var uncovered: [PrototypeFiles.InventoryEntry]

        /// The most files named in `sentence`.
        static let listed = 8

        var percent: Int { total == 0 ? 0 : Int((Double(covered) / Double(total) * 100).rounded()) }

        /// One honest sentence for the conversation and the manifest.
        var sentence: String {
            var out = "Coverage: the build named or read \(covered) of \(total) UI source files of 2 KB or more " +
                "(\(percent)%, \(Self.size(coveredBytes)) of \(Self.size(totalBytes)))."
            if !uncovered.isEmpty {
                let shown = uncovered.prefix(Self.listed).map { "\($0.path) (\(Self.size($0.bytes)))" }.joined(separator: ", ")
                let more = uncovered.count > Self.listed ? ", and \(uncovered.count - Self.listed) more" : ""
                out += " Not covered, largest first: \(shown)\(more)."
            }
            return out
        }

        private static func size(_ bytes: Int) -> String {
            bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : "\(max(1, bytes / 1000)) KB"
        }
    }

    static let sourceExtensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "vue", "svelte", "html", "htm"]
    static let minimumBytes = 2048

    /// A path as the plan and the log spell it: trimmed, without a leading `./` or the project folder.
    static func normalised(_ path: String, root: String? = nil) -> String {
        var out = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let root, out.hasPrefix(root + "/") { out.removeFirst(root.count + 1) }
        while out.hasPrefix("./") { out.removeFirst(2) }
        return out
    }

    /// Nil when the scope lists no UI source file of that size (nothing to measure).
    static func coverage(inventory: PrototypeFiles.Inventory, screens: [PrototypeAI.PlannedScreen], read: Set<String>) -> Coverage? {
        let candidates = inventory.entries.filter {
            sourceExtensions.contains(($0.path as NSString).pathExtension.lowercased()) && $0.bytes >= minimumBytes
        }
        guard !candidates.isEmpty else { return nil }
        var seen = read
        for screen in screens {
            for path in screen.evidence + screen.components { seen.insert(normalised(path)) }
        }
        let covered = candidates.filter { seen.contains($0.path) }
        let uncovered = candidates.filter { !seen.contains($0.path) }.sorted { ($0.bytes, $1.path) > ($1.bytes, $0.path) }
        return Coverage(covered: covered.count, total: candidates.count, coveredBytes: covered.reduce(0) { $0 + $1.bytes },
                        totalBytes: candidates.reduce(0) { $0 + $1.bytes }, uncovered: uncovered)
    }
}
