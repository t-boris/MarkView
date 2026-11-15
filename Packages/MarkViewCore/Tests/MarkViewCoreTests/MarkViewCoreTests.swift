import Foundation
import WebKit
import XCTest
@testable import MarkViewCore

final class MarkViewCoreTests: XCTestCase {
    func testSubprocessRunAndOutputCap() async {
        let ok = await Subprocess.run(SubprocessSpec(executable: "/bin/echo", arguments: ["hello", "world"]))
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")

        let capped = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "yes abcdefghijklmnopqrstuvwxyz | head -n 500"],
            timeout: 5,
            maxOutputBytes: 1024
        ))
        XCTAssertTrue(capped.truncated)
        XCTAssertLessThanOrEqual(capped.stdout.utf8.count, 1024)
    }

    func testSubprocessTimeoutEscalation() async {
        let timedOut = await Subprocess.run(SubprocessSpec(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(10)"],
            timeout: 0.2
        ))
        XCTAssertTrue(timedOut.timedOut)
    }

    func testSubprocessMergesEnvironmentAndRespectsExtraPATH() async throws {
        // Environment override merges with inherited environment instead of wiping it (`FU-04`).
        let merged = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s|%s' \"$PATH\" \"$MARKVIEW_TEST_ENV\""],
            environment: ["MARKVIEW_TEST_ENV": "merged-ok"]
        ))
        XCTAssertTrue(merged.succeeded)
        let parts = merged.stdout.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 2)
        XCTAssertFalse(parts[0].isEmpty, "Inherited PATH must be preserved when spec.environment is set")
        XCTAssertEqual(parts[1], "merged-ok")

        // `settings.cli.extraPATH` resolves custom binary locations (`FU-04`).
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mvbin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let toolURL = tempDir.appendingPathComponent("mv-custom-tool")
        try AtomicFile.write("#!/bin/sh\necho extra-path-ok\n", to: toolURL, permissions: 0o755)

        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: Subprocess.extraPATHDefaultsKey)
        defaults.set(tempDir.path, forKey: Subprocess.extraPATHDefaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: Subprocess.extraPATHDefaultsKey) }
            else { defaults.removeObject(forKey: Subprocess.extraPATHDefaultsKey) }
        }

        let resolved = Subprocess.resolveExecutable("mv-custom-tool")
        XCTAssertEqual(resolved, toolURL.path)
        let res = await Subprocess.run(SubprocessSpec(executable: "mv-custom-tool"))
        XCTAssertTrue(res.succeeded)
        XCTAssertEqual(res.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "extra-path-ok")
    }

    func testSubprocessDoesNotHangOnDetachedDescendantHoldingStdout() async {
        // Spawns a background sleep child that keeps stdout open after parent exits;
        // Subprocess.run must return promptly without blocking on unbounded readDataToEndOfFile (`FU-04`).
        let res = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "echo parent-done; sleep 3 &"],
            timeout: 2
        ))
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertFalse(res.timedOut)
        XCTAssertTrue(res.stdout.contains("parent-done"))
        XCTAssertLessThan(res.durationMs, 1500)
    }

    func testAtomicFilePermissionsBeforeRename() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mvatomic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let secret = temp.appendingPathComponent("token")
        try AtomicFile.write("secret-token", to: secret, permissions: 0o600)
        let attrs = try FileManager.default.attributesOfItem(atPath: secret.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)

        // When permissions is nil, overwriting preserves existing file mode (`FU-04`).
        try AtomicFile.write("secret-token-v2", to: secret, permissions: nil)
        let preservedAttrs = try FileManager.default.attributesOfItem(atPath: secret.path)
        let preservedMode = (preservedAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(preservedMode & 0o777, 0o600)
    }

    // MARK: AtomicFile (FU-23)

    private func makeScratchFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mvatomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func entries(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func mode(of url: URL) throws -> Int {
        ((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// How many replacement folders `FileManager` keeps for the volume of `folder`. The parent folder cannot be listed,
    /// but its link count is the number of entries plus two. The probe made here is not counted.
    private func replacementFolderCount(near folder: URL) throws -> Int {
        let fm = FileManager.default
        let probe = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? fm.removeItem(at: probe) }
        var info = stat()
        guard stat(probe.deletingLastPathComponent().path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(info.st_nlink) - 2 - 1
    }

    private func setExtendedAttribute(_ name: String, _ value: String, on url: URL) {
        XCTAssertEqual(setxattr(url.path, name, value, value.utf8.count, 0, 0), 0, "setxattr \(name)")
    }

    private func extendedAttribute(_ name: String, of url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, name, &buffer, size, 0, 0)
        return read < 0 ? nil : String(decoding: buffer.prefix(read), as: UTF8.self)
    }

    private func accessControlList(of url: URL) -> String? {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        return acl_to_text(acl, &length).map { String(cString: $0) }
    }

    func testAtomicFileWritesThroughSymbolicLinks() throws {
        let fm = FileManager.default
        let root = try makeScratchFolder()
        let real = root.appendingPathComponent("real.md")
        try AtomicFile.write("old", to: real)
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)

        // An absolute link, a relative link read from the folder the link lives in, and a chain of both.
        let absolute = root.appendingPathComponent("absolute.md")
        try fm.createSymbolicLink(at: absolute, withDestinationURL: real)
        let relative = sub.appendingPathComponent("relative.md")
        try fm.createSymbolicLink(atPath: relative.path, withDestinationPath: "../real.md")
        let chain = root.appendingPathComponent("chain.md")
        try fm.createSymbolicLink(atPath: chain.path, withDestinationPath: "absolute.md")
        for (index, link) in [absolute, relative, chain].enumerated() {
            let destination = try fm.destinationOfSymbolicLink(atPath: link.path)
            try AtomicFile.write("through link \(index)", to: link)
            XCTAssertTrue(isSymbolicLink(link), "\(link.lastPathComponent) must stay a link")
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), destination)
            XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "through link \(index)", "the file behind the link is updated")
        }

        // A link to a file that does not exist yet: the file is created where the link points.
        let dangling = root.appendingPathComponent("dangling.md")
        try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: "created.md")
        try AtomicFile.write("created through a link", to: dangling)
        XCTAssertTrue(isSymbolicLink(dangling))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("created.md"), encoding: .utf8), "created through a link")

        // A loop of links is an error, and nothing is replaced or left behind.
        let loopA = root.appendingPathComponent("loop-a.md"), loopB = root.appendingPathComponent("loop-b.md")
        try fm.createSymbolicLink(atPath: loopA.path, withDestinationPath: "loop-b.md")
        try fm.createSymbolicLink(atPath: loopB.path, withDestinationPath: "loop-a.md")
        XCTAssertThrowsError(try AtomicFile.write("x", to: loopA)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ELOOP)
        }
        XCTAssertTrue(isSymbolicLink(loopA) && isSymbolicLink(loopB))

        XCTAssertEqual(try entries(in: root), ["absolute.md", "chain.md", "created.md", "dangling.md", "loop-a.md", "loop-b.md", "real.md", "sub"])
        XCTAssertEqual(try entries(in: sub), ["relative.md"])
    }

    func testAtomicFileKeepsExtendedAttributesAndACL() throws {
        let root = try makeScratchFolder()
        let document = root.appendingPathComponent("downloaded.md")
        try AtomicFile.write("old", to: document)
        setExtendedAttribute("com.apple.quarantine", "0083;5f3c4d5e;Safari;11111111-2222-3333-4444-555555555555", on: document)
        let quarantine = try XCTUnwrap(extendedAttribute("com.apple.quarantine", of: document)) // the system rewrites what is set
        setExtendedAttribute("com.apple.metadata:_kMDItemUserTags", "tag-data", on: document)
        setExtendedAttribute("com.markview.test", "kept", on: document)
        let acl = try XCTUnwrap(acl_from_text("!#acl 1\nuser:FFFFEEEE-DDDD-CCCC-BBBB-AAAA000000C8:::allow:read"))
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        XCTAssertEqual(acl_set_file(document.path, ACL_TYPE_EXTENDED, acl), 0)
        let aclBefore = try XCTUnwrap(accessControlList(of: document))

        for round in 1...2 { // the second write starts from a file that was itself written by AtomicFile
            try AtomicFile.write("new \(round)", to: document)
            XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "new \(round)")
            XCTAssertEqual(extendedAttribute("com.apple.quarantine", of: document), quarantine)
            XCTAssertEqual(extendedAttribute("com.apple.metadata:_kMDItemUserTags", of: document), "tag-data")
            XCTAssertEqual(extendedAttribute("com.markview.test", of: document), "kept")
            XCTAssertEqual(accessControlList(of: document), aclBefore)
        }

        // A file that did not exist has none of these.
        let created = root.appendingPathComponent("created.md")
        try AtomicFile.write("fresh", to: created)
        XCTAssertNil(extendedAttribute("com.markview.test", of: created))
        XCTAssertNil(accessControlList(of: created))
    }

    func testAtomicFileModes() throws {
        let root = try makeScratchFolder()
        let created = root.appendingPathComponent("created.md")
        try AtomicFile.write("new file", to: created)
        XCTAssertEqual(try mode(of: created), 0o644, "a new file gets the default mode whatever the umask")

        let kept = root.appendingPathComponent("kept.md")
        try AtomicFile.write("v1", to: kept)
        XCTAssertEqual(chmod(kept.path, 0o640), 0)
        try AtomicFile.write("v2", to: kept)
        XCTAssertEqual(try mode(of: kept), 0o640, "an existing file keeps its mode")

        let tightened = root.appendingPathComponent("tightened.md")
        try AtomicFile.write("v1", to: tightened)
        XCTAssertEqual(try mode(of: tightened), 0o644)
        try AtomicFile.write("secret", to: tightened, permissions: 0o600)
        XCTAssertEqual(try mode(of: tightened), 0o600, "a requested mode replaces the existing one")
        XCTAssertEqual(try String(contentsOf: tightened, encoding: .utf8), "secret")
    }

    func testAtomicFileLeavesNoTemporaryFile() throws {
        let fm = FileManager.default
        let root = try makeScratchFolder()
        let document = root.appendingPathComponent("note.md")
        let blocked = root.appendingPathComponent("blocked.md", isDirectory: true)
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        try "inside".write(to: blocked.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)

        let before = try replacementFolderCount(near: root)
        for round in 1...5 {
            try AtomicFile.write("version \(round)", to: document)
            // A write that fails at the rename (the target is a folder) leaves the target alone and cleans up.
            XCTAssertThrowsError(try AtomicFile.write("x", to: blocked))
        }
        XCTAssertEqual(try entries(in: root), ["blocked.md", "note.md"], "nothing but the documents is ever put in the target's folder")
        XCTAssertEqual(try entries(in: blocked), ["inside.txt"])
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "version 5")
        XCTAssertLessThanOrEqual(try replacementFolderCount(near: root), before, "successful and failed writes leave nothing in the replacement folder")
    }

    func testAtomicFileNeverShowsATemporaryFileInTheTargetFolder() throws {
        final class Outcome: @unchecked Sendable { var error: Error? }
        let root = try makeScratchFolder()
        let document = root.appendingPathComponent("big.md")
        try AtomicFile.write("small", to: document)
        let payload = Data(repeating: 0x61, count: 48 * 1024 * 1024)
        let outcome = Outcome()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            do { try AtomicFile.write(payload, to: document) } catch { outcome.error = error }
        }
        // List the folder as fast as possible while the write runs: a temporary file next to the document would show up.
        var seen = Set<String>()
        repeat {
            seen.formUnion((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        } while group.wait(timeout: .now()) == .timedOut
        XCTAssertNil(outcome.error)
        XCTAssertEqual(seen.subtracting(["big.md"]), [], "watchers and git must not see a temporary file next to the document")
        XCTAssertEqual(try Data(contentsOf: document).count, payload.count)
    }

    func testSubprocessCancellationAndProcessGroupKill() async {
        // Pre-cancelled Task must abort before/during launch and not block (`FU-04`).
        let canceledTask = Task { () -> SubprocessResult in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return await Subprocess.run(SubprocessSpec(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: 5
            ))
        }
        canceledTask.cancel()
        let canceled = await canceledTask.value
        XCTAssertFalse(canceled.succeeded)
        XCTAssertLessThan(canceled.durationMs, 1500)

        // Timed-out parent spawning a child process group must terminate promptly (`FU-04`).
        let groupTimedOut = await Subprocess.run(SubprocessSpec(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 10 & wait"],
            timeout: 0.25
        ))
        XCTAssertTrue(groupTimedOut.timedOut)
        XCTAssertLessThan(groupTimedOut.durationMs, 3000)
    }

    func testProjectPathsSymlinkContainment() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mvcore-\(UUID().uuidString)")
        let root = temp.appendingPathComponent("project")
        let outside = temp.appendingPathComponent("outside")
        defer { try? FileManager.default.removeItem(at: temp) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try AtomicFile.write("secret", to: secret)

        let insideFile = root.appendingPathComponent("docs/readme.md")
        try AtomicFile.write("# Readme", to: insideFile)
        XCTAssertTrue(ProjectPaths.contains(insideFile, root: root))
        XCTAssertEqual(ProjectPaths.relativePath(of: insideFile, under: root), "docs/readme.md")

        let escapeLink = root.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: secret)
        XCTAssertFalse(ProjectPaths.contains(escapeLink, root: root))
    }

    func testProjectCacheIdentifierUniqueness() {
        let a = URL(fileURLWithPath: "/Users/alice/work/app")
        let b = URL(fileURLWithPath: "/Users/bob/work/app")
        XCTAssertNotEqual(ProjectPaths.projectCacheIdentifier(for: a), ProjectPaths.projectCacheIdentifier(for: b))
    }

    /// The layout of MarkView's own files in a project (AR-24). The expected strings are the contract: a stored project keeps
    /// working only while every accessor still names the same relative path, so each distinct path is asserted here.
    func testProjectLayoutPaths() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mvcore-layout-\(UUID().uuidString)")
        let folders: [(String, URL)] = [
            (".dde", ProjectPaths.localFolder(root)),
            (".dde/workflow/workflow.json", ProjectPaths.workflowFile(root)),
            (".dde/lifecycle", ProjectPaths.lifecycleFolder(root)),
            (".dde/lifecycle/cycle-time.json", ProjectPaths.cycleTimeFile(root)),
            (".dde/lifecycle/transitions.jsonl", ProjectPaths.transitionsLog(root)),
            (".dde/lifecycle/sessions.jsonl", ProjectPaths.sessionsLog(root)),
            (".dde/qa", ProjectPaths.qaFolder(root)),
            (".dde/studio", ProjectPaths.studioFolder(root)),
            (".dde/cockpit", ProjectPaths.cockpitFolder(root)),
            (".dde/cockpit/runs", ProjectPaths.cockpitRunsFolder(root)),
            (".dde/cockpit/results", ProjectPaths.cockpitResultsFolder(root)),
            (".dde/cockpit/temporal", ProjectPaths.cockpitTemporalFolder(root)),
            (".dde/discussions", ProjectPaths.discussionsFolder(root)),
            (".dde/understanding", ProjectPaths.understandingFolder(root)),
            (".dde/xray-folders", ProjectPaths.xrayFoldersFolder(root)),
            (".dde/cache", ProjectPaths.cacheFolder(root)),
            (".dde/cache/xray", ProjectPaths.xrayCacheFolder(root)),
            (".dde/cache/xray-content", ProjectPaths.xrayContentFolder(root)),
            (".dde/cache/explain", ProjectPaths.explainCacheFolder(root)),
            (".markview-insight", ProjectPaths.insightFolder(root)),
        ]
        for (relative, url) in folders {
            XCTAssertEqual(ProjectPaths.relativePath(of: url, under: root), relative, relative)
            XCTAssertTrue(ProjectPaths.contains(url, root: root), relative)
        }
        // Relative names that are stored, shown or handed to a tool.
        XCTAssertEqual(ProjectPaths.localFolderName, ".dde")
        XCTAssertEqual(ProjectPaths.insightFolderName, ".markview-insight")
        XCTAssertEqual(ProjectPaths.workflowRelativePath, ".dde/workflow/workflow.json")
        XCTAssertEqual(ProjectPaths.githubConnectionRelativePath, ".dde/github-connection.json")
        XCTAssertEqual(ProjectPaths.studioRelativePath, ".dde/studio")
        XCTAssertEqual(ProjectPaths.studioAttachmentsRelativePath, ".dde/studio/attachments")
        XCTAssertEqual(ProjectPaths.studioTitaniumDataRelativePath, ".dde/studio/titanium-data")
        XCTAssertEqual(ProjectPaths.studioCaptureRelativePath(id: "cap-1"), ".dde/studio/captures/cap-1.png")
        XCTAssertEqual(ProjectPaths.legacyPrototypesRelativePath, ".dde/prototypes")
        XCTAssertEqual(ProjectPaths.prototypeExportsRelativePath, ".dde/exports/prototypes")
        XCTAssertEqual(ProjectPaths.cockpitRelativePath, ".dde/cockpit")
        // Names of tabs that have no file behind them.
        XCTAssertEqual(ProjectPaths.placeholderName("terminal-1"), ".markview-terminal-1")
        XCTAssertEqual(ProjectPaths.placeholderName("github-a-b-pr-7"), ".markview-github-a-b-pr-7")
        XCTAssertEqual(ProjectPaths.sentinelRelativePath("git"), ".dde/.markview-git")
        XCTAssertEqual(ProjectPaths.sentinelRelativePath("ui-studio-"), ".dde/.markview-ui-studio-")
    }

    func testIsInLocalFolder() {
        XCTAssertTrue(ProjectPaths.isInLocalFolder(URL(fileURLWithPath: "/work/app/.dde/notes/a.md")))
        XCTAssertTrue(ProjectPaths.isInLocalFolder(URL(fileURLWithPath: "/work/app/.dde")))
        XCTAssertFalse(ProjectPaths.isInLocalFolder(URL(fileURLWithPath: "/work/app/docs/a.md")))
        XCTAssertFalse(ProjectPaths.isInLocalFolder(URL(fileURLWithPath: "/work/app/.ddenotes/a.md")),
                       "a folder whose name only starts with .dde is not the local folder")
    }

    func testContainsStrictlyExcludesTheRootAndEscapes() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mvcore-strict-\(UUID().uuidString)")
        let root = temp.appendingPathComponent("project")
        let outside = temp.appendingPathComponent("outside")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        XCTAssertTrue(ProjectPaths.contains(root, root: root), "the root contains itself")
        XCTAssertFalse(ProjectPaths.containsStrictly(root, root: root), "but not strictly")
        XCTAssertTrue(ProjectPaths.containsStrictly(root.appendingPathComponent("docs"), root: root))
        XCTAssertTrue(ProjectPaths.containsStrictly(root.appendingPathComponent("docs/not-yet.md"), root: root), "a file that is not there yet")
        XCTAssertFalse(ProjectPaths.containsStrictly(root.appendingPathComponent("../outside/x.md"), root: root), "a dot-dot escape")
        XCTAssertFalse(ProjectPaths.containsStrictly(temp.appendingPathComponent("project-sibling/x.md"), root: root), "a sibling that shares the prefix")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertFalse(ProjectPaths.containsStrictly(root.appendingPathComponent("link/x.md"), root: root), "a symlink that leaves the root")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("home"), withDestinationURL: root)
        XCTAssertFalse(ProjectPaths.containsStrictly(root.appendingPathComponent("home"), root: root), "a symlink to the root itself")
    }

    func testWeakScriptMessageHandlerDoesNotRetainTarget() {
        final class DummyHandler: NSObject, WKScriptMessageHandler {
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
        }
        weak var weakTarget: DummyHandler?
        autoreleasepool {
            let target = DummyHandler()
            weakTarget = target
            let proxy = WeakScriptMessageHandler(target)
            _ = proxy.target
        }
        XCTAssertNil(weakTarget)
    }
}
