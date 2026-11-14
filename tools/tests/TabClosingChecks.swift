import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("ok  \(message)")
}

// Tabs: 0 doc, 1 tool, 2 doc, 3 doc, 4 tool, 5 doc
let keep = [false, true, false, false, true, false]
check(TabClosing.activeIndex(afterKeeping: keep, active: 1) == 0, "a tool tab that stays keeps being active (its index moves up past the closed documents)")
check(TabClosing.activeIndex(afterKeeping: keep, active: 4) == 1, "the second tool tab becomes the second tab")
check(TabClosing.activeIndex(afterKeeping: keep, active: 3) == 0, "a closed active document hands over to the nearest tab on its left that stays")
check(TabClosing.activeIndex(afterKeeping: keep, active: 5) == 1, "the last tab closing hands over to the last tool tab")
check(TabClosing.activeIndex(afterKeeping: keep, active: 0) == 0, "with nothing to its left the first tab that stays on its right takes over")
check(TabClosing.activeIndex(afterKeeping: keep, active: 2) == 0, "a document between two tool tabs hands over to the one on its left")

check(TabClosing.activeIndex(afterKeeping: [false, false, false], active: 1) == -1, "when every tab closes the Welcome tab is active")
check(TabClosing.activeIndex(afterKeeping: [true, true], active: 1) == 1, "when nothing closes the active tab is unchanged")
check(TabClosing.activeIndex(afterKeeping: [true, false, true], active: 2) == 1, "a tab after a closed one moves up by one")
check(TabClosing.activeIndex(afterKeeping: keep, active: -1) == -1, "the Welcome tab stays active")
check(TabClosing.activeIndex(afterKeeping: [], active: 0) == -1 && TabClosing.activeIndex(afterKeeping: [], active: -1) == -1, "no tabs means the Welcome tab")
check(TabClosing.activeIndex(afterKeeping: [true], active: 0) == 0, "a single tab that stays")
check(TabClosing.activeIndex(afterKeeping: [false], active: 0) == -1, "a single tab that closes leaves the Welcome tab")
check(TabClosing.activeIndex(afterKeeping: keep, active: 99) == 1, "an index past the end is read as the last tab")
check(TabClosing.activeIndex(afterKeeping: [false, true, false], active: 7) == 0, "an index past the end whose last tab closes hands over to the tab on its left")
print("All tab closing checks passed")
