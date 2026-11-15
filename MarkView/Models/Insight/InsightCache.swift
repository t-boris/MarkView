// InsightCache.swift
// MarkView
//
// Per-session disk cache for the v2 Recursive Insight feature.
// Each `InsightSession` owns one `InsightCache` instance rooted at
// `<workspace>/.insight-cache/<sessionUUID>/`. The cache stores:
//   - `manifest.json`            — session metadata + node index
//   - `nodes/<nodeUUID>.html`    — per-node rendered HTML
//   - `_assets/`                 — copies of vendored libs (Mermaid, Chart.js,
//                                  KaTeX, Prism …) so the ZIP export is
//                                  self-contained and offline-renderable.
//
// Threading contract:
//   The struct is `@MainActor`-free and safe to invoke from background
//   `Task` contexts (T6's `withThrowingTaskGroup` Phase 2 issues parallel
//   writes off-main). All state is captured in `let` value-typed properties
//   (`URL`, `UUID`); no shared mutable state, no captured closures, no
//   reference types — therefore no retain cycles.
//
// Atomicity:
//   `writeNode` and `updateManifest` stage to a UUID-suffixed temp file in the
//   same parent directory, then atomically swap into place via
//   `FileManager.replaceItemAt(_:withItemAt:)`. The UUID suffix guarantees
//   per-call temp uniqueness (concurrent writers cannot collide on a shared
//   `manifest.json.tmp`). `replaceItemAt` performs the swap in-place — there
//   is no window in which the destination is absent, so a concurrent
//   `readNode` / `loadManifest` always observes either the previous or the
//   new content. `Data.write(to:options:.atomic)` provides an additional
//   internal-temp guarantee for the temp file write itself.

import Foundation
import CryptoKit

/// Typed errors emitted by `InsightCache`. All file-system or decoding
/// failures inside the cache surface as one of these cases so callers can
/// branch on a precise diagnostic instead of inspecting raw `NSError`s.
enum InsightCacheError: Error {
    /// A vendored bundle resource expected at session init was not found.
    case bundleResourceMissing(name: String)
    /// A constructed file URL escaped the session root after symlink
    /// resolution. The offending URL is included for logging (never
    /// surfaced to UI — it may contain absolute paths).
    case pathEscape(url: URL)
    /// `JSONDecoder` failed to materialise a manifest. Wraps the underlying
    /// `DecodingError` so the caller can debug schema drift without coupling
    /// to Foundation error types directly.
    case manifestDecode(underlying: Error)
}

/// Persisted session manifest describing the whole insight tree on disk.
/// Encoded with `.iso8601` date strategy + sorted keys for stable diffs.
struct InsightManifest: Codable {
    let sessionId: UUID
    let folderName: String
    let createdAt: Date
    var nodes: [NodeManifestEntry]

    struct NodeManifestEntry: Codable {
        let nodeId: UUID
        let parentId: UUID?
        let title: String
        let level: Int
        let createdAt: Date
    }
}

/// Per-session disk cache. See file header for layout, threading, atomicity.
struct InsightCache {
    /// Session root: `<workspace>/.insight-cache/<sessionUUID>/`.
    /// Public so callers (T8 ZIP exporter) can reason about the staging
    /// directory location; never mutate the contents from outside.
    let rootDirectory: URL

    /// `<root>/_assets/`. Internal-by-default; exposed via
    /// `vendoredLibURL(matching:)` so InsightSession can resolve the
    /// actual on-disk filenames (e.g. `chart-4.4.9.min.js`) at HTML-build
    /// time without hard-coding a parallel filename list.
    let assetsDirectory: URL  // <root>/_assets/
    private let nodesDirectory: URL   // <root>/nodes/
    private let manifestURL: URL      // <root>/manifest.json

    // MARK: - Init

    /// Creates the per-workspace cache directory layout and copies vendored
    /// libs into `_assets/`. The cache lives at
    /// `<workspace>/.markview-insight/` (NOT keyed by sessionId so that
    /// closing and re-opening the insight tab on the same folder REUSES the
    /// cached HTML — re-running an LLM analysis is expensive and the user
    /// shouldn't pay for it again unless they explicitly request a refresh).
    /// Idempotent: re-running against an existing dir is safe — already-
    /// present files are skipped without error. The `sessionId` parameter
    /// is retained for source compatibility but no longer participates in
    /// the path.
    init(workspaceURL: URL, sessionId: UUID) throws {
        _ = sessionId
        let root = workspaceURL
            .appendingPathComponent(".markview-insight", isDirectory: true)
        self.rootDirectory = root
        self.assetsDirectory = root.appendingPathComponent("_assets", isDirectory: true)
        self.nodesDirectory = root.appendingPathComponent("nodes", isDirectory: true)
        self.manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)

        let fm = FileManager.default
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: nodesDirectory, withIntermediateDirectories: true)

        // Copy vendored libs into _assets/. Layout in _assets/ is flat:
        // every file under vendor/{js,css} lands directly inside _assets/.
        // Documented choice — keeps the HTML asset references shallow
        // (`../_assets/<file>`) and matches Decision 4's staging shape.
        try Self.copyVendoredLibs(from: "Editor/vendor/js", into: assetsDirectory)
        try Self.copyVendoredLibs(from: "Editor/vendor/css", into: assetsDirectory)
    }

    // MARK: - Node CRUD

    /// Atomic write: stage to a UUID-suffixed temp sibling, then in-place
    /// swap via `FileManager.replaceItemAt`. The UUID suffix prevents
    /// concurrent writers from colliding on the same temp filename even
    /// though the documented contract is "one writer per node". On any
    /// error the orphan `.tmp` is best-effort removed before rethrowing.
    func writeNode(nodeId: UUID, html: String) throws {
        let finalURL = nodesDirectory
            .appendingPathComponent("\(nodeId.uuidString).html", isDirectory: false)
        let tmpURL = nodesDirectory
            .appendingPathComponent("\(nodeId.uuidString).\(UUID().uuidString).html.tmp", isDirectory: false)
        try Self.assertContained(finalURL, in: nodesDirectory)
        try Self.assertContained(tmpURL, in: nodesDirectory)

        let data = Data(html.utf8)
        do {
            try data.write(to: tmpURL, options: .atomic)
            try Self.atomicReplace(source: tmpURL, destination: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
    }

    /// Reads a previously-written node HTML. Throws if the file is absent
    /// or unreadable; callers handle the missing-cache case explicitly.
    func readNode(nodeId: UUID) throws -> String {
        let url = nodesDirectory
            .appendingPathComponent("\(nodeId.uuidString).html", isDirectory: false)
        try Self.assertContained(url, in: nodesDirectory)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Manifest CRUD

    /// Atomic manifest write: stage to a UUID-suffixed temp sibling, then
    /// in-place swap via `FileManager.replaceItemAt`. The UUID suffix is
    /// load-bearing — if two callers race `updateManifest`, the prior
    /// shared `manifest.json.tmp` filename would collide and either the
    /// `.atomic` write or the swap would clobber the other writer's
    /// in-flight data. Encoded with sorted keys + pretty-printed for stable
    /// diffs and `.iso8601` for human-readable dates inside the on-disk JSON.
    func updateManifest(_ manifest: InsightManifest) throws {
        let tmpURL = rootDirectory
            .appendingPathComponent("manifest.\(UUID().uuidString).tmp", isDirectory: false)
        try Self.assertContained(manifestURL, in: rootDirectory)
        try Self.assertContained(tmpURL, in: rootDirectory)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(manifest)
            try data.write(to: tmpURL, options: .atomic)
            try Self.atomicReplace(source: tmpURL, destination: manifestURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
    }

    // MARK: - Cross-session snapshot (skeleton + per-section content)
    //
    // `snapshot.json` holds the minimum data needed to restore an InsightSession's
    // root node from disk WITHOUT re-running any LLM call:
    //   - skeleton (the Phase 1 tool_use output, JSON-encoded)
    //   - per-section final buffer (the concatenated Phase 2 streamed HTML)
    //   - the deterministic root nodeId
    //
    // Written after Phase 2 completes. Read by `InsightSession.tryRestoreFromSnapshot`
    // before kicking off generation.

    /// File URL of the snapshot.
    var snapshotURL: URL { rootDirectory.appendingPathComponent("snapshot.json", isDirectory: false) }

    /// Snapshot file presence — quick existence check without decoding.
    func hasSnapshot() -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL.path)
    }

    /// Atomic write of the JSON-encoded `data` into snapshot.json.
    func writeSnapshotData(_ data: Data) throws {
        try Self.assertContained(snapshotURL, in: rootDirectory)
        let tmpURL = rootDirectory.appendingPathComponent("snapshot.\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try data.write(to: tmpURL, options: .atomic)
            try Self.atomicReplace(source: tmpURL, destination: snapshotURL)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
    }

    /// Read raw snapshot bytes; caller decodes (avoids coupling InsightCache to Insight types).
    /// Returns nil if file is absent or unreadable.
    func readSnapshotData() -> Data? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        return try? Data(contentsOf: snapshotURL)
    }

    /// Removes the snapshot file (used by Regenerate). Cache directory + assets remain.
    func deleteSnapshot() {
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    /// Best-effort delete of one node's cached HTML file. Used by
    /// `InsightSession.regenerateNode` to drop stale HTML for descendants
    /// that no longer belong to the new tree. Tolerates missing files.
    func deleteNode(nodeId: UUID) {
        let url = nodesDirectory.appendingPathComponent("\(nodeId.uuidString).html", isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }

    /// Deterministic UUID derived from a folder URL. SHA-256 → first 16 bytes
    /// → set RFC-4122 version (4) and variant bits → UUID. Same folder path
    /// always yields the same UUID, so cache files written under that UUID
    /// are findable across app restarts and tab close/reopen.
    static func deterministicRootUUID(forFolderPath path: String) -> UUID {
        let digest = SHA256.hash(data: Data(path.utf8))
        var bytes = Array(digest.prefix(16))
        // Version 4 marker.
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        // RFC-4122 variant marker.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Loads the manifest. `JSONDecoder` failures are wrapped in
    /// `InsightCacheError.manifestDecode` so the caller sees a typed error.
    func loadManifest() throws -> InsightManifest {
        try Self.assertContained(manifestURL, in: rootDirectory)
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(InsightManifest.self, from: data)
        } catch {
            throw InsightCacheError.manifestDecode(underlying: error)
        }
    }

    // MARK: - Lifecycle

    /// Removes the entire session directory. Tolerates concurrent removal
    /// or never-existed scenarios: POSIX `ENOENT` (Cocoa
    /// `NSFileNoSuchFileError`) is treated as the success state. Any other
    /// error is rethrown.
    func cleanup() throws {
        do {
            try FileManager.default.removeItem(at: rootDirectory)
        } catch let error as NSError {
            // `NSFileNoSuchFileError` (Cocoa code 4) and POSIX `ENOENT`
            // both indicate "already gone" — treat as success.
            let isMissing =
                (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
            if isMissing { return }
            throw error
        }
    }

    // MARK: - Archive staging

    /// Returns a directory URL ready for `/usr/bin/zip -r <dest> .` to be
    /// pointed at to produce the export.
    ///
    /// Per Decision 4 (`_assets/` lives inside the session dir so the export
    /// staging dir is just a manifest tweak + zip — no separate copy step),
    /// this returns `rootDirectory` itself. By the time T8's
    /// `WorkspaceManager.exportInsightArchive(sessionId:)` invokes us, it
    /// has already performed any required HTML rewriting in place
    /// (rewriting `<script src="blob:…">` → `<script src="../_assets/<lib>.js">`
    /// per Decision 5). InsightCache itself does NO HTML rewriting.
    ///
    /// `async` is part of the cross-task contract with T8: the exporter
    /// expects to `await` this call so future implementations may schedule
    /// asset finalisation off-main without breaking call sites.
    func archiveStagingDirectory() async throws -> URL {
        // Defense-in-depth: an external process will be spawned against the
        // returned URL. The previous `assertContained(rootDirectory, in:
        // rootDirectory)` call was a tautology (the `==` branch always
        // matches). Replace with a real precondition: the symlink-resolved
        // root must still exist on disk and resolve to a directory before
        // we hand it to a `zip` subprocess.
        let fm = FileManager.default
        let resolved = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else {
            throw InsightCacheError.pathEscape(url: rootDirectory)
        }
        return rootDirectory
    }

    // MARK: - Private helpers

    /// Iterates the subdirectory of the running app bundle and copies every
    /// file inside into `dest`. Idempotent: pre-existing files are skipped.
    /// The bundle path is the canonical source of truth — the lib list is
    /// whatever is committed under `Resources/Editor/vendor/{js,css}` at
    /// build time, so this stays in sync without a hard-coded filename list.
    ///
    /// `relativePath` is split into a leaf resource name + parent
    /// `subdirectory:` so the call matches Foundation's idiomatic
    /// `Bundle.url(forResource:withExtension:subdirectory:)` shape used
    /// elsewhere in the app (see EditorView.swift L26 / L453). Combining
    /// the two segments into a single `forResource:` argument worked by
    /// accident on the current bundle layout but is not the documented
    /// contract.
    ///
    /// Subdirectories are copied recursively so resources like KaTeX
    /// webfonts (under `vendor/css/fonts/`) reach `_assets/fonts/` and the
    /// exported standalone HTML can resolve `url(fonts/KaTeX_*.woff2)`
    /// references emitted by `katex.min.css`. Wave 6 audit T9 #2 fix.
    private static func copyVendoredLibs(from relativePath: String, into dest: URL) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard let leaf = components.last else {
            throw InsightCacheError.bundleResourceMissing(name: relativePath)
        }
        let parent = components.dropLast().joined(separator: "/")
        guard let sourceDir = Bundle.main.url(
            forResource: String(leaf),
            withExtension: nil,
            subdirectory: parent.isEmpty ? nil : parent
        ) else {
            throw InsightCacheError.bundleResourceMissing(name: relativePath)
        }
        try Self.copyDirectoryContents(from: sourceDir, into: dest)
    }

    /// Recursively copy every file beneath `sourceDir` into `dest`. Mirrors
    /// the source layout — a file at `<sourceDir>/fonts/X.woff2` lands at
    /// `<dest>/fonts/X.woff2`. Idempotent on per-file collisions
    /// (`.fileWriteFileExists` swallowed). Each destination URL is
    /// containment-checked against the original `dest` root before being
    /// written so a malicious symlink under `vendor/` cannot escape
    /// `_assets/`.
    private static func copyDirectoryContents(from sourceDir: URL, into dest: URL) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for src in entries {
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: src.path, isDirectory: &isDir)

            if isDir.boolValue {
                // Recurse: ensure the mirrored subdirectory exists in
                // `dest`, then copy its contents into it.
                let subDest = dest.appendingPathComponent(src.lastPathComponent, isDirectory: true)
                try Self.assertContained(subDest, in: dest)
                try fm.createDirectory(at: subDest, withIntermediateDirectories: true)
                try Self.copyDirectoryContents(from: src, into: subDest)
                continue
            }

            let dst = dest.appendingPathComponent(src.lastPathComponent, isDirectory: false)
            try Self.assertContained(dst, in: dest)
            do {
                try fm.copyItem(at: src, to: dst)
            } catch let error as NSError {
                // Idempotent re-init: tolerate `.fileWriteFileExists`.
                if error.domain == NSCocoaErrorDomain &&
                   error.code == NSFileWriteFileExistsError {
                    continue
                }
                throw error
            }
        }
    }

    // MARK: - Vendored lib lookup

    /// Resolve a vendored lib filename in `_assets/` by case-insensitive
    /// prefix match (e.g. `"chart"` → `"chart-4.4.9.min.js"`). Returns nil
    /// if no file matches. Used by `InsightSession.buildHTMLTemplate` to
    /// emit `<script src="../_assets/<actualFilename>">` without
    /// hard-coding upstream filenames that drift with version bumps
    /// (Wave 6 audit T9 #1 fix).
    ///
    /// `extension:` narrows the result set to `.js` or `.css` so a
    /// caller asking for the Prism stylesheet (`prism-okaidia.min.css`)
    /// is not handed `prism.min.js`. When two files share a prefix, the
    /// shorter filename wins (deterministic ordering by length then
    /// lexicographic) — keeps cache rebuilds reproducible.
    func vendoredLibURL(matching prefix: String, extension ext: String) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: assetsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let lowerPrefix = prefix.lowercased()
        let lowerExt = ext.lowercased()
        let matches = entries.filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasPrefix(lowerPrefix) && url.pathExtension.lowercased() == lowerExt
        }
        return matches.sorted { a, b in
            if a.lastPathComponent.count != b.lastPathComponent.count {
                return a.lastPathComponent.count < b.lastPathComponent.count
            }
            return a.lastPathComponent < b.lastPathComponent
        }.first
    }

    /// In-place atomic swap of `source` over `destination`. Wraps
    /// `FileManager.replaceItemAt(_:withItemAt:)` so callers do not have
    /// to special-case the "destination doesn't exist yet" branch — when
    /// `replaceItemAt` fails because there is nothing to replace, fall
    /// back to a plain `moveItem`. The replace path keeps the destination
    /// file present at all times during the swap, eliminating the window
    /// (previously created by `try? remove` + `moveItem`) where a
    /// concurrent reader could observe an absent file.
    private static func atomicReplace(source: URL, destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: source)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }

    /// Path-containment guard. Resolves symlinks and standardises BOTH
    /// candidate and root, then performs a path-separator-aware `hasPrefix`
    /// check so a sibling like `/x/foobar/secret` cannot pass for `/x/foo`.
    ///
    /// Mirrors the canonical pattern in `WorkspaceManager.scanMarkdownFiles`
    /// (post-bb828a9 sibling-prefix fix). Duplicated locally — InsightCache
    /// has zero coupling to WorkspaceManager.
    private static func assertContained(_ url: URL, in root: URL) throws {
        let resolvedRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        // `URL.standardizedFileURL.path` strips trailing slashes; guard
        // against an existing trailing `/` to avoid `//` artefacts.
        let rootPrefix = resolvedRootPath.hasSuffix("/")
            ? resolvedRootPath
            : resolvedRootPath + "/"
        let resolvedCandidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        // `==` covers the (legitimate) case of the root URL itself being
        // passed in (e.g. `archiveStagingDirectory` returning the root).
        // The prefix clause requires a path-separator boundary so
        // `/x/foobar/x.html` cannot pass containment for `/x/foo`.
        guard resolvedCandidate == resolvedRootPath ||
              resolvedCandidate.hasPrefix(rootPrefix) else {
            throw InsightCacheError.pathEscape(url: url)
        }
    }
}
