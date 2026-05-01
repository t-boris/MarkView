import Foundation

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
    /// Reuses the existing module-level `AnyCodable` enum defined in
    /// `MarkView/Bridge/WebViewBridge.swift` (Codable type-erased JSON wrapper). No need to
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
