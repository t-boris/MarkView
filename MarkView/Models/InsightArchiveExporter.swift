// InsightArchiveExporter.swift
// MarkView
//
// Bundles a v2 Recursive Insight staging directory (`<sessionUUID>/` containing
// `index.html`, `nodes/<uuid>.html`, `_assets/<lib>`, `manifest.json`) into a
// single ZIP archive at a user-chosen destination.
//
// Spawning policy (Decision 7 / Task 8):
//   - Uses Foundation `Process` to invoke `/usr/bin/zip` directly with an explicit
//     argument array. **Never** invokes `/bin/sh -c` or any shell — the destination
//     URL is user-chosen via NSSavePanel and could contain shell metacharacters
//     (`; rm -rf $HOME`, backticks, `$(...)`, newlines). Passing the raw `tmpURL.path`
//     as a separate argument to `Process` guarantees no shell interpretation.
//
// Atomicity:
//   - Writes to `<destination>.zip.tmp` first, then `replaceItemAt` swaps it into place
//     on `terminationStatus == 0`. If `zip` exits non-zero or the export is cancelled,
//     the `.zip.tmp` is removed and no partial file appears at the destination.
//
// Cancellation (Decision 11 §4):
//   - Wires `process.terminate()` (SIGTERM) into `withTaskCancellationHandler`'s
//     `onCancel:` so closing the insight tab during a long export kills the in-flight
//     `zip` process. Combined with `WorkspaceManager.closeTab`'s ordered cleanup
//     (`releaseInsightBlobs → session.cancel → cache.cleanup → tabsStore.removeTab`),
//     the staging directory is removed by `cache.cleanup` after the exporter exits.

import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Typed errors emitted by `InsightArchiveExporter.bundle`.
enum InsightArchiveExporterError: Error {
    /// `/usr/bin/zip` exited non-zero. Includes sanitized stderr (control chars
    /// stripped, truncated to 256 chars) for surfacing in NSAlert without log
    /// forgery (CWE-117).
    case zipFailed(String)
    /// Export was cancelled mid-flight. `.zip.tmp` cleaned up before throwing.
    case cancelled
    /// The atomic move from `.zip.tmp` to the final destination failed
    /// (cross-volume or permission). Includes sanitized error message.
    case moveFailed(String)
    /// `Process.run()` itself threw (e.g. `/usr/bin/zip` missing on a stripped
    /// macOS install — should never happen on stock macOS). Includes sanitized
    /// underlying-error description.
    case launchFailed(String)
}

/// Stateless ZIP-bundling helper. The single entry point `bundle(stagingURL:to:)`
/// is `async throws` so callers (`WorkspaceManager.exportInsightArchive(sessionId:)`)
/// can `await` and propagate cancellation through Swift's structured concurrency.
struct InsightArchiveExporter {

    /// Bundle every file under `stagingURL` into a ZIP at `destinationURL`.
    ///
    /// Implementation: `cd <stagingURL> && /usr/bin/zip -r <dest>.tmp .`, then
    /// atomically replace `<dest>` with `<dest>.tmp`. The current-directory shift
    /// (via `process.currentDirectoryURL`) keeps the archive's internal paths
    /// relative — `index.html`, `nodes/<uuid>.html`, `_assets/<lib>` end up at the
    /// archive root, NOT prefixed with the staging dir's absolute path.
    ///
    /// - Parameter stagingURL: Directory to zip. Must exist and be a directory
    ///   (caller's responsibility — `InsightCache.archiveStagingDirectory()`
    ///   guarantees this on success).
    /// - Parameter destinationURL: Where to write the final `.zip`. Existing files
    ///   at this path are overwritten via `replaceItemAt`.
    func bundle(stagingURL: URL, to destinationURL: URL) async throws {
        // Stage the zip output to `<destination>.zip.tmp` so failures or
        // cancellations leave no partial archive at the user-visible destination.
        // The `.tmp` suffix is appended to the FULL destination (including the
        // existing extension) so `final.zip` becomes `final.zip.tmp`.
        let tmpURL = destinationURL.appendingPathExtension("tmp")

        // Best-effort cleanup: if a previous run crashed and left a `.tmp`
        // sibling, remove it before launching the new process so `zip -r` does
        // not append entries to a stale archive.
        try? FileManager.default.removeItem(at: tmpURL)

        let executable = "/usr/bin/zip"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw InsightArchiveExporterError.launchFailed("zip executable not found at \(executable)")
        }

        // Delegate process execution, pipe draining, and cancellation (SIGTERM -> SIGKILL)
        // directly to shared `Subprocess` (`AR-07`, `AR-25`) with an explicit argument array.
        let spec = SubprocessSpec(
            executable: executable,
            arguments: ["-r", "-q", tmpURL.path, "."],
            cwd: stagingURL,
            timeout: 120,
            maxOutputBytes: 64 * 1024
        )
        let result = await Subprocess.run(spec)

        // Check cancellation FIRST so an aborted tab close surfaces `.cancelled`
        // rather than a misleading `.zipFailed` for the signal exit status.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: tmpURL)
            throw InsightArchiveExporterError.cancelled
        }

        if result.exitCode == -1 && !result.timedOut {
            try? FileManager.default.removeItem(at: tmpURL)
            let message = result.stderr.isEmpty
                ? "zip failed to launch"
                : Self.sanitizeForError(result.stderr)
            throw InsightArchiveExporterError.launchFailed(message)
        }

        if !result.succeeded {
            let raw = result.timedOut ? "zip timed out" : result.stderr
            let message = raw.isEmpty
                ? "zip exited with status \(result.exitCode)"
                : Self.sanitizeForError(raw)
            try? FileManager.default.removeItem(at: tmpURL)
            throw InsightArchiveExporterError.zipFailed(message)
        }

        // Atomic move `.tmp` → final. `replaceItemAt` handles both cases:
        // destination already exists (overwrites it) or doesn't yet
        // (delegates to a plain rename). Cross-volume falls back internally.
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            throw InsightArchiveExporterError.moveFailed(
                Self.sanitizeForError(error.localizedDescription)
            )
        }
    }

    /// Strip control characters (CR, LF, NUL, tab, other ASCII control) and
    /// truncate to 256 chars before surfacing an error message via NSAlert or
    /// NSLog. Defends against log forgery (CWE-117) and runaway output from
    /// adversarial filenames in `zip` stderr.
    private static func sanitizeForError(_ s: String) -> String {
        let stripped = s.replacingOccurrences(
            of: "[\\r\\n\\0\\t\\u{00}-\\u{1F}\\u{7F}]",
            with: " ",
            options: .regularExpression
        )
        let collapsed = stripped
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return String(collapsed.prefix(256))
    }
}
