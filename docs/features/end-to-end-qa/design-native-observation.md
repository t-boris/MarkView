# Dense native observation repair

## AI Context

- Owner-authorized bug fix, local delivery/restart and complete e2e, 2026-11-12. External report: broker-fabric `docs/bugs/BUG-157-qa-blocked-es-reload-positions.md`; consumer `.markview/qa/scenarios/strikedesk-paper.json`.
- Requirement: [REQ-018](requirements/REQ-018.md). Ownership: `MarkView/Models/QANative{Accessibility,Tree,Actor}.swift`, native action schema/runner only if scoped observation needs it, tests and docs.
- Verification: `tools/tests/qa-native-tests.sh`, `tools/tests/qa-tests.sh`, Debug build, clean merged Release/DMG and actual consumer e2e.

## Design and verification plan

1. Add bounded reader diagnostics and a read-only existing-app diagnostic test; measure the failure, without dumping user documents, passwords or unrelated content. Verify diagnostic accounting and secure-field regressions.
2. Repair the measured starvation/omission path. Keep read/time budgets bounded, make incomplete observations explicit, and supply scoped continuation when later content is not in the initial snapshot. Preserve current references and never invent controls from screenshots or stale handles. Add dense/deep native fixture coverage that fails before the repair.
3. Check the relevant action/runner call path and maintain attached process ownership across two branches/retries. Run pure/live native checks, QA model checks and Debug build. Review and merge a versioned PR only after checks pass, then follow the repository's Release/DMG/sign/notary workflow.
4. Install/restart the updated local app without losing unrelated workspace work. Run the full existing StrikeDesk broker-paper matrix and record per-case entry/close IDs and residual checks in the consumer report. No broker order is submitted by fixture tests, and no risk/freshness/account check is weakened to obtain a pass.

## Measured root cause and repair

The unchanged existing 96-strike StrikeDesk consumer read only 373 elements at physical depth 14, omitting 43 children by depth, with no count/time/failure exhaustion (89 ms). Decorative Electron layout wrappers exhausted the shared semantic depth limit. Reducing rows to 16 did not fix this failure.

The repair separates physical depth (64) from meaningful snapshot depth (14), uses bounded breadth-first reading (1500 elements / 8 seconds / three failed reads), and pages table/list/outline children in groups of 24. It reports each omission reason. Current-snapshot native-only `inspect` reads a container and direct-child offset; empty ref restores the whole window. A compact region index precedes long table bodies to retain routes to later panels under prompt truncation. Scoped cell/text references use real AX frames; fallback clicks refuse coordinates outside the target window, and web rows are clicked rather than merely setting AXSelected. Secure values are never fetched, and inspection responses/errors are scrubbed.

The repaired real consumer reads 1037 elements through depth 21 in about 134 ms, with zero depth/count/time/failure omissions and 130 table children explicitly deferred. Visible strikes, POSITIONS and Active accounts only are present. Read-only continuation exposes actual price-cell pointer references and returns to the whole window. This diagnosis submits no orders.

## Verification progress

- Pure/live native checks pass, including deep 16/96-row WKWebView fixtures, actual cell clicks invoking the web handler, later-page continuation, return to window, secure values, two attached branches and retry. QA model checks pass, including native-only inspect parsing. Final added boundary checks and the versioned build are tracked with the code PR.
- Versioned Debug build 6.11.0 passes. Existing 6.10.0 remains installed until the merged signed/notarized Release is ready.
- Consumer acceptance is pending: 30 explicit ES/SPX/SPY template/manual entry-and-close branches. Fixtures and read-only diagnosis do not satisfy the trading acceptance criterion.

