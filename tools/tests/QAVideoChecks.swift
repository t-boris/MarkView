import AVFoundation
import AppKit
import CoreGraphics
import CoreText
import Foundation

// Checks for MarkView/Models/QAVideoWriter.swift (feature end-to-end-qa), run by tools/tests/qa-video-tests.sh.
// Every video is written to a temp folder and read back with AVAssetReader, so the checks see what a player would see. All drawing
// is offscreen: no window is opened and no Screen Recording permission is needed.

var failures = 0

func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}

// MARK: - Pictures

struct RGB { let r: Int, g: Int, b: Int }

let red = RGB(r: 200, g: 40, b: 40)
let green = RGB(r: 40, g: 160, b: 60)
let blue = RGB(r: 40, g: 80, b: 200)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func cgColor(_ c: RGB) -> CGColor { CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1) }

/// A picture of one colour, or with `top` on its upper half and `bottom` on its lower half.
func picture(_ width: Int, _ height: Int, top: RGB, bottom: RGB? = nil) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
    context.setFillColor(cgColor(bottom ?? top))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(cgColor(top))
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))   // the context origin is bottom left
    return context.makeImage()!
}

// MARK: - Reading a video back

struct Frame {
    let time: Double
    let width: Int
    let height: Int
    let bytes: [UInt8]   // BGRA, tightly packed, first row = top of the picture

    func pixel(_ x: Int, _ y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(r: Int(bytes[i + 2]), g: Int(bytes[i + 1]), b: Int(bytes[i]))
    }
}

/// A rectangle of pixels; `x1` and `y1` are exclusive. Rows count from the top of the video.
struct Region {
    let x0: Int, y0: Int, x1: Int, y1: Int
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
}

struct Video {
    var playable = false
    var videoTracks = 0
    var size = CGSize.zero
    var duration = 0.0
    var times: [Double] = []          // presentation time of every frame, in order
    var frames: [Int: Frame] = [:]    // the frames asked for, by index
}

/// Decodes the file at `url`; keeps the pixels of the frames listed in `keep` (all of them when nil).
func readVideo(_ url: URL, keep: [Int]? = nil) async throws -> Video {
    let asset = AVURLAsset(url: url)
    var video = Video()
    video.playable = try await asset.load(.isPlayable)
    video.duration = try await asset.load(.duration).seconds
    let tracks = try await asset.loadTracks(withMediaType: .video)
    video.videoTracks = tracks.count
    guard let track = tracks.first else { return video }
    video.size = try await track.load(.naturalSize)

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "qa-video-checks", code: 1) }
    var index = 0
    while let sample = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        video.times.append(time)
        if keep == nil || keep!.contains(index), let buffer = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0..<height {
                bytes.withUnsafeMutableBufferPointer { $0.baseAddress!.advanced(by: row * width * 4).update(from: base.advanced(by: row * rowBytes), count: width * 4) }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            video.frames[index] = Frame(time: time, width: width, height: height, bytes: bytes)
        }
        index += 1
    }
    return video
}

// MARK: - Measuring pixels

func count(_ frame: Frame, _ region: Region, where predicate: (RGB) -> Bool) -> Int {
    var n = 0
    for y in region.y0..<region.y1 { for x in region.x0..<region.x1 where predicate(frame.pixel(x, y)) { n += 1 } }
    return n
}

func fraction(_ frame: Frame, _ region: Region, where predicate: (RGB) -> Bool) -> Double {
    Double(count(frame, region, where: predicate)) / Double(max(1, region.width * region.height))
}

func near(_ color: RGB, tolerance: Int = 16) -> (RGB) -> Bool {
    { abs($0.r - color.r) <= tolerance && abs($0.g - color.g) <= tolerance && abs($0.b - color.b) <= tolerance }
}

func luma(_ p: RGB) -> Int { (p.r * 299 + p.g * 587 + p.b * 114) / 1000 }
func isDark(_ p: RGB) -> Bool { max(p.r, p.g, p.b) <= 60 }
func isBlack(_ p: RGB) -> Bool { max(p.r, p.g, p.b) <= 24 }
func isLight(_ p: RGB) -> Bool { luma(p) >= 170 }
func isNearWhite(_ p: RGB) -> Bool { min(p.r, p.g, p.b) >= 200 }

/// The layout of a test video: the picture area on top (`pictureHeight` rows), the band under it.
struct Layout {
    let width: Int, pictureHeight: Int, height: Int
    var picture: Region { Region(x0: 0, y0: 0, x1: width, y1: pictureHeight) }
    /// The picture area without a margin where the encoder blurs the edge against the black or the band.
    var pictureInside: Region { Region(x0: 4, y0: 4, x1: width - 4, y1: pictureHeight - 4) }
    var band: Region { Region(x0: 0, y0: pictureHeight, x1: width, y1: height) }
}

func pictureMatches(_ frame: Frame, _ layout: Layout, _ color: RGB) -> Bool {
    fraction(frame, layout.pictureInside, where: near(color)) >= 0.99
}

func bandIsDark(_ frame: Frame, _ layout: Layout) -> Bool { count(frame, layout.band, where: { !isDark($0) }) == 0 }

/// The rows (relative to the band) that hold light text pixels: first and last, or nil when the band has no text.
func textRows(_ frame: Frame, _ layout: Layout) -> (first: Int, last: Int)? {
    var first: Int?, last: Int?
    for y in layout.band.y0..<layout.band.y1 where count(frame, Region(x0: 0, y0: y, x1: layout.width, y1: y + 1), where: isLight) > 0 {
        if first == nil { first = y - layout.band.y0 }
        last = y - layout.band.y0
    }
    if let first, let last { return (first, last) }
    return nil
}

// MARK: - Writing

let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qa-video-checks-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
func tempURL(_ name: String) -> URL { temp.appendingPathComponent(name) }

struct Step {
    let picture: CGImage
    let time: Double
    let subtitle: String?
}

/// Writes the steps to `name` and returns the writer and the decoded video.
func write(_ name: String, size: CGSize, band: CGFloat = 64, fps: Int = 10, steps: [Step], keep: [Int]? = nil) async throws -> (QAVideoWriter, Video) {
    let writer = try QAVideoWriter(url: tempURL(name), pictureSize: size, bandHeight: band, framesPerSecond: fps)
    for step in steps { try writer.append(step.picture, at: step.time, subtitle: step.subtitle) }
    let url = try await writer.finish()
    return (writer, try await readVideo(url, keep: keep))
}

func raises(_ body: () throws -> Void, _ matches: (QAVideoError) -> Bool) -> Bool {
    do { try body() } catch let error as QAVideoError { return matches(error) } catch { return false }
    return false
}

func raisesAsync(_ body: () async throws -> Void, _ matches: (QAVideoError) -> Bool) async -> Bool {
    do { try await body() } catch let error as QAVideoError { return matches(error) } catch { return false }
    return false
}

func section(_ name: String, _ body: () async throws -> Void) async {
    print("-- \(name)")
    do { try await body() } catch { check("\(name) ends without an unexpected error (\(error))", false) }
}

// MARK: - Checks

let basic = Layout(width: 320, pictureHeight: 180, height: 244)
let size320 = CGSize(width: 320, height: 180)

await section("a run with a gap, no subtitle and a Cyrillic subtitle") {
    let steps = [
        Step(picture: picture(320, 180, top: red), time: 0, subtitle: "Open the page and click Sign in"),
        Step(picture: picture(320, 180, top: green), time: 2.5, subtitle: nil),
        Step(picture: picture(320, 180, top: blue), time: 4.0, subtitle: "Нажмите «Войти» и проверьте, что появилось приветствие"),
    ]
    let (writer, video) = try await write("run.mp4", size: size320, steps: steps, keep: [5, 24, 25, 39, 40])
    check("the file exists", FileManager.default.fileExists(atPath: tempURL("run.mp4").path))
    check("the file is playable", video.playable)
    check("the file has one video track", video.videoTracks == 1)
    check("the video size is the picture width by the picture height plus the band", video.size == CGSize(width: 320, height: 244))
    check("the duration is the last time plus one frame (4.1 s)", abs(video.duration - 4.1) < 0.3)
    check("the frame count is the duration times the frame rate", abs(video.times.count - Int((video.duration * 10).rounded())) <= 1 && video.times.count == 41)
    check("framesWritten is the number of frames in the file", writer.framesWritten == video.times.count)
    check("the frame rate is constant: every frame is one tenth of a second after the previous one",
          video.times.enumerated().allSatisfy { abs($0.element - Double($0.offset) / 10) < 0.002 })

    if let f = video.frames[5] {
        check("a frame inside the first step shows its picture", pictureMatches(f, basic, red))
        check("a frame with a subtitle has light text pixels in the band", count(f, basic.band, where: isLight) > 40)
        check("the text stays inside the band with room above and below", textRows(f, basic).map { $0.first >= 3 && $0.last <= basic.band.height - 4 } ?? false)
        check("no text pixel reaches the picture", count(f, basic.pictureInside, where: isNearWhite) == 0)
    } else { check("frame 5 was decoded", false) }
    if let f = video.frames[24] {
        check("the gap is filled with the previous picture (frame 24, 2.4 s)", pictureMatches(f, basic, red))
        check("the gap is filled with the previous subtitle", count(f, basic.band, where: isLight) > 40)
    } else { check("frame 24 was decoded", false) }
    if let f = video.frames[25] {
        check("the next picture starts exactly at its time (frame 25, 2.5 s)", pictureMatches(f, basic, green))
        check("a frame with no subtitle has a uniformly dark band", bandIsDark(f, basic))
    } else { check("frame 25 was decoded", false) }
    if let f = video.frames[39] {
        check("the picture is held until the end of the step", pictureMatches(f, basic, green) && bandIsDark(f, basic))
    } else { check("frame 39 was decoded", false) }
    if let f = video.frames[40] {
        check("the last picture is written for one frame duration", pictureMatches(f, basic, blue))
        check("a Cyrillic subtitle draws in the band", count(f, basic.band, where: isLight) > 60 && !bandIsDark(f, basic))
        check("the Cyrillic text stays inside the band", textRows(f, basic).map { $0.first >= 3 && $0.last <= basic.band.height - 4 } ?? false)
    } else { check("frame 40 was decoded", false) }
}

await section("a picture of another shape is fitted on black, not stretched or flipped") {
    let tall = picture(160, 180, top: red, bottom: blue)           // 160 x 180 in a 320 x 180 area: bars left and right
    let wide = picture(640, 90, top: green)                        // 640 x 90: scaled to 320 x 45, bars above and below
    let steps = [Step(picture: tall, time: 0, subtitle: nil), Step(picture: wide, time: 1, subtitle: nil)]
    let (_, video) = try await write("shapes.mp4", size: size320, steps: steps, keep: [0, 10])
    if let f = video.frames[0] {
        check("the bars beside a tall picture are black", fraction(f, Region(x0: 4, y0: 4, x1: 70, y1: 176), where: isBlack) >= 0.99
              && fraction(f, Region(x0: 250, y0: 4, x1: 316, y1: 176), where: isBlack) >= 0.99)
        check("the upper half of the picture is at the top", fraction(f, Region(x0: 100, y0: 10, x1: 220, y1: 80), where: near(red)) >= 0.99)
        check("the lower half of the picture is at the bottom", fraction(f, Region(x0: 100, y0: 100, x1: 220, y1: 170), where: near(blue)) >= 0.99)
    } else { check("frame 0 was decoded", false) }
    if let f = video.frames[10] {
        check("the bars above and below a wide picture are black", fraction(f, Region(x0: 10, y0: 4, x1: 310, y1: 60), where: isBlack) >= 0.99
              && fraction(f, Region(x0: 10, y0: 120, x1: 310, y1: 176), where: isBlack) >= 0.99)
        check("a wide picture fills the width", fraction(f, Region(x0: 10, y0: 76, x1: 310, y1: 104), where: near(green)) >= 0.99)
    } else { check("frame 10 was decoded", false) }
}

await section("odd sizes are rounded up to even") {
    let (writer, video) = try await write("odd.mp4", size: CGSize(width: 321, height: 181), steps: [Step(picture: picture(321, 181, top: red), time: 0, subtitle: "Odd")])
    check("an odd picture width becomes even and the height is the picture plus the band, even", video.size == CGSize(width: 322, height: 246))
    check("the geometry says the same", writer.geometry.width == 322 && writer.geometry.height == 246 && writer.geometry.pictureHeight == 181)
    let exact = QAVideoGeometry(pictureSize: CGSize(width: 1280, height: 720), bandHeight: 64)
    check("even sizes are kept as they are", exact?.width == 1280 && exact?.pictureHeight == 720 && exact?.bandHeight == 64 && exact?.height == 784)
    let fractional = QAVideoGeometry(pictureSize: CGSize(width: 100.2, height: 50.2), bandHeight: 10.5)
    check("fractional sizes are rounded up", fractional?.width == 102 && fractional?.pictureHeight == 51 && fractional?.height == 62)
}

await section("a picture after time zero is preceded by black") {
    let (_, video) = try await write("leadin.mp4", size: size320, steps: [Step(picture: picture(320, 180, top: red), time: 1.0, subtitle: "Late")], keep: [5, 10])
    check("the video covers the time before the first picture", video.times.count == 11 && abs(video.duration - 1.1) < 0.3)
    if let f = video.frames[5] { check("the time before the first picture is black with a dark band", fraction(f, basic.pictureInside, where: isBlack) >= 0.99 && bandIsDark(f, basic)) }
    else { check("frame 5 was decoded", false) }
    if let f = video.frames[10] { check("the first picture shows from its time", pictureMatches(f, basic, red) && count(f, basic.band, where: isLight) > 20) }
    else { check("frame 10 was decoded", false) }
}

await section("two pictures at the same time: the later one wins") {
    let steps = [Step(picture: picture(320, 180, top: red), time: 0, subtitle: "First"), Step(picture: picture(320, 180, top: green), time: 0, subtitle: nil)]
    let (_, video) = try await write("same.mp4", size: size320, steps: steps, keep: [0])
    check("one frame is written", video.times.count == 1)
    if let f = video.frames[0] { check("it shows the later picture and no subtitle", pictureMatches(f, basic, green) && bandIsDark(f, basic)) }
    else { check("frame 0 was decoded", false) }
}

await section("a frame rate other than ten") {
    let steps = [Step(picture: picture(320, 180, top: red), time: 0, subtitle: nil), Step(picture: picture(320, 180, top: blue), time: 1.0, subtitle: nil)]
    let (_, video) = try await write("fps25.mp4", size: size320, fps: 25, steps: steps, keep: [24, 25])
    check("25 frames per second: 26 frames for one second plus the last picture", video.times.count == 26)
    check("the frame times are 40 ms apart", video.times.enumerated().allSatisfy { abs($0.element - Double($0.offset) / 25) < 0.002 })
    if let a = video.frames[24], let b = video.frames[25] { check("the switch happens at 1.0 s", pictureMatches(a, basic, red) && pictureMatches(b, basic, blue)) }
    else { check("frames 24 and 25 were decoded", false) }
}

// MARK: Long and unusual subtitles

let longLatin = String(repeating: "Verify that the order confirmation page shows the total price. ", count: 80)
let longCyrillic = String(repeating: "Проверьте, что на странице подтверждения заказа показана итоговая сумма. ", count: 45)
let unbroken = "https://example.com/" + String(repeating: "a", count: 700)
let japanese = String(repeating: "日本語のテキストは長い文章でも折り返されます。", count: 40) + " 🙂🙂"
let lineBreaks = "Line one\nLine two\n\nLine three\n   Line four"
let long = Layout(width: 640, pictureHeight: 360, height: 424)

await section("very long and unusual subtitles") {
    let subtitles: [(String, String)] = [("5000 Latin characters", longLatin), ("3000 Cyrillic characters", longCyrillic), ("a 700 character word", unbroken),
                                         ("Japanese with emoji", japanese), ("line breaks", lineBreaks), ("only white space", "  \n\t ")]
    // Every subtitle is shown for one second; a closing step makes the last of them last a second too.
    let steps = subtitles.enumerated().map { Step(picture: picture(640, 360, top: blue), time: Double($0.offset), subtitle: $0.element.1) }
        + [Step(picture: picture(640, 360, top: blue), time: Double(subtitles.count), subtitle: "The end")]
    let (_, video) = try await write("long.mp4", size: CGSize(width: 640, height: 360), steps: steps, keep: subtitles.indices.map { $0 * 10 + 5 })
    check("a video with long subtitles is written and playable", video.playable && video.times.count == subtitles.count * 10 + 1)
    for (index, (name, _)) in subtitles.enumerated() {
        guard let f = video.frames[index * 10 + 5] else { check("\(name): frame decoded", false); continue }
        check("\(name): the picture area is untouched", pictureMatches(f, long, blue) && count(f, long.pictureInside, where: isNearWhite) == 0)
        if name == "only white space" {
            check("\(name): the band stays dark", bandIsDark(f, long))
        } else {
            check("\(name): the text is drawn", count(f, long.band, where: isLight) > 100)
            check("\(name): the text fits in the band", textRows(f, long).map { $0.first >= 2 && $0.last <= long.band.height - 3 } ?? false)
        }
    }
}

await section("how a subtitle is laid out") {
    let width: CGFloat = 1200, height: CGFloat = 54
    let word = "alpha beta gamma delta epsilon "
    func lineWidth(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

    let short = QASubtitleLayout.make(text: "Click Save", width: width, height: height)
    check("a short subtitle is one line, as written", short?.lines.count == 1 && short?.texts == ["Click Save"] && short?.wasTruncated == false)
    let baseSize = short?.fontSize ?? 0
    check("two lines fit the height at the base size", baseSize > 0 && CGFloat(QASubtitleLayout.maxLines) * (short?.lineHeight ?? 1000) <= height)
    check("nothing to show for blank text", QASubtitleLayout.make(text: "", width: width, height: height) == nil
          && QASubtitleLayout.make(text: " \n\t", width: width, height: height) == nil)
    check("white space is collapsed", QASubtitleLayout.normalized("a\n\n b\t c  ") == "a b c")

    let medium = QASubtitleLayout.make(text: String(repeating: word, count: 8), width: width, height: height)
    let mediumText = String(repeating: word, count: 8)
    check("a text that needs two lines wraps at a space and loses nothing", medium.map {
        $0.lines.count == 2 && !$0.wasTruncated && $0.texts.joined(separator: " ") == QASubtitleLayout.normalized(mediumText)
    } ?? false)

    var shrunk: QASubtitleLayout?
    for words in 8...60 {
        let layout = QASubtitleLayout.make(text: String(repeating: word, count: words), width: width, height: height)
        if let layout, layout.fontSize < baseSize, !layout.wasTruncated { shrunk = layout; break }
    }
    check("a text that does not fit in two lines at the base size is shrunk before it is cut", shrunk != nil && (shrunk?.lines.count ?? 0) <= 2)

    for (name, text) in [("Latin", longLatin), ("Cyrillic", longCyrillic), ("one long word", unbroken), ("Japanese", japanese)] {
        let layout = QASubtitleLayout.make(text: text, width: width, height: height)
        check("\(name): at most two lines", (layout?.lines.count ?? 3) <= 2 && (layout?.texts.count ?? 3) <= 2)
        check("\(name): cut with an ellipsis at the end", layout?.wasTruncated == true && layout?.texts.last?.hasSuffix(QASubtitleLayout.ellipsis) == true)
        check("\(name): every line fits the width", layout.map { $0.lines.allSatisfy { lineWidth($0) <= width + 0.5 } } ?? false)
        check("\(name): the text is smaller than the base size", (layout?.fontSize ?? 100) < baseSize)
    }
    let cyrillic = QASubtitleLayout.make(text: "Нажмите «Войти» и проверьте результат", width: width, height: height)
    check("Cyrillic text is kept as written", cyrillic?.texts == ["Нажмите «Войти» и проверьте результат"])
    let narrow = QASubtitleLayout.make(text: "Open the page and click the Sign in button", width: 300, height: height)
    check("a narrow box wraps to two lines without cutting what fits", narrow.map { $0.lines.count == 2 && !$0.wasTruncated && ($0.texts.joined(separator: " ") == "Open the page and click the Sign in button") } ?? false)
    let broken = QASubtitleLayout.make(text: lineBreaks, width: width, height: height)
    check("line breaks in a subtitle become spaces", broken?.texts == ["Line one Line two Line three Line four"])
}

// MARK: Not blocking the caller

await section("appending does not block the caller") {
    let size = CGSize(width: 1280, height: 720)
    let writer = try QAVideoWriter(url: tempURL("big.mp4"), pictureSize: size)
    let pictures = [picture(2000, 1200, top: red, bottom: blue), picture(2000, 1200, top: green, bottom: red)]
    var slowest = 0.0
    for step in 0..<30 {
        let start = DispatchTime.now().uptimeNanoseconds
        try writer.append(pictures[step % 2], at: Double(step) * 0.5, subtitle: "Step \(step): " + String(repeating: "the quick brown fox ", count: 4))
        slowest = max(slowest, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }
    check("no append took 100 ms (slowest \(Int(slowest * 1000)) ms)", slowest < 0.1)
    let url = try await writer.finish()
    let video = try await readVideo(url, keep: [])
    check("a 1280 x 720 video is 1280 x 784, with a frame for every tenth of a second up to 14.5 s and one more", video.size == CGSize(width: 1280, height: 784) && video.times.count == 146)
    check("its duration is the last time plus one frame", abs(video.duration - 14.6) < 0.3)
}

// MARK: Errors

await section("errors") {
    let url = tempURL("errors.mp4")
    check("a zero-size picture is refused", raises({ _ = try QAVideoWriter(url: url, pictureSize: .zero) }, { $0 == .zeroSizePicture }))
    check("a picture with no height is refused", raises({ _ = try QAVideoWriter(url: url, pictureSize: CGSize(width: 100, height: 0)) }, { $0 == .zeroSizePicture }))
    check("a picture with a negative width is refused", raises({ _ = try QAVideoWriter(url: url, pictureSize: CGSize(width: -5, height: 100)) }, { $0 == .zeroSizePicture }))
    check("a negative band height is refused", raises({ _ = try QAVideoWriter(url: url, pictureSize: size320, bandHeight: -1) }, { if case .invalidSettings = $0 { return true }; return false }))
    check("a frame rate of zero is refused", raises({ _ = try QAVideoWriter(url: url, pictureSize: size320, framesPerSecond: 0) }, { if case .invalidSettings = $0 { return true }; return false }))
    check("an unwritable location is refused", raises({ _ = try QAVideoWriter(url: URL(fileURLWithPath: "/System/qa-video-checks/out.mp4"), pictureSize: size320) },
                                                       { if case .unwritableDestination = $0 { return true }; return false }))
    check("an address that is not a file is refused", raises({ _ = try QAVideoWriter(url: URL(string: "https://example.com/out.mp4")!, pictureSize: size320) },
                                                              { if case .unwritableDestination = $0 { return true }; return false }))
    check("a refused writer leaves no file", !FileManager.default.fileExists(atPath: url.path))

    let writer = try QAVideoWriter(url: url, pictureSize: size320)
    let red320 = picture(320, 180, top: red)
    try writer.append(red320, at: 2.0, subtitle: "Two seconds in")
    check("a time before the previous one is refused", raises({ try writer.append(red320, at: 1.0, subtitle: nil) }, { $0 == .timeWentBackwards(previous: 2.0, requested: 1.0) }))
    check("a time that is not a number is refused", raises({ try writer.append(red320, at: .nan, subtitle: nil) }, { if case .invalidTime = $0 { return true }; return false }))
    check("a negative time is refused", raises({ try writer.append(red320, at: -1, subtitle: nil) }, { if case .invalidTime = $0 { return true }; return false }))
    try writer.append(red320, at: 2.0, subtitle: "Same time is fine")
    try writer.append(red320, at: 3.0, subtitle: nil)
    let finished = try await writer.finish()
    check("the writer is still usable after a refused frame", finished == url && FileManager.default.fileExists(atPath: url.path))
    let video = try await readVideo(url, keep: [])
    check("the refused frames left no trace: the video ends one frame after 3.0 s", video.times.count == 31 && abs(video.duration - 3.1) < 0.3)
    check("appending after finish is refused", raises({ try writer.append(red320, at: 4.0, subtitle: nil) }, { $0 == .alreadyFinished }))
    check("finishing twice is refused", await raisesAsync({ _ = try await writer.finish() }, { $0 == .alreadyFinished }))

    let empty = try QAVideoWriter(url: tempURL("empty.mp4"), pictureSize: size320)
    check("finishing without a picture is refused", await raisesAsync({ _ = try await empty.finish() }, { $0 == .noFrames }))
    check("and leaves no file", !FileManager.default.fileExists(atPath: tempURL("empty.mp4").path))

    let allDescribed: [QAVideoError] = [.unwritableDestination(path: "/x", reason: "r"), .zeroSizePicture, .invalidSettings("s"), .invalidTime(-1),
                                        .timeWentBackwards(previous: 2, requested: 1), .alreadyFinished, .noFrames, .pixelBufferUnavailable, .writerFailed("w")]
    check("every error has a message", allDescribed.allSatisfy { !($0.errorDescription ?? "").isEmpty })
}

await section("the destination") {
    let nested = tempURL("a/b/c/nested.mp4")
    let (_, nestedVideo) = try await write("a/b/c/nested.mp4", size: size320, steps: [Step(picture: picture(320, 180, top: red), time: 0, subtitle: nil)], keep: [])
    check("missing folders are created", FileManager.default.fileExists(atPath: nested.path) && nestedVideo.playable)

    try Data("not a video".utf8).write(to: tempURL("replace.mp4"))
    let (_, replaced) = try await write("replace.mp4", size: size320, steps: [Step(picture: picture(320, 180, top: green), time: 0, subtitle: nil)], keep: [])
    check("an existing file is replaced", replaced.playable && replaced.times.count == 1)

    var dropped: QAVideoWriter? = try QAVideoWriter(url: tempURL("dropped.mp4"), pictureSize: size320)
    try dropped?.append(picture(320, 180, top: red), at: 0, subtitle: "Never finished")
    dropped = nil
    var gone = false
    for _ in 0..<100 where !gone {
        gone = !FileManager.default.fileExists(atPath: tempURL("dropped.mp4").path)
        if !gone { try await Task.sleep(nanoseconds: 20_000_000) }
    }
    check("a writer dropped without finish leaves no half-written file", gone)
}

await section("input markers in the exported video") {
    let grey = RGB(r: 100, g: 100, b: 100)
    let page = picture(1280, 800, top: grey)
    let target = CGRect(x: 0.25, y: 0.25, width: 0.2, height: 0.1)
    let click = QAInputMark(kind: .click, target: target)
    let fill = QAInputMark(kind: .fill, target: target)
    let clean = QAFrameComposer.compose([page, page])!
    let marked = QAFrameComposer.compose([page, page], marks: [1: click], names: ["Client", "Admin"])!
    let writer = try QAVideoWriter(url: tempURL("inputs.mp4"), pictureSize: CGSize(width: marked.width, height: marked.height))
    try writer.append(marked, at: 0, subtitle: "Click the control", minimumDuration: 0.75)
    try writer.append(QAFrameComposer.compose([page, page], marks: [0: fill], names: ["Client", "Admin"])!, at: 0.02,
                      subtitle: "Type into the field", minimumDuration: 0.75)
    try writer.append(clean, at: 0.03, subtitle: "Result")
    let url = try await writer.finish()
    let video = try await readVideo(url)
    check("fast successive inputs each remain readable", video.duration >= 1.6)
    func yellow(_ frame: Frame, _ region: Region) -> Int {
        var count = 0
        for y in region.y0..<region.y1 { for x in region.x0..<region.x1 {
            let p = frame.pixel(x, y)
            if p.r > 180 && p.g > 120 && p.b < 100 { count += 1 }
        } }
        return count
    }
    if let first = video.frames[0], let second = video.frames[8], let result = video.frames[16] {
        let firstTarget = Region(x0: 370, y0: 190, x1: 440, y1: 240)
        let adminTarget = Region(x0: 1530, y0: 190, x1: 1600, y1: 240)
        check("click ring is on the admin's actual target", yellow(first, adminTarget) > 100)
        check("other player's target is untouched", yellow(first, firstTarget) == 0)
        check("typing outlines the client's field", yellow(second, Region(x0: 280, y0: 175, x1: 530, y1: 260)) > 300)
        check("clean result is restored after the input", yellow(result, adminTarget) == 0 && yellow(result, firstTarget) == 0)
    } else { check("marker frames can be decoded", false) }
    let portrait = picture(400, 800, top: grey)
    let portraitMarked = QAFrameComposer.compose([portrait], marks: [0: click])!
    let portraitWriter = try QAVideoWriter(url: tempURL("portrait-input.mp4"), pictureSize: CGSize(width: portraitMarked.width, height: portraitMarked.height))
    try portraitWriter.append(portraitMarked, at: 0, subtitle: nil)
    let portraitVideo = try await readVideo(try await portraitWriter.finish())
    check("portrait target accounts for letterboxing", portraitVideo.frames[0].map { yellow($0, Region(x0: 490, y0: 185, x1: 555, y1: 245)) > 100 } ?? false)
    check("offscreen geometry is clipped", QAInputMark.normalized(CGRect(x: -10, y: 20, width: 30, height: 40), in: CGRect(x: 0, y: 0, width: 100, height: 100)) == CGRect(x: 0, y: 0.2, width: 0.2, height: 0.4))
    check("unknown or invalid target has no invented position", QAInputMark.normalized(CGRect(x: 1000, y: 0, width: 10, height: 10), in: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
    check("every action has a visible semantic label", QAActionKind.allCases.allSatisfy { !QAInputMark(kind: $0).label.isEmpty })
    check("scroll direction and failure are explicit", QAInputMark(kind: .scroll, direction: "up", failed: true).label == "Scroll ↑ · Failed")
    if let export = ProcessInfo.processInfo.environment["QA_ACTION_EXPORT"] {
        try FileManager.default.createDirectory(atPath: export, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: export).appendingPathComponent("inputs.mp4"))
    }
}

try? FileManager.default.removeItem(at: temp)
print(failures == 0 ? "All QA video checks passed" : "\(failures) QA video check(s) failed")
exit(failures == 0 ? 0 : 1)
