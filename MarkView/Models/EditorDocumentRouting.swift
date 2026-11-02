import Foundation

/// Decides which tab a message from the editor page belongs to.
///
/// One web view shows the document of one tab at a time. Text the page reports (`contentChanged`) and
/// the save request (`saveRequested`) describe the document the page is showing, not necessarily the
/// tab the app has selected at the moment the message is handled: a tab can be switched, closed or
/// reordered while the message is in flight, and the page can still hold the previous document.
/// Applying such a message to the selected tab wrote one file's text over another file (BUG-031).
///
/// The app therefore tells the page which tab it shows (`window.mvDocumentId`), the page names that id
/// in every message, and the message is applied to that tab only.
enum EditorDocumentRouting {
    /// The tab id the page attached to a message; an empty, missing or malformed value means "not named".
    static func documentID(from raw: Any?) -> UUID? {
        guard let text = raw as? String, !text.isEmpty else { return nil }
        return UUID(uuidString: text)
    }

    /// Index of the tab the message applies to, or nil when it must be dropped.
    ///
    /// - A named document goes to its own tab. If that tab was closed meanwhile, the message is dropped:
    ///   it must never fall back to whichever tab is selected now.
    /// - A message that names no document (the page shows an insight, an X-Ray or nothing yet) keeps the
    ///   earlier behaviour and applies to the selected tab.
    static func targetIndex(documentID: UUID?, tabIDs: [UUID], activeIndex: Int) -> Int? {
        if let documentID { return tabIDs.firstIndex(of: documentID) }
        return tabIDs.indices.contains(activeIndex) ? activeIndex : nil
    }
}
