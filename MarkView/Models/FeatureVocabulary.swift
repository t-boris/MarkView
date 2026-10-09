import Foundation

/// Statuses and vocabularies (spec §14–§28), stored lower-case in front matter.
enum FeatureVocabulary {
    static let featureStatuses = ["idea", "exploring", "draft", "review", "resolving", "ready",
                                  "implementing", "implemented", "verified", "archived"]
    static let requirementStatuses = ["draft", "review", "approved", "rejected", "superseded"]
    static let requirementTypes = ["functional", "non-functional", "ux", "security", "performance",
                                   "reliability", "privacy", "analytics", "operational", "compliance"]
    static let questionStatuses = ["open", "answered", "deferred"]
    static let questionTypes = ["product", "technical", "architecture", "ux", "security", "business",
                                "research", "clarification"]
    static let decisionStatuses = ["proposed", "accepted", "rejected", "superseded"]
    static let findingStatuses = ["open", "discussing", "resolved", "accepted-risk", "dismissed"]
    static let severities = ["blocker", "high", "medium", "low"]
    static let findingCategories = ["completeness", "ambiguity", "contradiction", "edge-case", "architecture",
                                    "security", "ux", "operations", "open-question", "related-docs",
                                    "external-research"]
    static let perspectives = ["Product", "UX", "Architecture", "Backend", "Frontend", "Security", "QA",
                               "Reliability", "Operations", "Data", "Privacy", "Business"]
    static let claimKinds = ["project-fact", "external-fact", "ai-inference", "user-decision", "open-assumption"]
    static let sourceRoles = ["ui-reference", "external-research", "previous-implementation", "related-specification",
                              "stakeholder-input", "architecture-reference", "api-documentation", "code",
                              "meeting-notes", "requirements"]
    /// What guided discovery tracks (spec §7).
    static let understanding = ["Problem", "Target Users", "Primary Workflow", "Permissions", "Failure Scenarios",
                                "Data Model", "Notifications", "Security", "Analytics", "Dependencies",
                                "Acceptance Criteria"]
    /// known | partial | unknown | n/a
    static let understandingStates = ["known", "partial", "unknown", "n/a"]

    static func label(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: " ").capitalized
    }
}
