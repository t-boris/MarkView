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

/// BUG-112: the diagram answers the mouse. Real mouse events go to the window hosted off screen: a click on a state opens the
/// state's inspector, a click on an arrow opens the transition's, and a drag from one state to another draws an arrow.
@MainActor func interaction() {
    let store = FeatureStore()
    store.lifecycle.workflowLoad = .loaded(.standard)
    let editor = WorkflowEditorModel()
    editor.attach(to: store)
    let hosting = NSHostingView(rootView: WorkflowTabView(store: store, editor: editor))
    let size = NSSize(width: 1100, height: 1500)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: size)
    defer { window.close() }
    // SwiftUI takes gestures only in a window that is on screen; this one is 20000 pt away from every display.
    window.orderFrontRegardless()
    settle(hosting)

    func quick() {
        for _ in 0..<2 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    /// With SNAPSHOT_DIR set, the hosted tab as it looks now is saved, to be looked at.
    func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    func send(_ type: NSEvent.EventType, _ p: CGPoint) {
        let location = hosting.convert(NSPoint(x: p.x, y: p.y), to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        window.sendEvent(event)
    }
    func click(_ p: CGPoint) { send(.leftMouseDown, p); send(.leftMouseUp, p); quick() }
    /// What the inspector below the diagram holds: a state's has a title field, a transition's has none but six menus and a button,
    /// which SwiftUI gives one focus ring each (the menus are no NSPopUpButton).
    func inspector() -> (fields: Int, controls: Int) {
        let views = descendants(hosting)
        return (views.filter { $0 is NSTextField }.count, views.filter { String(describing: type(of: $0)) == "_FocusRingView" }.count)
    }

    let feature = editor.draft.feature
    // The tab draws the diagram at the zoom that fits the 920 pt it is given.
    let zoom = WorkflowDiagram.zoom(statuses: feature.statuses, rules: feature.rules, available: 920)
    let diagram = WorkflowDiagram(statuses: feature.statuses, rules: feature.rules, width: 920, metrics: WorkflowDiagram.Metrics(zoom: zoom))
    let left: CGFloat = 16   // the tab's padding; the diagram is at its natural size in a 1100 pt tab
    let idea = diagram.nodes.first { $0.id == "idea" }!.frame
    guard let field = descendants(hosting).compactMap({ $0 as? NSTextField }).first(where: { ($0.placeholderString ?? "") == "new-status-id" }) else {
        check(false, "diagram: the add-a-state field is on screen"); return
    }
    let base = inspector()
    let top = field.convert(field.bounds, to: hosting).maxY

    // Find the diagram by clicking down the middle of the first state until the state opens.
    var hit: CGFloat?
    for y in stride(from: top, to: top + 300, by: 4) {
        click(CGPoint(x: left + idea.midX, y: y))
        if inspector().fields > base.fields { hit = y; break }
    }
    guard let found = hit else { check(false, "diagram: a click on a state opens its inspector"); return }
    check(inspector().fields == base.fields + 1, "diagram: a click on a state opens its inspector (a title field)", "\(base) -> \(inspector())")
    // The origin of the diagram: the first state's band starts within 4 pt above the first hit.
    let origin = found - idea.minY - 2
    func at(_ p: CGPoint) -> CGPoint { CGPoint(x: left + p.x, y: origin + p.y) }

    click(at(CGPoint(x: diagram.lanes[1].frame.midX, y: 6)))
    check(inspector().fields == base.fields && inspector().controls == base.controls, "diagram: a click on the empty lane closes the inspector", "\(inspector())")

    let start = diagram.arrows.first { feature.rules[$0.rule].kind == .start }!
    let stub = start.branches[0].stub
    click(at(CGPoint(x: (stub[0].x + stub[1].x) / 2, y: stub[0].y)))
    check(inspector().fields == base.fields && inspector().controls >= base.controls + 6,
          "diagram: a click on an arrow opens its transition (from, to, kind, three actors)", "\(base) -> \(inspector())")
    let startControls = inspector().controls
    snapshot("arrow-start")

    // BUG-115: the card of an arrow holds the settings of the processes that step reads, so a completion has more than a start.
    func stubPoint(_ kind: TransitionKind) -> CGPoint {
        let arrow = diagram.arrows.first { feature.rules[$0.rule].kind == kind }!
        let stub = arrow.branches[0].stub
        return at(CGPoint(x: (stub[0].x + stub[1].x) / 2, y: stub[0].y))
    }
    click(stubPoint(.completion))
    let completionControls = inspector().controls
    snapshot("arrow-completion")
    check(!editor.draft.variants(for: .feature).isEmpty && completionControls > startControls,
          "diagram: the card of a completion arrow holds the delivery settings of the processes (branch, checks, event)", "start \(startControls), completion \(completionControls)")
    click(stubPoint(.acceptance))
    snapshot("arrow-acceptance")
    check(inspector().controls >= base.controls + 6 && inspector().controls < completionControls,
          "diagram: …an acceptance arrow only who accepts", "\(inspector().controls) of \(completionControls)")

    // A drag from a state to another draws an arrow: idea has no way to start the work yet.
    click(at(CGPoint(x: diagram.lanes[1].frame.midX, y: 6)))
    let before = editor.draft.feature.rules
    let implementing = diagram.nodes.first { $0.id == "implementing" }!.frame
    let from = at(CGPoint(x: idea.midX, y: idea.midY)), to = at(CGPoint(x: implementing.midX, y: implementing.midY))
    send(.leftMouseDown, from)
    for step in 1...8 {
        let t = CGFloat(step) / 8
        send(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        quick()
    }
    send(.leftMouseUp, to)
    quick()
    let after = editor.draft.feature.rules
    let startRule = after.first { $0.kind == .start && $0.to == "implementing" }
    check(after.count == before.count && startRule?.from.contains("idea") == true,
          "diagram: dragging from a state to another adds the arrow (idea now starts the work)", "\(startRule?.from.sorted() ?? [])")
    check(inspector().fields == base.fields && inspector().controls >= base.controls + 6, "diagram: …and opens the transition it made", "\(inspector())")
}

@MainActor func run() {
    interaction()
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
