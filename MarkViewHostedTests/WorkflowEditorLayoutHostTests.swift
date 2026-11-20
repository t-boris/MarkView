import AppKit
import MarkViewCore
import SwiftUI
import XCTest
@testable import MarkView

/// Layout and mouse interaction use the shipping editor, lifecycle coordinator and a temporary project.
final class WorkflowEditorLayoutHostTests: XCTestCase {
    private var temporaryFolders: [URL] = []
    private var stores: [FeatureStore] = []

    @MainActor private func makeStore() -> FeatureStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mv-workflow-host-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporaryFolders.append(folder)
        let workflowURL = ProjectPaths.workflowFile(folder)
        try! FileManager.default.createDirectory(at: workflowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! ProjectWorkflowStore.text(of: .standard).write(to: workflowURL, atomically: true, encoding: .utf8)
        let store = FeatureStore()
        store.setup(root: folder)
        stores.append(store)
        return store
    }

    @MainActor private func check(_ ok: Bool, _ message: String, _ detail: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ok, message + (detail.isEmpty ? "" : " — " + detail), file: file, line: line)
    }

    @MainActor func testRemovingDefaultProcessKeepsWorkflowSavable() {
        let store = makeStore()
        let editor = WorkflowEditorModel()
        editor.attach(to: store)
        let removed = editor.draft.defaultBugVariant
        let remaining = VariantTemplate.directToMain.variant(kind: .bug, id: "local-bug")
        editor.draft.variants.append(remaining)
        editor.expanded.insert(removed)

        XCTAssertFalse(editor.removeProcess(removed, replacementDefault: editor.draft.defaultFeatureVariant))
        XCTAssertTrue(editor.removeProcess(removed))
        XCTAssertEqual(editor.draft.defaultBugVariant, remaining.id)
        XCTAssertTrue(editor.draft.validate().isEmpty)
        XCTAssertFalse(editor.expanded.contains(removed))
        XCTAssertFalse(editor.removeProcess(remaining.id))

        editor.save(in: store)
        XCTAssertFalse(editor.isDirty, editor.message ?? "")
        XCTAssertEqual(store.lifecycle.workflow.defaultBugVariant, remaining.id)
        XCTAssertNil(store.lifecycle.workflow.variant(removed))
    }

    @MainActor func testRemovingDefaultProcessWithSeveralAlternativesRequiresAChoice() {
        let editor = WorkflowEditorModel()
        let removed = editor.draft.defaultFeatureVariant
        let first = VariantTemplate.directToMain.variant(kind: .feature, id: "local-feature")
        let second = VariantTemplate.directToMain.variant(kind: .feature, id: "other-feature")
        editor.draft.variants += [first, second]
        let before = editor.draft

        XCTAssertFalse(editor.removeProcess(removed))
        XCTAssertFalse(editor.removeProcess(removed, replacementDefault: editor.draft.defaultBugVariant))
        XCTAssertEqual(editor.draft, before)

        XCTAssertTrue(editor.removeProcess(removed, replacementDefault: second.id))
        XCTAssertTrue(editor.removeProcess(first.id))
        XCTAssertEqual(editor.draft.defaultFeatureVariant, second.id)
        XCTAssertEqual(editor.draft.defaultBugVariant, before.defaultBugVariant)
        XCTAssertTrue(editor.draft.validate().isEmpty)
    }

@MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

@MainActor func settle(_ hosting: NSView) {
    var previous: [CGRect] = []
    var stable = 0
    for _ in 0..<18 {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let frames = descendants(hosting).map { $0.convert($0.bounds, to: hosting) }
        if !frames.isEmpty && frames == previous {
            stable += 1
            if stable >= 3 { return }
        } else {
            stable = 0
            previous = frames
        }
    }
}

/// Everything a person could see cut off: controls outside the sheet, or a scroll area whose content is wider than the area.
struct Extent { let sheet: CGFloat; let scroll: ClosedRange<CGFloat>?; let document: CGFloat?; let clip: CGFloat?; let controls: ClosedRange<CGFloat>? }

@MainActor func extent(of hosting: NSView) -> Extent {
    let views = descendants(hosting)
    func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: hosting) }
    let area = views.compactMap { $0 as? NSScrollView }.first
    let scroll = area.map(frame)
    let document = area?.documentView.map { frame($0).width }
    let clip = area.map { frame($0.contentView).width }
    let fields = views.filter { $0 is NSTextField || $0 is NSSegmentedControl }.map(frame).filter { $0.width > 0 }
    return Extent(sheet: hosting.bounds.width,
                  scroll: scroll.map { $0.minX...$0.maxX },
                  document: document, clip: clip,
                  controls: fields.isEmpty ? nil : (fields.map(\.minX).min()!)...(fields.map(\.maxX).max()!))
}

/// A workflow at its widest: every transition starts from every status, every actor needs every condition, ids are long, and the
/// project has the processes with transitions of their own.
@MainActor func widest() -> ProjectWorkflow {
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
@MainActor func withProcesses(_ base: ProjectWorkflow, widen: Bool = false) -> ProjectWorkflow {
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

@MainActor func measureTab(_ label: String, workflow: ProjectWorkflow, width: CGFloat, proposal: WorkflowProposal? = nil) {
    let store = makeStore()
    store.lifecycle.workflowProposal = proposal
    let editor = WorkflowEditorModel()
    editor.attach(to: store)
    editor.draft = workflow
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
            let area = all.compactMap { $0 as? NSScrollView }.first
            let scroll = area.map(frame)
            let document = area?.documentView.map { frame($0).width }
            let clip = area.map { frame($0.contentView).width }
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
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let store = makeStore()
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
    func accessibilityText(_ root: NSObject, depth: Int = 0) -> [String] {
        guard depth < 24 else { return [] }
        var values: [String] = []
        for selector in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
            let method = NSSelectorFromString(selector)
            if root.responds(to: method), let text = root.perform(method)?.takeUnretainedValue() as? String { values.append(text) }
        }
        let children = NSSelectorFromString("accessibilityChildren")
        if root.responds(to: children), let found = root.perform(children)?.takeUnretainedValue() as? [NSObject] {
            for child in found { values += accessibilityText(child, depth: depth + 1) }
        }
        return values
    }

    let feature = editor.draft.feature
    // The tab draws the diagram at the zoom that fits the 920 pt it is given.
    let zoom = WorkflowDiagram.zoom(statuses: feature.statuses, rules: feature.rules, available: 920)
    let diagram = WorkflowDiagram(statuses: feature.statuses, rules: feature.rules, width: 920, metrics: WorkflowDiagram.Metrics(zoom: zoom))
    let left: CGFloat = 16   // the tab's padding; the diagram is at its natural size in a 1100 pt tab
    guard let idea = diagram.nodes.first(where: { $0.id == "idea" })?.frame else {
        check(false, "diagram: the standard workflow has an idea state"); return
    }
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
    let startLabels = accessibilityText(hosting)
    check(["WHEN", "WHO", "EVIDENCE"].allSatisfy(startLabels.contains),
          "diagram: a click on an arrow opens its transition and actor evidence")
    snapshot("arrow-start")

    // BUG-115: the card of an arrow holds the settings of the processes that step reads, so a completion has more than a start.
    func stubPoint(_ kind: TransitionKind) -> CGPoint {
        let arrow = diagram.arrows.first { feature.rules[$0.rule].kind == kind }!
        let stub = arrow.branches[0].stub
        return at(CGPoint(x: (stub[0].x + stub[1].x) / 2, y: stub[0].y))
    }
    click(stubPoint(.completion))
    let completionLabels = accessibilityText(hosting)
    snapshot("arrow-completion")
    check(!editor.draft.variants(for: .feature).isEmpty && ["Reaches the branch", "Checks must pass", "Delivery event"].allSatisfy(completionLabels.contains),
          "diagram: the card of a completion arrow holds the delivery settings of the processes (branch, checks, event)")
    click(stubPoint(.acceptance))
    let acceptanceLabels = accessibilityText(hosting)
    snapshot("arrow-acceptance")
    check(acceptanceLabels.contains("Accepted by") && !acceptanceLabels.contains("Delivery event"),
          "diagram: …an acceptance arrow only who accepts")

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
    check(["WHEN", "WHO", "EVIDENCE"].allSatisfy(accessibilityText(hosting).contains), "diagram: …and opens the transition it made")
}

/// Every flow of the picker loaded into the tab (REQ-003): the draft is the flow and unsaved, the tab still lays out, and the Done
/// panel under the diagram says what Done means. With SNAPSHOT_DIR set, each flow's Features page is saved to be looked at.
@MainActor func flows() {
    for flow in WorkflowFlow.catalogue {
        let store = makeStore()
        let editor = WorkflowEditorModel()
        editor.attach(to: store)
        editor.apply(flow)
        check(editor.currentFlow?.id == flow.id && editor.draft.name == flow.title, "\(flow.title): loading it puts its statuses and name in the draft")
        check(flow.id == "markview" || editor.isDirty, "\(flow.title): …as an unsaved change", "dirty \(editor.isDirty)")
        check(editor.message?.contains("Nothing is saved yet") == true && editor.page == .features, "\(flow.title): …and says nothing is saved yet, on the Features page")
        check(editor.draft.validate().isEmpty, "\(flow.title): …and the draft is valid", editor.draft.validate().map(\.message).joined(separator: " | "))

        let hosting = NSHostingView(rootView: WorkflowTabView(store: store, editor: editor))
        let size = NSSize(width: 1100, height: 1500)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        settle(hosting)
        for _ in 0..<2 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("flow-\(flow.id).png"))
        }
        window.close()
        for width in [400, 1100] as [CGFloat] { measureTab("flow \(flow.title)", workflow: flow.applied(to: .standard), width: width) }
    }
}

/// A library over a temporary folder with two usable templates (one asks for GitHub, one asks for nothing), one file that cannot be
/// used, and the plain one chosen for new projects: never the real folder of the app.
@MainActor func sampleLibrary() -> WorkflowTemplateLibrary {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mv-layout-templates-\(UUID().uuidString)", isDirectory: true)
    temporaryFolders.append(folder)
    let store = WorkflowTemplateStore(folder: folder)
    var strict = WorkflowFlow.kanban.applied(to: .standard)
    for index in strict.variants.indices { strict.variants[index].integration = .pullRequest; strict.variants[index].checks = true; strict.variants[index].delivery = .githubRelease }
    _ = try! store.save(name: "Kanban with GitHub", note: "Pull request, CI and release on", workflow: strict)
    let plain = try! store.save(name: "Plain Kanban", note: "Nothing from GitHub", workflow: WorkflowFlow.kanban.applied(to: StandardWorkflow.make(bug: .init(pullRequestRequired: false, checksRequired: false, releaseRequired: false))))
    try! Data("not json".utf8).write(to: folder.appendingPathComponent("broken.json"))
    try! store.setDefault(plain.id)
    let library = WorkflowTemplateLibrary(store: store)
    Task { await library.reload() }
    let deadline = Date().addingTimeInterval(5)
    while !library.loaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return library
}

@MainActor func host<V: View>(_ view: V, size: NSSize, snapshot name: String?) -> (NSHostingView<V>, NSWindow) {
    let hosting = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: size)
    window.orderFrontRegardless()
    settle(hosting)
    for _ in 0..<2 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    if let name, let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    return (hosting, window)
}

/// The picker's list on its own: every flow is there with its columns, the templates of the shared folder come first, the one in use is
/// marked, and nothing runs past the edge.
@MainActor func picker() {
    let store = makeStore()
    let editor = WorkflowEditorModel()
    editor.attach(to: store)
    let library = sampleLibrary()
    var chosen: [String] = []
    var chosenTemplates: [String] = []
    let (hosting, window) = host(WorkflowFlowPicker(editor: editor, library: library, choose: { chosen.append($0.id) }, chooseTemplate: { chosenTemplates.append($0.id) }),
                                 size: NSSize(width: 460, height: 560), snapshot: "flow-picker")
    // SwiftUI buttons are not NSButtons; each one has a focus ring view, as in the inspector checks above.
    let buttons = descendants(hosting).filter { String(describing: type(of: $0)) == "_FocusRingView" }
    // Every flow but the one in use, each template, and "Save as template…".
    check(buttons.count == (WorkflowFlow.catalogue.count - 1) + library.templates.count + 1, "picker: a Use button for every flow but the one in use and for each template, and a Save button (\(buttons.count))")
    check(editor.currentFlow?.id == "markview", "picker: a project on the standard workflow is on MarkView with specification")
    check(library.templates.map(\.name) == ["Kanban with GitHub", "Plain Kanban"] && library.listing.unusable.map(\.file) == ["broken.json"], "picker: the library lists the two templates and names the broken file")
    window.close()

    // Taking a template puts all of it into the draft, processes included, and names it on the Flow button.
    let template = library.templates[0]
    editor.apply(template)
    check(editor.draft.variants == template.workflow.variants && editor.draft.feature == template.workflow.feature && editor.draft.bug == template.workflow.bug,
          "template: loading it replaces states, transitions and processes of the draft")
    check(editor.draft.revision == 1 && editor.message?.contains("Nothing is saved yet") == true && editor.isDirty, "template: …keeps the revision, is unsaved and says so")
    check(library.template(matching: editor.draft)?.id == template.id, "template: the draft is recognised as that template")
    var changed = editor.draft
    changed.variants[0].checks.toggle()
    editor.draft = changed
    check(library.template(matching: editor.draft) == nil, "template: …and no longer once a process is edited")
    editor.draft = template.applied(to: editor.draft)
    let (_, again) = host(WorkflowFlowPicker(editor: editor, library: library, choose: { _ in }, chooseTemplate: { _ in }), size: NSSize(width: 460, height: 560), snapshot: "flow-picker-template-in-use")
    again.close()
    _ = chosen; _ = chosenTemplates
}

/// The Settings part: the templates with what each can do, the choice for new projects and the text that says how to switch the
/// GitHub requirements on.
@MainActor func templateSettings() {
    let library = sampleLibrary()
    let (hosting, window) = host(WorkflowTemplatesSettings(library: library).padding(14).frame(width: 560, alignment: .leading), size: NSSize(width: 560, height: 760), snapshot: "template-settings")
    let buttons = descendants(hosting).filter { String(describing: type(of: $0)) == "_FocusRingView" }
    // Per template: Use/Stop, Reveal, Delete; then the built-in default button (a template is chosen) and Open folder.
    check(buttons.count == library.templates.count * 3 + 2, "settings: each template can be chosen, revealed and deleted, plus the built-in default and the folder (\(buttons.count))")
    window.close()
}

@MainActor func testWorkflowInteraction() {
    defer {
        for store in stores { store.reset() }
        for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
    }
    interaction()
}

@MainActor func testWorkflowLayout() {
    defer {
        for store in stores { store.reset() }
        for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
    }
    flows()
    picker()
    templateSettings()
    for width in [400, 760, 1100] as [CGFloat] {
        measureTab("standard workflow", workflow: .standard, width: width)
        measureTab("with processes", workflow: withProcesses(.standard), width: width)
        measureTab("widest workflow", workflow: widest(), width: width)
        var proposed = withProcesses(.standard)
        let existing = Set(proposed.bug.rules.map(\.id))
        let statuses = proposed.bug.statuses.map(\.id)
        var added = 0
        for from in statuses {
            for to in statuses where from != to && !existing.contains(from + ">" + to) && added < 10 {
                proposed.bug.rules.append(LifecycleRule(from: [from], to: to, kind: .spec, needs: [.human: [], .ai: [], .system: []],
                                                        event: added.isMultiple(of: 2) ? .workStarted : .investigationFinished))
                added += 1
            }
        }
        let proposal = WorkflowProposal(id: UUID(), workflow: proposed,
                                        summary: "Let an AI confirm the installation of a bug and move a bug to review when its investigation finishes, with a long enough sentence to wrap on a narrow tab",
                                        proposedBy: "Claude Code", at: Date(), differences: WorkflowDescription.differences(from: .standard, to: proposed))
        check(proposal.differences.count > 8, "the sample proposal has more changes than the banner shows at first (\(proposal.differences.count))")
        measureTab("with a proposal", workflow: .standard, width: width, proposal: proposal)
    }
}

}
