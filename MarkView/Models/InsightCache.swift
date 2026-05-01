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

    private let assetsDirectory: URL  // <root>/_assets/
    private let nodesDirectory: URL   // <root>/nodes/
    private let manifestURL: URL      // <root>/manifest.json

    // MARK: - Init

    /// Creates the session directory layout and copies vendored libs into
    /// `_assets/`. Idempotent: re-running against an existing session dir
    /// is safe — already-present files are skipped without error.
    init(workspaceURL: URL, sessionId: UUID) throws {
        let root = workspaceURL
            .appendingPathComponent(".insight-cache", isDirectory: true)
            .appendingPathComponent(sessionId.uuidString, isDirectory: true)
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
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for src in entries {
            // Skip nested directories (e.g. css/fonts/) — flat _assets/ layout
            // is the documented choice; nested resources like webfonts are
            // not required for the current export contract. If a future
            // change needs them, copy recursively here.
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: src.path, isDirectory: &isDir)
            if isDir.boolValue { continue }

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
