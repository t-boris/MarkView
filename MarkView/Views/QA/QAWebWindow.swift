import AppKit

/// A QA player's offscreen host must keep WebKit rendering as a visible page. Otherwise WebKit
/// pauses entrance animations at their first (often transparent) frame, even during snapshots.
/// This changes the visibility reported to the hosted view, not the window's position or focus.
@MainActor
final class QAWebWindow: NSWindow {
    override var occlusionState: NSWindow.OcclusionState {
        isVisible ? super.occlusionState.union(.visible) : super.occlusionState
    }
}
