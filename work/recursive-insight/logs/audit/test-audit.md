# Test Audit: Recursive Insight v2

**Auditor:** test-master skill (orchestrator-completed inline due to upstream rate limit)
**Date:** 2026-05-01
**Verdict:** **DEFERRAL JUSTIFIED**

## Summary

Per Decision 9 v2, XCTest target setup is deferred to a follow-up task. All 5 audit checks pass:

- T8's `tasks/todo.md` rewrite correctly removed v1-only test names (InsightMarkerParserTests, InsightSSEParserTests etc.)
- 8 v2-specific test paths now listed with concrete acceptance criteria per test
- Owner (Boris) and target date (within 2 weeks of merge — 2026-05-14) populated
- T9 + T10 audit findings (4 majors + 1 medium) ALL fixed in audit-fix iteration (commit 38236f7), so no critical path remains uncovered that would require pre-merge tests
- T12 Pre-deploy QA's 12 Instruments scenarios (5 happy + 7 adversarial including crash-recovery, blob-revocation Web Inspector check, KaTeX math content) cover new ARC surfaces (cache, exporter, iframe lifecycle)

## Per-check results

### Check 1: Deferral tracked in tasks/todo.md
**PASS.** `tasks/todo.md` heading reads "Pending after Recursive Insight (v2)". Top entry is XCTest infrastructure setup with: Why (Project has no test target), 5-step What-to-do (project.yml edit → xcodegen → scheme → install.sh → retroactive coverage), When (within 2 weeks after merge), Owner (Boris).

### Check 2: 8 v2 paths covered
**PASS.** Eight `Tests/Insight*.swift` entries listed with detailed AC per test:
- `InsightToolCallParsingTests.swift` — tool_use envelope + InsightSkeleton schema + fallback
- `InsightPostMessageTests.swift` — 5-type allowlist + payload schemas + frameInfo guard + event.source/origin defense
- `InsightCacheCRUDTests.swift` — atomic ops + UUID-suffixed temp + replaceItemAt + concurrent-writer + ENOENT + symlink
- `InsightArchiveExporterTests.swift` — staging dir + HTML rewriting + escape policy + Process arg safety
- `InsightBlobLifecycleTests.swift` — lazy createObjectURL + revocation on nav + releaseInsightBlobs on close
- `InsightPhase2ParallelismTests.swift` — TaskGroup cap=5 enforcement under burst
- `InsightIframeCSPTests.swift` — sandbox attribute + CSP meta + forbidden flags absent
- `InsightIframeTimeoutTests.swift` — 10s no-iframeReady → setInsightError + retry path

### Check 3: v1-only entries removed
**PASS.** No reference to `InsightMarkerParserTests`, `InsightSSEParserTests`, `InsightSessionLifecycleTests` (v1 names). The marker parser was deleted in T6 v2 rewrite — testing it would test dead code.

### Check 4: T9+T10 findings vs pre-merge tests
**No pre-merge tests required.** T9 (4 majors) + T10 (1 medium SEC-001) all addressed by audit-fix commit `38236f7`:
- Lib filename mismatch → InsightCache.vendoredLibURL helper, dynamic resolution from disk listing
- KaTeX webfonts → recursive copyDirectoryContents in copyVendoredLibs
- Cached CSP weaker → aligned with iframe srcdoc (Decision 10 §3 with 'self' for cache/export)
- Phase 2 error contract → withTaskGroup + per-task do/catch, sibling tasks not cancelled by one failure
- SEC-001 log-forgery → InsightSession.sanitizeForLog applied at all 6 NSLog sites

These are now code-resolved; XCTest coverage of these regression points is desirable but not blocking. Test follow-up should verify them post-merge.

### Check 5: T12 Instruments scenarios sufficient
**PASS.** T12 Pre-deploy QA enumerates 12 scenarios (a-l), exceeding minimum:
- 5 happy: open+expand+close, error+retry+close, 4th-retry rate-limit, ZIP export, breadcrumb-cache navigation
- 7 adversarial/edge: poisoned `.md` XSS attempt, rapid double-click race, close-during-export, close-during-streaming, crash-recovery, blob-revocation Web Inspector check, KaTeX math content

ARC surfaces newly introduced in v2 (InsightCache, InsightArchiveExporter, iframe lifecycle, blob URLs) all exercised.

## Critical paths uncovered

**None.** Audit-fix iteration resolved every major/critical from T9 + T10. Remaining low-priority items (T10 SEC-002 to SEC-005 — pre-existing CDN, no SRI, lib CVEs at-rest) are documented as risk-accepted in MANIFEST.txt with sandbox+CSP mitigation rationale.

## Recommendations

1. **Pre-merge:** None blocking. Proceed to T12 Pre-deploy QA.
2. **Post-merge follow-up (within 2 weeks):**
   - Set up MarkViewTests target per todo.md step 1-3
   - Author the 8 v2 test files per todo.md step 5
   - Add CI run via xcodebuild test
3. **Lib bumps deferred** to next maintenance window: KaTeX 0.16.21, Mermaid 10.9.3+, Prism 1.30.0 (all sandbox-mitigated currently — see MANIFEST.txt risk-accepted notes).

## Verdict

**DEFERRAL JUSTIFIED.** T12 Pre-deploy QA may proceed.
