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
