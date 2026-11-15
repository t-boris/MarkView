import Foundation

/// Which tab is active after some of the open tabs have been closed at once (Foundation only, so it is checked on its own).
enum TabClosing {
    /// `keep[i]` says whether the tab that was at index `i` stays open. `active` is the index of the active tab before the close
    /// (-1 is the pinned Welcome tab). Returns the active index among the tabs that stay (-1: the Welcome tab).
    ///
    /// A tab that stays open stays active. When the active tab closes, the nearest tab that stays on its left takes over, else the
    /// first one on its right, else the Welcome tab.
    static func activeIndex(afterKeeping keep: [Bool], active: Int) -> Int {
        guard active >= 0, !keep.isEmpty else { return -1 }
        let current = min(active, keep.count - 1)
        func position(of index: Int) -> Int { keep[..<index].filter { $0 }.count }
        if keep[current] { return position(of: current) }
        if let left = (0..<current).reversed().first(where: { keep[$0] }) { return position(of: left) }
        if let right = ((current + 1)..<keep.count).first(where: { keep[$0] }) { return position(of: right) }
        return -1
    }
}
