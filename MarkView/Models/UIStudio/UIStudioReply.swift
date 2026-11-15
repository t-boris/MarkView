import Foundation

/// Who made a request the session answers: the page in the preview, or the development server through a simulated
/// connection (REQ-007).
enum StudioRequestSource: Equatable {
    case page
    case server(variable: String)

    var transport: String { self == .page ? "page" : "server" }
    var variable: String? { if case .server(let variable) = self { return variable } else { return nil } }
}

/// The session's answer to a request, before it takes the page bridge's or the gateway's form.
enum StudioReply {
    case respond(StudioSimResponse)
    /// To its address, with these headers added (the page only).
    case pass(adding: [String: String])
    /// No answer any more: the session closed or the scenario was reset meanwhile.
    case dropped(String)
}

/// Delivers one reply of a request, once: the "preparing" answer and the real one race, and the first wins (BUG-089).
@MainActor
final class StudioReplyOnce {
    private let deliver: (StudioReply) -> Void
    private(set) var delivered = false

    init(_ deliver: @escaping (StudioReply) -> Void) { self.deliver = deliver }

    /// True when this call delivered the reply.
    @discardableResult
    func reply(_ value: StudioReply) -> Bool {
        guard !delivered else { return false }
        delivered = true
        deliver(value)
        return true
    }

    func callAsFunction(_ value: StudioReply) { reply(value) }
}
