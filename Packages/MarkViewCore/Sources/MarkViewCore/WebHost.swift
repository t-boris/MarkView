import Foundation
import WebKit

/// The one place a web view's configuration and the web view itself are made (`AR-27`).
///
/// Every host (the editor, the terminal, the browser tab, UI Studio, the prototype preview, the discussion thread, the PDF and
/// screenshot renderers, the small preview panels) calls `makeConfiguration` and `makeWebView`, so a host cannot forget what a
/// host must do:
///
/// - **Handlers are registered weakly.** `WKUserContentController` retains its message handlers, so a handler that owns or reaches
///   its web view makes a retain cycle that no one can break. Each handler is registered through a weak proxy: the host keeps the
///   strong reference to its handler, and releasing the host releases the web view.
/// - **Scripts, schemes and the data store are named in one call**, in the order the page needs them.
/// - **A page cannot open windows by itself** (`allowsPopups` is off) and a preview can have JavaScript turned off.
/// - **A Debug build can be inspected** (Safari's Web Inspector), a Release build cannot.
///
/// `limitsNavigationsToAppBoundDomains` is not set: it needs a fixed list of domains in the Info.plist, and the hosts that load
/// the open web (browser tabs, UI Studio, the QA player) navigate wherever the person or the assistant goes, while the other
/// hosts load only the app's own files and schemes.
public enum WebHost {
    /// Where a page keeps its cookies and storage.
    public enum DataStore {
        /// WebKit's shared persistent store: every web view that uses it shares its sign-ins and its `localStorage`.
        case `default`
        /// A store of its own that leaves nothing on disk and shares nothing.
        case nonPersistent
        /// A store the caller made and keeps (a QA player's own, so players never share a sign-in).
        case store(WKWebsiteDataStore)
    }

    /// A page-to-native message channel: `window.webkit.messageHandlers.<name>.postMessage(...)` in `world`.
    public struct Handler {
        enum Target {
            case message(WKScriptMessageHandler)
            case reply(WKScriptMessageHandlerWithReply)
        }
        let name: String
        let world: WKContentWorld
        let target: Target

        /// A handler that takes a message and does not answer it. The caller keeps `target` alive.
        public static func message(_ name: String, _ target: WKScriptMessageHandler, in world: WKContentWorld = .page) -> Handler {
            Handler(name: name, world: world, target: .message(target))
        }

        /// A handler whose page call returns a promise that `target` answers. The caller keeps `target` alive.
        public static func reply(_ name: String, _ target: WKScriptMessageHandlerWithReply, in world: WKContentWorld = .page) -> Handler {
            Handler(name: name, world: world, target: .reply(target))
        }
    }

    /// A configuration with `handlers` registered weakly, `userScripts` added in order and `urlSchemeHandlers` set.
    ///
    /// - `allowsJavaScript`: false for a preview that must not run the page's scripts.
    /// - `allowsPopups`: true only for a host that answers `createWebViewWith` (the browser tab and UI Studio); the rest never
    ///   let a script open a window.
    /// - `allowsElementFullscreen`: true for the browser tab, where a video can fill the screen.
    /// - `applicationName`: appended to the user agent, for the sites that refuse an embedded browser that does not name itself.
    @MainActor
    public static func makeConfiguration(
        dataStore: DataStore = .default,
        handlers: [Handler] = [],
        userScripts: [WKUserScript] = [],
        urlSchemeHandlers: [(scheme: String, handler: WKURLSchemeHandler)] = [],
        allowsJavaScript: Bool = true,
        allowsPopups: Bool = false,
        allowsElementFullscreen: Bool = false,
        applicationName: String? = nil
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        switch dataStore {
        case .default: break
        case .nonPersistent: configuration.websiteDataStore = .nonPersistent()
        case .store(let store): configuration.websiteDataStore = store
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowsPopups
        configuration.preferences.isElementFullscreenEnabled = allowsElementFullscreen
        if let applicationName { configuration.applicationNameForUserAgent = applicationName }
        #if DEBUG
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        let controller = configuration.userContentController
        for handler in handlers { register(handler, in: controller) }
        for script in userScripts { controller.addUserScript(script) }
        for (scheme, handler) in urlSchemeHandlers { configuration.setURLSchemeHandler(handler, forURLScheme: scheme) }
        return configuration
    }

    /// A web view with `configuration`, inspectable in a Debug build.
    @MainActor
    public static func makeWebView(frame: CGRect = .zero, configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: frame, configuration: configuration)
        markInspectable(webView)
        return webView
    }

    /// Lets Safari's Web Inspector attach to `webView` in a Debug build; does nothing in a Release build. For a host whose web view
    /// is a subclass of `WKWebView` and so cannot come from `makeWebView`.
    @MainActor
    public static func markInspectable(_ webView: WKWebView) {
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
    }

    @MainActor
    private static func register(_ handler: Handler, in controller: WKUserContentController) {
        switch handler.target {
        case .message(let target):
            controller.add(WeakScriptMessageHandler(target), contentWorld: handler.world, name: handler.name)
        case .reply(let target):
            controller.addScriptMessageHandler(WeakScriptMessageHandlerWithReply(target), contentWorld: handler.world, name: handler.name)
        }
    }
}

/// Weak proxy for `WKScriptMessageHandler`: the content controller retains the proxy, the proxy does not retain the target.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// The same for a handler that answers: when its target is gone the page's promise is rejected, not left waiting.
final class WeakScriptMessageHandlerWithReply: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: WKScriptMessageHandlerWithReply?

    init(_ target: WKScriptMessageHandlerWithReply) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let target else {
            replyHandler(nil, "The page's host is closed.")
            return
        }
        target.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}
