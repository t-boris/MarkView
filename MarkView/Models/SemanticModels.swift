import Foundation

// MARK: - Flexible JSON Value (for LLM responses that return mixed types)

enum AnyCodableValue: Codable, Hashable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let a = try? c.decode([AnyCodableValue].self) { self = .array(a) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

// MARK: - Block Types

enum BlockType: String, Codable, CaseIterable {
    case document
    case section
    case paragraph
    case list
    case listItem
    case table
    case tableRow
    case codeBlock
    case quote
    case callout
    case diagramReference
    case frontmatterProperty
    case adrBlock
    case rfcBlock
}

// MARK: - Semantic Block

struct SemanticBlock: Identifiable, Codable {
    let id: String
    let documentId: String
    let type: BlockType
    let level: Int?
    let content: String
    let plainText: String
    let contentHash: String
    var semanticHash: String?
    let headingPath: [String]
    let parentBlockId: String?
    let lineStart: Int
    let lineEnd: Int
    let position: Int
    let language: String?
    let anchor: String?

    /// Initialize from JS dictionary (bridge message payload)
    init?(from dict: [String: Any]) {
        guard let id = dict["id"] as? String,
              let typeStr = dict["type"] as? String,
              let content = dict["content"] as? String,
              let contentHash = dict["contentHash"] as? String,
              let lineStart = dict["lineStart"] as? Int,
              let lineEnd = dict["lineEnd"] as? Int,
              let position = dict["position"] as? Int else {
            return nil
        }

        self.id = id
        self.documentId = dict["documentId"] as? String ?? ""
        self.type = BlockType(rawValue: typeStr) ?? .paragraph
        self.level = dict["level"] as? Int
        self.content = content
        self.plainText = dict["plainText"] as? String ?? content
        self.contentHash = contentHash
        self.semanticHash = dict["semanticHash"] as? String
        self.headingPath = dict["headingPath"] as? [String] ?? []
        self.parentBlockId = dict["parentBlockId"] as? String
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.position = position
        self.language = dict["language"] as? String
        self.anchor = dict["anchor"] as? String
    }
}

// MARK: - Blocks Delta

struct BlocksDelta {
    let added: [SemanticBlock]
    let removed: [String]       // block IDs
    let changed: [SemanticBlock]
    let unchanged: [String]     // block IDs

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
    }
}

// MARK: - Block Compilation State

enum BlockCompilationState: Equatable {
    case pending
    case compiling
    case compiled
    case error(String)
}

// MARK: - Semantic Entity (§3.2)

struct SemanticEntity: Identifiable, Codable {
    let id: String
    var name: String
    var type: String
    var canonicalName: String
    var aliases: [String]?
    var attributes: [String: AnyCodableValue]?
    var description: String?
    var status: String?
    var sourceFile: String?
    var sourceBlockId: String?
    var createdAt: Date?
    var updatedAt: Date?

    // Non-optional computed accessors with defaults
    var safeAliases: [String] { aliases ?? [] }
    var safeStatus: String { status ?? "active" }
}

// MARK: - Semantic Claim (§3.3)

struct SemanticClaim: Identifiable, Codable {
    let id: String
    var type: String?
    var subjectEntityId: String?
    var predicate: String?
    var object: AnyCodableValue?
    var objectEntityId: String?

    var sourceFile: String?
    var sourceBlockId: String?
    var rawText: String?

    var status: String?
    var confidence: Double?
    var authorityLevel: String?
    var supersededBy: String?

    var scopeKind: String?
    var scopeValue: String?

    var temporalContextId: String?
    var effectiveFrom: String?
    var effectiveTo: String?

    var evidenceBlockIds: [String]?

    var createdAt: Date?
    var updatedAt: Date?

    // Non-optional computed accessors with defaults
    var safeType: String { type ?? "Definition" }
    var safeRawText: String { rawText ?? safeObject }
    var safeStatus: String { status ?? "proposed" }
    var safeConfidence: Double { confidence ?? 0.5 }
    var safeScopeKind: String { scopeKind ?? "global" }
    var safeSubjectEntityId: String { subjectEntityId ?? "" }
    var safeSourceBlockId: String { sourceBlockId ?? "" }
    var safeSourceFile: String { sourceFile ?? "" }
    var safeEvidenceBlockIds: [String] { evidenceBlockIds ?? [] }
    var safeObject: String {
        switch object {
        case .string(let s): return s
        case .array(let arr): return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }.joined(separator: ", ")
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .bool(let b): return "\(b)"
        default: return ""
        }
    }
}

// MARK: - Semantic Relation (§3.5)

struct SemanticRelation: Identifiable, Codable {
    let id: String
    var sourceId: String
    var targetId: String
    var type: String
    var sourceFile: String?
    var sourceBlockId: String?
    var confidence: Double?
    var createdAt: Date?
}

// MARK: - Temporal Context (§3.4)

struct TemporalContext: Identifiable, Codable {
    let id: String
    var label: String
    var kind: String                    // phase, milestone, release, version, calendar_window
    var orderIndex: Int
    var startTime: String?
    var endTime: String?
    var parentTemporalContextId: String?
}

// MARK: - Transition (§3.4)

struct Transition: Identifiable, Codable {
    let id: String
    var entityId: String
    var fromState: String
    var toState: String
    var fromTemporalContextId: String
    var toTemporalContextId: String
    var preconditions: [String]
    var postconditions: [String]
    var rollbackStrategy: String?
    var trigger: String?
    var evidenceBlockIds: [String]
}

// MARK: - Evidence Link (§3.6)

struct EvidenceLink: Identifiable, Codable {
    let id: String
    var claimId: String
    var blockId: String
    var documentId: String
    var quoteSpanStart: Int?
    var quoteSpanEnd: Int?
    var confidence: Double
    var extractionMethod: String        // llm, rule, manual
}

// MARK: - AI Job (§3.11)

struct AIJob: Identifiable, Codable {
    let id: String
    let jobType: AIJobType
    var priority: CompilationPriority
    var status: AIJobStatus
    let documentId: String?
    let blockIds: [String]
    let inputHash: String
    let modelPolicy: String?
    let privacyMode: PrivacyMode
    var resultRef: String?
    var errorState: String?
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var retryCount: Int
    var costTokens: Int?
}

enum AIJobType: String, Codable {
    case extractBlockSemantics
    case extractClaims
    case extractTemporalStructure
    case rewriteForClarity
    case rewritePreservingClaims
    case rewriteForAudience
    case fixContradiction
    case alignWithDecision
    case alignWithPhase
    case addMissingTransition
    case addMissingRationale
    case generateSectionDraft
    case generateExecutiveSummary
    case generateDecisionDigest
    case reviewCompiledSection
    case reviewContradictionCluster
    case translateBlock
    case translateSection
    case normalizeEntityCluster
    case normalizeTerminology
    case explainDiagnostic
    case explainImpactOfChange
    case buildSectionPlan
    case suggestMissingInputs
    case analyzeTemplateGaps
    case identifyHiddenAssumptions
    case generateAuthorQuestions
    case draftMissingSection
}

enum AIJobStatus: String, Codable {
    case pending, inProgress, completed, failed, cancelled
}

enum CompilationPriority: String, Codable {
    case immediate      // 0-30ms
    case responsive     // 50-150ms
    case deferred       // 200-1000ms
    case background     // when idle
}

enum PrivacyMode: String, Codable {
    case localOnly
    case redactBeforeSend
    case trustedRemote
}

// MARK: - Block Extraction Result (from AI)

struct BlockExtractionResult: Codable {
    var entities: [SemanticEntity]?
    var claims: [SemanticClaim]?
    var relations: [SemanticRelation]?
    var temporalContexts: [TemporalContext]?
    var transitions: [Transition]?

    // Safe accessors
    var safeEntities: [SemanticEntity] { entities ?? [] }
    var safeClaims: [SemanticClaim] { claims ?? [] }
    var safeRelations: [SemanticRelation] { relations ?? [] }
    var safeTemporalContexts: [TemporalContext] { temporalContexts ?? [] }
    var safeTransitions: [Transition] { transitions ?? [] }
}

// MARK: - Diagnostic (§11)

struct Diagnostic: Identifiable, Codable {
    let id: String
    var type: DiagnosticType
    var severity: DiagnosticSeverity
    var message: String
    var explanation: String?
    var documentId: String
    var blockId: String?
    var claimIds: [String]
    var entityIds: [String]
    var suggestedFix: String?
    var isSuppressed: Bool
    let createdAt: Date
}

enum DiagnosticType: String, Codable {
    case duplicateDefinition
    case undefinedReference
    case missingOwner
    case missingRationale
    case staleDecision
    case architecturalContradiction
    case missingTransition
    case temporalDependencyCycle
    case missingSection
    case missingRequiredClaim
    case missingRollback
}

enum DiagnosticSeverity: String, Codable {
    case error
    case warning
    case info
    case hint
}

// MARK: - Compile Profile (§13)

struct CompileProfile: Identifiable, Codable {
    let id: String
    var name: String
    var description: String
    var audience: String
    var requiredClaimTypes: [String]
    var requiredEntityTypes: [String]
    var sectionOrder: [String]
    var strictness: String              // strict, moderate, lenient
    var language: String
}

// MARK: - Compile Artifact (§17.10)

struct CompileArtifact: Identifiable, Codable {
    let id: String
    var compileJobId: String
    var artifactKind: String            // section, full_document, summary
    var sectionKey: String?
    var content: String
    var contentHash: String
    var sourceBlockIds: [String]
    var sourceClaimIds: [String]
    let createdAt: Date
}

// MARK: - Template & Completeness (§16)

struct DocumentTemplate: Identifiable, Codable {
    let id: String
    var name: String
    var description: String
    var sections: [TemplateSection]
    var requiredClaimTypes: [String]
    var requiredEntityTypes: [String]
}

struct TemplateSection: Identifiable, Codable {
    let id: String
    var title: String
    var isRequired: Bool
    var orderIndex: Int
    var expectedClaimTypes: [String]
    var description: String?
}

struct CompletenessEvaluation: Identifiable, Codable {
    let id: String
    var documentId: String
    var templateId: String
    var structuralScore: Double         // 0.0-1.0
    var semanticScore: Double
    var overallScore: Double
    var missingParts: [MissingPart]
    let evaluatedAt: Date
}

struct MissingPart: Identifiable, Codable {
    let id: String
    var kind: String                    // missing_section, missing_claim, missing_entity, missing_transition
    var description: String
    var severity: DiagnosticSeverity
    var templateSectionId: String?
    var suggestedAction: String?
}
