# MarkView Build and Integration Guide

## Quick Reference

### File Summary
- **12 Swift source files** organized into 4 layers
- **App Layer**: Entry point and app configuration
- **Model Layer**: Data structures and managers
- **View Layer**: SwiftUI user interface components
- **Bridge Layer**: JS-Swift communication and PDF export

### Architecture Overview

```
User Interface (SwiftUI)
    ↓
ContentView (3-panel layout)
    ├── FileTreeView (left)
    ├── EditorView + TabBarView (center)
    └── TOCView (right)
    ↓
WorkspaceManager (state)
    ├── FileNode (file system)
    └── OpenTab (document state)
    ↓
WebViewBridge ↔ WKWebView
    ├── Theme sync
    ├── Content sync
    ├── TOC extraction
    └── PDF export
```

## Integration Checklist

### 1. Xcode Project Setup
- [ ] Create new macOS App project targeting macOS 13.0+
- [ ] Create group structure: App, Models, Views, Bridge
- [ ] Add all 12 .swift files to appropriate groups
- [ ] Set Swift version to 5.9 or later
- [ ] Enable strict concurrency checking

### 2. Required Resources
Create these files in your project:

**Resources/Editor/index.html**
```
- Bootstrap markdown editor UI
- Expose window.editorBridge API
- Implement theme switching
- Handle markdown rendering
- Send messages back to Swift via webkit.messageHandlers.markviewBridge
```

**Assets.xcassets**
- App icon (various sizes)
- Any custom images

### 3. Info.plist Configuration
Add to your Info.plist:

```xml
<key>CFBundleDocumentTypes</key>
<array>
    <dict>
        <key>CFBundleTypeName</key>
        <string>Markdown Document</string>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>LSItemContentTypes</key>
        <array>
            <string>net.daringfireball.markdown</string>
            <string>public.plain-text</string>
        </array>
        <key>LSHandlerRank</key>
        <string>Default</string>
    </dict>
</array>

<key>UTImportedTypeDeclarations</key>
<array>
    <dict>
        <key>UTTypeIdentifier</key>
        <string>net.daringfireball.markdown</string>
        <key>UTTypeConformsTo</key>
        <array>
            <string>public.plain-text</string>
        </array>
        <key>UTTypeTagSpecification</key>
        <dict>
            <key>public.filename-extension</key>
            <array>
                <string>md</string>
                <string>markdown</string>
            </array>
        </dict>
    </dict>
</array>

<key>NSDocumentTypes</key>
<array>
    <dict>
        <key>NSDocumentClass</key>
        <string>MarkViewApp.MarkdownDocument</string>
        <key>NSName</key>
        <string>Markdown</string>
        <key>NSRole</key>
        <string>Editor</string>
        <key>CFBundleTypeExtensions</key>
        <array>
            <string>md</string>
            <string>markdown</string>
        </array>
    </dict>
</array>
```

### 4. Bridge Implementation (Editor HTML)

The **EditorView.swift** expects `Resources/Editor/index.html` to:

**Receive messages from Swift:**
```javascript
// Listen for content changes
window.editorBridge.setContent(markdownString)
window.editorBridge.setTheme(cssClassName)
window.editorBridge.scrollToHeading(headingId)
window.editorBridge.preparePrintLayout()
window.editorBridge.restoreEditLayout()
```

**Send messages to Swift:**
```javascript
// When content changes
window.editorBridge.sendMessage("contentChanged", {
    content: markdownString
})

// When headings are extracted
window.editorBridge.sendMessage("headingsExtracted", {
    headings: [
        { id: "h1", level: 1, text: "Title" },
        { id: "h2", level: 2, text: "Section" }
    ]
})

// When a heading is clicked
window.editorBridge.sendMessage("headingClicked", {
    headingId: "h1"
})

// When scroll position changes
window.editorBridge.sendMessage("scrollPositionChanged", {
    position: 100.5
})

// When editor is ready
window.editorBridge.sendMessage("editorReady", {})
```

## Key Classes and Responsibilities

### App Layer
**MarkViewApp**
- App lifecycle and scene setup
- Menu bar configuration
- Keyboard shortcuts
- Document type handling

### Model Layer
**ThemeManager**
- Theme persistence via @AppStorage
- Dark/light/system detection
- Observer pattern for theme changes
- Color palette definitions

**WorkspaceManager**
- Open files and tabs management
- File system operations
- File watching for external changes
- Recent files persistence
- Heading extraction from markdown

**FileNode**
- Recursive file tree structure
- Directory loading
- File filtering
- File system monitoring

**DocumentState**
- HeadingItem: Single TOC entry
- OpenTab: File state container

### View Layer
**ContentView**
- NavigationSplitView layout
- Toolbar setup
- File drop handling
- Panel visibility toggles

**FileTreeView**
- Recursive folder/file display
- Search/filter capability
- Context menus

**EditorView**
- WKWebView wrapper
- Bridge delegate implementation
- Content and theme synchronization

**TOCView**
- Heading list display
- Active heading tracking
- Click-to-scroll functionality

**TabBarView**
- Open files as tabs
- Tab switching
- Tab closing
- Modified state indicator

### Bridge Layer
**WebViewBridge**
- WKScriptMessageHandler implementation
- Message parsing and routing
- JavaScript evaluation helpers
- Delegate pattern

**PDFExporter**
- PDF generation via WKWebView
- Save panel integration
- Print layout handling
- Error handling

## Testing Checklist

- [ ] Open a markdown file
- [ ] Open a folder with markdown files
- [ ] Create new tab from file tree
- [ ] Close tab with unsaved changes (verify alert)
- [ ] Switch between tabs
- [ ] Edit content and verify modified indicator
- [ ] Toggle dark/light theme
- [ ] Verify TOC updates with headings
- [ ] Click heading in TOC to scroll
- [ ] Export to PDF
- [ ] Toggle file tree visibility
- [ ] Toggle TOC visibility
- [ ] Verify keyboard shortcuts
- [ ] Test file watcher (external file changes)
- [ ] Verify recent files persistence

## Performance Considerations

1. **File Loading**: Large folders may take time to load. Consider async loading.
2. **Memory**: WebView content holds markdown in memory. Document size limits may apply.
3. **Theme Switching**: Updates both macOS appearance and WebView content.
4. **File Watching**: Uses DispatchSource, should be efficient even with many files.
5. **TOC Extraction**: Simple regex-based heading detection. Can be optimized with proper markdown parser.

## Known Limitations

1. **No inline editing toolbar** in WebView (handled via menu bar)
2. **Single WKWebView instance** (one editor at a time)
3. **Simple markdown parsing** (heading extraction via regex)
4. **No undo/redo** (relies on macOS standard editing)
5. **No syntax highlighting** (delegated to WebView HTML)

## Future Enhancements

- [ ] Real-time Markdown previewing
- [ ] Syntax highlighting in editor
- [ ] Find and replace functionality
- [ ] Markdown preview vs source mode toggle
- [ ] Custom styling/themes
- [ ] Plugin architecture
- [ ] Cloud sync (iCloud Drive)
- [ ] Collaboration features

## Building and Distribution

### Development Build
```bash
xcodebuild build -scheme MarkView
```

### Release Build
```bash
xcodebuild build -scheme MarkView -configuration Release
```

### Archive for Distribution
```bash
xcodebuild archive -scheme MarkView
```

### Code Signing
- Ensure proper team ID and provisioning profile
- Sign with Developer Certificate
- Notarize for distribution (macOS 10.15+)

## Dependencies

- **SwiftUI**: Built-in (macOS 13.0+)
- **WebKit**: Built-in (macOS)
- **Foundation**: Built-in
- **AppKit**: For native dialogs and system integration

No external package dependencies required.

## Debugging Tips

1. **WKWebView Console**: Enable Developer Extras in config (already done in EditorView)
2. **Bridge Messages**: Add logging in WebViewBridge.handleMessage()
3. **File Operations**: Check NSLog output for file I/O errors
4. **Theme Changes**: Monitor NotificationCenter for ThemeDidChange notifications
5. **Memory**: Use Xcode Instruments to monitor WKWebView memory usage

