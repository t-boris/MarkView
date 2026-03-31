# MarkView EditorWeb

Production-ready Vite-built web editor for MarkView macOS app. This is the future build target for the editor component.

## Overview

The EditorWeb project is a TypeScript/Vite-based editor that compiles to a single JavaScript bundle for use in WKWebView. It provides:

- **Markdown rendering** with extended syntax support (tables, task lists, footnotes)
- **Live preview** with side-by-side editing
- **Theme support** (light/dark with CSS variables)
- **Table of Contents** auto-generation with IntersectionObserver tracking
- **Syntax highlighting** via Prism.js
- **Math rendering** with KaTeX
- **Diagrams** with Mermaid, Graphviz, and PlantUML
- **PDF export** with smart page breaks
- **Swift bridge** for native macOS integration
- **Print-optimized** stylesheets

## Development

### Prerequisites

- Node.js 16+
- npm or yarn

### Setup

```bash
cd EditorWeb
npm install
```

### Development Server

```bash
npm run dev
```

Runs on http://localhost:5173 with HMR.

### Build

```bash
npm run build
```

Outputs to `dist/` with source maps for debugging.

### Type Checking

```bash
npm run type-check
```

## Project Structure

```
src/
├── editor.ts           # Main editor class and initialization
├── bridge.ts           # Swift communication bridge
├── theme.ts            # Theme management (light/dark)
├── toc.ts              # Table of contents generation
├── pdf-prepare.ts      # PDF export utilities
├── plugins/
│   ├── admonition.ts   # Admonition/callout plugin
│   ├── graphviz.ts     # Graphviz diagram plugin
│   └── plantuml.ts     # PlantUML diagram plugin
└── styles/
    ├── editor.css      # Main editor styles with CSS variables
    └── print.css       # Print/PDF styles
```

## Dependencies

### Core
- **@milkdown/core** - Advanced markdown editor (alternative to markdown-it)
- **markdown-it** - Markdown parser with plugins
- **mermaid** - Diagram rendering
- **katex** - Math rendering
- **prismjs** - Code syntax highlighting

### Plugins
- **markdown-it-footnote** - Footnote support
- **markdown-it-task-lists** - Interactive checkboxes
- **markdown-it-container** - Container/admonition blocks
- **@viz-js/viz** - Graphviz WASM rendering

## Swift Integration

### Loading in WKWebView

```swift
let webView = WKWebView()
let bundleURL = Bundle.main.bundleURL
let resourceURL = bundleURL.appendingPathComponent("Editor/index.html")
webView.loadFileURL(resourceURL, allowingReadAccessTo: bundleURL)
```

### Message Handler

```swift
contentController.add(self, name: "bridge")

// Receive messages from web editor
func userContentController(_ userContentController: WKUserContentController,
                         didReceive message: WKScriptMessage) {
    let payload = message.body as? [String: Any]
    let type = payload?["type"] as? String
}
```

### Calling Web Functions

```swift
webView.evaluateJavaScript("setContent('\(markdown)')")
webView.evaluateJavaScript("setTheme('dark')")
webView.evaluateJavaScript("scrollToHeading('\(id)')")
```

## Features

### Markdown Syntax

- **Headings**: `# H1` through `###### H6`
- **Emphasis**: `*italic*`, `**bold**`, `~~strikethrough~~`
- **Lists**: Ordered, unordered, task lists
- **Code**: Inline `` ` `` or blocks ` ``` `
- **Blockquotes**: `> quote`
- **Tables**: GFM table syntax
- **Links**: `[text](url)`
- **Images**: `![alt](url)`
- **Footnotes**: `[^1]` with `[^1]: definition`

### Extended Syntax

- **Admonitions**: `::: info / warning / tip / danger`
- **Math**: `$inline$` or `$$block$$` (KaTeX)
- **Diagrams**:
  - ` ```mermaid ` - Flowcharts, sequence, class diagrams
  - ` ```dot ` or ` ```graphviz ` - Graph diagrams
  - ` ```plantuml ` - UML diagrams
- **Task lists**: `- [ ] unchecked`, `- [x] checked`

### Keyboard Shortcuts

- **Cmd/Ctrl+Shift+P**: Toggle preview mode
- **Cmd/Ctrl+Shift+T**: Toggle theme (light/dark)

## Theming

Colors are managed with CSS custom properties in `src/styles/editor.css`:

```css
:root {
  --bg-primary: #ffffff;
  --text-primary: #1a1a1a;
  --accent-primary: #0066cc;
  /* ... */
}
```

Switch themes by setting `data-theme` attribute:

```javascript
document.documentElement.setAttribute('data-theme', 'dark');
```

Theme preference is saved to localStorage and persists across sessions.

## Build Output

The Vite build produces:

1. **dist/index.es.js** - ES module (primary)
2. **dist/index.js** - CommonJS fallback
3. **dist/index.d.ts** - TypeScript declarations
4. **dist/index.d.ts.map** - Declaration source map

For WKWebView, import the bundle and minify separately if needed.

## PDF Export

PDF features are handled in `pdf-prepare.ts`:

- Smart page breaks to avoid orphans/widows
- Preserved colors and fonts
- Image max-width constraints
- Table formatting
- Page numbers

Use `preparePrintLayout()` before printing and `restoreEditLayout()` after.

## Performance Considerations

1. **Debounced rendering** - Markdown only re-renders on meaningful changes
2. **Lazy diagram loading** - Mermaid/Graphviz diagrams render on-demand
3. **IntersectionObserver** - Heading tracking only when visible
4. **CSS containment** - Layout optimization with `contain` property
5. **Code splitting** - Separate style and script bundles

## Browser/WKWebView Support

- macOS 11+
- iOS 14+
- Modern Safari (WebKit)
- ES2020 syntax (no transpilation for WKWebView)

## Troubleshooting

### Math not rendering
- Ensure KaTeX CSS is loaded before JS
- Check delimiters in markdown: `$...$` (inline) or `$$...$$` (block)

### Diagrams not showing
- Mermaid: Check syntax, view browser console
- Graphviz: Requires @viz-js/viz WASM module
- PlantUML: Requires server URL or Wasm module

### Performance issues
- Profile with Xcode DevTools
- Check for excessive re-renders in console
- Disable unnecessary plugins if unused

## Future Enhancements

- [ ] Collaborative editing
- [ ] Real-time syntax suggestions
- [ ] Custom themes/CSS injection
- [ ] Export to multiple formats (PDF, HTML, DOCX)
- [ ] Plugin system for custom markdown extensions
- [ ] Undo/redo history with CRDT
- [ ] Search and replace with regex

## License

Part of MarkView macOS app.
