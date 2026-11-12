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

The previous observed source limits (8 seconds, 1500 read elements, depth 14, 400 rendered elements) are hypotheses, not a root-cause finding. Reducing rows to 16 did not fix the consumer. The exact reader failure must be evidenced before this design is finalized.
