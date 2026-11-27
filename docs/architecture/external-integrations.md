# External Integrations

MarkView has no backend of its own. Every external dependency is a local CLI, a local file, or a
direct HTTPS call.

Checked against the code at `ac3001ba` (2026-11-15) for the rows changed in this edit (the assistant list, the HTTP table, the system services and the AI terminal text); the CLI argument details in section 1 were not re-read.

## 1. AI command-line tools

| Tool | Invocation | Auth | Access granted |
|---|---|---|---|
| Claude Code (`claude`) | `-p`, stream-json output, prompt on stdin; system prompt and schema passed as args | CLI's own login (`claude auth status`) | Read-only: `Read,Grep,Glob,Agent` only with a readable folder (subagents get the same tools); `WebSearch,WebFetch` only with `allowWeb` |
| Codex (`codex`) | `exec --sandbox read-only --json`, `--output-schema <tmp file>` | CLI's own login | Read-only sandbox, subagent tools off (`-c agents.enabled=false`) |
| Cline (`cline --acp`) | ACP JSON-RPC over stdio, Plan mode | CLI's own login | Permission requests: reads inside the project and searches allowed, everything else refused |
| GitHub Copilot CLI (`--acp`) | ACP JSON-RPC over stdio | CLI's own login | Limited to its `view/grep/glob` tools |
| Antigravity (`agy`) | one-shot requests in print mode with stream-json output through `CLICompletion` (`AntigravityProvider`); terminals use its interactive mode | CLI's own login | not re-checked; terminals pass `--dangerously-skip-permissions` |

The assistants are the entries of `AssistantProviders.list` (`Models/AI/Providers/AssistantProviderList.swift`).

The **AI terminal** is different. For Claude it starts `claude update && claude … --dangerously-skip-permissions`
(`AITerminalsController.startupCommand`; the `update` step comes from the provider's `updateArgs`, which only Claude has), so there
the agent has full write and exec permissions (Antigravity's terminal also passes `--dangerously-skip-permissions`). See [security](./security.md).

Resolution order: `settings.cli.<tool>Path` → `zsh -lc "command -v <bin>"` with
`settings.cli.extraPATH`. Details: [ai-assistants](./modules/ai-assistants-and-dictation.md).

## 2. HTTP endpoints

| Endpoint | Purpose | Auth | Source |
|---|---|---|---|
| `POST https://api.openai.com/v1/audio/transcriptions` | Whisper dictation | Bearer OpenAI key from the Keychain (`WhisperClient.loadAPIKey`) | `WhisperClient` |
| `GET https://api.openai.com/v1/models` | Key check in Settings | same | `DDESettingsView` |
| `POST https://api.openai.com/v1/embeddings` (`text-embedding-3-small`) | **Unused**: nothing creates an `EmbeddingClient` (only its key helpers are called) | same | `EmbeddingClient` |
| `GET https://api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`) | Claude quota | Claude Code OAuth token, read-only, from `~/.claude/.credentials.json` or Keychain | `AgentUsageTracker` |
| `GET https://chatgpt.com/backend-api/wham/usage` (`ChatGPT-Account-Id`) | Codex quota | token from `~/.codex/auth.json` | `AgentUsageTracker` |
| `agy --output-format json -p "/usage"` (a local command, not HTTP) | Antigravity quota (DEC-020): MarkView reads no token | the CLI's own login | `AntigravityProvider` (`AntigravityUsage`) |
| URL sources in feature ingest (http/https) | Fetch page text | none | `FeatureIngest` |

The two quota endpoints are undocumented vendor APIs, called by default unless the agent is
hidden (DEC-005/DEC-012 in the agent-usage feature spec). Tokens are re-read on every fetch,
redirects are refused, and refresh tokens are never used.

## 3. Git and GitHub

| Tool | Used for | Notes |
|---|---|---|
| `git` (`/usr/bin/env git` in `GitClient`, `/usr/bin/git` in `GitHubClient` and `UIStudioChanges`) | Status, diff, stage, commit, push/pull, blame, grep, `ls-files`, log metrics, PR fetch | `GitClient` has no timeout and doesn't suppress prompts |
| `gh` | PRs, issues (including Issues-list Sync closing issues as completed), labels, Actions runs, `api` REST/GraphQL, `auth login` via `.command` file | MarkView never stores a GitHub token. Gated by `settings.github.enabled`, except the terminal PR picker |

Details: [git-github §A](./modules/git-github-terminal-lifecycle-usage.md).

## 4. System services

| Service | Use |
|---|---|
| `NSWorkspace.open` | External URLs (restricted to `https://github.com` for bridge `openURL`), non-openable files |
| Terminal.app | "Open in Terminal.app" opens the folder in the app with `NSWorkspace` (`FileTreeView.swift`, AR-11: no AppleScript); the CLI login scripts are `.command` files opened the same way (`AIAssistants.swift`). The entitlements file still lists Apple Events and its comment still says the menu item drives Terminal through them, which the code no longer does |
| `/usr/bin/security find-generic-password` | Read the Claude Code OAuth token |
| `/usr/bin/zip` | Insight archive export |
| `forkpty` + `$SHELL -l` | Embedded terminals |
| AVFoundation microphone | Dictation (needs the audio-input entitlement and `NSMicrophoneUsageDescription`) |

## 5. Vendored web libraries

These are bundled in `MarkView/Resources/Editor/vendor/js`, built by `tools/web-vendor`
(`npm ci && ./build.sh`): markdown-it + plugins, Mermaid 10.6.1, KaTeX 0.16.9, Prism 1.29.0,
CodeMirror 6, Cytoscape + ELK + cytoscape-elk, Chart.js 4.4.9, js-yaml, and xterm.js with the
web-links addon. Versions are in `tools/web-vendor/package.json` and `vendor/MANIFEST.txt`. Mermaid,
KaTeX and Prism are old versions with published CVEs; see [risks](./risks-and-tech-debt.md).
