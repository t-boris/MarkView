# App probe: look at the real app without showing it

Compiles and injects `mvprobe.m` into a **copy** of the Debug build, so a check can use the real windows, the real
`ContentView` and the real routing (tiles, sheets, panels) without a window on the screen and without touching the
running app or its data.

## Set up

```bash
xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration Debug \
  -derivedDataPath /tmp/MarkViewDerivedData CODE_SIGNING_ALLOWED=NO build
mkdir -p /tmp/markview-probe && cp -R /tmp/MarkViewDerivedData/Build/Products/Debug/MarkView.app /tmp/markview-probe/MarkViewProbe.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.markview.MarkViewProbe" /tmp/markview-probe/MarkViewProbe.app/Contents/Info.plist
```

The own bundle id keeps the probe's preferences apart from the installed app's. The preferences file
`~/Library/Preferences/com.markview.MarkViewProbe.plist` is the only thing left outside `$PROBE_WORK`; delete it when done.

## Script

One step per line, run on the main queue (`#` starts a comment). Output goes to `$PROBE_WORK/out-<name>/` (`log.txt`, PNGs).

| Step | Does |
|---|---|
| `wait <s>` | pause |
| `pick <n>` | work on the n-th visible window (default: the largest) |
| `picktitle <part>` | work on the visible window whose title contains this text (useful with several project windows) |
| `key` | make the picked window the key window (needed before `openurl`: the app opens a folder in the key window) |
| `openurl <path>` | calls the delegate's `application(_:open:)`, as Finder does |
| `size <w> <h>` | content size of the window |
| `snap <name>` | PNG of the window's content view (model layers: an animated backdrop shows its first frame) |
| `frame <name>` | PNG of the backdrop's presentation layer (what the render server shows now) |
| `motion begin` / `motion end` | how many backdrop layers moved between the two, and the backdrop's hit test |
| `ax` | accessibility tree: every button with its frame in window coordinates (top-left origin) and whether it is enabled |
| `move x y` / `click x y` | real mouse events through `sendEvent:` |
| `clicklabel <label>` | clicks the first element whose accessibility label or title is `<label>` (independent of the layout) |
| `drag x1 y1 x2 y2` | mouse down, five drags, mouse up (content coordinates, top-left origin) |
| `cmdkey <char>` | presses ⌘<char> in the picked window (menu and `.keyboardShortcut` equivalents) |
| `windows` | every window: class, title, visibility, sheets, modal window |
| `quit` | exit |

## Safety

Every `NSWindow` is created with alpha 0 and `ignoresMouseEvents`, the activation policy is accessory, `HOME` is empty,
`MARKVIEW_SOCKET_DIR` is its own, and a watchdog exits after 90 s. Child processes of the app (indexer, MCP servers) and the applications it launches (the QA native player's application) are not probed.
Do not click a tile that opens a system panel (Open File, Open Folder): a panel is a window the probe cannot promise to hide.
Keychain items are shared with the installed app; avoid features that read them (browser passwords, database connections).
