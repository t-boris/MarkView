import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The empty strip after the last tab: a tab dropped there goes to the end.
private let tabDropZoneWidth: CGFloat = 40

/// Open tabs: they scroll sideways (trackpad, the plain mouse wheel, or the ‹ › buttons that appear while the tabs do not fit),
/// the active one is kept in view, the ▾ menu on the right lists every tab, and tabs are reordered by dragging.
struct TabBarView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject var workspaceManager: WorkspaceManager
    /// What the ‹ › buttons need to know about this window's strip.
    @StateObject private var scroller = TabStripScroller(endInset: tabDropZoneWidth)
    /// The tab a drag is over (a blue line marks where the dragged tab lands).
    @State private var dropTarget: UUID?

    var body: some View {
        HStack(spacing: 0) {
            homeTab
            if scroller.overflows { scrollButton(.left) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(workspaceManager.openTabs.enumerated()), id: \.element.id) { index, tab in
                            tabItem(tab: tab, index: index).id(tab.id)
                        }
                        // Dropping after the last tab puts the dragged one at the end.
                        Color.clear.frame(width: tabDropZoneWidth, height: 24)
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                drop(providers, before: workspaceManager.openTabs.count)
                            }
                    }
                }
                .background(TabStripScrollHook(scroller: scroller))
                .onChange(of: workspaceManager.activeTabIndex) { _ in revealActiveTab(proxy, animated: true) }
                // The buttons take room from the strip when they appear: keep the active tab in view.
                .onChange(of: scroller.overflows) { _ in revealActiveTab(proxy, animated: false) }
                .onAppear { revealActiveTab(proxy, animated: false) }
            }
            if scroller.overflows { scrollButton(.right) }
            tabsMenu
        }
        .frame(height: 24)
        .background(palette.bg)
        .overlay(Rectangle().frame(height: 1).foregroundColor(palette.border), alignment: .bottom)
    }

    private func revealActiveTab(_ proxy: ScrollViewProxy, animated: Bool) {
        let index = workspaceManager.activeTabIndex
        guard workspaceManager.openTabs.indices.contains(index) else { return }
        let id = workspaceManager.openTabs[index].id
        if animated { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } else { proxy.scrollTo(id) }
    }

    /// A small arrow at one end of the strip; it moves the tabs by most of the visible width and is dimmed once that end is reached.
    private func scrollButton(_ side: TabStripScroller.Side) -> some View {
        let enabled = side == .left ? scroller.canScrollLeft : scroller.canScrollRight
        let name = side == .left ? "left" : "right"
        return Button { scroller.page(side) } label: {
            Image(systemName: "chevron.\(name)")
                .uiFont(size: 9, weight: .semibold)
                .foregroundColor(palette.textDim)
                .opacity(enabled ? 1 : 0.35)
                .frame(width: 18, height: 24)
                .background(palette.bg)
                .overlay(Rectangle().frame(width: 1).foregroundColor(palette.border), alignment: side == .left ? .trailing : .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Show the tabs on the \(name)")
        .accessibilityLabel("Scroll tabs \(name)")
    }

    /// The welcome screen stays pinned even when the other tabs scroll or close.
    private var homeTab: some View {
        let selected = workspaceManager.activeTabIndex == -1
        return Button {
            workspaceManager.activeTabIndex = -1
            workspaceManager.layout.workspaceArea = .files
            workspaceManager.showCenter = true
        } label: {
            Image(systemName: selected ? "house.fill" : "house")
                .uiFont(size: 11)
                .foregroundColor(selected ? palette.blue : palette.textDim)
                .frame(width: 32, height: 24)
                .background(selected ? palette.bgSidebar : palette.bg)
                .overlay(Rectangle().frame(height: 2).foregroundColor(selected ? palette.blue : .clear), alignment: .top)
                .overlay(Rectangle().frame(width: 1).foregroundColor(palette.border), alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Welcome")
        .accessibilityLabel("Welcome")
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
            Image(systemName: "chevron.down").uiFont(size: 9, weight: .semibold)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 24)
        .overlay(Rectangle().frame(width: 1).foregroundColor(palette.border), alignment: .leading)
        .help("All open tabs (\(workspaceManager.openTabs.count))")
    }

    private func icon(for tab: OpenTab) -> String {
        switch tab.kind {
        case .terminal: return "terminal"
        case .architecture(let scope): return scope == TabKind.pullRequestScope ? "arrow.triangle.pull" : "viewfinder"
        case .insight: return "sparkles"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .archive: return "archivebox"
        case .deployments: return "server.rack"
        case .discussions: return "bubble.left.and.text.bubble.right"
        case .workflow: return "arrow.triangle.branch"
        case .git: return "arrow.triangle.branch"
        case .changeReview: return "doc.text.magnifyingglass"
        case .browser: return "globe"
        case .prototype: return "rectangle.on.rectangle.angled"
        case .uiStudio: return "macwindow.and.cursorarrow"
        case .cockpit: return "airplane"
        case .qa: return "checklist.checked"
        case .data:
            switch tab.fileType {
            case .log: return "list.bullet.rectangle"
            case .sqlite: return "cylinder"
            default: return "tablecells"
            }
        case .github(let item):
            if case .run = item { return "gearshape.2" }
            if case .pullRequest = item { return "arrow.triangle.pull" }
            return "smallcircle.filled.circle"
        case .file: return tab.isMarkdown ? "doc.text" : "chevron.left.forwardslash.chevron.right"
        }
    }

    private func tabItem(tab: OpenTab, index: Int) -> some View {
        let isActive = index == workspaceManager.activeTabIndex

        return HStack(spacing: 5) {
            Image(systemName: icon(for: tab))
                .uiFont(size: 10)
                .foregroundColor(isActive ? palette.blue : palette.textDim)

            if tab.isModified {
                Circle()
                    .fill(palette.orange)
                    .frame(width: 6, height: 6)
            }

            Group {
                if case .browser(let session) = tab.kind { BrowserTabTitle(session: session) }
                else { Text(tab.displayName) }
            }
                .uiFont(size: 11)
                .foregroundColor(isActive ? palette.textBright : palette.textDim)
                .lineLimit(1)

            Button(action: { workspaceManager.closeTab(at: index) }) {
                Image(systemName: "xmark")
                    .uiFont(size: 8)
                    .foregroundColor(palette.textDim)
            }
            .buttonStyle(.plain)
            .opacity(isActive ? 1 : 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(height: 24)
        .background(isActive ? palette.bgSidebar : palette.bg)
        .overlay(
            Rectangle().frame(height: 2)
                .foregroundColor(isActive ? palette.blue : Color.clear),
            alignment: .top
        )
        .overlay(Rectangle().frame(width: 1).foregroundColor(palette.border), alignment: .trailing)
        .overlay(Rectangle().frame(width: 2).foregroundColor(dropTarget == tab.id ? palette.blue : Color.clear), alignment: .leading)
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
            // Every file tab goes; Git, Workflow, X-Ray, QA and the other tool tabs stay.
            Button("Close Documents") {
                workspaceManager.closeDocuments()
            }
            .disabled(!workspaceManager.openTabs.contains(where: \.isDocument))
            Button("Close All") {
                workspaceManager.closeAllTabs()
            }
            Divider()
            if tab.isFileBacked && FileType.isHTML(tab.url) {
                Button("Open in Browser") { workspaceManager.openHTMLInBrowser(tab.url) }
            }
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

/// What the ‹ › buttons need from the tab strip: whether there is more to see on either side, and a move by a page. It watches the
/// `NSScrollView` SwiftUI made for the strip (found by `TabStripScrollHook`) and publishes a flag only when it changes, so scrolling
/// does not redraw the bar on every tick. Main thread only.
final class TabStripScroller: ObservableObject {
    enum Side { case left, right }

    @Published private(set) var canScrollLeft = false
    @Published private(set) var canScrollRight = false
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    /// Empty room after the last tab that does not count as something more to see: the right end is reached when only it is hidden.
    private let endInset: CGFloat

    init(endInset: CGFloat = 0) { self.endInset = endInset }

    /// True while the tabs do not all fit.
    var overflows: Bool { canScrollLeft || canScrollRight }

    deinit { detach() }

    func attach(_ scroll: NSScrollView) {
        guard scroll !== scrollView else { return }
        detach()
        scrollView = scroll
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        var watched: [(Notification.Name, NSView)] = [(NSView.boundsDidChangeNotification, clip), (NSView.frameDidChangeNotification, clip)]
        if let document = scroll.documentView {
            document.postsFrameChangedNotifications = true
            watched.append((NSView.frameDidChangeNotification, document))
        }
        observers = watched.map { name, view in
            NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in self?.refresh() }
        }
        refresh()
    }

    func detach() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        scrollView = nil
    }

    private func refresh() {
        guard let scroll = scrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let maxX = lastOffset(document: document, clip: clip)
        let left = clip.bounds.origin.x > 0.5, right = clip.bounds.origin.x < maxX - 0.5
        if left != canScrollLeft { canScrollLeft = left }
        if right != canScrollRight { canScrollRight = right }
    }

    /// The offset at which the last tab is fully in view.
    private func lastOffset(document: NSView, clip: NSClipView) -> CGFloat {
        max(0, document.frame.width - endInset - clip.bounds.width)
    }

    /// Moves the strip by 60% of its visible width (animated), never past either end.
    func page(_ side: Side) {
        guard let scroll = scrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let maxX = lastOffset(document: document, clip: clip)
        let step = clip.bounds.width * 0.6 * (side == .left ? -1 : 1)
        let target = min(max(0, clip.bounds.origin.x + step), maxX)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            clip.animator().setBoundsOrigin(NSPoint(x: target, y: clip.bounds.origin.y))
        }
    }
}

/// Sits behind the tab strip. The plain mouse wheel (vertical) scrolls the enclosing horizontal scroll view sideways while the pointer
/// is over it (trackpad swipes keep working as they do), and the strip's `NSScrollView` is handed to the `TabStripScroller`.
private struct TabStripScrollHook: NSViewRepresentable {
    let scroller: TabStripScroller

    /// A plain view that tells its owner when it has a window or a new size, which is when the strip's scroll view can be found.
    final class HookView: NSView {
        var onChange: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
        override func layout() {
            super.layout()
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = HookView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.scroller = scroller
        view.onChange = { [weak coordinator] in coordinator?.attachIfNeeded() }
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator] event in
            coordinator?.handle(event) ?? event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.scroller = scroller
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in coordinator?.attachIfNeeded() }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.scroller?.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var scroller: TabStripScroller?
        var monitor: Any?

        func attachIfNeeded() {
            guard let view, view.window != nil, let scroller, let scrollView = Self.scrollView(near: view) else { return }
            scroller.attach(scrollView)
        }

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
