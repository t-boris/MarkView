import AppKit
import SwiftUI
import XCTest
import MarkViewCore
@testable import MarkView

private struct GraphProbePrompts: UserPrompts {
    func ask(_ prompt: UserPrompt) -> Int? { nil }
}

/// Optional real-project probes receive TEST_RUNNER_MARKVIEW_GRAPH_PROFILE_ROOT or TEST_RUNNER_MARKVIEW_TOC_PROFILE_ROOT
/// from xcodebuild; the accessibility checks use temporary synthetic documents and run without either variable.
final class GraphPerformanceProbe: XCTestCase {
    @MainActor func testContentsAccessibilityAndSelection() async throws {
        let headings = (0..<120).map { HeadingItem(id: "heading-\($0)", level: 1, text: "Fixture heading \($0)") }
        let tab = OpenTab(url: URL(fileURLWithPath: "/tmp/toc-accessibility.md"), content: "", originalContent: "", headings: headings)
        let scroll = DocumentScrollSideTable()
        var selected: String?
        let hosting = NSHostingView(rootView: TOCHeadingsListView(tab: tab, scrollState: scroll, onSelectHeading: { selected = $0 }))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 350, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 350, height: 700)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        var labels: [String] = []
        var last: NSObject?
        func walk(_ element: NSObject, depth: Int = 0) {
            guard depth < 24 else { return }
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let name = NSSelectorFromString(selector)
                if element.responds(to: name), let value = element.perform(name)?.takeUnretainedValue() as? String {
                    labels.append(value)
                    if value.contains("Fixture heading 119"), element.responds(to: NSSelectorFromString("accessibilityPerformPress")) { last = element }
                }
            }
            let actionNames = NSSelectorFromString("accessibilityActionNames")
            if element.responds(to: actionNames), let actions = element.perform(actionNames)?.takeUnretainedValue() as? [String] {
                for action in ["AXScrollToBottom", "AXScrollToTop"] where actions.contains(action) {
                    element.perform(NSSelectorFromString("accessibilityPerformAction:"), with: action)
                }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if element.responds(to: children), let values = element.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for child in values { walk(child, depth: depth + 1) }
            }
        }
        walk(hosting)
        XCTAssertTrue(labels.contains { $0.contains("Fixture heading 0") })
        let button = try XCTUnwrap(last, "The last heading must be reachable by accessibility.")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(button.method(for: selector))
        let press = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        XCTAssertTrue(press(button, selector))
        XCTAssertEqual(selected, "heading-119")
    }

    @MainActor func testOpenContentsOnProjectDocument() async throws {
        guard let path = ProcessInfo.processInfo.environment["MARKVIEW_TOC_PROFILE_ROOT"], !path.isEmpty else {
            throw XCTSkip("Set MARKVIEW_TOC_PROFILE_ROOT to run the local profiling probe.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let contents = await Task.detached { () -> String in
            var best = ""
            var maxHeadings = 0
            for relative in BackgroundFileScans.markdownPaths(in: root) {
                let url = root.appendingPathComponent(relative)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5_000_000,
                      let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let count = text.components(separatedBy: "\n").filter { line in
                    let hashes = line.prefix { $0 == "#" }.count
                    return (1...6).contains(hashes) && line.dropFirst(hashes).first == " "
                }.count
                if count > maxHeadings { maxHeadings = count; best = text }
            }
            return best
        }.value
        let headings: [HeadingItem] = contents.split(separator: "\n").enumerated().compactMap { index, line in
            let hashes = line.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
            let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return HeadingItem(id: "heading-\(index)", level: hashes, text: text)
        }
        XCTAssertGreaterThan(headings.count, 100)
        let lastHeading = try XCTUnwrap(headings.last).text
        let tab = OpenTab(url: URL(fileURLWithPath: "/tmp/graph-profile.md"), content: "", originalContent: "", headings: headings)
        let scroll = DocumentScrollSideTable()
        var maxInterval = 0.0
        var lastTick = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            maxInterval = max(maxInterval, (now - lastTick) * 1000)
            lastTick = now
        }
        timer.resume()
        defer { timer.cancel() }
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        print("TOC_PROFILE_START headings=\(headings.count)")
        for iteration in 0..<5 {
            let hosting = NSHostingView(rootView: TOCHeadingsListView(tab: tab, scrollState: scroll, onSelectHeading: { _ in }))
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 350, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 350, height: 700)
            window.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 500_000_000)
            if iteration == 4 {
                timer.cancel()
                func containsLast(_ element: NSObject, depth: Int = 0) -> Bool {
                    guard depth < 24 else { return false }
                    for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                        let name = NSSelectorFromString(selector)
                        if element.responds(to: name), let value = element.perform(name)?.takeUnretainedValue() as? String,
                           value.contains(lastHeading) { return true }
                    }
                    let children = NSSelectorFromString("accessibilityChildren")
                    guard element.responds(to: children), let values = element.perform(children)?.takeUnretainedValue() as? [NSObject] else { return false }
                    return values.contains { containsLast($0, depth: depth + 1) }
                }
                XCTAssertTrue(containsLast(hosting), "The last heading must be accessible before the timing is accepted.")
            }
            window.orderOut(nil)
            window.close()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("TOC_PROFILE_MAX_INTERVAL_MS \(String(format: "%.1f", maxInterval))")
    }

    @MainActor func testDocumentListAccessibilityAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-a11y-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<120 {
            let file = root.appendingPathComponent(String(format: "fixture-%03d.md", index))
            try "# Fixture\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let manager = WorkspaceManager(prompts: GraphProbePrompts())
        manager.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let view = GraphCreatorSheet(workspaceManager: manager, isPresented: .constant(true)).environmentObject(manager.tabs)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 550), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 550)
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        var labels: [String] = []
        var last: NSObject?
        func walk(_ element: NSObject, depth: Int = 0) {
            guard depth < 24 else { return }
            for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let name = NSSelectorFromString(selector)
                if element.responds(to: name), let value = element.perform(name)?.takeUnretainedValue() as? String {
                    labels.append(value)
                    if value.contains("fixture-119.md"), element.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                        last = element
                    }
                }
            }
            let actionNames = NSSelectorFromString("accessibilityActionNames")
            if element.responds(to: actionNames), let actions = element.perform(actionNames)?.takeUnretainedValue() as? [String] {
                for action in ["AXScrollToBottom", "AXScrollToTop"] where actions.contains(action) {
                    element.perform(NSSelectorFromString("accessibilityPerformAction:"), with: action)
                }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if element.responds(to: children), let values = element.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for child in values { walk(child, depth: depth + 1) }
            }
        }
        walk(hosting)
        XCTAssertTrue(labels.contains { $0.contains("fixture-000.md") }, "Accessibility labels: \(labels.prefix(25))")
        let button = try XCTUnwrap(last, "The last document must be reachable by accessibility; labels: \(labels.prefix(25))")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(button.method(for: selector))
        let press = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        XCTAssertTrue(press(button, selector))
        try await Task.sleep(nanoseconds: 200_000_000)
        labels.removeAll()
        walk(hosting)
        XCTAssertTrue(labels.contains { $0.contains("1 selected") }, "Accessibility selection must update the graph's selection.")
    }

    @MainActor func testOpenGraphCreatorOnProject() async throws {
        guard let path = ProcessInfo.processInfo.environment["MARKVIEW_GRAPH_PROFILE_ROOT"], !path.isEmpty else {
            throw XCTSkip("Set MARKVIEW_GRAPH_PROFILE_ROOT to run the local profiling probe.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let files = await Task.detached { BackgroundFileScans.markdownPaths(in: root) }.value
        XCTAssertGreaterThan(files.count, 100)
        let lastFile = try XCTUnwrap(files.last)
        let manager = WorkspaceManager(prompts: GraphProbePrompts())
        manager.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        var maxInterval = 0.0
        var lastTick = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            maxInterval = max(maxInterval, (now - lastTick) * 1000)
            lastTick = now
        }
        timer.resume()
        defer { timer.cancel() }
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        print("GRAPH_PROFILE_START files=\(files.count)")
        for iteration in 0..<5 {
            let content = GraphCreatorSheet(workspaceManager: manager, isPresented: .constant(true)).environmentObject(manager.tabs)
            let hosting = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 500, height: 550), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 550)
            window.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 800_000_000)
            if iteration == 4 {
                timer.cancel()
                func containsLast(_ element: NSObject, depth: Int = 0) -> Bool {
                    guard depth < 24 else { return false }
                    for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                        let name = NSSelectorFromString(selector)
                        if element.responds(to: name), let value = element.perform(name)?.takeUnretainedValue() as? String,
                           value.contains(lastFile) { return true }
                    }
                    let children = NSSelectorFromString("accessibilityChildren")
                    guard element.responds(to: children), let values = element.perform(children)?.takeUnretainedValue() as? [NSObject] else { return false }
                    return values.contains { containsLast($0, depth: depth + 1) }
                }
                XCTAssertTrue(containsLast(hosting), "The document list must be loaded before the timing is accepted.")
            }
            window.orderOut(nil)
            window.close()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("GRAPH_PROFILE_MAX_INTERVAL_MS \(String(format: "%.1f", maxInterval))")
    }
    @MainActor func testLargeProjectActionTimings() async throws {
        guard let path = ProcessInfo.processInfo.environment["MARKVIEW_ACTION_PROFILE_ROOT"], !path.isEmpty else {
            throw XCTSkip("Set MARKVIEW_ACTION_PROFILE_ROOT to run the local profiling probe.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let foundDocument = await Task.detached { () -> URL? in
            BackgroundFileScans.markdownPaths(in: root).compactMap { relative -> (URL, Int)? in
                let url = root.appendingPathComponent(relative)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 5_000_000 else { return nil }
                return (url, size)
            }.max { $0.1 < $1.1 }?.0
        }.value
        let document = try XCTUnwrap(foundDocument)
        let suite = "action-profile-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("action-profile-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let context = ProjectContext(prompts: NoPrompts(), recentFilesURL: temp, settings: Settings(defaults))
        let tabs = TabsController(prompts: NoPrompts())
        defer { tabs.shutdown() }
        var action = "idle"
        var largest: [String: Double] = [:]
        var lastTick = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            largest[action] = max(largest[action] ?? 0, (now - lastTick) * 1000)
            lastTick = now
        }
        timer.resume()
        defer { timer.cancel() }
        try await Task.sleep(nanoseconds: 200_000_000)
        action = "tree-load"
        for _ in 0..<3 {
            let loaded = await context.loadTree(of: root)
            XCTAssertTrue(loaded)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(context.rootNode)
        action = "document-open"
        for _ in 0..<3 {
            await tabs.openTextFile(document)
            XCTAssertEqual(tabs.openTabs.count, 1)
            tabs.removeTab(at: 0)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        action = "idle"
        print("ACTION_PROFILE tree-load_ms=\(String(format: "%.1f", largest["tree-load"] ?? 0)) document-open_ms=\(String(format: "%.1f", largest["document-open"] ?? 0))")
    }

}
