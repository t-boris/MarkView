import AppKit
import SwiftUI

// BUG-107 and BUG-109: the shipping "Observed file changes" tab (ProjectChangeReviewTab) hosted off screen (a borderless window far
// outside the display, never shown) and measured at the widths a person has it: the file list only names a file and the changes get
// the rest, nothing is wider than the tab, and a long line wraps instead of widening the page. It was a sheet that could not be
// enlarged; as a tab it follows the window. Run through tools/tests/project-change-review-layout-tests.sh, which compiles the real view,
// the real line diff and the real explanation types with the stand-ins below.

extension View {
    func uiFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        font(.system(size: size, weight: weight, design: design))
    }
    func uiFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View { font(.system(style)).fontWeight(weight) }
}
struct ProjectChange: Identifiable {
    enum Kind: String { case added, modified, deleted }
    let path: String
    let kind: Kind
    let before: String?
    let current: String?
    var id: String { path }
}
@MainActor final class ProjectChangeReview: ObservableObject {
    @Published var changes: [ProjectChange]
    @Published var isScanning = false
    @Published var explanations: [String: ChangeExplanation] = [:]
    @Published var explaining: Set<String> = []
    @Published var explanationFailures: [String: String] = [:]
    init(_ changes: [ProjectChange]) { self.changes = changes }
    static func explanationKey(_ change: ProjectChange) -> String { ContentHash.of(change.path + (change.before ?? "") + (change.current ?? "")) }
    func refresh() async {}
    func acknowledge() async {}
    func explain(_ change: ProjectChange, hunks: [DiffHunk]) {}
}
final class FileNode { let url = URL(fileURLWithPath: "/tmp/project") }
@MainActor final class WorkspaceManager: ObservableObject {
    @Published var rootNode: FileNode? = FileNode()
    func openFile(_ url: URL) {}
    func openChangeReview() {}
}

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message)\(ok || detail.isEmpty ? "" : " — " + detail)")
}

@MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

@MainActor func settle(_ hosting: NSView) {
    for _ in 0..<10 {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
}

/// A file of 120 lines with a change every 15 lines, one of them a very long line.
func fixture() -> (before: String, after: String) {
    let before = (1...120).map { "let value\($0) = compute(\($0))" }
    var after = before
    for i in stride(from: 5, to: 120, by: 15) { after[i] = "let value\(i + 1) = recomputed(\(i + 1))" }
    after[50] = "let long = " + String(repeating: "a very long expression that has to wrap instead of widening the page + ", count: 12)
    return (before.joined(separator: "\n") + "\n", after.joined(separator: "\n") + "\n")
}

@MainActor func run() {
    let file = fixture()
    let review = ProjectChangeReview([
        ProjectChange(path: "apps/bf-menubar/Sources/BrokerFabricMenu/ConfigurationWindowModel.swift", kind: .modified, before: file.before, current: file.after),
        ProjectChange(path: "docs/notes/another-file.md", kind: .added, before: nil, current: "new\n"),
    ])
    let hosting = NSHostingView(rootView: ProjectChangeReviewTab(review: review).environmentObject(WorkspaceManager()))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 700), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer { window.close() }

    // The narrowest a window's centre column can be, a normal one, and a very wide one: a tab follows its window.
    for (name, width, height) in [("narrowest centre, 400 pt", CGFloat(400), CGFloat(500)), ("normal, 800 pt", CGFloat(800), CGFloat(640)),
                                  ("wide, 1600 pt", CGFloat(1600), CGFloat(900))] {
        window.setContentSize(NSSize(width: width, height: height))
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        settle(hosting)
        let views = descendants(hosting)
        func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: hosting) }
        guard let list = views.first(where: { String(describing: type(of: $0)).hasPrefix("ListCoreScrollView") }) else {
            check(false, "\(name): the file list is on screen"); continue
        }
        let scrolls = views.filter { String(describing: type(of: $0)) == "HostingScrollView" }.map(frame)
        guard let diff = scrolls.max(by: { $0.height < $1.height }) else { check(false, "\(name): the changes are on screen"); continue }
        let document = views.first { String(describing: type(of: $0)) == "DocumentView" && abs(frame($0).minX - diff.minX) < 2 }.map { frame($0) }
        let clip = views.first { String(describing: type(of: $0)) == "HostingClipView" && abs(frame($0).minX - diff.minX) < 2 }.map { frame($0) }
        let total = hosting.bounds.width
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("review-\(Int(width)).png"))
        }
        print("info  \(name): list \(Int(frame(list).width)), changes \(Int(diff.width)) at x \(Int(diff.minX)), document \(document.map { Int($0.width) } ?? -1) / \(document.map { Int($0.height) } ?? -1), clip \(clip.map { Int($0.width) } ?? -1) / \(clip.map { Int($0.height) } ?? -1)")
        check(frame(list).width >= 145 && frame(list).width <= 265, "\(name): the file list stays narrow (\(Int(frame(list).width)) pt)")
        check(diff.minX >= 0 && diff.maxX <= total + 0.5, "\(name): the changes lie inside the tab (\(Int(diff.minX))…\(Int(diff.maxX)) of \(Int(total)))")
        check(diff.width >= max(190, (total - 265) - 2), "\(name): the changes get all the width the list leaves (\(Int(diff.width)) pt)", "changes \(diff.width) of \(total)")
        if let document, let clip {
            check(document.width <= clip.width + 0.5, "\(name): a long line wraps, the page is no wider than the tab (\(Int(document.width)) of \(Int(clip.width)))")
            check(document.height > clip.height, "\(name): the 8 changes of the file are laid out below the fold, so they scroll (\(Int(document.height)) of \(Int(clip.height)))")
        } else {
            check(false, "\(name): the page and its viewport can be measured")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated { run() }
print(failures == 0 ? "All project change review layout checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
