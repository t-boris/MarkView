import XCTest
@testable import MarkViewCore

final class ConflictPromptTests: XCTestCase {
    func testConflictInstructions() {
        let merge = ConflictPrompt.make(files: ["a.swift", "docs/b.md"], operation: "merge", branch: "feat/x")
        XCTAssertTrue(merge.contains("- a.swift\n- docs/b.md"))
        XCTAssertTrue(merge.contains("middle of a merge on branch feat/x"))
        XCTAssertTrue(merge.contains("`git merge --continue`"))
        XCTAssertTrue(merge.contains("Do not commit, push or abort"))
        XCTAssertTrue(ConflictPrompt.make(files: ["a"], operation: "rebase", branch: "b").contains("`git rebase --continue`"))
        let plain = ConflictPrompt.make(files: ["a"], operation: nil, branch: "main")
        XCTAssertTrue(plain.contains("The work tree is on branch main."))
        XCTAssertTrue(plain.contains("the matching `git … --continue`"))
        let many = ConflictPrompt.make(files: (1...75).map { "f\($0).txt" }, operation: "merge", branch: "m")
        XCTAssertTrue(many.contains("- f60.txt"))
        XCTAssertFalse(many.contains("- f61.txt"))
        XCTAssertTrue(many.contains("and 15 more"))
    }
}
