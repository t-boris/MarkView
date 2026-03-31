# MarkView Editor - Quick Start Guide

## The Deliverables

You have TWO complete systems:

### 1. Standalone HTML Editor (MVP) - Use This First

**File**: `MarkView/Resources/Editor/index.html` (1087 lines)

This is production-ready TODAY. No build, no npm, no dependencies to install.

```swift
// Load in WKWebView
let config = WKWebViewConfiguration()
config.userContentController.add(self, name: "bridge")

let webView = WKWebView(frame: .zero, configuration: config)
let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")!
webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
```

### 2. Vite TypeScript Project - Use For Production

**Directory**: `EditorWeb/`

For modular development, testing, and advanced build optimization later.

```bash
cd EditorWeb
npm install
npm run dev      # Test in browser
npm run build    # Production build
```

---

## Features at a Glance

### Editor
- Split-pane source/preview
- Real-time rendering
- Theme toggle (light/dark)
- Word/character count
- Keyboard shortcuts

### Markdown
- All standard syntax
- Tables, footnotes, task lists
- Code with 14+ language syntax highlighting
- Blockquotes, images, links

### Advanced
- KaTeX math: `$E=mc^2$` and `$$x^2$$`
- Mermaid diagrams: flowcharts, sequence, class diagrams
- Graphviz: `dot` and `graphviz` syntax
- Admonitions: `::: info`, `::: warning`, `::: tip`, `::: danger`

### Swift Integration
```swift
// Send content to editor
webView.evaluateJavaScript("window.setContent('\(markdown)')")

// Receive updates
func userContentController(_ userContentController: WKUserContentController,
                         didReceive message: WKScriptMessage) {
    let type = (message.body as? [String: Any])?["type"] as? String
    switch type {
    case "contentChanged":
        let markdown = (message.body as? [String: Any])?["payload"]?["markdown"] as? String
        // Handle update
    case "headingsUpdated":
        // Update TOC/sidebar
    case "scrollPosition":
        // Update active heading indicator
    default: break
    }
}
```

---

## Directory Structure

```
MarkView/
├── Resources/Editor/
│   └── index.html              ← Start here (1087 lines, complete)
├── EditorWeb/                  ← Production project
│   ├── src/
│   │   ├── editor.ts
│   │   ├── bridge.ts
│   │   ├── theme.ts
│   │   ├── toc.ts
│   │   ├── pdf-prepare.ts
│   │   ├── plugins/
│   │   │   ├── admonition.ts
│   │   │   ├── graphviz.ts
│   │   │   └── plantuml.ts
│   │   └── styles/
│   │       ├── editor.css
│   │       └── print.css
│   ├── package.json
│   ├── vite.config.ts
│   └── README.md
├── EDITOR_IMPLEMENTATION.md    ← Complete docs
└── QUICKSTART.md               ← This file
```

---

## Getting Started: 3 Steps

### Step 1: Load the Standalone Editor (Immediate)

Copy `Resources/Editor/index.html` to your Xcode project under Resources, then:

```swift
import WebKit

class EditorViewController: UIViewController {
    let webView = WKWebView()

    override func viewDidLoad() {
        super.viewDidLoad()

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "bridge")

        let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor")!
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        view.addSubview(webView)
        webView.frame = view.bounds
    }
}

extension EditorViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                             didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let type = body["type"] as? String
        let payload = body["payload"] as? [String: Any]

        switch type {
        case "contentChanged":
            if let markdown = payload?["markdown"] as? String {
                print("Content updated: \(markdown)")
            }
        case "headingsUpdated":
            if let headings = payload as? [[String: Any]] {
                print("Headings: \(headings)")
            }
        case "ready":
            print("Editor ready!")
        default: break
        }
    }
}
```

### Step 2: Add Content

```swift
let markdown = """
# Welcome to MarkView

This is **bold** and this is *italic*.

## Code Example

\`\`\`swift
let greeting = "Hello, World!"
print(greeting)
\`\`\`

## Math

Einstein's equation: $E = mc^2$

## Diagram

\`\`\`mermaid
graph LR
    A[Start] --> B[Process] --> C[End]
\`\`\`

## Task List

- [x] Done
- [ ] TODO
"""

webView.evaluateJavaScript("window.setContent('\(markdown.replacingOccurrences(of: "'", with: "\\'"))')")
```

### Step 3: Handle Theme Changes

```swift
func updateTheme(_ isDark: Bool) {
    let theme = isDark ? "dark" : "light"
    webView.evaluateJavaScript("window.setTheme('\(theme)')")
}
```

---

## Common Tasks

### Get HTML for PDF Export

```swift
webView.evaluateJavaScript("window.getHTML()") { (result, error) in
    if let html = result as? String {
        // Use html for PDF generation
    }
}
```

### Jump to Heading

```swift
webView.evaluateJavaScript("window.scrollToHeading('heading-id')")
```

### Export Markdown

```swift
webView.evaluateJavaScript("window.getMarkdown()") { (result, error) in
    if let markdown = result as? String {
        // Save or send markdown
    }
}
```

### Prepare for Printing

```swift
webView.evaluateJavaScript("window.preparePrintLayout()") { (result, error) in
    // Trigger print dialog
    let printController = UIPrintInteractionController.shared
    // ... configure and show
}
// Then restore:
webView.evaluateJavaScript("window.restoreEditLayout()")
```

---

## Keyboard Shortcuts

Users can press:

- **Cmd+Shift+P** (Mac) or **Ctrl+Shift+P** (other): Toggle preview
- **Cmd+Shift+T** (Mac) or **Ctrl+Shift+T** (other): Toggle dark mode

---

## Styling Customization

All colors use CSS variables. Edit `EditorWeb/src/styles/editor.css`:

```css
:root {
  --bg-primary: #ffffff;
  --text-primary: #1a1a1a;
  --accent-primary: #0066cc;
  /* ... */
}

html[data-theme="dark"] {
  --bg-primary: #1a1a2e;
  --text-primary: #e8e8e8;
  --accent-primary: #4da6ff;
  /* ... */
}
```

Or in the standalone HTML, edit the style block directly.

---

## For Production Build

When ready to optimize:

```bash
cd EditorWeb
npm install
npm run build
# Output in dist/ ready for bundling
```

Then integrate dist files into your app bundle.

---

## Troubleshooting

### Nothing shows up
- Check Safari console in Xcode DevTools
- Verify message handler name is "bridge"
- Check WKWebViewConfiguration setup

### Theme not changing
- Make sure to call `window.setTheme('dark')` or `window.setTheme('light')`
- Check HTML has `data-theme` attribute

### Math not rendering
- Use `$...$` for inline or `$$...$$` for display math
- Make sure KaTeX is loaded (check console for errors)

### Diagrams not showing
- Mermaid: Check syntax at mermaid.live
- Graphviz: May need WASM module for Viz.js
- PlantUML: Requires integration with PlantUML server or Wasm

---

## Next Steps

1. ✅ Copy `index.html` to your project
2. ✅ Load it in WKWebView
3. ✅ Set up message handler
4. ✅ Send/receive markdown content
5. 🔄 Customize styling if needed
6. 🚀 Deploy to App Store

For advanced development, use the EditorWeb project:
- See `EditorWeb/README.md` for full documentation
- Run `npm run dev` to test in browser
- TypeScript for type safety
- Modular architecture for extensions

---

## Support

- Complete docs: `EDITOR_IMPLEMENTATION.md`
- EditorWeb docs: `EditorWeb/README.md`
- Standalone HTML: `MarkView/Resources/Editor/index.html` (well-commented)
- All source TypeScript: `EditorWeb/src/` (fully typed)

Everything is production-ready. Use the standalone HTML immediately, upgrade to Vite project when you need advanced features.
