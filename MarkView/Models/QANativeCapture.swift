import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit

// End-to-End QA (feature end-to-end-qa, DEC-012, DEC-017, REQ-004): the pictures of a native player's window. One SCStream per player shows
// the window of the application's process whether or not it is covered by other windows; only the latest frame is kept, and it is turned
// into a PNG when the runner asks for a picture (the video writer takes the pictures from there). It needs the Screen Recording permission,
// which the caller has checked before: nothing here asks for it. macOS 13 compatible (no SCScreenshotManager, no SCRecordingOutput).

final class QANativeCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// The window is captured this many times a second at most; a window that does not change sends nothing new.
    static let framesPerSecond = 10
    /// How long the first picture of a window is waited for.
    static let firstFrameWait: TimeInterval = 1.5

    /// What the stream callback and the callers share, behind one lock.
    private final class State {
        private let lock = NSLock()
        private var stream: SCStream?
        private var windowID: CGWindowID?
        private var latest: CMSampleBuffer?
        private var stopped = false

        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        var picture: CMSampleBuffer? { lock.lock(); defer { lock.unlock() }; return latest }

        func shows(_ window: CGWindowID) -> Bool { lock.lock(); defer { lock.unlock() }; return stream != nil && windowID == window }

        /// Remembers the stream that now shows the window; false when the player was stopped meanwhile.
        func begin(_ created: SCStream, window: CGWindowID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if stopped { return false }
            stream = created
            windowID = window
            latest = nil
            return true
        }

        /// Forgets the stream and the picture; the stream that was running, to be stopped by the caller.
        func clear(stopping: Bool = false) -> SCStream? {
            lock.lock()
            defer { lock.unlock() }
            if stopping { stopped = true }
            let running = stream
            stream = nil
            windowID = nil
            latest = nil
            return running
        }

        func store(_ sample: CMSampleBuffer, from source: SCStream) {
            lock.lock()
            if source === stream { latest = sample }
            lock.unlock()
        }

        func ended(_ source: SCStream) {
            lock.lock()
            if source === stream {
                stream = nil
                windowID = nil
                latest = nil
            }
            lock.unlock()
        }
    }

    private let pid: pid_t
    private let state = State()
    private let queue = DispatchQueue(label: "markview.qa-native.capture", qos: .userInitiated)
    private let context = CIContext()

    init(pid: pid_t) {
        self.pid = pid
    }

    /// The latest picture of the application's window as a PNG, or nil when the process has no window on screen or none arrives in time.
    /// `frame` (the window as Accessibility reports it, in points) tells which window is meant when the process has several; without it
    /// the largest one is taken. The capture follows the process to another window when the first one is gone.
    func latestPNG(preferring frame: CGRect? = nil) async -> Data? {
        guard await follow(frame) else { return nil }
        let deadline = Date().addingTimeInterval(Self.firstFrameWait)
        while Date() < deadline {
            if let sample = state.picture { return png(from: sample) }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return state.picture.flatMap(png(from:))
    }

    func stop() async {
        try? await state.clear(stopping: true)?.stopCapture()
    }

    // MARK: Choosing the window

    /// Makes sure the stream shows the window that is meant now. False when the process has no window to show.
    private func follow(_ hint: CGRect?) async -> Bool {
        if state.isStopped { return false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = Self.choose(from: content.windows.filter { $0.owningApplication?.processID == pid }, preferring: hint) else {
            try? await state.clear()?.stopCapture()
            return false
        }
        if state.shows(window.windowID) { return true }
        return await start(on: window)
    }

    /// The window of the process that is meant: the one matching the hint, else the largest ordinary window.
    static func choose(from windows: [SCWindow], preferring hint: CGRect?) -> SCWindow? {
        let ordinary = windows.filter { $0.windowLayer == 0 && $0.isOnScreen && $0.frame.width >= 40 && $0.frame.height >= 40 }
        if let hint {
            let distance = { (window: SCWindow) -> CGFloat in
                abs(window.frame.minX - hint.minX) + abs(window.frame.minY - hint.minY) + abs(window.frame.width - hint.width) + abs(window.frame.height - hint.height)
            }
            if let match = ordinary.min(by: { distance($0) < distance($1) }), distance(match) <= 12 { return match }
        }
        return ordinary.max { ($0.frame.width * $0.frame.height, $1.windowID) < ($1.frame.width * $1.frame.height, $0.windowID) }
    }

    // MARK: The stream

    private func start(on window: SCWindow) async -> Bool {
        try? await state.clear()?.stopCapture()
        let scale = Self.scale(of: window.frame)
        let configuration = SCStreamConfiguration()
        configuration.width = min(Int((window.frame.width * scale).rounded()), 4096)
        configuration.height = min(Int((window.frame.height * scale).rounded()), 4096)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.framesPerSecond))
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let created = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: self)
        do {
            try created.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            guard state.begin(created, window: window.windowID) else { return false }
            try await created.startCapture()
            return true
        } catch {
            try? await state.clear()?.stopCapture()
            return false
        }
    }

    /// Pixels per point of the display that holds most of the rect (2 on a Retina display).
    private static func scale(of rect: CGRect) -> CGFloat {
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, 1, &display, &count) == .success, count > 0,
              let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 2 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    private func png(from sample: CMSampleBuffer) -> Data? {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let rendered = context.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: color) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, rendered, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: SCStreamOutput, SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = attachments[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        state.store(sampleBuffer, from: stream)
    }

    /// The window went away or the system ended the capture: the next picture asks again where the window is.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        state.ended(stream)
    }
}
