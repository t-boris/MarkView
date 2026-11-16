import Foundation
import WebKit

/// The page-to-native handler of a session. A separate object, so the web view's content controller does not keep the
/// session alive.
final class StudioMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var session: StudioSession?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let session else {
            replyHandler(nil, "The UI Studio session is closed.")
            return
        }
        session.receive(message, reply: replyHandler)
    }
}
