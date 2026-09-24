# MarkView DDE

**Documentation Development Environment** — a native macOS app for viewing, editing, analyzing, and generating documentation with AI assistance.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## What is MarkView?

MarkView is more than a markdown editor. It's a full **Documentation Development Environment** that combines:

- **WYSIWYG Markdown Editor** — rich text editing with live preview, Mermaid diagrams, KaTeX math, Prism.js syntax highlighting
- **AI-Powered Analysis** — Claude Code and OpenAI Codex integration for code analysis, documentation generation, and architecture visualization
- **Interactive Architecture Diagrams** — D3.js force-directed graphs with drag & drop, built from Mermaid code blocks
- **Git Integration** — stage, commit, push/pull directly from the file tree
- **Voice Input** — OpenAI Whisper transcription for hands-free documentation
- **Multi-Window** — each window is an independent workspace

## Features

### Editor
- WYSIWYG rich text editing (contentEditable + Turndown.js)
- Mermaid diagram rendering (standard SVG + interactive D3 canvas with `%%INTERACTIVE`)
- Code syntax highlighting (Prism.js — 20+ languages)
- KaTeX math rendering
- Font size slider
- Dark/Light theme
- Translate to English (via Claude API)
- Save, Refresh, Export PDF

### AI Tools (⟁ menu)
| Tool | Description |
|------|-------------|
| 🏗 System Architecture | Generate C4 architecture diagram |
| 🔀 Data Flow | Data movement between components |
| ⚙ Pipeline | Processing stages diagram |
| ☁ Deployment | Infrastructure diagram |
| ↔ Sequence | Interaction sequence diagram |
| ◆ Entity-Relationship | Data model diagram |
| 🔍 Constructive Critic | Code/doc review with action items |
| 🌐 Deep Research | Online research of APIs and dependencies |
| 📋 Full Codebase Audit | Complete architecture documentation |
| 🗂 Code Structure Map | Visual code structure with dependencies |
| 📚 Generate Full Documentation | Parallel docs next to code with metadata |

### AI Console
- Claude Code CLI integration (streaming, session continuity)
- OpenAI Codex support (switchable backend)
- Voice input via Whisper
- Auto-opens files created by AI
- CLAUDE.md skill file with the workspace document structure

### Code and architecture
- Read-only code viewer for 40+ languages (CodeMirror 6): highlighting, line numbers, folding, indent guides; `file.ts#L40-L60` links jump to lines
- Architecture tab (⌘4, opens by itself for code folders): Modules, Deployment and Docs views; double-click to zoom into a module (outside connections stay), files open in the code viewer, document sections open at the heading
- Overlays: Documentation (none / fresh / outdated), Tests, Bug history, Freshness, Complexity, Size, Changes (branch, uncommitted work or GitHub PR) with an AI review
- Deterministic scan stored in the workspace database; Analyze uses the selected AI CLI to describe modules and map deployment, and only re-describes what changed

### Search
- FTS5 full-text search across the workspace (Search tab in the right panel)

### Git (in File Tree)
- Branch indicator + Pull/Push/Refresh
- File status icons (M/A/D/?)
- Right-click: Stage, Unstage, Discard, Commit, Push
- Commit dialog with "Commit & Push" option

### Interactive Diagrams
- Mermaid → D3.js canvas for `%%INTERACTIVE` blocks
- Dagre layered layout (no overlaps)
- Drag nodes, zoom/pan
- Click node → info popup + AI edit
- Click edge → relationship info
- Subgraph grouping with colored backgrounds
- Filter by group/layer
- Export as Mermaid

### YAML Frontmatter
- Collapsible metadata panel
- Color-coded status (active/deprecated)
- Array values as styled badges

## Requirements

- **macOS 13+** (Ventura or later)
- **Xcode 15+** for building
- **Claude Code CLI** and/or **OpenAI Codex CLI**, signed in — every AI feature runs through the one selected in DDE Settings
- **OpenAI API key** (optional) — for Whisper voice input

## Installation

### From Source
```bash
git clone https://github.com/YOUR_USERNAME/MarkView.git
cd MarkView
xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug build
cp -R "$(xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug -showBuildSettings | grep ' BUILD_DIR' | head -1 | awk '{print $3}')/Debug/MarkView.app" /Applications/
```

### Make Default .md Viewer
```bash
# Set as default handler for markdown files
swift -e 'import CoreServices; LSSetDefaultRoleHandlerForContentType("net.daringfireball.markdown" as NSString, LSRolesMask.all, "com.markview.MarkView" as NSString)'
```

### Finder "Open in MarkView" Service
The app includes a Quick Action workflow. Enable it in:
**System Settings → Keyboard → Keyboard Shortcuts → Services → "Open in MarkView"**

## Configuration

### AI assistant (Settings → DDE Settings → AI CLI Tools)
All AI features — the AI console, selection actions (RU / EN / ?), whole-document
translation, architecture diagrams and Recursive Insight — run through the Claude Code
or Codex CLI you pick there (also switchable from the AI console header), with the model
chosen for it. No provider API key is needed; the CLI's own sign-in is used.

### API Keys
| Provider | Key | Used For |
|----------|-----|----------|
| OpenAI | `sk-...` | Whisper voice input |

### Claude Code CLI
```bash
npm install -g @anthropic-ai/claude-code
```

### OpenAI Codex CLI
```bash
npm install -g @openai/codex
```

## Architecture

```
MarkView/
├── App/
│   └── MarkViewApp.swift          # Entry point, window management
├── Models/
│   ├── AIConsoleEngine.swift       # Claude Code / Codex CLI integration
│   ├── WhisperClient.swift         # Voice input via OpenAI Whisper
│   ├── GitClient.swift             # Git operations
│   ├── SemanticDatabase.swift      # SQLite FTS5 semantic index
│   ├── StructuralIndexer.swift     # Markdown parsing, headings/links index
│   ├── WorkspaceManager.swift      # Central state management
│   ├── CLICompletion.swift         # One-shot Claude Code / Codex runs for app features
│   ├── DocumentActions.swift       # Action model, prompts, cached analyses (.dde/cache/actions)
│   ├── EmbeddingClient.swift       # OpenAI key storage (Whisper)
│   └── ...
├── Views/
│   ├── ContentView.swift           # Main layout (HSplitView)
│   ├── EditorView.swift            # WKWebView markdown editor
│   ├── FileTreeView.swift          # File browser + Git status
│   ├── ModuleExplorerView.swift    # AI panel: Actions, Discussion
│   ├── ActionsView.swift           # Per-document AI actions (analyse → suggested buttons)
│   ├── TOCView.swift               # Contents, Search, Git
│   ├── AIConsoleView.swift         # AI chat tab
│   ├── GitView.swift               # Git tab
│   ├── GraphCreatorSheet.swift     # Diagram generation dialog
│   └── ...
├── Resources/Editor/
│   └── index.html                  # WYSIWYG editor + D3 canvas + all JS
├── Bridge/
│   ├── WebViewBridge.swift         # Swift ↔ JavaScript communication
│   └── PDFExporter.swift           # PDF export
└── MarkView.entitlements           # Sandbox config
```

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI Framework | SwiftUI + AppKit |
| Editor | WKWebView + contentEditable |
| Markdown | markdown-it + plugins |
| Diagrams | Mermaid.js + D3.js + Dagre.js |
| Syntax | Prism.js |
| Math | KaTeX |
| Database | SQLite (C API) + FTS5 |
| AI (Cloud) | OpenAI API (Whisper) |
| AI (CLI) | Claude Code, OpenAI Codex |
| Voice | OpenAI Whisper |
| HTML→MD | Turndown.js |

## License

MIT License — see [LICENSE](LICENSE)
