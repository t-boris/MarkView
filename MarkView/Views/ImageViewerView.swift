import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An editor tab showing an image (any format ImageIO / NSImage reads: PNG, JPEG, GIF,
/// HEIC, WebP, TIFF, BMP, ICO, SVG, RAW…). Wheel or pinch zooms around the cursor,
/// dragging pans, double-click toggles fit / 100 %. Images dropped on it open in tabs;
/// the handle in the header drags the file out to Finder or another app.
struct ImageViewerView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    let url: URL
    @StateObject private var canvas = ImageCanvasController()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(VSDark.border)
            if let image = canvas.image {
                ImageCanvasRepresentable(image: image, controller: canvas) { urls in
                    urls.forEach { workspaceManager.openFile($0) }
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "photo").font(.system(size: 28)).foregroundColor(VSDark.textDim)
                    Text(canvas.loaded ? "This image format can't be displayed." : "Loading…")
                        .font(.system(size: 11)).foregroundColor(VSDark.textDim)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(VSDark.bg)
        .task(id: url) { await canvas.load(url) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo").font(.system(size: 10)).foregroundColor(VSDark.textDim)
            Text(url.lastPathComponent).font(.system(size: 10, weight: .semibold)).foregroundColor(VSDark.text).lineLimit(1)
            Text(canvas.info).font(.system(size: 10)).foregroundColor(VSDark.textDim).lineLimit(1)
            Spacer()
            if canvas.image != nil {
                iconButton("minus.magnifyingglass", "Zoom out") { canvas.zoom(by: 1 / 1.25) }
                Text("\(Int((canvas.zoom * 100).rounded())) %")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(VSDark.text)
                    .frame(minWidth: 44)
                iconButton("plus.magnifyingglass", "Zoom in") { canvas.zoom(by: 1.25) }
                textButton("Fit", "Fit the image in the window") { canvas.fit() }
                textButton("1:1", "Actual size (one image pixel per screen pixel)") { canvas.actualSize() }
            }
            if url.pathExtension.lowercased() == "svg" {
                textButton("Source", "Open the SVG as XML text") { workspaceManager.openImageAsText(url) }
            }
            Image(systemName: "hand.draw")
                .font(.system(size: 11)).foregroundColor(VSDark.textDim)
                .padding(3)
                .contentShape(Rectangle())
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help("Drag the image file to Finder or another app")
            iconButton("folder", "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(VSDark.bgSidebar)
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundColor(VSDark.textDim)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func textButton(_ title: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundColor(VSDark.text)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(VSDark.border.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The loaded image and the zoom state shown in the header; commands go to the canvas.
@MainActor
final class ImageCanvasController: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var loaded = false
    @Published private(set) var info = ""
    /// 1 = one image pixel per screen pixel.
    @Published var zoom: CGFloat = 1
    weak var canvas: ImageCanvasView?

    func load(_ url: URL) async {
        loaded = false
        // Read off the main thread; NSImage decodes lazily when drawn.
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        let image = data.flatMap { NSImage(data: $0) }
        var parts: [String] = []
        if let image {
            let pixels = ImageCanvasView.pixelSize(of: image)
            parts.append("\(Int(pixels.width)) × \(Int(pixels.height))")
        }
        if let data {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
        }
        if let type = UTType(filenameExtension: url.pathExtension)?.localizedDescription {
            parts.append(type)
        }
        self.image = image
        self.info = parts.joined(separator: " · ")
        loaded = true
    }

    func zoom(by factor: CGFloat) { canvas?.zoom(by: factor, around: nil) }
    func fit() { canvas?.fit() }
    func actualSize() { canvas?.actualSize() }
}

private struct ImageCanvasRepresentable: NSViewRepresentable {
    let image: NSImage
    let controller: ImageCanvasController
    let openFiles: ([URL]) -> Void

    func makeNSView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView()
        view.onZoomChange = { [weak controller] zoom in controller?.zoom = zoom }
        view.onDropFiles = openFiles
        view.image = image
        controller.canvas = view
        return view
    }

    func updateNSView(_ view: ImageCanvasView, context: Context) {
        if view.image !== image { view.image = image }
        view.onDropFiles = openFiles
        controller.canvas = view
    }
}

/// Pan and zoom surface for one image. The image is an `NSImageView` (animated GIFs
/// play) framed at `origin` with size `pixelSize × scale`.
final class ImageCanvasView: NSView {
    var image: NSImage? {
        didSet {
            imageView.image = image
            fitting = true
            needsLayout = true
        }
    }
    var onZoomChange: ((CGFloat) -> Void)?
    var onDropFiles: (([URL]) -> Void)?

    private let imageView = NSImageView()
    /// Points per image pixel.
    private var scale: CGFloat = 1
    /// Bottom-left corner of the image in view coordinates.
    private var origin: CGPoint = .zero
    /// Keep fitting the window until the user zooms or pans.
    private var fitting = true
    private var dragStart: NSPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.isEditable = false
        imageView.unregisterDraggedTypes()
        addSubview(imageView)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Size in pixels: the largest bitmap representation, else the image's own size (SVG, PDF).
    static func pixelSize(of image: NSImage) -> CGSize {
        var best = CGSize.zero
        for rep in image.representations where rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            if rep.pixelsWide * rep.pixelsHigh > Int(best.width * best.height) {
                best = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
        }
        return best == .zero ? image.size : best
    }

    private var pixelSize: CGSize {
        guard let image else { return .zero }
        let size = Self.pixelSize(of: image)
        return CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    /// Screen pixels per point, so 100 % shows one image pixel per screen pixel.
    private var backing: CGFloat { window?.backingScaleFactor ?? 2 }

    // MARK: - Zoom and pan

    override func layout() {
        super.layout()
        if fitting { fit() } else { apply() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        apply()
    }

    /// The whole image in view (never enlarged past 100 %), centred.
    func fit() {
        guard image != nil, bounds.width > 0, bounds.height > 0 else { return }
        let size = pixelSize
        let margin: CGFloat = 16
        let available = CGSize(width: max(bounds.width - 2 * margin, 20), height: max(bounds.height - 2 * margin, 20))
        scale = min(available.width / size.width, available.height / size.height, 1 / backing)
        center()
        fitting = true
        apply()
    }

    func actualSize() {
        zoom(to: 1 / backing, around: nil)
    }

    func zoom(by factor: CGFloat, around point: NSPoint?) {
        zoom(to: scale * factor, around: point)
    }

    private func zoom(to newScale: CGFloat, around point: NSPoint?) {
        guard image != nil else { return }
        let clamped = min(max(newScale, 0.01 / backing), 64 / backing)
        let anchor = point ?? NSPoint(x: bounds.midX, y: bounds.midY)
        // Keep the image point under the anchor where it is.
        let imagePoint = CGPoint(x: (anchor.x - origin.x) / scale, y: (anchor.y - origin.y) / scale)
        scale = clamped
        origin = CGPoint(x: anchor.x - imagePoint.x * scale, y: anchor.y - imagePoint.y * scale)
        fitting = false
        apply()
    }

    private func center() {
        let size = pixelSize
        origin = CGPoint(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2)
    }

    private func pan(dx: CGFloat, dy: CGFloat) {
        origin.x += dx
        origin.y += dy
        fitting = false
        apply()
    }

    private func apply() {
        let size = pixelSize
        imageView.frame = CGRect(origin: origin, size: CGSize(width: size.width * scale, height: size.height * scale))
        needsDisplay = true
        onZoomChange?(scale * backing)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1).setFill()
        bounds.fill()
        guard image != nil else { return }
        // Checkerboard under the image so transparency is visible.
        let frame = imageView.frame
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: frame).addClip()
        let tile: CGFloat = 8
        NSColor(white: 0.32, alpha: 1).setFill()
        frame.fill()
        NSColor(white: 0.24, alpha: 1).setFill()
        let startX = floor(frame.minX / tile), startY = floor(frame.minY / tile)
        var row = startY
        while row * tile < min(frame.maxY, dirtyRect.maxY) {
            var column = startX
            while column * tile < min(frame.maxX, dirtyRect.maxX) {
                if Int(row + column) % 2 == 0 { NSRect(x: column * tile, y: row * tile, width: tile, height: tile).fill() }
                column += 1
            }
            row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Events

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The canvas handles every event; the image view only draws.
        frame.contains(point) ? self : nil
    }

    /// Wheel zooms around the cursor, ⇧+wheel pans (as in the canvas viewer).
    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.shift) {
            let step: CGFloat = precise ? 1 : 12
            pan(dx: event.scrollingDeltaX * step, dy: -event.scrollingDeltaY * step)
            return
        }
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        let factor = exp(delta * (precise ? 0.01 : 0.08))
        zoom(by: factor, around: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if fitting { zoom(to: 1 / backing, around: point) } else { fit() }
            return
        }
        dragStart = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        pan(dx: point.x - start.x, dy: point.y - start.y)
        dragStart = point
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoom(by: 1.25, around: nil)
        case "-": zoom(by: 1 / 1.25, around: nil)
        case "0": fit()
        case "1": actualSize()
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Drop images to open them

    private func imageURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { FileType.isOpenable($0) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }
}
