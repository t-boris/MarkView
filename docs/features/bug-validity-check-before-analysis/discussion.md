# Discussion — Bug Validity Check Before Analysis

### AI decided the rest · 2026-11-04

• DEC-001: Require affirmative evidence of resolution
• DEC-002: Verify against main
• DEC-003: Keep automatic closure local
• DEC-004: Handle inconclusive checks without closure

### AI updated the requirements · 2026-11-04

DEC-001, DEC-002, DEC-003, DEC-004 written into REQ-001, REQ-002, REQ-005, the overview.

### AI implemented the feature · 2026-11-04

Implemented on branch `feat/bug-validity-check-before-analysis` (plan items I-1 #283, I-2 #284, I-3 #285; feature #235). No question was left open by the specification; these are the readings the implementation relies on, so they stay visible:

• DEC-002, baseline: the first of `origin/main`, `origin/master`, the target of `origin/HEAD`, `main`, `master` that resolves to a commit. The commit hash, date and subject are recorded in the report. The code is read from `git archive` of that single commit, never from the working tree, so uncommitted work, unpushed local commits and fixes on other branches cannot be seen. No `git fetch` is run: a stale `origin/main` can only make a just-merged fix look still present, which is the safe direction. No identifiable main (not a repository, no main branch, export failed or too large) is an inconclusive outcome.
• DEC-001, evidence: an already-fixed answer is accepted only with a basis of fix-in-code, covered-by-test or scenario-removed, at least one cited file that exists in the exported main (never the report itself), and a non-empty explanation. Anything else is downgraded to inconclusive with the assistant's finding kept as the reason. "Could not reproduce" is never a basis.
• DEC-004, failed save: the investigation stops only after the closure has been saved. If saving fails, the error is shown in the panel banner, the report stays open, no closure is claimed, and the analysis continues and is told that closing failed.
• DEC-003: closing is local. The code added for this feature makes no GitHub issue or comment call; the report keeps its `issue` link, so the manual Sync closes the GitHub issue under the existing linking rules.
• Order of steps: the user's input (answer or discussion message) is saved first, then the check runs once, then the discussion reply (if any), then the analysis. An already-fixed report keeps the user's input and gets no reply and no analysis.
• Visibility (REQ-005): the report gets a "Validity check" section (outcome, baseline, evidence, explanation) that analysis rewrites keep, an entry in the discussion for an automatic closure, and a panel section; the panel says "Checking whether the bug still exists on main…" while the check runs.
