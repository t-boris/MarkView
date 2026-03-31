# MarkView DDE

**Documentation Development Environment** — a native macOS app for viewing, editing, analyzing, and generating documentation with AI assistance.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## What is MarkView?

MarkView is more than a markdown editor. It's a full **Documentation Development Environment** that combines:

- **WYSIWYG Markdown Editor** — rich text editing with live preview, Mermaid diagrams, KaTeX math, Prism.js syntax highlighting
- **AI-Powered Analysis** — Claude Code and OpenAI Codex integration for code analysis, documentation generation, and architecture visualization
- **Interactive Architecture Diagrams** — D3.js force-directed graphs with drag & drop, built from Mermaid code blocks
- **Semantic Module Extraction** — automatic component discovery using Haiku (cloud) or Ollama (local)
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
- CLAUDE.md skill file with semantic DB export

### Modules & Search
- Automatic module extraction (Ollama local or Haiku cloud)
- FTS5 full-text search
- 50+ component types: software, business, trading, generic
- Refresh button for re-indexing

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
- **Claude Code CLI** (`~/.local/bin/claude`) — for AI features
- **Ollama** (optional) — for free local module extraction
- **OpenAI API key** (optional) — for Whisper voice input and embeddings

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

### API Keys (Settings → DDE Settings)
| Provider | Key | Used For |
|----------|-----|----------|
| Anthropic | `sk-ant-...` | Research, Diagrams, Translation |
| OpenAI | `sk-...` | Whisper voice input, Embeddings |

### Ollama (Local LLM)
```bash
brew install ollama
brew services start ollama
ollama pull llama3.2:3b
```
MarkView auto-detects Ollama on `localhost:11434`.

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
│   ├── OllamaClient.swift          # Local LLM for module extraction
│   ├── GitClient.swift             # Git operations
│   ├── SemanticDatabase.swift      # SQLite FTS5 semantic index
│   ├── StructuralIndexer.swift     # Markdown parsing, module detection
│   ├── ActionEngine.swift          # LLM actions (describe, summarize, diagram)
│   ├── WorkspaceManager.swift      # Central state management
│   ├── AIProviderClient.swift      # Anthropic API client
│   ├── EmbeddingClient.swift       # OpenAI embeddings
│   ├── HybridSearch.swift          # FTS5 + embeddings + graph search
│   └── ...
├── Views/
│   ├── ContentView.swift           # Main layout (HSplitView)
│   ├── EditorView.swift            # WKWebView markdown editor
│   ├── FileTreeView.swift          # File browser + Git status
│   ├── ModuleExplorerView.swift    # Right panel tabs
│   ├── AIConsoleView.swift         # AI chat tab
│   ├── GitView.swift               # Git tab
│   ├── GraphCreatorSheet.swift     # Diagram generation dialog
│   ├── CanvasView.swift            # D3.js standalone canvas
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
| AI (Cloud) | Claude API, OpenAI API |
| AI (Local) | Ollama |
| AI (CLI) | Claude Code, OpenAI Codex |
| Voice | OpenAI Whisper |
| HTML→MD | Turndown.js |

## License

MIT License — see [LICENSE](LICENSE)
