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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // Explicit argument array — NEVER `/bin/sh -c` or string concatenation.
        // `tmpURL.path` and `"."` are passed verbatim to `zip`; shell
        // metacharacters in the user-chosen destination filename cannot escape
        // into command interpretation.
        process.arguments = ["-r", tmpURL.path, "."]
        process.currentDirectoryURL = stagingURL

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // Discard stdout (zip's progress output is non-essential for this use
        // case; we surface only stderr in error paths).
        process.standardOutput = Pipe()

        // Cancellation hook: if the parent Task is cancelled (e.g. closeTab
        // fires during export), send SIGTERM to the zip process and clean up
        // the partial `.tmp`. The `withTaskCancellationHandler` runs the
        // `onCancel:` block synchronously on the Task that observed the
        // cancellation; `process.terminate()` is itself synchronous and
        // signal-based — safe from any thread.
        do {
            try await withTaskCancellationHandler {
                try process.run()
                // Bridge the synchronous `waitUntilExit` to async via
                // `terminationHandler`. Done outside `withCheckedContinuation`
                // means the cancellation handler can `terminate()` while we
                // wait, which produces a non-zero exit code that we observe
                // below and translate to `.cancelled`.
                await Self.waitUntilExit(process: process)
            } onCancel: {
                // Synchronous SIGTERM. Idempotent — `terminate()` on an
                // already-exited process is a no-op (no exception).
                if process.isRunning {
                    process.terminate()
                }
            }
        } catch {
            // `process.run()` threw — could not even spawn. Best-effort cleanup.
            try? FileManager.default.removeItem(at: tmpURL)
            throw InsightArchiveExporterError.launchFailed(
                Self.sanitizeForError(error.localizedDescription)
            )
        }

        // After process exits — check for cancellation FIRST so we surface
        // `.cancelled` rather than a misleading `.zipFailed` for the SIGTERM
        // exit code (typically 143 = 128 + SIGTERM).
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: tmpURL)
            throw InsightArchiveExporterError.cancelled
        }

        if process.terminationStatus != 0 {
            // Read sanitized stderr for the error message. Best-effort — if
            // the pipe is exhausted or unreadable, fall back to an exit-code
            // string.
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: stderrData, encoding: .utf8) ?? ""
            let message = raw.isEmpty
                ? "zip exited with status \(process.terminationStatus)"
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

    /// Bridge `Process.waitUntilExit` (synchronous) to `async`. Foundation
    /// invokes `terminationHandler` exactly once when the process exits, even
    /// if the handler is set AFTER the exit (the runtime calls it synchronously
    /// upon assignment in that case). The handler may fire on a background
    /// queue; the continuation resume is itself thread-safe.
    private static func waitUntilExit(process: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
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
