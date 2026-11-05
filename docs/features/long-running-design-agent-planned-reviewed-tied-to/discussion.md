# Discussion — Long-running design agent: planned, reviewed, tied to a feature

### Boris · 2026-11-05

Original request (translated from Russian): The agent that does our design — I think something is wrong with it. It does not understand, it is not ready to make long, big changes. It makes only small changes. I give it, say, a button, it changes it. I need a big change, so that it can do that. That is, it is a long-running agent that runs for a long time, splits the tasks into pieces and does them. Think about how to do this better. Besides that, integration with requirements and features: it must be connected. Every time we are going to change something, we must open a new feature automatically, add all the changes to it, everything we say, what has to be done. But it must periodically check the state, ask questions and everything else.

### Boris · 2026-11-05

Changes must also be two-level (translated from Russian): first we prepare a plan, and only then we do a review of this plan, then we start the implementation, then we do a review of the implementation compared with the requirements.

### Boris · 2026-11-05

Besides that (translated from Russian): give the ability to add images right into the dialog in the InputBox.

### Plan reviewer · 2026-11-05

Independent review of plan v1 against the code (blocker 1, major 9, minor 4). Blocker: the single-flight `busy` of `runWork` would block answers during a waiting run, or let Undo and scenario changes run mid-run; fixed with a run lock and a phase table. Major: a run does not survive closing the tab (pause and resume instead); structured edits cannot overwrite or delete a file and a cut-off answer is not detectable (add hash-guarded overwrite/delete and stop reason); verify is a fixed 1.2 s sleep on one route (per-chunk route, compile signal, After capture fed back); `change()` cannot be called per chunk (extract performEdit); existing tracking writes `approved` requirements (run skips it); "the agent never approves" was unenforced (draft-only writer, one person-action path); deny list for build/CI/dependency files; redaction and image privacy; crash safety (intent record, lock file); replan, conflict policy and deadline missing. Minor: image code lives in PrototypeSession not PrototypeImages; tests need the session harness and Xcode registration; release batching (one release for steps 2-8). Plan v2 in tasks/todo.md applies all of them; it is re-reviewed after Boris answers Q-001…Q-004.
