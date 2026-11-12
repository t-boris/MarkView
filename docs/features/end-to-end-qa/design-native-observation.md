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

### Real consumer follow-up after installed 6.11 restart

Broker Fabric run `20261112-170416-41d7` on installed MarkView6.11/PID77471 and system StrikeDesk1.43.5/PID75565 ended after two baseline blocks, one interruption and27 unexecuted branches. No order changed. The assistant reached current Positions/Working controls but could not combine their evidence with Accounts/Connected in its current observation. This is a failed consumer acceptance, not a passing regression fixture.

The current read-only consumer diagnostic measures1072 elements at depth21, zero depth/count/time/failure omissions and139 explicitly paged children. The complete rendered observation contains both panels; its actual8000-character prompt prefix contains Accounts/Connected/Visible strikes but excludes Active accounts only. Scoped Positions inspection exposes the missing state while replacing the Accounts portion. The existing compact region index supplies routes but does not itself supply simultaneous current facts. A successful scope round trip does not test this cross-panel prompt boundary.

REQ-018 follow-up design: put a bounded current-window overview of controls and panel state before dense table details. Preserve current-reference identity, secure-field filtering and explicit omission/inspection routes. Prefer shallow semantic controls and compact table/region summaries over a chain's repetitive row bodies; account/connection, chain selection and later-panel state must remain discoverable within QAStepPrompt.maxSnapshot. Do not enlarge prompts without bounds, weaken the baseline, invent absent values or treat historical narration as current observation.

Verification: add a pure dense multi-panel regression using the actual8000-character prompt cap, checking account/connection, Visible strikes, current Positions/Working identity and scope routes together. Keep existing native/pointer/secure/ref/deep-limit checks; exercise both16/96-row live fixtures, QA runner tests and Debug build. Measure the current consumer again, then complete versioned PR, merged signed/notarized delivery and a fresh installed native run. The final REQ-018 consumer criterion stays unchecked until real acceptance passes.

Repeated live validation also exposed a transient attach discovery failure: the retained-session check sometimes receives an empty running-application lookup even though the user-owned fixture is not terminated and the immediately subsequent lookup lists the same PID. Preserve existing-app attachment under that condition with a bounded read-only discovery retry (at most400ms). Never launch a replacement, retry an ambiguous match, claim another player's process or loosen the absent-application error. Add a deterministic live check with two empty discovery replies followed by the same owned fixture; verify its PID and lifecycle remain unchanged. This refines existing attachment REQ-002 and REQ-018 retained-session verification rather than skipping the failing check.

- Pure/live native checks pass, including deep 16/96-row WKWebView fixtures, actual cell clicks invoking the web handler, later-page continuation, return to window, secure values, two attached branches and retry. QA model checks pass, including native-only inspect parsing. Final added boundary checks and the versioned build are tracked with the code PR.
- Versioned Debug build 6.11.0 passes. Existing 6.10.0 remains installed until the merged signed/notarized Release is ready.
- Consumer acceptance is pending: 30 explicit ES/SPX/SPY template/manual entry-and-close branches. Fixtures and read-only diagnosis do not satisfy the trading acceptance criterion.

