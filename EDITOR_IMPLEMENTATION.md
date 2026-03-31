# MarkView Editor Implementation Guide

Complete web editor layer for MarkView macOS Markdown app.

## Overview

Two complementary systems:

1. **Standalone MVP** (`Resources/Editor/index.html`) - Complete, self-contained HTML file that works immediately in WKWebView. No build step required. Uses CDN libraries and works offline after caching.

2. **EditorWeb Project** (`EditorWeb/`) - Production-grade TypeScript/Vite project for future development. Allows modular architecture, better testing, and advanced bundling.

## Part 1: Standalone index.html (MVP)

**Location**: `/sessions/gracious-loving-goodall/mnt/MarkDV/MarkView/MarkView/Resources/Editor/index.html`

### Features

- **Self-contained**: Single HTML file, no dependencies on build output
- **CDN libraries**: All scripts loaded from jsDelivr (cached, fallback available)
- **Complete editor**:
  - Split-pane source/preview editing
  - Real-time markdown rendering
  - Live heading extraction and tracking
  - Word/character count
  - Theme toggle (light/dark)
  - Keyboard shortcuts (Cmd/Ctrl+Shift+P, Cmd/Ctrl+Shift+T)

### Markdown Support

```markdown
# Headings (h1-h6)
**Bold**, *italic*, ~~strikethrough~~

## Lists
- Item 1
- [x] Task (checked)
- [ ] Task (unchecked)

## Code
`inline code`

\`\`\`python
code block with syntax highlighting
\`\`\`

## Diagrams
\`\`\`mermaid
graph LR
  A[Start] --> B[End]
\`\`\`

## Math
Inline: $E=mc^2$
Block: $$x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}$$

## Admonitions
::: info
Information box
:::

::: warning
Warning box
:::

::: tip
Tip box
:::

::: danger
Danger box
:::

## Tables
| Header 1 | Header 2 |
|----------|----------|
| Cell     | Cell     |

## Footnotes
Text with footnote[^1]

[^1]: Footnote definition
```

### Libraries Included

| Library | Version | Purpose |
|---------|---------|---------|
| markdown-it | 13.0.1 | Markdown parser |
| markdown-it-footnote | 3.0.3 | Footnote support |
| markdown-it-task-lists | 2.1.1 | Task list checkboxes |
| markdown-it-container | 4.0.0 | Admonition blocks |
| mermaid | 10.6.1 | Diagram rendering |
| KaTeX | 0.16.9 | Math rendering |
| Prism.js | 1.29.0 | Code syntax highlighting |

### Language Support (Prism.js)

Pre-loaded: JavaScript, TypeScript, Python, Swift, Rust, Go, Java, C, C++, Bash, JSON, YAML, HTML, CSS, SQL, Markdown

### Swift Bridge

#### Sending to Swift

```javascript
window.webkit.messageHandlers.bridge.postMessage({
  type: 'contentChanged',
  payload: { markdown, html }
});
```

Message types:
- `contentChanged`: {markdown, html}
- `headingsUpdated`: [{id, level, text}, ...]
- `scrollPosition`: {activeHeadingId}
- `ready`: {}

#### Receiving from Swift

```swift
webView.evaluateJavaScript("setContent('\(markdown)')")
webView.evaluateJavaScript("setTheme('dark')")
webView.evaluateJavaScript("toggleSourceMode()")
webView.evaluateJavaScript("scrollToHeading('heading-id')")
webView.evaluateJavaScript("getHTML()")
webView.evaluateJavaScript("getMarkdown()")
webView.evaluateJavaScript("preparePrintLayout()")
webView.evaluateJavaScript("restoreEditLayout()")
```

### Styling

All colors use CSS custom properties (CSS variables):

Light theme defaults:
- Background: white (#ffffff)
- Text: dark gray (#1a1a1a)
- Accent: blue (#0066cc)

Dark theme:
- Background: dark navy (#1a1a2e)
- Text: light gray (#e8e8e8)
- Accent: light blue (#4da6ff)

Switch themes: `document.documentElement.setAttribute('data-theme', 'dark')`

### Print/PDF Support

Optimized print styles in `@media print`:
- Hides editor UI
- Smart page breaks (avoid breaking headings, images, code blocks)
- Preserves colors with `print-color-adjust: exact`
- Page numbers (optional)
- Proper spacing and margins

Use `preparePrintLayout()` to prepare, then trigger native print dialog.

### Performance

- **Debounced rendering**: Markdown only re-renders on input change
- **Lazy syntax highlighting**: Runs after render, doesn't block UI
- **IntersectionObserver**: Tracks visible heading efficiently
- **Mermaid lazy loading**: Renders on content change only
- **KaTeX async**: Math rendering deferred to not block parsing

### Browser Compatibility

- macOS 11+ (Safari/WKWebView)
- iOS 14+ (WKWebView)
- Modern Safari (ES2020)

## Part 2: EditorWeb TypeScript Project

**Location**: `/sessions/gracious-loving-goodall/mnt/MarkDV/MarkView/EditorWeb/`

For future modular development, advanced plugins, and production bundling.

### Project Structure

```
EditorWeb/
├── src/
│   ├── editor.ts           # Main editor class
│   ├── bridge.ts           # Typed Swift communication
│   ├── theme.ts            # Theme management
│   ├── toc.ts              # TOC generation
│   ├── pdf-prepare.ts      # PDF utilities
│   ├── plugins/
│   │   ├── admonition.ts   # Custom admonition plugin
│   │   ├── graphviz.ts     # Graphviz diagram support
│   │   └── plantuml.ts     # PlantUML diagram support
│   └── styles/
│       ├── editor.css      # Main styles (CSS variables)
│       └── print.css       # Print styles
├── vite.config.ts
├── tsconfig.json
├── package.json
└── README.md
```

### Setup

```bash
cd EditorWeb
npm install
npm run dev      # Dev server on localhost:5173
npm run build    # Build to dist/
npm run type-check
```

### Key Classes

#### `MarkViewEditor`

Main editor class managing state and rendering.

```typescript
const editor = new MarkViewEditor();
editor.initialize();
```

Methods:
- `initialize()`: Setup and init
- `render()`: Re-render markdown
- `toggleMode()`: Source/preview switch
- `toggleTheme()`: Light/dark toggle

#### `EditorBridge`

Typed message passing with Swift.

```typescript
bridge.send('contentChanged', { markdown, html });
bridge.onContentChanged((payload) => {
  console.log(payload.markdown);
});
```

#### `ThemeManager`

Theme state and CSS variable management.

```typescript
themeManager.setTheme('dark');
themeManager.toggle(); // Returns new theme
themeManager.getColor('accentPrimary'); // Get color value
```

#### `TOCManager`

Heading extraction and tracking.

```typescript
const headings = tocManager.extractHeadings(container);
tocManager.setupObserver(container, (activeId) => {
  console.log('Active heading:', activeId);
});
tocManager.scrollToHeading('heading-id');
```

#### `PDFPreparer`

PDF export utilities with page break optimization.

```typescript
const clone = pdfPreparer.preparePrintLayout(element);
pdfPreparer.print(element);
pdfPreparer.restoreEditLayout(element);
```

### Plugin Architecture

#### Admonition Plugin

Supports `::: type` container syntax.

```markdown
::: info
Information content
:::

::: warning
Warning content
:::

::: tip
Tip content
:::

::: danger
Danger content
:::
```

#### Graphviz Plugin

Uses @viz-js/viz for WASM-based rendering.

```markdown
\`\`\`dot
digraph {
  A -> B;
  B -> C;
}
\`\`\`

\`\`\`graphviz
graph {
  A -- B;
  B -- C;
}
\`\`\`
```

#### PlantUML Plugin

Integration point for PlantUML diagrams (server or WASM).

```markdown
\`\`\`plantuml
@startuml
A -> B
B -> C
@enduml
\`\`\`
```

### TypeScript Features

- Strict type checking enabled
- Full declarations and source maps
- Type-safe bridge communication
- No implicit any

### Styling System

CSS custom properties for all colors and spacing:

```css
:root {
  --bg-primary: white;
  --text-primary: #1a1a1a;
  --accent-primary: #0066cc;
  --border-color: #e0e0e0;
  --shadow-md: 0 2px 4px rgba(0,0,0,0.1);
  /* ... */
}

html[data-theme="dark"] {
  --bg-primary: #1a1a2e;
  --text-primary: #e8e8e8;
  /* ... */
}
```

Easy theme customization without modifying component code.

### Build Output

```
dist/
├── index.es.js       # ES module (primary)
├── index.js          # CommonJS fallback
├── index.d.ts        # TypeScript declarations
└── index.d.ts.map    # Source map for types
```

Build is minified and optimized for production.

### Dependencies

See `package.json` for complete list. Key libraries:

- **@milkdown/core** - Advanced editor (optional upgrade path)
- **markdown-it** - Markdown parsing
- **mermaid** - Diagrams
- **katex** - Math rendering
- **prismjs** - Code highlighting
- **@viz-js/viz** - Graphviz WASM

Most are from CDN in MVP, bundled in Vite build.

## Integration with Swift

### WKWebView Setup

```swift
let config = WKWebViewConfiguration()
let contentController = config.userContentController
contentController.add(self, name: "bridge")

let webView = WKWebView(frame: .zero, configuration: config)

// Load editor
let editorURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")!
webView.loadFileURL(editorURL, allowingReadAccessTo: editorURL.deletingLastPathComponent())
```

### Message Handling

```swift
func userContentController(_ userContentController: WKUserContentController,
                         didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any],
          let type = body["type"] as? String,
          let payload = body["payload"] as? [String: Any] else { return }

    switch type {
    case "contentChanged":
        let markdown = payload["markdown"] as? String ?? ""
        let html = payload["html"] as? String ?? ""
        self.didUpdateContent(markdown: markdown, html: html)

    case "headingsUpdated":
        let headings = payload as? [[String: Any]] ?? []
        self.didUpdateHeadings(headings)

    case "scrollPosition":
        let headingId = payload["activeHeadingId"] as? String
        self.didUpdateScrollPosition(activeHeadingId: headingId)

    case "ready":
        self.editorReady()

    default:
        break
    }
}
```

### Sending Content to Editor

```swift
func loadMarkdown(_ markdown: String) {
    let escaped = markdown.replacingOccurrences(of: "'", with: "\\'")
    webView.evaluateJavaScript("window.setContent('\(escaped)')")
}

func switchTheme(_ theme: String) {
    webView.evaluateJavaScript("window.setTheme('\(theme)')")
}

func exportHTML() -> String {
    var html = ""
    webView.evaluateJavaScript("window.getHTML()") { result, error in
        if let result = result as? String {
            html = result
        }
    }
    return html
}

func exportPDF() {
    webView.evaluateJavaScript("window.preparePrintLayout()") { [weak self] result, error in
        // Trigger native print/PDF save
        let printController = UIPrintInteractionController.shared
        // ... configure and present print controller
        self?.webView.evaluateJavaScript("window.restoreEditLayout()")
    }
}
```

## Deployment

### For MVP (index.html)

1. Copy `Resources/Editor/index.html` to Xcode project
2. Add to target's Copy Bundle Resources build phase
3. Reference in WKWebView as shown above

### For Production Build

```bash
cd EditorWeb
npm install
npm run build
# Output in dist/ ready for bundling
```

Then integrate dist files into app bundle.

## Performance Tips

1. **Debounce input**: Current implementation debounces rendering
2. **Lazy diagram rendering**: Mermaid/Graphviz render on-demand
3. **Virtual scrolling**: For very long documents, implement in future
4. **Code splitting**: Separate styles and scripts for parallel loading
5. **Preload fonts**: System fonts are default, no web fonts

## Testing

For EditorWeb:

```bash
npm run type-check  # Full TypeScript checking
```

Test in browser first:
```bash
npm run dev
# Open http://localhost:5173 in browser
# Test markdown, theme switching, diagrams, etc.
```

## Future Enhancements

- Collaborative editing
- Plugin system for custom extensions
- Offline-first with service workers
- Real-time syntax suggestions
- Export formats: DOCX, EPUB, etc.
- Undo/redo with history
- Search and replace
- Spell checking
- Custom CSS injection

## Troubleshooting

### Editor not loading
- Check console for JavaScript errors
- Verify CDN resources are accessible
- Check WKWebView message handler setup

### Markdown not rendering
- Check for syntax errors in markdown
- Verify markdown-it is loaded before first render
- Check for JavaScript errors in console

### Bridge messages not reaching Swift
- Verify message handler name matches ("bridge")
- Check Swift side message handler implementation
- Test with console.log before postMessage

### Theme not persisting
- Check localStorage is enabled in WKWebView
- Verify `data-theme` attribute is set on html element

### Math not rendering
- Ensure KaTeX CSS and JS are both loaded
- Check math delimiters: `$...$` (inline) or `$$...$$` (block)
- Verify renderMathInElement is called after DOM update

### Diagrams not showing
- Mermaid: Check syntax with live editor at mermaid.live
- Graphviz: Ensure @viz-js/viz is available (needs WASM)
- PlantUML: Requires server or Wasm integration

## Support

See EditorWeb/README.md for additional details on the Vite project structure and development workflow.
