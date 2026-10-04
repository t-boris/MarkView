import Foundation

/// Finder-like selection in a list (the Files sidebar, the feature navigator): a click selects
/// one item, ⌘-click adds or removes one, ⇧-click selects the range from the anchor — the last
/// item clicked without ⇧ — to the clicked one, in the list's order.
struct ListSelection<Item: Hashable>: Equatable {
    private(set) var items: Set<Item> = []
    private(set) var anchor: Item?

    enum Click { case plain, toggle, range }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    func contains(_ item: Item) -> Bool { items.contains(item) }

    /// The selected items in the list's order.
    func ordered(_ order: [Item]) -> [Item] { order.filter(items.contains) }

    mutating func click(_ item: Item, _ kind: Click, in order: [Item]) {
        switch kind {
        case .plain:
            items = [item]
            anchor = item
        case .toggle:
            if items.contains(item) { items.remove(item) } else { items.insert(item) }
            anchor = item
        case .range:
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: item) else {
                items = [item]
                self.anchor = item
                return
            }
            items = Set(order[min(from, to)...max(from, to)])
        }
    }

    mutating func clear() {
        items = []
        anchor = nil
    }

    /// Forget items that are no longer listed (deleted, moved, filtered out).
    mutating func keep(only order: [Item]) {
        items.formIntersection(order)
        if let anchor, !order.contains(anchor) { self.anchor = nil }
    }
}
