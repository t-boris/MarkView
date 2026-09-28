# External Integrations

MarkView has no backend of its own. Every external dependency is a local CLI, a local file, or a
direct HTTPS call.

## 1. AI command-line tools

| Tool | Invocation | Auth | Access granted |
|---|---|---|---|
| Claude Code (`claude`) | `-p`, stream-json output, prompt on stdin; system prompt and schema passed as args | CLI's own login (`claude auth status`) | Read-only: `Read,Grep,Glob` only with a readable folder; `WebSearch,WebFetch` only with `allowWeb` |
| Codex (`codex`) | `exec --sandbox read-only --json`, `--output-schema <tmp file>` | CLI's own login | Read-only sandbox |
| Cline (`cline --acp`) | ACP JSON-RPC over stdio, Plan mode | CLI's own login | Permission requests: reads inside the project and searches allowed, everything else refused |
| GitHub Copilot CLI (`--acp`) | ACP JSON-RPC over stdio | CLI's own login | Limited to its `view/grep/glob` tools |

The **AI terminal** is different. It starts Claude as
`claude update && claude … --dangerously-skip-permissions` (`WorkspaceManager.swift:3100`), so there
the agent has full write and exec permissions. See [security](./security.md).

Resolution order: `settings.cli.<tool>Path` → `zsh -lc "command -v <bin>"` with
`settings.cli.extraPATH`. Details: [ai-assistants](./modules/ai-assistants-and-dictation.md).

## 2. HTTP endpoints

| Endpoint | Purpose | Auth | Source |
|---|---|---|---|
| `POST https://api.openai.com/v1/audio/transcriptions` | Whisper dictation | Bearer OpenAI key from UserDefaults | `WhisperClient` |
| `GET https://api.openai.com/v1/models` | Key check in Settings | same | `DDESettingsView` |
| `POST https://api.openai.com/v1/embeddings` (`text-embedding-3-small`) | **Unused**: no callers | same | `EmbeddingClient` |
| `GET https://api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`) | Claude quota | Claude Code OAuth token, read-only, from `~/.claude/.credentials.json` or Keychain | `AgentUsageTracker` |
| `GET https://chatgpt.com/backend-api/wham/usage` (`ChatGPT-Account-Id`) | Codex quota | token from `~/.codex/auth.json` | `AgentUsageTracker` |
| `https://cdn.jsdelivr.net/npm/{d3@7.9.0, @dagrejs/dagre@1.1.4, turndown@7.1.3, turndown-plugin-gfm@1.0.2}` | Editor scripts, no SRI | none | `index.html:1539-1544` |
| URL sources in feature ingest (http/https) | Fetch page text | none | `FeatureIngest` |

The two quota endpoints are undocumented vendor APIs, called by default unless the agent is
hidden (DEC-005/DEC-012 in the agent-usage feature spec). Tokens are re-read on every fetch,
redirects are refused, and refresh tokens are never used.

## 3. Git and GitHub

| Tool | Used for | Notes |
|---|---|---|
| `git` (`/usr/bin/env git` in `GitClient`, `/usr/bin/git` in `GitHubClient`) | Status, diff, stage, commit, push/pull, blame, grep, `ls-files`, log metrics, PR fetch | `GitClient` has no timeout and doesn't suppress prompts |
| `gh` | PRs, issues (including Issues-list Sync closing issues as completed), labels, Actions runs, `api` REST/GraphQL, `auth login` via `.command` file | MarkView never stores a GitHub token. Gated by `settings.github.enabled`, except the terminal PR picker |

Details: [git-github §A](./modules/git-github-terminal-lifecycle-usage.md).

## 4. System services

| Service | Use |
|---|---|
| `NSWorkspace.open` | External URLs (restricted to `https://github.com` for bridge `openURL`), non-openable files |
| `NSAppleScript` → Terminal.app | "Open in Terminal.app" (needs the Apple Events entitlement) |
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
