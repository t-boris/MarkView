import AppKit
import SwiftUI

// BUG-107: the shipping "Observed file changes" sheet (ProjectChangeReviewSheet) hosted off screen, measured at the sizes a
// person sees it. The file list only names a file; the Before and Current versions must get the rest of the sheet. Run through
// tools/tests/project-change-review-layout-tests.sh, which compiles the real view with the stand-ins below.

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
    init(_ changes: [ProjectChange]) { self.changes = changes }
    func refresh() async {}
    func acknowledge() async {}
}
final class FileNode { let url = URL(fileURLWithPath: "/tmp/project") }
@MainActor final class WorkspaceManager: ObservableObject {
    @Published var rootNode: FileNode? = FileNode()
    func openFile(_ url: URL) {}
}

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message)\(ok || detail.isEmpty ? "" : " — " + detail)")
}

struct Measured { let total: CGFloat; let list: CGFloat; let before: CGFloat; let current: CGFloat }

@MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

@MainActor func measure(_ hosting: NSHostingView<some View>, in window: NSWindow, width: CGFloat, height: CGFloat) -> Measured? {
    window.setContentSize(NSSize(width: width, height: height))
    for _ in 0..<6 {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
    let views = descendants(hosting)
    func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: hosting) }
    // The file list is a SwiftUI List (an AppKit list scroll view); each version sits in a SwiftUI ScrollView.
    guard let list = views.first(where: { String(describing: type(of: $0)).hasPrefix("ListCoreScrollView") }) else { return nil }
    let versions = views.filter { String(describing: type(of: $0)) == "HostingScrollView" }.map(frame).sorted { $0.minX < $1.minX }
    guard versions.count == 2 else { return nil }
    return Measured(total: hosting.bounds.width, list: frame(list).width, before: versions[0].width, current: versions[1].width)
}

@MainActor func run() {
    let sentence = "One file per bug, named `BUG-NNN-<short-kebab-title>.md`, with YAML frontmatter and a long line of words. "
    let text = String(repeating: sentence, count: 20)
    let review = ProjectChangeReview([
        ProjectChange(path: "docs/bugs/README.md", kind: .deleted, before: text, current: nil),
        ProjectChange(path: "docs/notes/another-file.md", kind: .modified, before: "old", current: "new"),
    ])
    let hosting = NSHostingView(rootView: ProjectChangeReviewSheet(review: review).environmentObject(WorkspaceManager()))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 700), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer { window.close() }

    // Where the sheet opens: its ideal size, not the minimum it can shrink to.
    let ideal = hosting.fittingSize
    check(ideal.width >= 900 && ideal.width <= 1300, "the sheet opens wide enough to read two versions (\(Int(ideal.width)) pt)", "ideal width \(ideal.width)")
    check(ideal.height >= 520 && ideal.height <= 900, "...and tall enough to read them (\(Int(ideal.height)) pt)", "ideal height \(ideal.height)")

    // The sizes a person sees it at: as small as it goes, as it opens, and dragged larger.
    for (name, width, height) in [("smallest", CGFloat(760), CGFloat(440)), ("as it opens", min(ideal.width, 1300), min(ideal.height, 900)),
                                  ("enlarged", CGFloat(1600), CGFloat(900))] {
        guard let m = measure(hosting, in: window, width: width, height: height) else {
            check(false, "\(name): the file list and the two versions are on screen"); continue
        }
        let share = (m.before + m.current) / m.total
        print("info  \(name) \(Int(m.total)) pt: list \(Int(m.list)), Before \(Int(m.before)), Current \(Int(m.current)), comparison \(Int(share * 100)) %")
        check(m.list <= 265, "\(name): the file list stays narrow (\(Int(m.list)) pt)", "list \(m.list)")
        check(m.list >= 175, "\(name): the file list is still wide enough to name a file (\(Int(m.list)) pt)", "list \(m.list)")
        check(share >= 0.6, "\(name): the two versions have at least 60 % of the sheet (\(Int(share * 100)) %)", "Before \(m.before), Current \(m.current) of \(m.total)")
        check(m.before >= 235 && m.current >= 235, "\(name): each version is at least 235 pt wide (about 40 monospaced characters)", "Before \(m.before), Current \(m.current)")
        check(abs(m.before - m.current) <= 2, "\(name): Before and Current are equally wide", "Before \(m.before), Current \(m.current)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated { run() }
print(failures == 0 ? "All project change review layout checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
