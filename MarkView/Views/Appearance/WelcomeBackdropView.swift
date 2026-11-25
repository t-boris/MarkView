import SwiftUI
import AppKit
import QuartzCore
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The animated backdrop of the welcome screen as a SwiftUI view (REQ-002, REQ-003). It draws nothing itself: `BackdropBuilder` makes
/// the layers and Core Animation moves them.
struct WelcomeBackdropView: NSViewRepresentable {
    /// What to draw; `.shuffle` is resolved by the caller, here it draws nothing.
    let kind: WelcomeBackdrop
    let colors: BackdropColors
    let seed: UInt64
    /// Draw a still picture even when motion is allowed (a check wants to look at the scene).
    var still = false
    var detail = 1

    func makeNSView(context: Context) -> BackdropHostView { BackdropHostView() }

    func updateNSView(_ view: BackdropHostView, context: Context) {
        view.configure(kind: kind, colors: colors, seed: seed, still: still, detail: detail)
    }
}

extension BackdropColors {
    /// The colours a backdrop draws with, taken from the window's theme (REQ-003: a backdrop follows the theme, dark or light).
    init(_ palette: AppPalette) {
        let model = palette.model
        self.init(background: NSColor(model.bg), bright: NSColor(model.textBright), dim: NSColor(model.textDim),
                  green: NSColor(model.green), cyan: NSColor(model.cyan), purple: NSColor(model.purple), blue: NSColor(model.blue),
                  orange: NSColor(model.orange), red: NSColor(model.red), yellow: NSColor(model.yellow), isDark: model.isDark)
    }
}

/// A layer-hosting view that never takes a mouse event, so the tiles and lists above it work as if it were not there.
final class BackdropHostView: NSView {
    private var kind = WelcomeBackdrop.off
    private var colors: BackdropColors?
    private var seed: UInt64 = 1
    var currentSeed: UInt64 { seed }
    var currentKind: WelcomeBackdrop { kind }
    private var still = false
    private var detail = 1
    private(set) var builtSize = CGSize.zero
    /// The scale and the motion setting the layers were built with: a callback that changes neither must not restart the animations.
    private var builtScale: CGFloat = 0
    private var builtAnimated = false
    private var pendingRebuild: Task<Void, Never>?
    /// How many times the layers were built: a SwiftUI update that changes nothing must not restart the animations.
    private(set) var buildCount = 0
    private let observers = NotificationObservers()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
        observers.observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] _ in
            MainActor.assumeIsolated { self?.motionSettingMayHaveChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError("BackdropHostView is made in code") }

    deinit {
        pendingRebuild?.cancel()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isOpaque: Bool { false }

    var isAnimating: Bool { !still && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func configure(kind: WelcomeBackdrop, colors: BackdropColors, seed: UInt64, still: Bool, detail: Int = 1) {
        guard kind != self.kind || colors != self.colors || seed != self.seed || still != self.still || detail != self.detail else { return }
        self.kind = kind
        self.colors = colors
        self.seed = seed
        self.still = still
        self.detail = min(4, max(1, detail))
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
        // task: kept as pendingRebuild and cancelled by the next resize
        pendingRebuild = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    /// Animations stop when a view leaves its window; a build starts them again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { rebuild() }
    }

    /// A colour space change calls this too; only a new scale needs new layers.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if backingScale != builtScale { rebuild() }
    }

    /// The system posts one notification for every display option (contrast, transparency, colours); only Reduce Motion changes the build.
    private func motionSettingMayHaveChanged() {
        if isAnimating != builtAnimated { rebuild() }
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func rebuild() {
        pendingRebuild?.cancel()
        guard let root = layer, let colors else { return }
        builtSize = bounds.size
        builtScale = backingScale
        builtAnimated = isAnimating
        buildCount += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers = nil
        root.contentsScale = builtScale
        let builder = BackdropBuilder(size: bounds.size, colors: colors, scale: builtScale, animated: builtAnimated, seed: seed, detail: detail)
        for layer in builder.layers(for: kind) { root.addSublayer(layer) }
        CATransaction.commit()
    }
}
