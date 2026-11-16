import AppKit
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The pictures of the preview a session took (CAP-01..CAP-04): the captures on disk, taking one, and the side-by-side comparison of two.
/// Owns the captures and the comparison the Evidence panel and the chat show.
@MainActor
final class StudioCaptures: ObservableObject {
    unowned let session: StudioSession

    @Published private(set) var captures: [StudioCapture] = []
    @Published var comparison: StudioSession.Comparison?
    /// Whether the comparison fills the whole tab instead of the narrow Evidence panel (BUG-094).
    @Published var comparisonEnlarged = false

    init(session: StudioSession) {
        self.session = session
        captures = StudioStore.loadCaptures(session.root)
    }

    // MARK: - Captures

    /// A picture of the preview linked to the code revision, the scenario and the rendering conditions (CAP-01, CAP-02).
    @discardableResult
    func capture(label: String, operationId: String? = nil) async -> StudioCapture? {
        guard session.appURL != nil else { return nil }
        let info = (try? await session.call("return await window.__markviewStudio.prepareCapture();")) as? [String: Any] ?? [:]
        let image = await session.snapshot(nil)
        _ = try? await session.call("return window.__markviewStudio.finishCapture();")
        guard let image else { return nil }
        let id = "cap-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "") + "-" + UUID().uuidString.prefix(4).lowercased()
        let relative = ProjectPaths.studioCaptureRelativePath(id: id)
        let file = session.root.appendingPathComponent(relative)
        StudioStore.prepareLocalFolder(session.root)
        guard await Task.detached(operation: { StudioImageDiff.writePNG(image, to: file) }).value else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let rendering = StudioRendering(
            engine: info["engine"] as? String ?? "WebKit",
            os: "macOS \(os.majorVersion).\(os.minorVersion)",
            viewport: StudioViewport(width: (info["width"] as? NSNumber)?.intValue ?? session.scenario.viewport.width,
                                     height: (info["height"] as? NSNumber)?.intValue ?? session.scenario.viewport.height),
            devicePixelRatio: (info["devicePixelRatio"] as? NSNumber)?.doubleValue ?? 1,
            fonts: info["fonts"] as? [String] ?? [],
            locale: info["locale"] as? String ?? session.scenario.locale,
            timeZone: info["timeZone"] as? String ?? TimeZone.current.identifier,
            colorScheme: info["colorScheme"] as? String ?? session.scenario.theme.rawValue)
        let revision = await StudioRevisionProbe.compute(root: session.root, editorBuffers: session.editorBuffers()).0
        let capture = StudioCapture(id: id, label: label, file: relative, revision: revision, scenarioId: session.scenario.id,
                                    scenarioRevision: session.scenario.revision,
                                    contractFingerprint: StudioScenarioCompatibility.fingerprint(session.scenario, spec: session.spec),
                                    rendering: rendering, operationId: operationId)
        captures.append(capture)
        let all = captures, root = session.root
        session.io.async { try? StudioStore.saveCaptures(all, root: root) }
        return capture
    }

    func captureNow() {
        session.runWork("Capturing") { session in
            if await session.captureStore.capture(label: "Capture of \(session.scenario.name)") != nil {
                session.notice = "Saved a capture of \(session.scenario.name)."
            }
        }
    }

    func url(of capture: StudioCapture) -> URL { session.root.appendingPathComponent(capture.file) }

    /// Side by side and the pixel difference of two captures (CAP-03, CAP-04); different conditions are named, not hidden.
    /// `enlarge` shows the result at the size of the whole tab (the chat's Compare button), otherwise in the Evidence panel.
    func compare(_ beforeID: String, _ afterID: String, enlarge: Bool = false) {
        guard let before = captures.first(where: { $0.id == beforeID }), let after = captures.first(where: { $0.id == afterID }) else { return }
        let reasons = StudioImageDiff.incomparability(before, after)
        let a = url(of: before), b = url(of: after)
        let output = StudioStore.capturesFolder(session.root).appendingPathComponent("diff-\(before.id)-\(after.id).png")
        Task {
            let result = await Task.detached { () -> (URL?, Double?, CGRect?) in
                guard let first = StudioImageDiff.load(a), let second = StudioImageDiff.load(b),
                      let diff = StudioImageDiff.compare(first, second) else { return (nil, nil, nil) }
                return (StudioImageDiff.writePNG(diff.image, to: output) ? output : nil, diff.ratio, diff.bounds)
            }.value
            comparison = StudioSession.Comparison(before: before, after: after, diffFile: result.0, changedRatio: result.1, changedBounds: result.2, reasons: reasons)
            comparisonEnlarged = enlarge
        }
    }
}
