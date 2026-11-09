import SwiftUI
import AppKit
import QuartzCore

/// The animated backdrop of the welcome screen as a SwiftUI view (REQ-002, REQ-003). It draws nothing itself: `BackdropBuilder` makes
/// the layers and Core Animation moves them.
struct WelcomeBackdropView: NSViewRepresentable {
    /// What to draw; `.shuffle` is resolved by the caller, here it draws nothing.
    let kind: WelcomeBackdrop
    let colors: BackdropColors
    let seed: UInt64
    /// Draw a still picture even when motion is allowed (a check wants to look at the scene).
    var still = false

    func makeNSView(context: Context) -> BackdropHostView { BackdropHostView() }

    func updateNSView(_ view: BackdropHostView, context: Context) {
        view.configure(kind: kind, colors: colors, seed: seed, still: still)
    }
}

/// A layer-hosting view that never takes a mouse event, so the tiles and lists above it work as if it were not there.
final class BackdropHostView: NSView {
    private var kind = WelcomeBackdrop.off
    private var colors: BackdropColors?
    private var seed: UInt64 = 1
    var currentSeed: UInt64 { seed }
    private var still = false
    private(set) var builtSize = CGSize.zero
    private var pendingRebuild: DispatchWorkItem?
    /// How many times the layers were built: a SwiftUI update that changes nothing must not restart the animations.
    private(set) var buildCount = 0
    private var reduceMotionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    required init?(coder: NSCoder) { fatalError("BackdropHostView is made in code") }

    deinit {
        pendingRebuild?.cancel()
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isOpaque: Bool { false }

    var isAnimating: Bool { !still && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func configure(kind: WelcomeBackdrop, colors: BackdropColors, seed: UInt64, still: Bool) {
        guard kind != self.kind || colors != self.colors || seed != self.seed || still != self.still else { return }
        self.kind = kind
        self.colors = colors
        self.seed = seed
        self.still = still
        rebuild()
    }

    /// A window being resized would rebuild every frame: wait until the size has settled. The first build is not delayed.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeMayHaveChanged()
    }

    override func layout() {
        super.layout()
        sizeMayHaveChanged()
    }

    private func sizeMayHaveChanged() {
        guard bounds.size != builtSize else { return }
        if builtSize == .zero {
            rebuild()
            return
        }
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Animations stop when a view leaves its window; a build starts them again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { rebuild() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    private func rebuild() {
        pendingRebuild?.cancel()
        guard let root = layer, let colors else { return }
        builtSize = bounds.size
        buildCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers = nil
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        root.contentsScale = scale
        let builder = BackdropBuilder(size: bounds.size, colors: colors, scale: scale, animated: isAnimating, seed: seed)
        for layer in builder.layers(for: kind) { root.addSublayer(layer) }
        CATransaction.commit()
    }
}
