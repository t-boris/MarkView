import AppKit
import Foundation
import WebKit

/// One screen of one saved version of a prototype from code, rendered offscreen and returned as a PNG (feature "Prototype and code stay
/// in step", REQ-017).
///
/// The hand-off shows what changed by a picture before and a picture after, so the same screen must be rendered the same way from two
/// different folders: the baseline's `versions/v<N>` and the live `site/`. Each capture gets a web view of its own with a non-persistent
/// data store, so the sample data is the seed on both sides and nothing is shared with the visible preview or with the other capture;
/// the folder is served through the same scheme handler as the preview (one origin, real errors). The viewport is fixed and the person's
/// theme is applied before the first paint. No assistant takes part. The web view sits in a borderless window outside every screen,
/// because WebKit renders and snapshots only a view that has a window.
@MainActor
final class PrototypeScreenshots {
    /// What to render.
    struct Target: Equatable {
        /// The folder that is served: the live `site/` or a version's folder.
        var site: URL
        /// A screen id of the plan; its route is read from `App.plan` of that very version. nil shows the page's first screen.
        var screen: String?
        /// A page of the site instead of a screen (an isolated component view); wins over `screen`.
        var page: String?
    }

    /// The root attribute that selects a theme of the original stylesheets (`data-theme="tastytrade"`), as the preview sets it.
    struct Theme: Equatable {
        var attribute: String
        var id: String
    }

    enum Failure: Error, Equatable, LocalizedError {
        case noSite
        case noScreen(String)
        case loadFailed(String)
        case timedOut(String)
        case snapshotFailed

        var errorDescription: String? {
            switch self {
            case .noSite: return "the version has no files to show"
            case .noScreen(let id): return "the version has no screen \"\(id)\""
            case .loadFailed(let reason): return "the page did not load (\(reason))"
            case .timedOut(let what): return "timed out: \(what)"
            case .snapshotFailed: return "the picture could not be taken"
            }
        }
    }

    /// The same size for every capture, so a before and an after compare.
    static let viewport = CGSize(width: 1280, height: 800)
    /// Pictures are scaled to this longest side before they are saved.
    static let maxSide: CGFloat = 1600
    private static let loadLimit: TimeInterval = 20
    private static let settleLimit: TimeInterval = 8

    // MARK: - Pure parts

    /// The route of screen `id` in `plan`, the JSON of `App.plan` (`[{id, route, …}]`), with a leading slash; nil when there is no such screen.
    static func route(of id: String, inPlan plan: String) -> String? {
        guard let data = plan.data(using: .utf8), let screens = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let screen = screens.first(where: { $0["id"] as? String == id }), var route = screen["route"] as? String,
              !route.isEmpty else { return nil }
        if route.hasPrefix("#") { route.removeFirst() }
        return route.hasPrefix("/") ? route : "/" + route
    }

    /// Runs in the page: resolves once the page has had no change for `quiet` ms, after at least `min` and at most `max` ms, and has no
    /// loading skeleton on it. The same idea as the audit's settle, kept here because that one is private to its script.
    static let settleScript = """
    const min = 900, quiet = 400, max = 6000;
    await document.fonts.ready.catch(() => {});
    await new Promise((resolve) => {
      const start = Date.now();
      let last = start;
      const observer = new MutationObserver(() => { last = Date.now(); });
      observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true });
      (function tick() {
        const now = Date.now();
        const loading = document.querySelector('.skeleton,[aria-busy="true"]') !== null;
        if ((now - start >= min && now - last >= quiet && !loading) || now - start >= max) { observer.disconnect(); resolve(); }
        else setTimeout(tick, 60);
      })();
    });
    return 'settled';
    """

    // MARK: - Capturing

    /// The PNG of `target`. Throws a `Failure` that says in words why there is no picture; the caller reports it and goes on.
    func capture(_ target: Target, theme: Theme? = nil) async throws -> Data {
        let index = target.site.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: index.path) else { throw Failure.noSite }
        if let page = target.page, !FileManager.default.fileExists(atPath: target.site.appendingPathComponent(page).path) {
            throw Failure.noScreen(page)
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let handler = PrototypeSchemeHandler(root: target.site)
        configuration.setURLSchemeHandler(handler, forURLScheme: PrototypeSchemeHandler.scheme)
        if let theme {
            configuration.userContentController.addUserScript(WKUserScript(
                source: PrototypeThemes.startScript(attribute: theme.attribute, id: theme.id),
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let size = Self.viewport
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = web
        window.orderBack(nil)
        let loader = Loader()
        web.navigationDelegate = loader
        defer {
            web.navigationDelegate = nil
            web.stopLoading()
            window.contentView = nil
            window.close()
        }

        guard let address = PrototypeSchemeHandler.address(of: target.page ?? "index.html") else { throw Failure.loadFailed("no address") }
        web.load(URLRequest(url: address))
        try await loader.finished(within: Self.loadLimit)

        if target.page == nil, let id = target.screen {
            guard let plan = try await web.evaluate("return JSON.stringify((window.App && App.plan) || []);") as? String,
                  let route = Self.route(of: id, inPlan: plan) else { throw Failure.noScreen(id) }
            _ = try await web.evaluate("location.hash = \(PrototypeThemes.literal("#" + route)); return 'ok'")
        }
        _ = try await web.evaluate(Self.settleScript, limit: Self.settleLimit + 4)

        let configurationShot = WKSnapshotConfiguration()
        configurationShot.rect = NSRect(origin: .zero, size: size)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with: configurationShot) { image, error in
                if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? Failure.snapshotFailed) }
            }
        }
        guard let png = PrototypeImages.pngData(from: image, maxSide: Self.maxSide) else { throw Failure.snapshotFailed }
        return png
    }

    // MARK: - Navigation

    /// Answers once the page finished loading, failed, or the limit passed.
    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        func finished(within limit: TimeInterval) async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        if let result = self.result { continuation.resume(with: result) } else { self.continuation = continuation }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                    throw Failure.timedOut("the page did not finish loading")
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard self.result == nil else { return }
            self.result = result
            continuation?.resume(with: result)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(.failure(Failure.loadFailed(error.localizedDescription)))
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(.failure(Failure.loadFailed(error.localizedDescription)))
        }
    }
}

private extension WKWebView {
    /// Runs an async function body in the page and returns its result; a thrown page error becomes a `Failure`.
    @MainActor
    func evaluate(_ body: String, limit: TimeInterval = 10) async throws -> Any? {
        try await withThrowingTaskGroup(of: Any?.self) { group in
            group.addTask { @MainActor in
                do { return try await self.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page) }
                catch { throw PrototypeScreenshots.Failure.loadFailed(((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription) }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                throw PrototypeScreenshots.Failure.timedOut("the page did not answer")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return nil }
            return first
        }
    }
}
