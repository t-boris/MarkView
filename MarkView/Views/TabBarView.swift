import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Open tabs: they scroll sideways (trackpad, or the plain mouse wheel), the active one is kept
/// in view, the ▾ menu on the right lists every tab, and tabs are reordered by dragging.
struct TabBarView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    /// The tab a drag is over (a blue line marks where the dragged tab lands).
    @State private var dropTarget: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(workspaceManager.openTabs.enumerated()), id: \.element.id) { index, tab in
                            tabItem(tab: tab, index: index).id(tab.id)
                        }
                        // Dropping after the last tab puts the dragged one at the end.
                        Color.clear.frame(width: 40, height: 24)
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                drop(providers, before: workspaceManager.openTabs.count)
                            }
                    }
                }
                .background(WheelScrollsHorizontally())
                .onChange(of: workspaceManager.activeTabIndex) { index in
                    guard workspaceManager.openTabs.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(workspaceManager.openTabs[index].id) }
                }
                .onAppear {
                    let index = workspaceManager.activeTabIndex
                    if workspaceManager.openTabs.indices.contains(index) { proxy.scrollTo(workspaceManager.openTabs[index].id) }
                }
            }
            tabsMenu
        }
        .frame(height: 24)
        .background(VSDark.bg)
        .overlay(Rectangle().frame(height: 1).foregroundColor(VSDark.border), alignment: .bottom)
    }

    /// Every open tab, also those scrolled out of sight.
    private var tabsMenu: some View {
        Menu {
            ForEach(Array(workspaceManager.openTabs.enumerated()), id: \.element.id) { index, tab in
                Button(action: { workspaceManager.activeTabIndex = index }) {
                    Label((index == workspaceManager.activeTabIndex ? "✓ " : "") + tab.displayName + (tab.isModified ? " •" : ""),
                          systemImage: icon(for: tab))
                }
            }
            if workspaceManager.openTabs.count > 1 {
                Divider()
                Button("Close All") { workspaceManager.closeAllTabs() }
            }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 24)
        .overlay(Rectangle().frame(width: 1).foregroundColor(VSDark.border), alignment: .leading)
        .help("All open tabs (\(workspaceManager.openTabs.count))")
    }

    private func icon(for tab: OpenTab) -> String {
        switch tab.kind {
        case .terminal: return "terminal"
        case .architecture(let scope): return scope == TabKind.pullRequestScope ? "arrow.triangle.pull" : "viewfinder"
        case .insight: return "sparkles"
        case .image: return "photo"
        case .github(let item):
            if case .run = item { return "gearshape.2" }
            return "smallcircle.filled.circle"
        case .file: return tab.isMarkdown ? "doc.text" : "chevron.left.forwardslash.chevron.right"
        }
    }

    private func tabItem(tab: OpenTab, index: Int) -> some View {
        let isActive = index == workspaceManager.activeTabIndex

        return HStack(spacing: 5) {
            Image(systemName: icon(for: tab))
                .font(.system(size: 10))
                .foregroundColor(isActive ? VSDark.blue : VSDark.textDim)

            if tab.isModified {
                Circle()
                    .fill(VSDark.orange)
                    .frame(width: 6, height: 6)
            }

            Text(tab.displayName)
                .font(.system(size: 11))
                .foregroundColor(isActive ? VSDark.textBright : VSDark.textDim)
                .lineLimit(1)

            Button(action: { workspaceManager.closeTab(at: index) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8))
                    .foregroundColor(VSDark.textDim)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(height: 24)
        .background(isActive ? VSDark.bgSidebar : VSDark.bg)
        .overlay(
            Rectangle().frame(height: 2)
                .foregroundColor(isActive ? VSDark.blue : Color.clear),
            alignment: .top
        )
        .overlay(Rectangle().frame(width: 1).foregroundColor(VSDark.border), alignment: .trailing)
        .overlay(Rectangle().frame(width: 2).foregroundColor(dropTarget == tab.id ? VSDark.blue : Color.clear), alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { workspaceManager.activeTabIndex = index }
        .onDrag {
            workspaceManager.activeTabIndex = index
            return NSItemProvider(object: "markview-tab:\(tab.id.uuidString)" as NSString)
        }
        .onDrop(of: [UTType.plainText], isTargeted: Binding(get: { dropTarget == tab.id },
                                                            set: { dropTarget = $0 ? tab.id : (dropTarget == tab.id ? nil : dropTarget) })) { providers in
            drop(providers, before: index)
        }
        .help(relativePath(for: tab))
        .contextMenu {
            Button("Reveal in File Tree") {
                workspaceManager.revealInFileTree(url: tab.url)
            }
            Divider()
            Button("Close") {
                workspaceManager.closeTab(at: index)
            }
            Button("Close Others") {
                workspaceManager.closeOtherTabs(except: index)
            }
            Button("Close Tabs to the Right") {
                workspaceManager.closeTabsToRight(of: index)
            }
            Button("Close All") {
                workspaceManager.closeAllTabs()
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url.path, forType: .string)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(tab.url.path, inFileViewerRootedAtPath: "")
            }
        }
    }

    /// A dragged tab dropped before the tab at `index`.
    private func drop(_ providers: [NSItemProvider], before index: Int) -> Bool {
        dropTarget = nil
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String, text.hasPrefix("markview-tab:"),
                  let id = UUID(uuidString: String(text.dropFirst("markview-tab:".count))) else { return }
            Task { @MainActor in workspaceManager.moveTab(id, to: index) }
        }
        return true
    }

    private func relativePath(for tab: OpenTab) -> String {
        guard let root = workspaceManager.rootNode?.url else { return tab.url.path }
        let rootPath = root.path
        let filePath = tab.url.path
        if filePath.hasPrefix(rootPath) {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return filePath
    }
}

/// The plain mouse wheel (vertical) scrolls the enclosing horizontal scroll view sideways while
/// the pointer is over it; trackpad swipes keep working as they do.
private struct WheelScrollsHorizontally: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event) ?? event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?

        func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let scrollView = Self.scrollView(near: view) else { return event }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(point) else { return event }
            let clip = scrollView.contentView
            let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - clip.bounds.width)
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            var origin = clip.bounds.origin
            origin.x = min(max(0, origin.x - step), maxX)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return nil
        }

        /// The NSScrollView SwiftUI made for the tab row: the one lying where this background
        /// view lies in the window.
        private static func scrollView(near view: NSView) -> NSScrollView? {
            if let own = view.enclosingScrollView { return own }
            let target = view.convert(view.bounds, to: nil)
            var ancestor = view.superview
            for _ in 0..<6 {
                guard let current = ancestor else { break }
                if let found = firstScrollView(in: current, over: target) { return found }
                ancestor = current.superview
            }
            return nil
        }

        private static func firstScrollView(in view: NSView, over target: NSRect) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                let rect = scroll.convert(scroll.bounds, to: nil)
                if rect.intersection(target).width > target.width * 0.8, abs(rect.midY - target.midY) < 6 { return scroll }
            }
            for sub in view.subviews { if let found = firstScrollView(in: sub, over: target) { return found } }
            return nil
        }
    }
}
