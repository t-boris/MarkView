import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

// MARK: - Insight Skeleton (Phase 1 output)

/// The deterministic structure produced by Phase 1 (`GraphRAG.buildSkeleton`) — Anthropic
/// `tool_use` returns this verbatim under a strict JSON schema. Parent-side code consumes it
/// to build the iframe srcdoc placeholder layout BEFORE Phase 2 streams per-section content.
///
/// All string fields here are LLM-controlled and MUST be HTML-escaped (Decision 10) before
/// being interpolated into srcdoc / parent chrome / exported HTML.
struct InsightSkeleton: Codable {
    let title: String
    /// Optional theme hint ("light" | "dark"). Treated as advisory; parent renders default
    /// theme if absent / unrecognized.
    let suggestedTheme: String?
    let sections: [InsightSection]
}

/// One renderable section in the insight node. Identified by `id` (unique within skeleton),
/// typed via `SectionType`, optionally scoped to a subset of source files via `scopeHint`.
struct InsightSection: Codable, Identifiable {
    /// Stable, unique-within-skeleton key. Used as DOM id and postMessage routing key.
    let id: String
    let type: SectionType
    let title: String?
    /// Subset of source-folder file paths (relative to `folderURL`) this section should focus
    /// on. `nil` = use all files. Empty array = explicit "no source files" (renders an empty
    /// section, NOT a fallback to all files — see GraphRAG.buildSectionPrompt edge cases).
    let scopeHint: [String]?
    /// Type-specific configuration (e.g. `{"chartType": "bar"}` for `chartJsChart`). Schema
    /// is loose by design — sections may carry arbitrary visualization hints.
    ///
    /// Reuses the `AnyCodable` enum in `MarkViewCore` (Codable type-erased JSON wrapper). No need to
    /// re-define here — single canonical type avoids drift between bridge marshalling and
    /// insight model storage.
    let metadata: [String: AnyCodable]
    /// Optional inline 🤿 deep-dive anchors. Each topic spawns a child node when clicked.
    let deepDiveTopics: [InsightDeepDiveTopic]?
}

/// Visualization variant for a section. The lookup table in `GraphRAG.buildSectionPrompt`
/// maps each case to a Phase-2 system-prompt hint describing the expected HTML output shape
/// (e.g. `<pre class="mermaid">…</pre>` for `mermaidDiagram`).
enum SectionType: String, Codable, CaseIterable {
    case hero
    case prose
    case mermaidDiagram
    case chartJsChart
    case comparisonTable
    case timeline
    case cardsGrid
    case callout
    case collapsibleDetails

    /// Convenience accessor for tool_use schema construction (`enum` array of valid strings).
    /// Kept as a static computed so the schema cannot drift from the source-of-truth enum.
    static var allCaseStrings: [String] { allCases.map { $0.rawValue } }
}

/// One deep-dive topic anchored inside a parent section. When the user clicks the 🤿 control,
/// the parent spawns a child `InsightNode` whose Phase-1 prompt receives the topic `hint` and
/// the file list resolved from `scopeHint`.
///
/// **Naming note:** prefixed with `Insight` to avoid collision with the v1
/// `DeepDiveTopic` struct (which has `id: UUID`) still alive in `InsightSession.swift` until
/// T6 fully replaces v1. After T6 lands, the v1 type disappears and this can be renamed to
/// the spec-canonical `DeepDiveTopic`. Until then both must coexist for build-green
/// (additive-only T4 strategy).
struct InsightDeepDiveTopic: Codable, Identifiable {
    /// String id (NOT UUID per v2 spec) — stable within section, used for postMessage routing
    /// (`insightDeepDiveClicked.topicId`).
    let id: String
    let label: String
    let hint: String
    let scopeHint: [String]
}

// MARK: - Per-section runtime state

/// Coarse content-type classification produced by Phase 0 (classifier LLM call).
/// Phase 1 (skeleton) and Phase 2 (section content) prompts branch on this so that a
/// philosophy essay isn't framed as a software dossier and a recipe isn't framed as
/// a business analysis. `general` is the safe fallback when classification is unclear.
enum InsightContentType: String, Codable, CaseIterable {
    case software         // architecture docs, code reviews, ADRs, project specs
    case educational      // course notes, lectures, textbook material, study guides
    case philosophy       // arguments, thought experiments, ethical analysis, theology
    case business         // strategy, operations, marketing, financial analysis
    case history          // chronological events, biographical, civilisational analysis
    case scientific       // research papers, experimental data, methodology, hypotheses
    case fiction          // novels, short stories, scripts, plot/character analysis
    case journal          // diary entries, personal reflection, daily logs, emails
    case news             // current events, journalism, press releases, briefs
    case legal            // contracts, regulations, case law, compliance
    case recipe           // cooking, mixology, formulations, step-by-step procedures
    case psychology       // therapy notes, behavior analysis, case studies, well-being
    case general          // any mixed / unclear / catch-all source corpus

    /// Human-friendly label used in UI badges and snapshot display.
    var displayLabel: String {
        switch self {
        case .software:    return "Software / Technical"
        case .educational: return "Educational / Course"
        case .philosophy:  return "Philosophy"
        case .business:    return "Business / Strategy"
        case .history:     return "History"
        case .scientific:  return "Scientific / Research"
        case .fiction:     return "Fiction / Narrative"
        case .journal:     return "Journal / Personal"
        case .news:        return "News / Current Events"
        case .legal:       return "Legal"
        case .recipe:      return "Recipe / Procedure"
        case .psychology:  return "Psychology"
        case .general:     return "General"
        }
    }
}

/// Mutable streaming state for one section within the active insight node. Kept separate
/// from `InsightSection` (immutable Codable model) so per-node UI state can mutate without
/// touching the skeleton. `InsightSession` owns one map of these keyed by `section.id`.
struct SectionState: Codable {
    /// Accumulated HTML chunks streamed from Phase 2's `streamCompletion` for this section.
    /// Forwarded to the iframe as deltas via `bridge.updateInsightSection`.
    var buffer: String = ""
    var status: Status = .pending

    enum Status: String, Codable {
        case pending      // skeleton placed, no Phase-2 call started
        case streaming    // Phase-2 call in flight, deltas arriving
        case ready        // Phase-2 completed successfully
        case failed       // Phase-2 errored; section keeps any partial buffer for diagnostics
    }
}

// MARK: - Supporting Types
//
// V2 Recursive Insight (tech-spec.md, Decision 1, 4, 10, 11). One InsightSession owns
// the in-memory tree of insight nodes for a single tab; the actual rendered HTML is
// composed deterministically by `writeFinalHTMLToCache(...)` (NOT by an iframe round-trip)
// and persisted via `InsightCache` (T3). The bridge layer (T7) subscribes to the
// `@Published` surface to drive the JS-side iframe srcdoc + per-section streaming.
//
// V1 marker parser (`---DEEP-DIVES---`), `streamCompletion`-only single-shot path, and
// right-pane deep-dive list are all deleted. v2 splits generation into:
//   Phase 1: `graphRAG.buildSkeleton(...)` returns a strict-schema `InsightSkeleton`
//            via Anthropic tool_use (single non-streaming call, T4 owns the call).
//   Phase 2: N parallel `AIOperation.ask(...)` calls — one per section
//            in the skeleton — capped at 5 concurrent via `withThrowingTaskGroup`. Per
//            section `SectionState.buffer` accumulates the streamed HTML fragment.
//
// Types `InsightSkeleton`, `InsightSection`, `SectionType`, `InsightDeepDiveTopic`,
// `SectionState`, and the existing `AnyCodable` (defined in MarkViewCore, reused
// per T4 decision) live in `InsightModels.swift` — DO NOT redeclare them here.

/// Scope of an InsightNode within the recursive tree.
/// `.folderRoot` is the top-level summary covering every `.md` file in the folder.
/// `.topic` is a deep-dive narrowed to a labelled subset (the model-emitted topic name,
/// hint, and the validated `.md` files matching the topic's `scope_hint`).
enum NodeScope: Codable {
    case folderRoot
    case topic(label: String, hint: String, files: [URL])

    // Manual Codable: associated values + URL serialise via path strings so the cached
    // node tree can round-trip cleanly (T8 Pre-deploy QA may exercise this).
    private enum CodingKeys: String, CodingKey { case kind, label, hint, files }
    private enum Kind: String, Codable { case folderRoot, topic }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folderRoot:
            try c.encode(Kind.folderRoot, forKey: .kind)
        case .topic(let label, let hint, let files):
            try c.encode(Kind.topic, forKey: .kind)
            try c.encode(label, forKey: .label)
            try c.encode(hint, forKey: .hint)
            try c.encode(files.map { $0.path }, forKey: .files)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .folderRoot:
            self = .folderRoot
        case .topic:
            let label = try c.decode(String.self, forKey: .label)
            let hint = try c.decode(String.self, forKey: .hint)
            let paths = try c.decode([String].self, forKey: .files)
            self = .topic(label: label, hint: hint, files: paths.map { URL(fileURLWithPath: $0) })
        }
    }

    /// Convenience accessor for `phase1Skeleton` to feed `graphRAG.buildSkeleton`.
    var label: String? {
        switch self {
        case .folderRoot: return nil
        case .topic(let label, _, _): return label
        }
    }

    var hint: String? {
        switch self {
        case .folderRoot: return nil
        case .topic(_, let hint, _): return hint
        }
    }
}

/// Lightweight breadcrumb entry — UUIDs serialised as strings so the JS bridge can
/// pass them back as identifiers without re-decoding.
struct BreadcrumbEntry: Codable {
    let nodeId: String
    let title: String
}

/// Snapshot of the current insight view, consumed by the WebView bridge layer.
/// V2 shape: skeleton replaces v1 `markdown + deepDives` (the per-section iframe srcdoc
/// is rebuilt parent-side from `skeleton + section buffers`, see `writeFinalHTMLToCache`).
/// All identifiers serialised as strings to avoid JSON↔Swift UUID round-trip cost.
struct InsightViewSnapshot: Codable {
    let sessionId: String
    let nodeId: String
    let title: String
    let breadcrumbs: [BreadcrumbEntry]
    let skeleton: InsightSkeleton?
    let isStreaming: Bool
}

/// One node in the in-memory insight tree. Reference type because the tree is mutated
/// in place (per-section `buffer` accumulation, status transitions) and other parts of
/// `InsightSession` hold direct references via `nodes[id]`.
final class InsightNode: Identifiable, Codable {
    enum Status: String, Codable {
        case pending                // initialised, no LLM call yet
        case generatingSkeleton     // Phase 1 in flight
        case streamingContent       // Phase 2 in flight (one or more sections)
        case ready                  // all sections completed + cache written
        case failed                 // any phase errored or cap exceeded
    }

    let id: UUID
    let parentId: UUID?
    let level: Int
    let title: String
    let scope: NodeScope
    var skeleton: InsightSkeleton?
    /// Per-section streaming state. Keyed by `InsightSection.id`. Mutated only on
    /// `@MainActor`. Initialised lazily in `phase1Skeleton` once the skeleton is parsed.
    var sectionStates: [String: SectionState]
    var children: [UUID]
    var status: Status
    var generatedAt: Date?
    let model: String

    init(
        id: UUID = UUID(),
        parentId: UUID?,
        level: Int,
        title: String,
        scope: NodeScope,
        model: String = "claude-sonnet-4-6"
    ) {
        self.id = id
        self.parentId = parentId
        self.level = level
        self.title = title
        self.scope = scope
        self.skeleton = nil
        self.sectionStates = [:]
        self.children = []
        self.status = .pending
        self.generatedAt = nil
        self.model = model
    }

    /// Live byte total across all section buffers. Used by per-node + per-session caps
    /// (Decision 10 §7 / tech-spec "Resource caps"). UTF-8 byte count, not Swift `count`.
    var rawBufferForCap: Int {
        sectionStates.values.reduce(0) { $0 + $1.buffer.utf8.count }
    }
}
