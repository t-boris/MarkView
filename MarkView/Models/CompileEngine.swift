import Foundation

/// Compiles target-specific documentation from the semantic model.
/// 4 MVP profiles: high_level_architecture, migration_plan, deployment_doc, contradiction_report
@MainActor
class CompileEngine: ObservableObject {
    @Published var compiledSections: [CompileArtifact] = []
    @Published var isCompiling = false
    @Published var compilationError: String?

    private weak var database: SemanticDatabase?
    private let orchestrator: AIOrchestrator

    static let profiles: [CompileProfile] = [
        CompileProfile(
            id: "high_level_architecture",
            name: "High-Level Architecture",
            description: "Architecture overview for stakeholders",
            audience: "Technical leadership",
            requiredClaimTypes: ["Definition", "Decision", "CurrentState"],
            requiredEntityTypes: ["System", "Service", "Database"],
            sectionOrder: ["Overview", "Components", "Data Flow", "Decisions", "Constraints"],
            strictness: "moderate",
            language: "en"
        ),
        CompileProfile(
            id: "migration_plan",
            name: "Migration Plan",
            description: "Temporal document with phases and transitions",
            audience: "Engineering teams",
            requiredClaimTypes: ["CurrentState", "TargetState", "Decision"],
            requiredEntityTypes: ["Service", "Database", "Phase"],
            sectionOrder: ["Current State", "Target State", "Migration Phases", "Rollback Strategy", "Risks"],
            strictness: "strict",
            language: "en"
        ),
        CompileProfile(
            id: "deployment_doc",
            name: "Deployment Documentation",
            description: "Operational deployment artifact",
            audience: "DevOps / SRE",
            requiredClaimTypes: ["Requirement", "Constraint", "Decision"],
            requiredEntityTypes: ["Service", "Environment", "Database"],
            sectionOrder: ["Prerequisites", "Architecture", "Deployment Steps", "Configuration", "Monitoring"],
            strictness: "moderate",
            language: "en"
        ),
        CompileProfile(
            id: "contradiction_report",
            name: "Contradiction Report",
            description: "Audit/quality artifact listing contradictions",
            audience: "Technical reviewers",
            requiredClaimTypes: ["Decision", "Constraint", "Assumption"],
            requiredEntityTypes: [],
            sectionOrder: ["Summary", "Contradictions", "Stale Decisions", "Missing Information", "Recommendations"],
            strictness: "strict",
            language: "en"
        ),
        CompileProfile(
            id: "executive_summary",
            name: "Executive Summary",
            description: "Non-technical overview for leadership",
            audience: "C-level / Product",
            requiredClaimTypes: ["Definition", "Decision", "Risk"],
            requiredEntityTypes: ["System", "Service"],
            sectionOrder: ["Summary", "Key Decisions", "Risks", "Timeline", "Next Steps"],
            strictness: "lenient",
            language: "en"
        ),
        CompileProfile(
            id: "system_design",
            name: "System Design Document",
            description: "Detailed system architecture",
            audience: "Engineers",
            requiredClaimTypes: ["Definition", "Decision", "Constraint", "Requirement"],
            requiredEntityTypes: ["System", "Service", "Component", "API", "Database"],
            sectionOrder: ["Overview", "Architecture", "Components", "APIs", "Data Model", "Security", "Scalability"],
            strictness: "strict",
            language: "en"
        ),
        CompileProfile(
            id: "service_design",
            name: "Service Design",
            description: "Individual service specification",
            audience: "Service team",
            requiredClaimTypes: ["Definition", "Requirement", "Constraint"],
            requiredEntityTypes: ["Service", "API", "Database", "Queue"],
            sectionOrder: ["Overview", "API", "Data Model", "Dependencies", "Deployment", "Monitoring"],
            strictness: "moderate",
            language: "en"
        ),
        CompileProfile(
            id: "security_architecture",
            name: "Security Architecture",
            description: "Security design and trust boundaries",
            audience: "Security team",
            requiredClaimTypes: ["Constraint", "Decision", "Requirement", "Risk"],
            requiredEntityTypes: ["System", "Service", "API", "Environment"],
            sectionOrder: ["Trust Boundaries", "Authentication", "Authorization", "Data Protection", "Audit", "Threats"],
            strictness: "strict",
            language: "en"
        ),
        CompileProfile(
            id: "data_architecture",
            name: "Data Architecture",
            description: "Data model and storage design",
            audience: "Data engineers",
            requiredClaimTypes: ["Definition", "Decision", "Constraint"],
            requiredEntityTypes: ["Database", "Service", "Queue"],
            sectionOrder: ["Data Model", "Storage", "Data Flow", "Consistency", "Backup", "Migration"],
            strictness: "moderate",
            language: "en"
        ),
        CompileProfile(
            id: "rollout_plan",
            name: "Rollout Plan",
            description: "Deployment rollout strategy",
            audience: "Engineering + Ops",
            requiredClaimTypes: ["Decision", "Requirement", "Risk"],
            requiredEntityTypes: ["Service", "Environment", "Phase"],
            sectionOrder: ["Pre-conditions", "Rollout Steps", "Validation", "Rollback", "Communication"],
            strictness: "strict",
            language: "en"
        ),
        CompileProfile(
            id: "adr_summary",
            name: "ADR Summary",
            description: "Architecture Decision Records digest",
            audience: "Technical leadership",
            requiredClaimTypes: ["Decision", "Assumption", "Constraint"],
            requiredEntityTypes: ["System", "Service"],
            sectionOrder: ["Active Decisions", "Superseded Decisions", "Open Questions", "Decision Log"],
            strictness: "moderate",
            language: "en"
        ),
        CompileProfile(
            id: "runbook",
            name: "Runbook",
            description: "Operational procedures",
            audience: "SRE / On-call",
            requiredClaimTypes: ["Requirement", "Constraint"],
            requiredEntityTypes: ["Service", "Environment", "Database"],
            sectionOrder: ["Service Overview", "Health Checks", "Common Issues", "Escalation", "Recovery"],
            strictness: "moderate",
            language: "en"
        ),
        CompileProfile(
            id: "integration_architecture",
            name: "Integration Architecture",
            description: "System integration patterns",
            audience: "Integration team",
            requiredClaimTypes: ["Definition", "Decision"],
            requiredEntityTypes: ["API", "Event", "Queue", "Service"],
            sectionOrder: ["Integration Overview", "Sync APIs", "Async Events", "Data Contracts", "Error Handling"],
            strictness: "moderate",
            language: "en"
        )
    ]

    init(database: SemanticDatabase, orchestrator: AIOrchestrator) {
        self.database = database
        self.orchestrator = orchestrator
    }

    /// Compile a document using the specified profile
    func compile(profileId: String, blocks: [SemanticBlock], documentId: String) async {
        guard let profile = Self.profiles.first(where: { $0.id == profileId }) else {
            compilationError = "Unknown profile: \(profileId)"
            return
        }

        isCompiling = true
        compilationError = nil
        compiledSections = []

        let jobId = UUID().uuidString

        // Template-based assembly (no LLM) — assemble sections from blocks
        for (index, sectionTitle) in profile.sectionOrder.enumerated() {
            let relevantBlocks = blocks.filter { block in
                block.headingPath.contains(where: {
                    $0.lowercased().contains(sectionTitle.lowercased())
                })
            }

            let content: String
            if relevantBlocks.isEmpty {
                content = "_No content found for this section. Consider adding documentation about \(sectionTitle)._"
            } else {
                content = relevantBlocks.map { $0.content }.joined(separator: "\n\n")
            }

            let artifact = CompileArtifact(
                id: "\(jobId)_\(index)",
                compileJobId: jobId,
                artifactKind: "section",
                sectionKey: sectionTitle,
                content: content,
                contentHash: "",
                sourceBlockIds: relevantBlocks.map { $0.id },
                sourceClaimIds: [],
                createdAt: Date()
            )
            compiledSections.append(artifact)
        }

        isCompiling = false
    }

    /// Export compiled document as markdown
    func exportAsMarkdown(title: String) -> String {
        var output = "# \(title)\n\n"
        output += "_Compiled by MarkView DDE_\n\n---\n\n"

        for section in compiledSections {
            if let key = section.sectionKey {
                output += "## \(key)\n\n"
            }
            output += section.content + "\n\n"
        }

        return output
    }
}
