import AppKit
import WebKit

/// The view that holds a UI Studio page at its scenario's viewport. Its bounds are the viewport and its frame is the
/// viewport times the zoom, so AppKit scales drawing and mouse coordinates together: the page keeps its own
/// `innerWidth`/`innerHeight` and media queries, and a click lands on the element under the pointer at any zoom (PRE-03,
/// REQ-003). `pageZoom` would change the page's CSS viewport instead.
final class StudioZoomContainer: NSView {
    override var isFlipped: Bool { true }
}

/// Keeps a document smaller than the visible area in its middle.
final class StudioCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Scrolls the zoomed page; "fit" (`zoom == nil`) scales the viewport down to the visible area, never above 100 %.
final class StudioPreviewScrollView: NSScrollView {
    let container = StudioZoomContainer()
    private(set) var webView: WKWebView
    var viewport = CGSize(width: 1280, height: 800) { didSet { if viewport != oldValue { applyZoom() } } }
    var zoom: Double? { didSet { if zoom != oldValue { applyZoom() } } }
    /// The scale in effect, reported when it changes (fit follows the window size).
    var onScale: ((Double) -> Void)?
    private(set) var scale: Double = 1

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        contentView = StudioCenteringClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        documentView = container
        attach(webView)
    }

    required init?(coder: NSCoder) { nil }

    func attach(_ next: WKWebView) {
        if webView !== next || next.superview !== container {
            webView.removeFromSuperview()
            webView = next
            next.autoresizingMask = []
            container.addSubview(next)
        }
        applyZoom()
    }

    override func tile() {
        super.tile()
        applyZoom()
    }

    func applyZoom() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let available = contentSize
        let fit = min(1, (available.width - 24) / viewport.width, (available.height - 24) / viewport.height)
        let next = zoom ?? max(0.1, fit)
        let size = NSSize(width: (viewport.width * next).rounded(), height: (viewport.height * next).rounded())
        if container.frame.size != size { container.setFrameSize(size) }
        if container.bounds.size != viewport { container.setBoundsSize(viewport) }
        let frame = CGRect(origin: .zero, size: viewport)
        if webView.frame != frame { webView.frame = frame }
        if next != scale {
            scale = next
            onScale?(next)
        }
    }
}
