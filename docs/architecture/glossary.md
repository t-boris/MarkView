# Glossary

| Term | Meaning |
|---|---|
| **ACP** | Agent Client Protocol: JSON-RPC over stdio, used to drive Cline and GitHub Copilot CLIs (`ACPAssistant`) |
| **Assistant / backend** | The selected AI CLI (`CLITool`: claude, codex, cline, copilot), stored in `settings.ai.backend` |
| **Bridge** | The `bridge` WKScriptMessageHandler plus `evaluateJavaScript` calls between Swift and the editor page. See the [catalog](./modules/editor-and-bridge.md#5-bridge-message-catalog) |
| **`sendToSwift`** | JS helper that posts to the bridge |
| **Catalog mode** | Insight mode used when sources are too large to inline: the CLI gets read-only file tools instead of pasted text |
| **Consolidation / cleanup** | Feature operations that merge duplicate requirements, and move stale objects to the Trash while rewriting links |
| **DDE** | Documentation Development Environment, MarkView's internal name for its workspace features |
| **`.dde/`** | Per-workspace metadata folder: SQLite DB and caches. Regenerable |
| **`--dde-index` / mvindexer** | The app re-launched as a headless structural indexer child process |
| **Deep dive (🤿)** | Creates a child Insight node for a topic |
| **Epic / plan issue (`I-n`)** | Implementation plan items in `implementation/plan.md`, optionally mirrored as GitHub issues |
| **Explain / margin notes** | AI annotations for a code file, shown in the notes view |
| **Feature object** | One Markdown file per requirement (`REQ-nnn`), question (`Q-nnn`), decision (`DEC-nnn`), finding (`F-nnn`), research (`R-nnn`) or source (`SRC-nnn`) |
| **Bug question (`BQ-n`)** | Clarifying question stored in a bug report's front matter |
| **File-backed tab** | An `OpenTab` of kind `.file`. Other kinds (image, X-Ray, terminal, GitHub, Insight) use marker URLs |
| **Folder X-Ray** | An X-Ray scoped to a subfolder, stored as JSON in `.dde/xray-folders/` |
| **GraphRAG** | Class that assembles prompts from raw workspace files. Despite the name, it does no graph or vector retrieval |
| **Intake** | The New Feature / New Bug / "I Need to Understand" sheet |
| **Lifecycle event** | A JSONL record of a feature/bug stage transition, used for cycle-time analytics |
| **Lossless front matter** | `FrontMatter.isLossless`: the YAML subset parser can round-trip the block unchanged |
| **OSC 8** | Terminal escape sequence for hyperlinks whose label differs from the target. Claude Code emits them with a BEL terminator |
| **PR X-Ray** | X-Ray overlay and review of a pull request's diff (`arch_reviews`) |
| **Readiness** | The computed "understanding" score of a feature across dimensions |
| **Recursive Insight** | AI-generated, navigable explanation documents (nodes → sections → child nodes) |
| **Skeleton** | The JSON-schema answer that defines an Insight node's sections and children |
| **Structure view / Logical view** | X-Ray views: the file and module hierarchy vs AI-grouped subsystems (`s-*`) and components (`c-*`) |
| **Temporary filter (`tmp-*`)** | The ephemeral X-Ray filter produced by a ⚡ search |
| **Workspace** | The folder open in a window, or a single-file workspace rooted at the file's parent |
| **WYSIWYG / preview vs source mode** | Editor modes. WYSIWYG edits convert back to Markdown through Turndown on save (`wysiwygDirty`) |
| **X-Ray** | Architecture map of a code project. Its details panel is what users call "explanations" |
