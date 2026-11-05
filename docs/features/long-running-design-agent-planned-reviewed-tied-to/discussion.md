# Discussion — Long-running design agent: planned, reviewed, tied to a feature

### Boris · 2026-11-05

Original request (translated from Russian): The agent that does our design — I think something is wrong with it. It does not understand, it is not ready to make long, big changes. It makes only small changes. I give it, say, a button, it changes it. I need a big change, so that it can do that. That is, it is a long-running agent that runs for a long time, splits the tasks into pieces and does them. Think about how to do this better. Besides that, integration with requirements and features: it must be connected. Every time we are going to change something, we must open a new feature automatically, add all the changes to it, everything we say, what has to be done. But it must periodically check the state, ask questions and everything else.

### Boris · 2026-11-05

Changes must also be two-level (translated from Russian): first we prepare a plan, and only then we do a review of this plan, then we start the implementation, then we do a review of the implementation compared with the requirements.

### Boris · 2026-11-05

Besides that (translated from Russian): give the ability to add images right into the dialog in the InputBox.

### Plan reviewer · 2026-11-05

Independent review of plan v1 against the code (blocker 1, major 9, minor 4). Blocker: the single-flight `busy` of `runWork` would block answers during a waiting run, or let Undo and scenario changes run mid-run; fixed with a run lock and a phase table. Major: a run does not survive closing the tab (pause and resume instead); structured edits cannot overwrite or delete a file and a cut-off answer is not detectable (add hash-guarded overwrite/delete and stop reason); verify is a fixed 1.2 s sleep on one route (per-chunk route, compile signal, After capture fed back); `change()` cannot be called per chunk (extract performEdit); existing tracking writes `approved` requirements (run skips it); "the agent never approves" was unenforced (draft-only writer, one person-action path); deny list for build/CI/dependency files; redaction and image privacy; crash safety (intent record, lock file); replan, conflict policy and deadline missing. Minor: image code lives in PrototypeSession not PrototypeImages; tests need the session harness and Xcode registration; release batching (one release for steps 2-8). Plan v2 in tasks/todo.md applies all of them; it is re-reviewed after Boris answers Q-001…Q-004.

### Answer to Q-001 · 2026-11-05

Which design agent is meant: UI Studio (edits the real application's source, request box under the live preview) or Prototype Studio (edits 

Both at once: UI Studio and Prototype Studio get the long-running agent in the same release (Boris chose option C, 2026-11-05, answering in the conversation).

### Answer to Q-002 · 2026-11-05

How does the agent write a chunk: as structured search/replace edits that MarkView applies and checks itself, or as a full-access terminal a

Edits through MarkView (option A): the agent returns edits, MarkView applies them, builds and checks, and gives the result back to the agent. Undo of every chunk is kept. Commands such as npm install are not run by the agent; it asks the person.

### Answer to Q-003 · 2026-11-05

When is a feature opened: for every single request, or once per conversation, and does a one-element request ("change this button") also go 

One feature per task (option A): a small request is recorded in the current feature as a requirement and takes the quick path as today; a big one becomes a job with the four gates (plan, plan review, implementation, implementation review).

### Answer to Q-004 · 2026-11-05

Who approves the plan after its review: always the person, or the agent continues alone when the review finds no problems?

Always the person approves the plan (option A). After approving, the person may switch the run to unattended, except for deny-listed files (package.json, CI, configs).

### Plan reviewer · 2026-11-05

Second independent review of plan v3 (blocker 1, major 13). Blocker: the Prototype Studio verify works only while its tab is the visible one (the audit returns "no problems" when no preview answers) and no close path pauses a run; fixed by verifying through the existing off-screen renderer with a three-state result (clean / problems / unavailable) and pause hooks on every close path. Major: the run lock was written in UI Studio terms (Prototype `isBusy` is nil between chunks, so Sync, Rebuild, revert and clear-conversation would be enabled mid-run, and clear-conversation deletes the images); one prototype version per chunk copies the whole site each time into a committed folder and restore cannot undo one chunk (use a per-chunk journal in .dde and one version at the end); several rows of the two-host table were wrong (Change.files is an unguarded overwrite, reviseSchema has no question field, the sweep fan-out breaks the per-chunk call budget, path guards and the deny list are host-specific); settleAndFix needs a three-state verify scoped to the chunk's screens; conflicts of a prototype (hand edits, changed sources) were undefined; the 2 h deadline contradicts the lesson that prototype calls have no timeout (make it a soft limit that asks); the pid lock cannot separate windows of one process (in-process registry plus file with heartbeat); the protocol lacked redaction, feature-store access, usage record, cancel, progress; no step built the run UI; some earlier findings were only mentioned (draft-only mechanism, stop reason per engine, compile signal, resume UI, replan trigger); requirement mismatches (REQ-005 sources vs privacy, REQ-003 redaction and draft vs the quick-path tracker, engines that ignore images); release slicing (smallest slice: engine plus Prototype host); rule issues (a bump per commit, CI path filters and pull_request-only workflows, no harness for PrototypeSession). Requirements REQ-001, REQ-003, REQ-005 were amended accordingly; plan v4 in tasks/todo.md.
