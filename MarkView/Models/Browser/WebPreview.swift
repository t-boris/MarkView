import Foundation

/// What a preview tab shows while it looks for the project's web app.
enum WebPreviewState: Equatable {
    case searching
    /// Several apps in the project: the user picks one.
    case choose([WebAppTarget])
    /// Waiting for the app's server; `started` once MarkView ran its dev script.
    case starting(WebAppTarget, started: Bool)
    case timedOut(WebAppTarget)
    case portInUse(WebAppTarget, Int)
    case noApp
}

/// Reads a dev server's terminal output for the first local address it prints.
@MainActor
final class DevServerWatch {
    private var tail = ""
    private(set) var url: URL?

    func read(_ data: Data) {
        guard url == nil else { return }
        tail += String(decoding: data, as: UTF8.self)
        if tail.count > 16_000 { tail = String(tail.suffix(8_000)) }
        url = WebAppPreview.firstLocalURL(in: tail)
    }
}

/// What a browser tab asks of its window (`BrowserHost`): the places it cannot reach itself. The window shows other tabs, takes a picked
/// element to the AI, and runs the dev server of Preview Web App. The tab keeps a weak reference.
@MainActor
protocol BrowserSessionHost: AnyObject {
    /// `target="_blank"` links and `window.open` of `session`: the page opens in a tab of the window.
    func browserSession(_ session: BrowserSession, openInNewTab url: URL)
    /// An element the person picked on the page, with its screenshot (nil when the element is off screen).
    func browserSession(_ session: BrowserSession, picked element: PickedElement, screenshot: URL?)
    /// Preview Web App: show `target` in `session`, starting its server when it does not answer yet.
    func browserSession(_ session: BrowserSession, startWebApp target: WebAppTarget)
    /// Preview Web App: bring the terminal tab of the dev server `session` started to the front.
    func browserSessionShowTerminal(_ session: BrowserSession)
}
