import AppKit
import os
import MarkViewCore
import SwiftUI
import WebKit
import XCTest
@testable import MarkView

/// The real editor with the real per-window parts, in the isolated app-hosted test build.
final class EditorHostTests: XCTestCase {
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
