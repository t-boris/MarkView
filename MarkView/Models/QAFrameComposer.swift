import AppKit
import ImageIO
import CoreText

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
    static func compose(_ pictures: [CGImage?], marks: [Int: QAInputMark] = [:], names: [String] = []) -> CGImage? {
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
            let imageRect = CGRect(x: slot.minX + (slot.width - width) / 2, y: slot.minY + (slot.height - drawn) / 2, width: width, height: drawn)
            context.draw(picture, in: imageRect)
            if let mark = marks[index] { draw(mark, name: names.indices.contains(index) ? names[index] : "Player \(index + 1)", in: imageRect, context: context) }
        }
        return context.makeImage()
    }


    /// The overlay exists only in the composed video, not in the app or the clean review screenshot.
    private static func draw(_ mark: QAInputMark, name: String, in image: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: image)
        let color = mark.failed ? CGColor(srgbRed: 1, green: 0.22, blue: 0.22, alpha: 1)
            : CGColor(srgbRed: 1, green: 0.72, blue: 0.05, alpha: 1)
        if let target = mark.target {
            let box = CGRect(x: image.minX + target.minX * image.width, y: image.maxY - target.maxY * image.height,
                             width: target.width * image.width, height: target.height * image.height)
            let path = CGPath(roundedRect: box.insetBy(dx: -3, dy: -3), cornerWidth: 6, cornerHeight: 6, transform: nil)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.85)); context.setLineWidth(7)
            context.addPath(path); context.strokePath()
            context.setStrokeColor(color); context.setLineWidth(3); context.addPath(path); context.strokePath()
            if mark.kind == .click {
                let ring = CGRect(x: box.midX - 18, y: box.midY - 18, width: 36, height: 36)
                context.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.3)); context.fillEllipse(in: ring)
                context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(7); context.strokeEllipse(in: ring)
                context.setStrokeColor(color); context.setLineWidth(3); context.strokeEllipse(in: ring)
                context.setFillColor(color); context.fillEllipse(in: CGRect(x: box.midX - 4, y: box.midY - 4, width: 8, height: 8))
            }
        }
        if mark.kind == .scroll {
            let x = image.maxX - 48, middle = image.midY
            let tip = middle + (mark.direction == "up" ? 48 : -48)
            let tail = middle - (mark.direction == "up" ? 48 : -48)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.9)); context.setLineWidth(12)
            context.move(to: CGPoint(x: x, y: tail)); context.addLine(to: CGPoint(x: x, y: tip)); context.strokePath()
            context.setStrokeColor(color); context.setLineWidth(6)
            context.move(to: CGPoint(x: x, y: tail)); context.addLine(to: CGPoint(x: x, y: tip)); context.strokePath()
            let back = tip + (mark.direction == "up" ? -18 : 18)
            context.move(to: CGPoint(x: x - 14, y: back)); context.addLine(to: CGPoint(x: x, y: tip))
            context.addLine(to: CGPoint(x: x + 14, y: back)); context.strokePath()
        }
        let label = String(name.prefix(45)) + " · " + mark.label
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: NSColor(cgColor: color) ?? .yellow
        ]))
        let width = min(image.width - 24, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 24)
        let badge = CGRect(x: image.minX + 12, y: image.maxY - 49, width: width, height: 37)
        context.setFillColor(CGColor(gray: 0.04, alpha: 0.94))
        context.addPath(CGPath(roundedRect: badge, cornerWidth: 8, cornerHeight: 8, transform: nil)); context.fillPath()
        context.clip(to: badge.insetBy(dx: 8, dy: 0))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: badge.minX + 12, y: badge.minY + 11)
        CTLineDraw(line, context)
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
