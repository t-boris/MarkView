# Cockpit end-to-end checks

Drive the real Debug MarkView app (a copy of it) through the Copilot Cockpit: UI clicks through the accessibility tree, a fake
planner, a fake step agent on a real PTY, real Temporal workflow, real tool gate, real tickets. Nothing touches the user's
running app, the network or a real agent CLI.

    python3 tools/tests/cockpit-e2e/e2e.py --app <Debug MarkView.app> [--work DIR] [--keep] S5 S7 S8 S9 S10 S11 S12 S13 S14 S15 S16 S17 S18

| Scenario | What it proves |
|---|---|
| S5  | base run: happy path, allowed calls pass, outcome shown |
| S7  | `markview_cockpit_ask` answered by the supervisor, logged in the run (`exchanges`), shown as "Supervisor: 1 question" |
| S8  | a question about deploying is "outside the plan": result says do not act, record a blocker |
| S9  | supervisor control off: fixed reply, zero supervisor calls, no exchanges, step prompt says so |
| S10 | repeated question answered once; 25-question cap; a NEW step starts with a fresh count |
| S11 | supervisor exit 1 / garbage / once: agent told to decide alone, run goes on, same question can be asked again |
| S12 | wrong ticket from inside a step and from a process outside every step: refused, supervisor never called |
| S13 | a step's model reaches the agent command (`--model opus`, none for a step without one); the run records a dated timeline; the plan screen shows agent and model |
| S14 | takes pictures of both screens (plan, step editor, running run, finished run, each tab) for a look; checks only that the run finished |
| S15 | instrument panel: a lever switched off mid-step makes the gate refuse the agent's next call (plan untouched), a note is saved, read by the supervisor and in the next step's briefing |
| S16 | instrument panel with a failed step: banner and lamp, pictures |
| S17 | toolbar marks of the singleton tabs: current, open in the background, closed, six states |
| S18 | the assistant's title names the run: plan screen, run header and run list show it, the goal the person typed is kept in the saved plan; a plan with no title falls back to the goal's first line (S5) |

Files: `e2e.py` (orchestrator), `scenarios.py` (plans, probe scripts, checks), `fake-claude.py` (`claude` stand-in: planner,
step agent and supervisor modes), `e2eprobe.m` (probe dylib with AX steps), `make-fixture.sh` (fixture git project).

Evidence per run is kept under `<work>/<scenario>/` (`e2e/agent.log`, `e2e/supervisor.log`, `e2e/*-prompt-*.txt`, `out/dump-*.txt`,
the run JSON in the fixture). Pass `--keep` to keep the app's HOME too. The app copy lives in `<work>/MarkViewE2E.app` (delete it
when done). Not covered: real model behaviour, real MCP attribution of Claude/Codex, deployments against a real environment.
