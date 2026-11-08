import AppKit
import SwiftUI

// BUG-108: the shipping project workflow editor (WorkflowEditorSheet) hosted off screen (a borderless window far outside the
// display, never shown) and measured: every control must lie inside the sheet at every tab, and the sheet must be no wider than
// the settings window it opens from. Run through tools/tests/workflow-editor-layout-tests.sh, which compiles the real view and the
// real workflow model with the stand-ins below.

extension View {
    func uiFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        font(.system(size: size, weight: weight, design: design))
    }
    func uiFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View { font(.system(style)).fontWeight(weight) }
}

/// The part of the coordinator the sheet calls; the real one needs a project folder on disk.
@MainActor final class IssueLifecycleCoordinator {
    struct WorkflowSaveReport: Equatable {
        var workflow: ProjectWorkflow
        var failures: [String] = []
    }
    var workflowLoad: WorkflowLoad = .loaded(.standard)
    var workflow: ProjectWorkflow { workflowLoad.effective }
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

/// A workflow at its widest: every transition starts from every status, every actor needs every condition, ids are long.
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
    return workflow
}

@MainActor func measureSheet(_ label: String, workflow: ProjectWorkflow) {
    let store = FeatureStore()
    store.lifecycle.workflowLoad = .loaded(workflow)
    let hosting = NSHostingView(rootView: WorkflowEditorSheet(store: store))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 760, height: 700), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    defer { window.close() }

    let ideal = hosting.fittingSize
    window.setContentSize(ideal)
    settle(hosting)
    check(ideal.width <= 760, "\(label): the sheet asks for no more than 760 pt (\(Int(ideal.width)) pt)", "ideal width \(ideal.width)")
    guard let tabs = descendants(hosting).compactMap({ $0 as? NSSegmentedControl }).first else {
        check(false, "\(label): the tab picker is on screen"); return
    }
    for (index, name) in ["Features", "Bugs", "Rule variants"].enumerated() {
        tabs.selectedSegment = index
        if let action = tabs.action { NSApp.sendAction(action, to: tabs.target, from: tabs) }
        settle(hosting)
        let e = extent(of: hosting)
        print("info  \(label) / \(name): sheet \(Int(e.sheet)), scroll \(e.scroll.map { "\(Int($0.lowerBound))…\(Int($0.upperBound))" } ?? "-"), document \(e.document.map { Int($0) } ?? -1), clip \(e.clip.map { Int($0) } ?? -1), fields \(e.controls.map { "\(Int($0.lowerBound))…\(Int($0.upperBound))" } ?? "-")")
        guard let scroll = e.scroll, let document = e.document, let clip = e.clip, let controls = e.controls else {
            check(false, "\(label) / \(name): the list is on screen"); continue
        }
        check(scroll.lowerBound >= 0 && scroll.upperBound <= e.sheet,
              "\(label) / \(name): the list lies inside the sheet (\(Int(scroll.lowerBound))…\(Int(scroll.upperBound)) of \(Int(e.sheet)))")
        check(document <= clip + 0.5, "\(label) / \(name): the list's content is no wider than the list (\(Int(document)) of \(Int(clip)))")
        check(controls.lowerBound >= 0 && controls.upperBound <= e.sheet,
              "\(label) / \(name): every text field and the tab picker lie inside the sheet (\(Int(controls.lowerBound))…\(Int(controls.upperBound)))")
        if let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(label)-\(index).png"))
        }
    }
}

@MainActor func run() {
    measureSheet("standard workflow", workflow: .standard)
    measureSheet("widest workflow", workflow: widest())
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated { run() }
print(failures == 0 ? "All workflow editor layout checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
