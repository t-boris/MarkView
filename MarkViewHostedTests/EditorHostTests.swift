import AppKit
import os
import MarkViewCore
import SwiftUI
import WebKit
import XCTest
@testable import MarkView

private actor DraftCheckpointRecorder {
    private var drafts: [ProjectDraft] = []
    func append(_ draft: ProjectDraft) { drafts.append(draft) }
    func snapshot() -> [ProjectDraft] { drafts }
}

/// The real editor with the real per-window parts, in the isolated app-hosted test build.
final class EditorHostTests: XCTestCase {
    func testAssistantJSONSearchPlacesAcrossTask() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-places-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "one\ntwo\n".write(to: folder.appendingPathComponent("file.swift"), atomically: true, encoding: .utf8)
        let json: [String: Any] = ["steps": [["title": "Trace", "places": [
            ["path": "file.swift", "start": 1, "end": 99],
            ["path": "../outside", "start": 1],
        ]]]]
        let result = try CLICompletion.Result(text: "", structured: json, inputTokens: 0, outputTokens: 0, costUSD: nil)
        let places = await Task.detached {
            XRaySearch.places(from: (result.structured as? [String: Any])?["steps"], root: folder)
        }.value
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.path, "file.swift")
        XCTAssertEqual(places.first?.start, 1)
        XCTAssertEqual(places.first?.end, 3)
    }

    func testAssistantResultOwnsValidatedJSON() throws {
        let original = NSMutableDictionary(dictionary: ["items": [1, 2, 3], "flag": true, "label": "Пример"])
        let result = try CLICompletion.Result(text: "answer", structured: original, inputTokens: 3, outputTokens: 4, costUSD: nil)
        original["label"] = "changed"
        let object = try XCTUnwrap(result.structured as? [String: Any])
        XCTAssertEqual(object["label"] as? String, "Пример")
        XCTAssertEqual(object["items"] as? [Int], [1, 2, 3])
        XCTAssertEqual(object["flag"] as? Bool, true)
        let fragment = try CLICompletion.Result(text: "", structured: "value", inputTokens: 0, outputTokens: 0, costUSD: nil)
        XCTAssertEqual(fragment.structured as? String, "value")
        XCTAssertThrowsError(try CLICompletion.Result(text: "", structured: Date(), inputTokens: 0, outputTokens: 0, costUSD: nil))
    }

    func testProjectBootstrapPersistsEachStage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-bootstrap-" + UUID().uuidString)
        let specification = folder.appendingPathComponent("specification")
        try FileManager.default.createDirectory(at: specification, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Requirements\n".write(to: specification.appendingPathComponent("requirements.md"), atomically: true, encoding: .utf8)
        var draft = ProjectDraft(idea: "Test project")
        draft.parentPath = folder.path
        draft.folderName = "created-project"
        let recorder = DraftCheckpointRecorder()
        let result = try await ProjectBootstrap.run(&draft, specification: specification, slug: "test-feature", readme: "# Test\n") { saved in
            await recorder.append(saved)
        }
        let checkpoints = await recorder.snapshot()
        XCTAssertEqual(checkpoints.count, 3)
        XCTAssertEqual(checkpoints.map(\.filesWritten), [false, true, true])
        XCTAssertEqual(checkpoints.map(\.gitInitialized), [false, false, true])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent(".git").path))
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("docs/features/test-feature/requirements.md"), encoding: .utf8),
                       "# Requirements\n")
    }

    func testNotificationRouterExposesResponseCallback() {
        let router = ProjectOperationNotificationRouter()
        let selector = NSSelectorFromString("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")
        XCTAssertTrue(router.responds(to: selector), "UserNotifications must be able to call the response handler")
        XCTAssertEqual(ProjectOperationNotificationRouter.destination(for: ["cockpitRoot": "/project", "cockpitRunID": "run"]),
                       .cockpit(root: "/project", runID: "run"))
        XCTAssertEqual(ProjectOperationNotificationRouter.destination(for: ["projectOperationRoot": "/project", "projectOperationID": "build"]),
                       .operation(root: "/project", id: "build"))
        XCTAssertNil(ProjectOperationNotificationRouter.destination(for: ["projectOperationRoot": "/project"]))
    }

    func testParallelSearchScoresAllReadableFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = (0..<64).map { "file-\($0).txt" }
        for (index, name) in names.enumerated() {
            try (index.isMultiple(of: 2) ? "needle" : "unrelated").write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let results = FilterSearch.scoreFiles(names + ["missing.txt"], root: folder, terms: ["needle"])
        XCTAssertEqual(results.count, names.count)
        XCTAssertNil(results["missing.txt"])
        for (index, name) in names.enumerated() {
            XCTAssertEqual((results[name]?.score ?? -1) > 0, index.isMultiple(of: 2), name)
        }
    }

    func testScannerRetainsParallelDocumentAndCodeResults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-scan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<32 {
            try "func check\(index)(_ n: Int) -> Int { if n > 0 { return n }; return 0 }\n"
                .write(to: folder.appendingPathComponent("source\(index).swift"), atomically: true, encoding: .utf8)
            try "# Chapter \(index)\n\nSee source\(index).swift.\n"
                .write(to: folder.appendingPathComponent("chapter\(index).md"), atomically: true, encoding: .utf8)
        }
        let result = ArchitectureScanner(root: folder).run()
        XCTAssertEqual(result.sourceFileCount, 32)
        for index in 0..<32 {
            XCTAssertNotNil(result.metrics["m:source\(index).swift"], "source \(index)")
            XCTAssertTrue(result.docs.nodes.contains { $0.path == "chapter\(index).md" }, "chapter \(index)")
        }
    }

    @MainActor
    func testEditorLoadsDocumentWithScopedWindowParts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-hosted-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("sample.md")
        let text = "# Hosted editor\n\nScoped window parts work.\n"
        try text.write(to: document, atomically: true, encoding: .utf8)
        let workspace = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: folder.appendingPathComponent("recent.json"))
        defer { workspace.windowWillClose() }
        let editor = EditorView(research: workspace.research, insight: workspace.insight, taskBag: workspace.taskBag)
            .observingParts(of: workspace)
            .environmentObject(workspace.theme)
        let hosting = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        workspace.tabs.openDocument(document)

        func findWebView(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            for child in view.subviews { if let found = findWebView(child) { return found } }
            return nil
        }
        var rendered: String?
        for _ in 0..<200 {
            if let webView = findWebView(hosting), !webView.isLoading {
                rendered = try? await webView.callAsyncJavaScript(
                    "return document.querySelector('#editor-input')?.value || '';", arguments: [:], in: nil, contentWorld: .page) as? String
                if rendered == text { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(rendered, text, "The real editor receives the opened document through its scoped dependencies")
        let webView = try XCTUnwrap(findWebView(hosting))
        _ = try await webView.callAsyncJavaScript(
            "window.__observedHeading = ''; window.scrollToHeading = value => { window.__observedHeading = value; };",
            arguments: [:], in: nil, contentWorld: .page)
        let other = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: folder.appendingPathComponent("other-recent.json"))
        defer { other.windowWillClose() }
        NotificationCenter.default.post(.scrollToHeading, for: other, object: "wrong-window")
        try await Task.sleep(nanoseconds: 100_000_000)
        var heading = try await webView.callAsyncJavaScript("return window.__observedHeading;", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(heading, "", "A notification for another window must not reach this editor")
        NotificationCenter.default.post(.scrollToHeading, for: workspace, object: "right-window")
        for _ in 0..<50 {
            heading = try await webView.callAsyncJavaScript("return window.__observedHeading;", arguments: [:], in: nil, contentWorld: .page) as? String
            if heading == "right-window" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(heading, "right-window", "The window's own notification reaches its editor")
    }
    @MainActor
    func testEditorObserverLifetimeRemovesRegistrations() {
        let center = NotificationCenter()
        let name = Notification.Name("EditorObserverLifetime-" + UUID().uuidString)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var observers: NotificationObservers? = NotificationObservers()
        observers?.observe(name, center: center) { _ in calls.withLock { $0 += 1 } }
        center.post(name: name, object: nil)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        observers?.removeAll()
        center.post(name: name, object: nil)
        XCTAssertEqual(calls.withLock { $0 }, 1, "Removed observers must not receive future notifications")
        observers?.observe(name, center: center) { _ in calls.withLock { $0 += 1 } }
        observers = nil
        center.post(name: name, object: nil)
        XCTAssertEqual(calls.withLock { $0 }, 1, "Released observers must not receive future notifications")
    }

    @MainActor
    func testGitHubNavigationDelegateExposesPolicyCallback() {
        let coordinator = GitHubHTMLView.Coordinator()
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        XCTAssertTrue(coordinator.responds(to: selector), "WebKit must be able to call the navigation policy handler")
    }

    @MainActor
    func testDiscussionNavigationDelegateExposesPolicyCallback() {
        let coordinator = DiscussionThreadView.Coordinator()
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        XCTAssertTrue(coordinator.responds(to: selector), "WebKit must be able to call the navigation policy handler")
    }

}
