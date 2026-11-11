# HTTP API QA fixture

Run `tools/tests/qa-api-tests.sh` from the repository root. It launches the Python
standard-library server on a random loopback port, compiles the actual API client,
actor and runner, and removes the process and temporary files when finished.
No external services or Keychain reads are involved.

`openapi.json` and `server.py` are source material for scenario generation.
`scenario-proposal.json` is a real Claude-generated proposal (2026-11-11, 19 nodes,
four branches): authenticated CRUD, anonymous access, invalid input and invalid
credentials. The suite parses and replays every proposed branch on each run.
The fixed credentials and bearer token are dummy data for this fixture only.

Additional endpoints exercise redirects, transport timeouts, cancellation,
response limits and the rule that a mutating request is never retried because
its status did not match. Requests never leave loopback.

To check another structured generation result:

```sh
QA_API_GENERATED_SCENARIO=/absolute/path/proposal.json tools/tests/qa-api-tests.sh
```

`QA_API_EXPORT_PROMPTS=/tmp/qa-prompts` also exports the shipping generation
schema and system prompt, for a manual real-assistant generation check. The
suite's in-memory factory supplies the fixture credentials; the app instead
uses the saved login selected for each player.
