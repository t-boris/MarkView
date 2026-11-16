import AppKit
import XCTest
@testable import MarkView

/// Exercise the shipping control runner and window registry in the isolated host.
final class ControlToolRunnerTests: XCTestCase {
    @MainActor
    func testRoutesControlRequestsToTheSelectedRealWorkspace() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markview-control-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: folder.appendingPathComponent("first.json"))
        let second = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: folder.appendingPathComponent("second.json"))
        let firstWindow = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 100, height: 100),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        let secondWindow = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 100, height: 100),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        firstWindow.title = "First test window"
        secondWindow.title = "Second test window"
        first.hostWindow = firstWindow
        second.hostWindow = secondWindow
        let firstID = UUID()
        let secondID = UUID()
        AgentToolServer.register(firstID, AgentToolWindow(workspace: { first }, root: { nil }))
        AgentToolServer.register(secondID, AgentToolWindow(workspace: { second }, root: { nil }))
        defer {
            AgentToolServer.unregister(firstID)
            AgentToolServer.unregister(secondID)
            first.windowWillClose()
            second.windowWillClose()
        }
        let caller = ControlToolRunner.Caller(pids: [], folder: folder.path)
        let list = await ControlToolRunner.run("markview_windows", [:], caller: caller)
        XCTAssertFalse(list.isError)
        XCTAssertTrue(list.text.contains("First test window"))
        XCTAssertTrue(list.text.contains("Second test window"))
        let chosen = try ControlToolRunner.window(["window": secondID.uuidString], caller: caller)
        XCTAssertEqual(chosen.id, secondID)
        XCTAssertTrue((chosen.workspace as AnyObject) === second)
        let ambiguous = await ControlToolRunner.run("markview_agents", [:], caller: caller)
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.text.contains("Several windows"))
        let missing = await ControlToolRunner.run("markview_agents", ["window": "missing-window"], caller: caller)
        XCTAssertTrue(missing.isError)
    }
}
