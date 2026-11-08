import AppKit
import SwiftUI

// BUG-108: the shipping Workflow tab (WorkflowTabView) hosted off screen (a borderless window far outside the display, never
// shown) and measured at the widths a person may have it: every control and every list must lie inside the tab on every page, in
// the graphical and in the source view, for the standard workflow and for one at its widest (the first form of the bug was a
// transition whose label was wider than its sheet, which cut off the left edge). Run through
// tools/tests/workflow-editor-layout-tests.sh, which compiles the real view and the real workflow model with the stand-ins below.

extension View {
    func uiFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        font(.system(size: size, weight: weight, design: design))
    }
    func uiFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View { font(.system(style)).fontWeight(weight) }
}

/// The part of the coordinator the tab calls; the real one needs a project folder on disk.
@MainActor final class IssueLifecycleCoordinator {
    struct WorkflowSaveReport: Equatable {
        var workflow: ProjectWorkflow
        var failures: [String] = []
    }
    var workflowLoad: WorkflowLoad = .loaded(.standard)
    var workflow: ProjectWorkflow { workflowLoad.effective }
    var workflowStore: ProjectWorkflowStore? { nil }
    func reloadWorkflow() {}
    func workflowImpact(of changed: ProjectWorkflow) -> WorkflowImpact { WorkflowImpact() }
    func saveWorkflow(_ changed: ProjectWorkflow, statusReplacements: [IssueKind: [String: String]] = [:],
                      variantReplacements: [String: String] = [:], by actor: LifecycleActor) -> Result<WorkflowSaveReport, WorkflowStoreError> {
        .success(WorkflowSaveReport(workflow: changed))
    }
}
@MainActor final class FeatureStore: ObservableObject {
    var root: URL? = URL(fileURLWithPath: "/tmp/project")
    var lifecycleActor = "Tester"
    let lifecycle = IssueLifecycleCoordinator()
}

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message)\(ok || detail.isEmpty ? "" : " — " + detail)")
}

@MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

@MainActor func settle(_ hosting: NSView) {
    for _ in 0..<6 {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
}

/// Everything a person could see cut off: controls outside the sheet, or a scroll area whose content is wider than the area.
struct Extent { let sheet: CGFloat; let scroll: ClosedRange<CGFloat>?; let document: CGFloat?; let clip: CGFloat?; let controls: ClosedRange<CGFloat>? }

@MainActor func extent(of hosting: NSView) -> Extent {
    let views = descendants(hosting)
    func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: hosting) }
    let scroll = views.first { String(describing: type(of: $0)) == "HostingScrollView" }.map(frame)
    let document = views.first { String(describing: type(of: $0)) == "DocumentView" }.map { frame($0).width }
    let clip = views.first { String(describing: type(of: $0)) == "HostingClipView" }.map { frame($0).width }
    let fields = views.filter { $0 is NSTextField || $0 is NSSegmentedControl }.map(frame).filter { $0.width > 0 }
    return Extent(sheet: hosting.bounds.width,
                  scroll: scroll.map { $0.minX...$0.maxX },
                  document: document, clip: clip,
                  controls: fields.isEmpty ? nil : (fields.map(\.minX).min()!)...(fields.map(\.maxX).max()!))
}

/// A workflow at its widest: every transition starts from every status, every actor needs every condition, ids are long, and the
/// project has the processes with transitions of their own.
func widest() -> ProjectWorkflow {
    var workflow = ProjectWorkflow.standard
    for kind in [IssueKind.feature, .bug] {
        var definition = workflow.lifecycle(kind)
        definition.statuses = definition.statuses.map { WorkflowStatus(id: $0.id + "-with-a-very-long-status-identifier", role: $0.role) }
        let ids = Set(definition.statuses.map(\.id))
        definition.rules = definition.rules.map { rule in
            var rule = rule
            rule.from = ids
            rule.to = definition.statuses.last?.id ?? rule.to
            for actor in [LifecycleActorKind.human, .ai, .system] { rule.needs[actor] = LifecycleCondition.allCases }
            return rule
        }
        workflow.setLifecycle(kind, definition)
    }
    return withProcesses(workflow, widen: true)
}

/// The processes with transitions of their own: Quick feature, and a bug process from the copy template.
func withProcesses(_ base: ProjectWorkflow, widen: Bool = false) -> ProjectWorkflow {
    var workflow = base
    var quick = ProcessTemplate.quickFeature.variant(kind: .feature, id: ProcessTemplate.quickFeatureID, in: workflow)
    var copy = ProcessTemplate.standardTransitions.variant(kind: .bug, id: "bug-copy", in: workflow)
    if widen {
        for index in (quick.rules ?? []).indices {
            quick.rules![index].from = Set(workflow.feature.statusIDs)
            for actor in [LifecycleActorKind.human, .ai, .system] { quick.rules![index].needs[actor] = LifecycleCondition.allCases }
        }
        quick.name = "A quick feature process with a name that goes on and on and on"
        copy.name = "Copy of the standard bug process with another very long name"
    }
    workflow.variants += [quick, copy]
    return workflow
}

@MainActor func measureTab(_ label: String, workflow: ProjectWorkflow, width: CGFloat) {
    let store = FeatureStore()
    store.lifecycle.workflowLoad = .loaded(workflow)
    let editor = WorkflowEditorModel()
    editor.attach(to: store)
    editor.expanded = [ProcessTemplate.quickFeatureID, "bug-copy"]
    let hosting = NSHostingView(rootView: WorkflowTabView(store: store, editor: editor))
    let size = NSSize(width: width, height: 720)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: size)
    defer { window.close() }

    // The narrowest the tab can be: ask for far less and see what it settles at. The window's centre column is at least 400 pt wide.
    if width == 400 {
        window.setContentSize(NSSize(width: 100, height: 720))
        settle(hosting)
        check(hosting.bounds.width <= 400, "\(label): the tab shrinks to the narrowest centre column of the window, 400 pt (\(Int(hosting.bounds.width)) pt)")
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
    }

    let views: [(String, () -> Void)] = [
        ("Features", { editor.page = .features }),
        ("Bugs", { editor.page = .bugs }),
        ("Processes", { editor.page = .processes }),
        ("Source", { editor.switchMode(.source, store: store) }),
    ]
    for (index, (name, show)) in views.enumerated() {
        show()
        settle(hosting)
        let all = descendants(hosting)
        func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: hosting) }
        let w = hosting.bounds.width
        let name = "\(label) @ \(Int(width)) pt / \(name)"
        // The controls of the header (tab picker, view picker, name field) and every text field of the page.
        let controls = all.filter { $0 is NSTextField || $0 is NSSegmentedControl }.map(frame).filter { $0.width > 0 }
        if let low = controls.map(\.minX).min(), let high = controls.map(\.maxX).max() {
            check(low >= 0 && high <= w, "\(name): every text field and picker lie inside the tab (\(Int(low))…\(Int(high)) of \(Int(w)))")
        } else {
            check(false, "\(name): there are controls on screen")
        }
        if editor.mode == .source {
            let text = all.first { $0 is NSTextView }.map(frame)
            check(text != nil && text!.minX >= 0 && text!.maxX <= w, "\(name): the source text lies inside the tab",
                  text.map { "\(Int($0.minX))…\(Int($0.maxX))" } ?? "no text view")
        } else {
            let scroll = all.first { String(describing: type(of: $0)) == "HostingScrollView" }.map(frame)
            let document = all.first { String(describing: type(of: $0)) == "DocumentView" }.map { frame($0).width }
            let clip = all.first { String(describing: type(of: $0)) == "HostingClipView" }.map { frame($0).width }
            print("info  \(name): scroll \(scroll.map { "\(Int($0.minX))…\(Int($0.maxX))" } ?? "-"), document \(document.map { Int($0) } ?? -1), clip \(clip.map { Int($0) } ?? -1)")
            if let scroll, let document, let clip {
                check(scroll.minX >= 0 && scroll.maxX <= w, "\(name): the list lies inside the tab (\(Int(scroll.minX))…\(Int(scroll.maxX)) of \(Int(w)))")
                check(document <= clip + 0.5, "\(name): the list's content is no wider than the list (\(Int(document)) of \(Int(clip)))")
            } else {
                check(false, "\(name): the list is on screen")
            }
        }
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(label)-\(Int(width))-\(index).png"))
        }
        if editor.mode == .source { editor.switchMode(.visual, store: store) }
    }
}

@MainActor func run() {
    for width in [400, 760, 1100] as [CGFloat] {
        measureTab("standard workflow", workflow: .standard, width: width)
        measureTab("with processes", workflow: withProcesses(.standard), width: width)
        measureTab("widest workflow", workflow: widest(), width: width)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated { run() }
print(failures == 0 ? "All workflow editor layout checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
