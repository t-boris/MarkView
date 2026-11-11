import AVFoundation
import AppKit
import CoreGraphics
import CoreText
import CoreVideo
import Foundation

// Feature end-to-end-qa: the video of a QA run. A run produces a picture every few seconds (one per step); this file turns those
// pictures into one constant-frame-rate H.264 .mp4 with a subtitle band under the picture that says what is being done, where and why.
//
// Everything is drawn offscreen into pixel buffers from a CVPixelBufferPool: no window and no Screen Recording permission are needed,
// and the only dependencies are AVFoundation, CoreGraphics, CoreText and AppKit's NSFont (no other MarkView type).
//
// Threading: `append` validates its arguments and queues the work on a private serial queue, so it never blocks the caller (the main
// thread) on rendering or on the encoder. The queue renders the picture, fills the time between two pictures with copies of the held
// frame at `framesPerSecond`, and waits on a background thread when the encoder is not ready. A failure on the queue is remembered and
// thrown by the next `append` and by `finish`.

/// One line of the subtitle track of a recording; `start`/`end` are seconds from the start of the recording, `end` nil = until the next line.
struct QASubtitleLine: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double?
}

enum QAVideoError: LocalizedError, Equatable {
    case unwritableDestination(path: String, reason: String)
    case zeroSizePicture
    case invalidSettings(String)
    case invalidTime(Double)
    case timeWentBackwards(previous: Double, requested: Double)
    case alreadyFinished
    case noFrames
    case pixelBufferUnavailable
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .unwritableDestination(let path, let reason):
            return "The video file cannot be written to \(path): \(reason)"
        case .zeroSizePicture:
            return "The video picture has no size: its width and height must be at least one pixel."
        case .invalidSettings(let message):
            return "The video settings are not valid: \(message)"
        case .invalidTime(let time):
            return "The frame time \(time) is not valid: it must be a finite number of seconds, zero or more."
        case .timeWentBackwards(let previous, let requested):
            return "The frame time went backwards: \(requested) s comes after \(previous) s."
        case .alreadyFinished:
            return "The video is already finished; no more frames can be added."
        case .noFrames:
            return "The video has no frames: add at least one picture before finishing."
        case .pixelBufferUnavailable:
            return "A pixel buffer for the video frame could not be created."
        case .writerFailed(let reason):
            return "Writing the video failed: \(reason)"
        }
    }
}

/// The pixel layout of the video: the picture area on top, the subtitle band under it.
struct QAVideoGeometry: Equatable {
    /// Width of the video and of the picture area; rounded up to an even number.
    let width: Int
    /// Height of the picture area (the requested height rounded up to a whole pixel).
    let pictureHeight: Int
    /// Height of the band; at least the requested height, one pixel more when that makes the total height even.
    let bandHeight: Int
    var height: Int { pictureHeight + bandHeight }

    init?(pictureSize: CGSize, bandHeight requestedBand: CGFloat) {
        guard pictureSize.width.isFinite, pictureSize.height.isFinite, requestedBand.isFinite,
              pictureSize.width > 0, pictureSize.height > 0, requestedBand >= 0 else { return nil }
        func evenUp(_ value: Int) -> Int { value % 2 == 0 ? value : value + 1 }
        let picture = Int(pictureSize.height.rounded(.up))
        width = evenUp(Int(pictureSize.width.rounded(.up)))
        pictureHeight = picture
        bandHeight = evenUp(picture + Int(requestedBand.rounded(.up))) - picture
    }
}

/// How one subtitle is laid out in the band: wrapped to at most two lines, the font shrunk when it does not fit, and the end
/// replaced with an ellipsis when it still does not fit at the smallest size. Pure text layout; drawing is done by the writer.
struct QASubtitleLayout {
    let lines: [CTLine]
    /// The text of each line as it is drawn (the last line ends with an ellipsis when `wasTruncated`).
    let texts: [String]
    let fontSize: CGFloat
    let ascent: CGFloat
    let lineHeight: CGFloat
    let wasTruncated: Bool

    static let maxLines = 2
    static let ellipsis = "\u{2026}"
    private static let largestFontSize = 28
    private static let smallestFontSize = 9
    /// Longer input is cut before layout; two lines can never show more than this.
    private static let maxCharacters = 2000

    /// The text with every run of white space (line breaks included) reduced to one space, and absurdly long input cut.
    static func normalized(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > maxCharacters else { return collapsed }
        return String(collapsed.prefix(maxCharacters)) + ellipsis
    }

    /// The layout of `raw` for a box of `width` x `height`, or nil when there is nothing to show.
    static func make(text raw: String, width: CGFloat, height: CGFloat) -> QASubtitleLayout? {
        let text = normalized(raw)
        guard !text.isEmpty, width >= 1 else { return nil }
        var base = largestFontSize
        while base > smallestFontSize, CGFloat(maxLines) * metrics(size: base).lineHeight > height { base -= 1 }
        let smallest = max(smallestFontSize, Int((Double(base) * 0.6).rounded()))
        for size in stride(from: base, through: smallest, by: -1) {
            if let layout = wrapped(text, size: size, width: width) { return layout }
        }
        return truncated(text, size: smallest, width: width)
    }

    private static func font(size: Int) -> NSFont { NSFont.systemFont(ofSize: CGFloat(size), weight: .medium) }

    private static func metrics(size: Int) -> (ascent: CGFloat, lineHeight: CGFloat) {
        let ctFont = font(size: size) as CTFont
        let ascent = CTFontGetAscent(ctFont).rounded(.up)
        return (ascent, ascent + CTFontGetDescent(ctFont).rounded(.up) + CTFontGetLeading(ctFont).rounded(.up))
    }

    private static func attributed(_ text: String, size: Int) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font(size: size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
    }

    private static func width(of text: String, size: Int) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(text, size: size)), nil, nil, nil))
    }

    /// Greedy word wrap of the whole text into at most `maxLines` lines; nil when it needs more.
    private static func wrapped(_ text: String, size: Int, width: CGFloat) -> QASubtitleLayout? {
        let typesetter = CTTypesetterCreateWithAttributedString(attributed(text, size: size))
        let string = text as NSString
        var lines: [CTLine] = [], texts: [String] = []
        var start = 0
        while start < string.length {
            guard lines.count < maxLines else { return nil }
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { return nil }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            texts.append(string.substring(with: NSRange(location: start, length: count)).trimmingCharacters(in: .whitespaces))
            start += count
        }
        return QASubtitleLayout(lines: lines, texts: texts, size: size, truncated: false)
    }

    /// The text at `size`: the first lines wrapped as usual, the last line cut to fit and ended with an ellipsis.
    private static func truncated(_ text: String, size: Int, width: CGFloat) -> QASubtitleLayout {
        let typesetter = CTTypesetterCreateWithAttributedString(attributed(text, size: size))
        let string = text as NSString
        var lines: [CTLine] = [], texts: [String] = []
        var start = 0
        while lines.count < maxLines - 1, start < string.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            texts.append(string.substring(with: NSRange(location: start, length: count)).trimmingCharacters(in: .whitespaces))
            start += count
        }
        let characters = Array(string.substring(from: start))
        func candidate(_ count: Int) -> String { String(characters[0..<count]).trimmingCharacters(in: .whitespaces) + ellipsis }
        var low = 0, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if Self.width(of: candidate(middle), size: size) <= width { low = middle } else { high = middle - 1 }
        }
        let last = candidate(low)
        lines.append(CTLineCreateWithAttributedString(attributed(last, size: size)))
        texts.append(last)
        return QASubtitleLayout(lines: lines, texts: texts, size: size, truncated: true)
    }

    private init(lines: [CTLine], texts: [String], size: Int, truncated: Bool) {
        let metrics = Self.metrics(size: size)
        self.lines = lines
        self.texts = texts
        self.fontSize = CGFloat(size)
        self.ascent = metrics.ascent
        self.lineHeight = metrics.lineHeight
        self.wasTruncated = truncated
    }
}

final class QAVideoWriter: @unchecked Sendable {
    let url: URL
    let framesPerSecond: Int
    let geometry: QAVideoGeometry

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let pool: CVPixelBufferPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let queue = DispatchQueue(label: "markview.qa-video-writer", qos: .utility)

    // Guarded by `lock`: written by `append`/`finish` on the caller's thread and by the queue.
    private let lock = NSLock()
    private var finished = false
    private var lastTime = 0.0
    private var failure: QAVideoError?
    private var written = 0

    // Confined to `queue`: the rendered frame of the latest picture, held until the next picture arrives.
    private var held: CVPixelBuffer?
    private var heldUntil = 0

    private static let bandColor = CGColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1)
    private static let waitForEncoder: TimeInterval = 60

    /// Creates the file at `url` (the missing folders are created, an existing file is replaced) and starts the H.264 session.
    /// The video is `pictureSize` wide (rounded up to even) and `pictureSize.height + bandHeight` high (rounded up to even).
    init(url: URL, pictureSize: CGSize, bandHeight: CGFloat = 64, framesPerSecond: Int = 10) throws {
        guard pictureSize.width.isFinite, pictureSize.height.isFinite, pictureSize.width >= 1, pictureSize.height >= 1 else {
            throw QAVideoError.zeroSizePicture
        }
        guard bandHeight.isFinite, bandHeight >= 0 else { throw QAVideoError.invalidSettings("the band height must be zero or more") }
        guard (1...120).contains(framesPerSecond) else { throw QAVideoError.invalidSettings("the frame rate must be 1 to 120 frames per second") }
        guard let geometry = QAVideoGeometry(pictureSize: pictureSize, bandHeight: bandHeight) else { throw QAVideoError.zeroSizePicture }
        try Self.prepareDestination(url)

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch {
            throw QAVideoError.unwritableDestination(path: url.path, reason: error.localizedDescription)
        }
        let bitRate = min(20_000_000, max(500_000, Int(Double(geometry.width * geometry.height * framesPerSecond) * 0.25)))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: geometry.width,
            AVVideoHeightKey: geometry.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = CMTimeScale(framesPerSecond * 1000)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: geometry.width,
            kCVPixelBufferHeightKey as String: geometry.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { throw QAVideoError.writerFailed("the video track cannot be added to the file") }
        writer.add(input)
        guard writer.startWriting() else {
            throw QAVideoError.writerFailed(writer.error?.localizedDescription ?? "the file could not be started")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw QAVideoError.pixelBufferUnavailable
        }
        self.url = url
        self.framesPerSecond = framesPerSecond
        self.geometry = geometry
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.pool = pool
    }

    deinit {
        // A recording that is dropped without `finish` has no index and cannot be played: do not leave the half file behind.
        if !finished, writer.status == .writing { writer.cancelWriting() }
    }

    /// The number of frames handed to the encoder so far. Frames are written in the background, so this can trail `append`;
    /// after `finish` it is the length of the video in frames.
    var framesWritten: Int { locked { written } }

    /// Shows `picture` (scaled to fit the picture area on black) with `subtitle` in the band from `time` seconds on, until the next
    /// picture. `time` is seconds from the start of the recording and must not go backwards. The frames in between are filled with the
    /// previous picture; before the first picture (when it comes after time zero) the video shows black. Two pictures within one
    /// frame duration: the later one wins. Returns at once: rendering and encoding happen on a background queue.
    func append(_ picture: CGImage, at time: Double, subtitle: String?, minimumDuration: Double = 0) throws {
        guard picture.width > 0, picture.height > 0 else { throw QAVideoError.zeroSizePicture }
        guard time.isFinite, time >= 0 else { throw QAVideoError.invalidTime(time) }
        guard minimumDuration.isFinite, (0...10).contains(minimumDuration) else { throw QAVideoError.invalidSettings("the minimum frame duration must be 0 to 10 seconds") }
        try locked {
            if finished { throw QAVideoError.alreadyFinished }
            if let failure { throw failure }
            if time < lastTime { throw QAVideoError.timeWentBackwards(previous: lastTime, requested: time) }
            lastTime = time
            // Queued under the lock so that the queue sees the pictures in the order their times were accepted.
            queue.async { self.process(picture, at: time, subtitle: subtitle, minimumDuration: minimumDuration) }
        }
    }

    /// Writes the last picture for one frame duration, closes the file and returns its url. A second call throws `alreadyFinished`;
    /// it throws the first failure of the writer, and `noFrames` when no picture was appended (the file is removed then).
    func finish() async throws -> URL {
        try locked {
            if finished { throw QAVideoError.alreadyFinished }
            finished = true
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async { self.complete(continuation) }
        }
    }

    // MARK: - Queue

    private func process(_ picture: CGImage, at time: Double, subtitle: String?, minimumDuration: Double) {
        guard locked({ failure }) == nil else { return }
        do {
            // The first frame that shows this picture; every frame before it still shows the held one.
            // Reserve enough frames to read fast input markers, without delaying the tested app.
            // Later wall-clock gaps absorb this short extension rather than accumulating an offset.
            let first = max(heldUntil, Int((time * Double(framesPerSecond) - 1e-6).rounded(.up)))
            try fill(upTo: first)
            held = try render(picture, subtitle: subtitle)
            heldUntil = first + Int((minimumDuration * Double(framesPerSecond)).rounded(.up))
        } catch {
            fail(error)
        }
    }

    private func complete(_ continuation: CheckedContinuation<URL, Error>) {
        if let failure = locked({ failure }) {
            continuation.resume(throwing: failure)
            return
        }
        guard let held else {
            writer.cancelWriting()
            continuation.resume(throwing: QAVideoError.noFrames)
            return
        }
        do {
            try fill(upTo: heldUntil)
            try write(held)
        } catch {
            fail(error)
            continuation.resume(throwing: locked({ failure }) ?? QAVideoError.writerFailed(error.localizedDescription))
            return
        }
        self.held = nil
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(locked { written }), timescale: CMTimeScale(framesPerSecond)))
        writer.finishWriting { [self] in
            if writer.status == .completed {
                continuation.resume(returning: url)
            } else {
                continuation.resume(throwing: QAVideoError.writerFailed(writer.error?.localizedDescription ?? "the file was not completed"))
            }
        }
    }

    /// Writes the held frame (black before the first picture) for every frame that is not written yet and comes before `index`.
    private func fill(upTo index: Int) throws {
        guard locked({ written }) < index else { return }
        let buffer = try held ?? render(nil, subtitle: nil)
        while locked({ written }) < index { try write(buffer) }
    }

    /// Hands `buffer` to the encoder as the next frame; the same buffer may be written many times.
    private func write(_ buffer: CVPixelBuffer) throws {
        let deadline = Date().addingTimeInterval(Self.waitForEncoder)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw QAVideoError.writerFailed(writer.error?.localizedDescription ?? "the writer stopped") }
            guard Date() < deadline else { throw QAVideoError.writerFailed("the encoder did not accept a frame for \(Int(Self.waitForEncoder)) s") }
            Thread.sleep(forTimeInterval: 0.002)
        }
        let time = CMTime(value: CMTimeValue(locked { written }), timescale: CMTimeScale(framesPerSecond))
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw QAVideoError.writerFailed(writer.error?.localizedDescription ?? "the encoder rejected a frame")
        }
        locked { written += 1 }
    }

    private func fail(_ error: Error) {
        let failure = (error as? QAVideoError) ?? QAVideoError.writerFailed(error.localizedDescription)
        locked { if self.failure == nil { self.failure = failure } }
        held = nil
        if writer.status == .writing { writer.cancelWriting() }
    }

    // MARK: - Drawing

    /// One frame: the picture fitted on black above, the subtitle in the band below. `picture` nil = black.
    private func render(_ picture: CGImage?, subtitle: String?) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else {
            throw QAVideoError.pixelBufferUnavailable
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: geometry.width, height: geometry.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw QAVideoError.pixelBufferUnavailable }

        // The context origin is bottom left: the band is the bottom strip, the picture area the rest above it.
        let canvasWidth = CGFloat(geometry.width)
        let bandRect = CGRect(x: 0, y: 0, width: canvasWidth, height: CGFloat(geometry.bandHeight))
        let pictureRect = CGRect(x: 0, y: bandRect.maxY, width: canvasWidth, height: CGFloat(geometry.pictureHeight))
        context.setFillColor(Self.bandColor)
        context.fill(bandRect)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(pictureRect)

        if let picture {
            let scale = min(pictureRect.width / CGFloat(picture.width), pictureRect.height / CGFloat(picture.height))
            let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
            context.saveGState()
            context.clip(to: pictureRect)
            context.interpolationQuality = .high
            context.draw(picture, in: CGRect(x: pictureRect.midX - size.width / 2, y: pictureRect.midY - size.height / 2,
                                             width: size.width, height: size.height))
            context.restoreGState()
        }
        if let subtitle { drawSubtitle(subtitle, in: bandRect, context: context) }

        // Tell the encoder how to read the pixels so that the colours survive the trip to YCbCr and back.
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    /// White text centred in the band, at most two lines; clipped to the band so that it can never reach the picture.
    private func drawSubtitle(_ subtitle: String, in band: CGRect, context: CGContext) {
        let horizontalPadding = max(8, (band.width * 0.02).rounded())
        let verticalPadding = max(4, (band.height * 0.08).rounded())
        guard band.height > 2 * verticalPadding,
              let layout = QASubtitleLayout.make(text: subtitle, width: band.width - 2 * horizontalPadding,
                                                 height: band.height - 2 * verticalPadding)
        else { return }
        context.saveGState()
        context.clip(to: band)
        context.textMatrix = .identity
        let textWidth = band.width - 2 * horizontalPadding
        let top = band.midY + CGFloat(layout.lines.count) * layout.lineHeight / 2
        for (index, line) in layout.lines.enumerated() {
            let baseline = (top - CGFloat(index) * layout.lineHeight - layout.ascent).rounded()
            let offset = CGFloat(CTLineGetPenOffsetForFlush(line, 0.5, Double(textWidth)))
            context.textPosition = CGPoint(x: band.minX + horizontalPadding + offset, y: baseline)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    // MARK: - Helpers

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Makes sure a new file can be created at `url`: a file url, its folder exists (created when missing) and is writable,
    /// and nothing is in the way (an existing file is replaced, as AVAssetWriter refuses to overwrite).
    private static func prepareDestination(_ url: URL) throws {
        func unwritable(_ reason: String) -> QAVideoError { .unwritableDestination(path: url.path, reason: reason) }
        guard url.isFileURL, !url.lastPathComponent.isEmpty else { throw unwritable("it is not a file location") }
        let manager = FileManager.default
        do { try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
            throw unwritable(error.localizedDescription)
        }
        if manager.fileExists(atPath: url.path) {
            do { try manager.removeItem(at: url) } catch { throw unwritable("the existing file cannot be replaced: \(error.localizedDescription)") }
        }
        guard manager.createFile(atPath: url.path, contents: nil) else { throw unwritable("the folder is not writable") }
        try? manager.removeItem(at: url)
    }
}
