import AppKit
import UniformTypeIdentifiers

/// Images the reviewer sends to the assistant in Prototype Studio (pasted, chosen, or a screenshot of a pointed-at
/// element): normalised to PNG, shrunk so a screenshot does not cost more than it shows, and stored next to the
/// prototype where the assistant can open them.
enum PrototypeImages {
    static let maxSide: CGFloat = 1600

    /// PNG data of `image`, scaled down so its longer side is at most `maxSide` pixels.
    static func pngData(from image: NSImage, maxSide: CGFloat = PrototypeImages.maxSide) -> Data? {
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

    /// PNG data of an image file the reviewer chose.
    static func image(at url: URL) -> Data? {
        NSImage(contentsOf: url).flatMap { pngData(from: $0) }
    }

    /// Writes `data` as a new file in `<prototype>/attachments/`.
    static func save(_ data: Data, in prototypeFolder: URL) throws -> URL {
        let dir = prototypeFolder.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString.prefix(8).lowercased() + ".png")
        try data.write(to: url, options: .atomic)
        return url
    }
}
