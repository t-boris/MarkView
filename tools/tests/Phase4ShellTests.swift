import Combine
import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

print("=== Phase 4 Shell Decomposition & Scoped State Tests (AR-14..AR-19) ===")

@MainActor
func runPhase4Tests() async {
    // 1. AR-14: MarkdownDocumentChunker lossless splitting & skeleton verification
    let sampleMarkdown = """
    ---
    title: Sample
    ---

    # Introduction

    First paragraph with prose.

    | Col A | Col B |
    | --- | --- |
    | 1 | 2 |

    ```swift
    let x = 42
    ```

    - Item one
    - Item two
    """
    let (prefix, chunks) = MarkdownDocumentChunker.splitForTranslation(sampleMarkdown, maxChars: 120)
    let rejoined = prefix + chunks.map { $0.text + $0.separator }.joined()
    check(rejoined == sampleMarkdown, "AR-14: MarkdownDocumentChunker.splitForTranslation is byte-for-byte lossless")
    check(chunks.first?.isTranslatable == false, "AR-14: YAML front matter is marked non-translatable")
    check(chunks.contains(where: { !$0.isTranslatable && $0.text.contains("let x = 42") }), "AR-14: Fenced code block is marked non-translatable")

    let skel = MarkdownDocumentChunker.skeleton(of: sampleMarkdown)
    check(skel.headingLevels == [1], "AR-14: MarkdownDocumentChunker.skeleton extracts heading levels")
    check(skel.tableRows == 3, "AR-14: MarkdownDocumentChunker.skeleton counts table rows")
    check(skel.listItems == 2, "AR-14: MarkdownDocumentChunker.skeleton counts list items")
    check(skel.fences == 2, "AR-14: MarkdownDocumentChunker.skeleton counts code fences")
    check(MarkdownDocumentChunker.normalizeTranslation("```markdown\nHello world\n```") == "Hello world", "AR-14: normalizeTranslation strips outer fence")

    // 2. AR-15: DocumentScrollSideTable scoped observation & silent tab metadata updates
    let scrollState = DocumentScrollSideTable()
    var scrollPublishedCount = 0
    let cancellable = scrollState.objectWillChange.sink { _ in
        scrollPublishedCount += 1
    }
    let tabID = UUID()
    scrollState.setScrollPosition(128.5, for: tabID)
    scrollState.setScrollPosition(256.0, for: tabID)
    check(scrollState.scrollPosition(for: tabID) == 256.0, "AR-15: DocumentScrollSideTable stores per-tab scroll position")
    check(scrollPublishedCount == 0, "AR-15: DocumentScrollSideTable does not fire objectWillChange on scroll updates")

    scrollState.setActiveHeading("section-1", for: tabID)
    check(scrollPublishedCount == 1, "AR-15: DocumentScrollSideTable fires objectWillChange when active heading changes")
    scrollState.setActiveHeading("section-1", for: tabID)
    check(scrollPublishedCount == 1, "AR-15: DocumentScrollSideTable deduplicates identical active heading updates")
    _ = cancellable

    // 3. AR-19: TaskBag keyed cancellation and cleanup
    let bag = TaskBag()
    let task1 = Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
    bag.store(task1, for: "index")
    check(bag.contains(key: "index") && bag.activeCount == 1, "AR-19: TaskBag tracks keyed task")

    let task2 = Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
    bag.store(task2, for: "index")
    check(task1.isCancelled, "AR-19: Storing new task under existing key cancels previous task")

    let unkeyedToken = bag.insert(Task {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
    })
    check(bag.activeCount == 2, "AR-19: TaskBag tracks both keyed and unkeyed tasks")
    bag.cancel(id: unkeyedToken)
    check(bag.activeCount == 1, "AR-19: TaskBag cancels unkeyed task by token")

    bag.cancelAll()
    check(task2.isCancelled && bag.activeCount == 0, "AR-19: TaskBag.cancelAll cancels all tracked tasks")

    // 4. FU-11: DocumentScrollSideTable cleans up per-tab scroll state when tabs close
    let closedTabID = UUID()
    scrollState.setScrollPosition(420.0, for: closedTabID)
    scrollState.setActiveHeading("h-close", for: closedTabID)
    scrollState.removeTab(closedTabID)
    check(scrollState.scrollPosition(for: closedTabID) == 0 && scrollState.activeHeading(for: closedTabID) == nil,
          "FU-11: DocumentScrollSideTable.removeTab clears scroll position and active heading for closed tabs")
}

let semaphore = DispatchSemaphore(value: 0)
Task { @MainActor in
    await runPhase4Tests()
    semaphore.signal()
}
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
}

print("\nPhase 4 summary: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
