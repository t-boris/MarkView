import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("ok  \(message)")
}
check(FeatureReviewGate.passed(newFindings: 0, openBlockingQuestions: 0, openSeriousFindings: 0, proposedDecisions: 0), "a clean review passes")
check(!FeatureReviewGate.passed(newFindings: 1, openBlockingQuestions: 0, openSeriousFindings: 0, proposedDecisions: 0), "a new finding prevents passing")
check(!FeatureReviewGate.passed(newFindings: 0, openBlockingQuestions: 1, openSeriousFindings: 0, proposedDecisions: 0), "a blocking question prevents passing")
check(!FeatureReviewGate.passed(newFindings: 0, openBlockingQuestions: 0, openSeriousFindings: 1, proposedDecisions: 0), "an unresolved serious finding prevents passing")
check(!FeatureReviewGate.passed(newFindings: 0, openBlockingQuestions: 0, openSeriousFindings: 0, proposedDecisions: 1), "an unaccepted decision prevents passing")
print("All feature review gate checks passed")
