import Combine
import Foundation
import SwiftUI

// MARK: - Scoped Scroll & Heading Side Table (AR-15)

/// Per-tab scroll position and active heading side table (`AR-15`).
///
/// Scroll offsets are stored in a non-published dictionary so continuous WebView scroll
/// notifications never invalidate `WorkspaceManager` or re-render the window chrome.
/// Active heading changes publish only on `DocumentScrollSideTable`, allowing `TOCView`
/// to observe heading changes without invalidating unrelated views.
@MainActor
final class DocumentScrollSideTable: ObservableObject {
    /// Scroll positions keyed by `OpenTab.id` (not `@Published`, read on demand by session save/restore).
    private(set) var scrollPositions: [UUID: CGFloat] = [:]

    /// Active heading IDs keyed by `OpenTab.id` (`@Published` only to observers of this side table).
    @Published private(set) var activeHeadings: [UUID: String] = [:]

    func setScrollPosition(_ position: CGFloat, for tabID: UUID) {
        let sanitized = position.isFinite ? max(0, position) : 0
        scrollPositions[tabID] = sanitized
    }

    func scrollPosition(for tabID: UUID, fallback: CGFloat = 0) -> CGFloat {
        scrollPositions[tabID] ?? fallback
    }

    func setActiveHeading(_ headingID: String?, for tabID: UUID) {
        if activeHeadings[tabID] != headingID {
            activeHeadings[tabID] = headingID
        }
    }

    func activeHeading(for tabID: UUID, fallback: String? = nil) -> String? {
        activeHeadings[tabID] ?? fallback
    }

    func removeTab(_ tabID: UUID) {
        scrollPositions.removeValue(forKey: tabID)
        if activeHeadings[tabID] != nil {
            activeHeadings.removeValue(forKey: tabID)
        }
    }

    func reset() {
        scrollPositions.removeAll()
        if !activeHeadings.isEmpty {
            activeHeadings.removeAll()
        }
    }
}
