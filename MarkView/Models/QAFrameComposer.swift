import AppKit
import ImageIO

// End-to-End QA (feature end-to-end-qa, REQ-009): the picture of a video is the players side by side, each as large as the height allows,
// so a scenario with two players is one recording that shows both of them. Pictures also become the small ones of the live feed.

enum QAFrameComposer {
    static let height = 720
    static let gap = 8
    static let background = CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)

    /// The size every composed picture has for this many players, so a video keeps one size from its first frame to its last.
    static func pictureSize(players: Int) -> CGSize {
        let count = max(1, players)
        return CGSize(width: count * slotWidth + (count - 1) * gap, height: height)
    }

    /// A player's picture, as the page is 1280 × 800.
    static let slotWidth = 1152

    /// The players' latest pictures side by side. A player with no picture yet is a dark slot.
    static func compose(_ pictures: [CGImage?]) -> CGImage? {
        let size = pictureSize(players: pictures.count)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .medium
        for (index, picture) in pictures.enumerated() {
            guard let picture else { continue }
            let slot = CGRect(x: index * (slotWidth + gap), y: 0, width: slotWidth, height: height)
            let scale = min(slot.width / CGFloat(picture.width), slot.height / CGFloat(picture.height))
            let width = CGFloat(picture.width) * scale, drawn = CGFloat(picture.height) * scale
            context.draw(picture, in: CGRect(x: slot.minX + (slot.width - width) / 2, y: slot.minY + (slot.height - drawn) / 2, width: width, height: drawn))
        }
        return context.makeImage()
    }

    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A small copy for the feed.
    static func thumbnail(from data: Data, width: Int = 420) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: width]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
