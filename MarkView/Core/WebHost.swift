import Foundation
import WebKit

/// Weak proxy for `WKScriptMessageHandler` that breaks the strong retain cycle
/// between `WKUserContentController` and the handler (`AR-27`).
public final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    public weak var target: WKScriptMessageHandler?

    public init(_ target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Shared WebKit configuration factory and registration helpers (`AR-04`, `AR-27`).
public enum WebHost {
    @MainActor
    public static func makeConfiguration(
        messageHandler: WKScriptMessageHandler? = nil,
        channelName: String = "editorBridge",
        schemeHandlers: [(String, WKURLSchemeHandler)] = []
    ) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        if let messageHandler {
            contentController.add(WeakScriptMessageHandler(messageHandler), name: channelName)
        }
        config.userContentController = contentController
        for (scheme, handler) in schemeHandlers {
            config.setURLSchemeHandler(handler, forURLScheme: scheme)
        }
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        return config
    }

    @MainActor
    public static func configureInspectable(_ webView: WKWebView) {
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
    }
}
