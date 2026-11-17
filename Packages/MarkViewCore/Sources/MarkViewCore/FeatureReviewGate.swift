// A full review can raise review-passed only when it found nothing new and its blocking work is settled.
public enum FeatureReviewGate {
    public static func passed(newFindings: Int, openBlockingQuestions: Int, openSeriousFindings: Int, proposedDecisions: Int) -> Bool {
        newFindings == 0 && openBlockingQuestions == 0 && openSeriousFindings == 0 && proposedDecisions == 0
    }
}
