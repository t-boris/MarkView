import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// What a page's theme function receives. Equatable, so a host can leave out a theme the page already has.
struct WebThemeArguments: Equatable {
    let id: String
    let accent: String?
    /// The theme's data as one line of JSON (`ThemeDefinition.webPayload`).
    let payload: String

    /// The arguments for `JS.call`: the payload goes in as a parsed JSON value, never as script text.
    var list: [Any] { [id, accent ?? NSNull(), JS.JSONText(payload)] }
}
