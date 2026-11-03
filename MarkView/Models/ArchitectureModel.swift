import Foundation

/// A box in an architecture view: the project root, a folder or package, a file, an
/// external dependency, a deployment unit or a document. Nodes nest via `parent`;
/// the Architecture tab draws expanded parents as containers around their children.
struct ArchNode: Codable, Hashable {
    var id: String
    var parent: String?
    /// root | dir | package | file | externalGroup | external | service | datastore |
    /// queue | client | infra | doc | collection | group | entity (contents of a file)
    var kind: String
    var name: String
    /// Workspace-relative path for folders, files and documents.
    var path: String?
    var language: String?
    var loc: Int = 0
    var files: Int = 0
    /// Filled by the AI enrichment pass.
    var summary: String?
    var role: String?
    var tech: String?
    /// Hash of the file sizes and modification dates below this node. When it
    /// differs from `summarySignature`, the AI description is out of date.
    var signature: String?
    var summarySignature: String?
    /// Logical component (Logical view id "l:c:…") this folder or file belongs to.
    var component: String?
    /// Signals such as entry, ui, api, tests, config, build, docs, generated.
    var tags: [String]?
    /// Where in its file a node is: the line an item or section starts on, the last line a
    /// section spans (Book view), and the start line's text as rendered, to find it in a
    /// markdown preview.
    var line: Int?
    var endLine: Int?
    var anchor: String?
}

/// A dependency between two nodes. The scanner records file-level edges; the
/// Architecture tab lifts them to whichever ancestors are currently visible.
struct ArchEdge: Codable, Hashable {
    var source: String
    var target: String
    /// imports | references | uses | links | calls | runs
    var kind: String
    var weight: Int = 1
    var label: String?
    /// Code-model dependency citation; scanner edges need not have one.
    var evidence: String? = nil
}

struct ArchView: Codable {
    /// modules | deployment | docs
    var id: String
    var nodes: [ArchNode]
    var edges: [ArchEdge]
}

/// How well one code file is documented.
struct CoverageEntry: Codable {
    /// none | fresh | stale
    var status: String
    /// Workspace-relative paths of documents that mention the file or its folder.
    var docs: [String]
}

/// Per-file facts behind the Tests, Bug history, Complexity and Size overlays.
struct FileMetrics: Codable {
    var loc: Int
    /// Decision points (if / for / while / case / catch / && / || …) in the file.
    var complexity: Int
    /// Commits touching the file (last 20 000 in history).
    var commits: Int
    /// Of those, commits whose subject reads like a fix (fix, bug, hotfix, regression, crash).
    var bugfixes: Int
    var isTest: Bool
    /// A test file imports, references or is named after this file.
    var tested: Bool
    var testFiles: [String]
    /// Line coverage 0…1 from an lcov or Cobertura report, when one exists.
    var lineCoverage: Double?
    /// Unix time of the last commit touching the file (modification date without git).
    var lastChanged: Int
    /// Functions found and their cyclomatic complexity (1 + decision points inside).
    var functions: Int = 0
    var maxFunctionComplexity: Int = 0
    var maxFunctionName: String?
    /// Functions above 10 — McCabe's threshold for "needs attention".
    var complexFunctions: Int = 0
}

/// AI grouping of one folder or file into a logical component.
struct LogicalAssignment: Codable {
    /// Component id without prefix.
    var component: String
    var tags: [String]
}

/// A logical component proposed by the AI (the Logical view's containers).
struct LogicalComponent: Codable {
    var id: String
    var name: String
    var purpose: String
    /// Parent component id, or "" for top level.
    var parent: String
    /// presentation | application | domain | data | infrastructure | integration |
    /// platform | tooling | tests | docs
    var layer: String
}

/// How well the local scanner and the AI code model understood each language of
/// the project: the explicit incompleteness statement behind the Code view.
/// Built by `CodeArchitecture.coverage` after a scan and after a code analysis;
/// persisted with the snapshot. Bump `currentVersion` when the shape changes.
struct CodeCoverage: Codable, Equatable {
    static let currentVersion = 1

    enum Level: String, Codable {
        /// Dependencies were extracted (imports or type references), declarations
        /// are outlined, and the AI model assigned the files to components.
        case full
        /// The language is recognized and scanned, but a dependency extractor, an
        /// outline pattern or the AI model is missing.
        case partial
        /// Nothing beyond the file's existence: configuration formats, bundles,
        /// oversized files, or files no component of the model owns.
        case notAnalyzed
    }

    /// One language of the project with its files counted per level.
    struct Language: Codable, Equatable {
        /// Language id as `FileType.codeLanguage` reports it ("text" for plain text).
        var language: String
        var level: Level
        var full: Int
        var partial: Int
        var notAnalyzed: Int
        var files: Int { full + partial + notAnalyzed }
    }

    /// Why the scanner left a file out of the Modules view.
    enum SkipReason: String, Codable {
        /// Configuration, build or plain-text formats without a dependency graph.
        case configFormat
        /// Minified or bundled third-party code.
        case generatedBundle
        /// Larger than `ArchitectureScanner.maxParseBytes`.
        case tooLarge
    }

    /// Files of one language skipped for one reason; kept so a later analysis can
    /// rebuild the report without rescanning.
    struct Skipped: Codable, Equatable {
        var language: String
        var reason: SkipReason
        var files: Int
    }

    /// Which languages the shipping scanner and outline pass understand. Not
    /// persisted: the report records the outcome, not the tables.
    struct Capabilities {
        /// Languages with file-level dependency extraction (import resolution or type references).
        var dependencyLanguages: Set<String>
        /// Languages with a declaration outline pattern.
        var outlineLanguages: Set<String>
    }

    var version: Int
    /// Sorted by language id.
    var languages: [Language]
    /// Scanned files that no component of the code model owns (0 without a model).
    var unassignedFiles: Int
    var skipped: [Skipped]
    /// Human-readable statements of what was not understood, in a stable order.
    var reasons: [String]
    /// The report reflects an AI code model, not only the local scan.
    var hasModel: Bool
    var computedAt: Date
}

/// Everything the Architecture tab shows, as persisted in the workspace database.
struct ArchitectureSnapshot: Codable {
    var views: [ArchView]
    /// Keyed by module-view node id of a file.
    var coverage: [String: CoverageEntry]
    /// Keyed by module-view node id of a file.
    var metrics: [String: FileMetrics] = [:]
    /// Name of the coverage report the Tests overlay used, if any.
    var coverageReport: String?
    /// Signature of the deployment config files the Deployment view was built from.
    var deploymentSignature: String?
    /// What the system is, from the AI analysis.
    var systemName: String?
    var systemPurpose: String?
    var components: [LogicalComponent] = []
    /// Folder or file path → component and tags (AI).
    var assignments: [String: LogicalAssignment] = [:]
    /// Folder or file path → component id chosen by the user; wins over the AI.
    var overrides: [String: String] = [:]
    /// Root signature of the Modules view when the logical grouping was made.
    var logicalSignature: String?
    /// Output language of the AI descriptions (a change re-describes on the next Analyze).
    var language: String?
    /// The logical grouping is the folder-layout draft, not yet the AI's.
    var logicalDraft = false
    /// AI ratings per filter id, keyed by "p:<path>", "c:<component>" or a section id.
    var ratings: [String: [String: ImportanceRater.Rating]] = [:]
    /// Config files that describe how the project is built and deployed.
    var deploymentHints: [String]
    var scannedAt: Date
    var enrichedAt: Date?
    var gitHead: String?
    /// Source-grounded scenarios; optional for snapshots saved before the Code view.
    var codeSequences: [CodeSequence]? = nil
    var codeModel: CodeArchitectureModel? = nil
    /// Per-language understanding report; nil for snapshots saved before it existed.
    var codeCoverage: CodeCoverage? = nil

    func view(_ id: String) -> ArchView? { views.first { $0.id == id } }
}
