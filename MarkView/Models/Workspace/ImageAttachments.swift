import AppKit
import Foundation
import UniformTypeIdentifiers

/// An image waiting to be sent with the next request of a request box (Prototype Studio, UI Studio): its PNG data, as it
/// is written to disk, and the picture shown as a thumbnail.
struct ImageAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let image: NSImage
}

/// The images in a request box before the request is sent (REQ-005). A value, so a studio keeps it as one `@Published`
/// property and the shared views edit it through a binding. It enforces the limits of a request: at most
/// `ImageAttachments.maxCount` images, none whose PNG is over `ImageAttachments.maxBytes`; what is refused is named in
/// `notice` instead of being dropped without a word.
struct ImageAttachmentList {
    private(set) var items: [ImageAttachment] = []
    /// One line about the last images that were not added; nil when all were added.
    private(set) var notice: String?

    var isEmpty: Bool { items.isEmpty }

    /// Adds finished PNG images (see `ImageAttachments.pngData`), up to the limits.
    mutating func add(_ pngs: [Data]) {
        var tooMany = 0, tooLarge = 0, unreadable = 0
        for data in pngs {
            if items.count >= ImageAttachments.maxCount {
                tooMany += 1
            } else if data.count > ImageAttachments.maxBytes {
                tooLarge += 1
            } else if let image = NSImage(data: data) {
                items.append(ImageAttachment(data: data, image: image))
            } else {
                unreadable += 1
            }
        }
        var parts: [String] = []
        if tooMany > 0 {
            parts.append("A request takes at most \(ImageAttachments.maxCount) images; \(tooMany) not added.")
        }
        if tooLarge > 0 {
            parts.append((tooLarge == 1 ? "An image is" : "\(tooLarge) images are") + " over \(ImageAttachments.maxBytes / 1_048_576) MB and not added.")
        }
        if unreadable > 0 {
            parts.append(unreadable == 1 ? "An image could not be read." : "\(unreadable) images could not be read.")
        }
        notice = parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Takes the images on the pasteboard; false when there were none (a text paste then goes on as text). True also when
    /// they were all refused, so that the notice, not a paste of their file names, answers the person.
    @discardableResult
    mutating func addFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let images = ImageAttachments.images(on: pasteboard)
        add(images)
        return !images.isEmpty
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        notice = nil
    }

    mutating func removeAll() {
        items = []
        notice = nil
    }
}

/// What the request boxes of Prototype Studio and UI Studio share to take images (REQ-005): normalising a picture to
/// PNG, reading pasteboards, dropped items and files, saving the file a request sends, and a paste of text at the caret.
enum ImageAttachments {
    /// At most this many images go with one request, none over `maxBytes` once normalised.
    static let maxCount = 6
    static let maxBytes = 8 * 1_048_576
    /// An image is scaled down so that its longer side is at most this many pixels: a screenshot must not cost more than it shows.
    static let maxSide: CGFloat = 1600

    /// PNG data of `image`, scaled down so its longer side is at most `maxSide` pixels.
    static func pngData(from image: NSImage, maxSide: CGFloat = ImageAttachments.maxSide) -> Data? {
        guard let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) else { return nil }
        var width = CGFloat(rep.pixelsWide), height = CGFloat(rep.pixelsHigh)
        if width <= 0 || height <= 0 { width = image.size.width; height = image.size.height }
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxSide / max(width, height))
        let target = NSSize(width: max(1, (width * scale).rounded()), height: max(1, (height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = target
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target), from: .zero, operation: .copy, fraction: 1)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// The images on a pasteboard: image data (a screenshot, a copied picture) and image files copied in Finder.
    static func images(on pasteboard: NSPasteboard) -> [Data] {
        var found: [Data] = []
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        for case let url as URL in pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? [] {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let image = NSImage(contentsOf: url), let png = pngData(from: image) else { continue }
            found.append(png)
        }
        if found.isEmpty, let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let png = pngData(from: image) {
            found.append(png)
        }
        return found
    }

    /// PNG data of an image file the person chose.
    static func image(at url: URL) -> Data? {
        NSImage(contentsOf: url).flatMap { pngData(from: $0) }
    }

    /// Reads the images of dropped items, an image file or a picture dragged from an app. `deliver` gets each one's PNG
    /// data as it has been read, on a background thread. False when no item looks like an image, so the drop is refused.
    @discardableResult
    static func load(from providers: [NSItemProvider], deliver: @escaping (Data) -> Void) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                // A file keeps its full resolution; when it is not an image file, the item may still carry a picture.
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, let png = image(at: url) { deliver(png) } else { loadPicture(from: provider, deliver: deliver) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                loadPicture(from: provider, deliver: deliver)
            }
        }
        return accepted
    }

    private static func loadPicture(from provider: NSItemProvider, deliver: @escaping (Data) -> Void) {
        guard provider.canLoadObject(ofClass: NSImage.self) else { return }
        _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
            if let image = object as? NSImage, let png = pngData(from: image) { deliver(png) }
        }
    }

    /// Writes `data` as a new `<8 hex digits>.png` in `folder`, which is made when it is missing. An existing file is never replaced.
    static func save(_ data: Data, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url: URL
        repeat {
            url = folder.appendingPathComponent(UUID().uuidString.prefix(8).lowercased() + ".png")
        } while FileManager.default.fileExists(atPath: url.path)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Pasting text

    /// Puts `text` into `textView` at the caret, in place of the selection, as typing would: the text view tells its
    /// delegate, so a SwiftUI binding on it follows, and the edit can be undone.
    static func insertAtCaret(_ text: String, in textView: NSTextView) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    /// A paste of text into a request box (the box takes the paste command itself, to take images): inserted at the
    /// caret of the focused text view. Only when no text view has the focus, `append` gets the text, to add it to the draft.
    /// Call it on the main thread, as a paste command is.
    static func pasteText(from pasteboard: NSPasteboard = .general, append: (String) -> Void) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        if let textView = NSApp?.keyWindow?.firstResponder as? NSTextView, textView.isEditable {
            insertAtCaret(text, in: textView)
        } else {
            append(text)
        }
    }
}
