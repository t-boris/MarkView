import XCTest
@testable import MarkViewCore

final class FeatureReviewGateTests: XCTestCase {
    func testReviewPassesOnlyWhenAllBlockingWorkIsSettled() {
        XCTAssertTrue(FeatureReviewGate.passed(newFindings: 0, openBlockingQuestions: 0, openSeriousFindings: 0, proposedDecisions: 0))
        XCTAssertFalse(FeatureReviewGate.passed(newFindings: 1, openBlockingQuestions: 0, openSeriousFindings: 0, proposedDecisions: 0))
        XCTAssertFalse(FeatureReviewGate.passed(newFindings: 0, openBlockingQuestions: 1, openSeriousFindings: 0, proposedDecisions: 0))
        XCTAssertFalse(FeatureReviewGate.passed(newFindings: 0, openBlockingQuestions: 0, openSeriousFindings: 1, proposedDecisions: 0))
        XCTAssertFalse(FeatureReviewGate.passed(newFindings: 0, openBlockingQuestions: 0, openSeriousFindings: 0, proposedDecisions: 1))
    }
}
