import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Before/after comparison (CAP-01, CAP-04): whether two captures are comparable, and their pixel difference. A pixel
/// difference is an aid for review, never a proof that a feature is correct.
enum StudioImageDiff {
    struct Result {
        var image: CGImage
        var changed: Int
        var total: Int
        /// The smallest rectangle holding every changed pixel, in pixels; nil when nothing changed.
        var bounds: CGRect?
        var ratio: Double { total == 0 ? 0 : Double(changed) / Double(total) }
    }

    /// Why two captures cannot be compared fairly; empty when they can (same scenario, contracts and rendering).
    static func incomparability(_ before: StudioCapture, _ after: StudioCapture) -> [String] {
        var reasons: [String] = []
        if before.scenarioId != after.scenarioId { reasons.append("different scenarios (\(before.scenarioId), \(after.scenarioId))") }
        if before.scenarioRevision != after.scenarioRevision { reasons.append("different scenario revisions") }
        if before.contractFingerprint != after.contractFingerprint { reasons.append("different simulated contracts") }
        let a = before.rendering, b = after.rendering
        if a.viewport != b.viewport { reasons.append("viewport \(a.viewport.width)×\(a.viewport.height) vs \(b.viewport.width)×\(b.viewport.height)") }
        if a.devicePixelRatio != b.devicePixelRatio { reasons.append("pixel ratio \(a.devicePixelRatio) vs \(b.devicePixelRatio)") }
        if a.engine != b.engine { reasons.append("browser engine \(a.engine) vs \(b.engine)") }
        if a.os != b.os { reasons.append("system \(a.os) vs \(b.os)") }
        if a.locale != b.locale || a.timeZone != b.timeZone { reasons.append("locale or time zone") }
        if a.colorScheme != b.colorScheme { reasons.append("theme \(a.colorScheme) vs \(b.colorScheme)") }
        if Set(a.fonts) != Set(b.fonts) { reasons.append("loaded fonts") }
        if a.animations != b.animations { reasons.append("animation rules") }
        return reasons
    }

    /// The difference of two pictures of the same size: the after picture faded, changed pixels in magenta. nil when the
    /// sizes differ (they were not taken under the same conditions).
    static func compare(_ before: CGImage, _ after: CGImage, threshold: Int = 24) -> Result? {
        guard before.width == after.width, before.height == after.height, before.width > 0, before.height > 0 else { return nil }
        let width = before.width, height = before.height
        guard let a = rgba(before), let b = rgba(after) else { return nil }
        var output = [UInt8](repeating: 0, count: width * height * 4)
        var changed = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let delta = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])),
                                abs(Int(a[i + 3]) - Int(b[i + 3])))
                if delta > threshold {
                    changed += 1
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    output[i] = 255; output[i + 1] = 0; output[i + 2] = 200; output[i + 3] = 255
                } else {
                    let gray = UInt8((Int(b[i]) * 30 + Int(b[i + 1]) * 59 + Int(b[i + 2]) * 11) / 100)
                    let faded = UInt8(200 + Int(gray) / 5)
                    output[i] = faded; output[i + 1] = faded; output[i + 2] = faded; output[i + 3] = 255
                }
            }
        }
        guard let image = makeImage(output, width: width, height: height) else { return nil }
        let bounds = maxX >= 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
        return Result(image: image, changed: changed, total: width * height, bounds: bounds)
    }

    static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    static func makeImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    @discardableResult
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

/// A feature package exported from UI Studio (CAP-05): what changed, from which code to which, in which scenario and under
/// which rendering, with the captures and the verification. It is kept in `.markview/studio/packages/` and linked from the
/// feature it created; a later change of the files it covers marks it for revalidation (CAP-06).
struct StudioPackage: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case current, revalidationRequired = "revalidation-required" }

    struct Picture: Codable, Equatable {
        var label: String
        var captureId: String
        /// Path relative to the project root.
        var file: String
        /// Copied into the feature's references (small pictures); large ones stay in `.dde/studio/captures/`, out of Git.
        var inFeature: Bool
        var bytes: Int
    }

    var id: String
    var featureSlug: String
    var title: String
    var summary: String
    var created = Date()
    var requests: [String]
    var operations: [String]
    var scenario: StudioScenario
    var baselineRevision: StudioRevision
    var finalRevision: StudioRevision
    /// The hash of every changed file after the change.
    var files: [String: String]
    var patch: String
    var rendering: StudioRendering?
    var pictures: [Picture]
    var checks: [StudioCheck]
    var status: Status = .current
    var changedSince: [String] = []
    var checked: Date? = nil

    /// Pictures up to this size are copied into the feature (and so into Git when the person commits it).
    static let inFeatureLimit = 400_000

    /// The package against the files as they are now.
    func revalidated(root: URL, now: Date = Date()) -> StudioPackage {
        let current = StudioRevisionProbe.currentHashes(Array(files.keys), root: root)
        let changed = files.keys.filter { current[$0] != files[$0] }.sorted()
        var next = self
        next.changedSince = changed
        next.status = changed.isEmpty ? status : .revalidationRequired
        next.checked = now
        return next
    }

    /// The Markdown overview of the feature it creates.
    func overview(redactor: StudioRedactor) -> String {
        var lines = ["## Idea", "", summary, "", "## UI Studio evidence", ""]
        lines.append("- Scenario: \(scenario.name) (`\(scenario.id)`, revision \(scenario.revision)), route `\(scenario.route)`")
        lines.append("- Baseline code revision: `\(baselineRevision.label)`")
        lines.append("- Final code revision: `\(finalRevision.label)`")
        if let rendering {
            lines.append("- Rendering: \(rendering.engine), \(rendering.os), viewport \(rendering.viewport.width)×\(rendering.viewport.height) @\(rendering.devicePixelRatio)x, "
                         + "\(rendering.locale), \(rendering.timeZone), \(rendering.colorScheme), animations \(rendering.animations)")
        }
        lines.append("- Package: `.markview/studio/packages/\(StudioStore.safeID(id)).json` (status: \(status.rawValue))")
        lines += ["", "### Requests", ""] + requests.map { "- " + redactor.redact(text: $0) }
        lines += ["", "### Verification", ""] + (checks.isEmpty ? ["- No checks were recorded."] :
            checks.map { "- [\($0.passed ? "x" : " ")] \($0.name)" + ($0.detail.isEmpty ? "" : " — \(redactor.redact(text: $0.detail))") })
        lines += ["", "### Captures", ""]
        for picture in pictures {
            lines.append(picture.inFeature ? "- \(picture.label): see the attached source picture"
                         : "- \(picture.label): `\(picture.file)` (\(picture.bytes / 1024) KB, kept out of Git)")
        }
        lines += ["", "### Code changes", "", "```diff", redactor.redact(text: patch).trimmingCharacters(in: .newlines), "```", ""]
        return lines.joined(separator: "\n")
    }
}
