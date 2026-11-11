import AppKit
import WebKit

// Real WebKit regression for BUG-125. No window intersects a display or takes focus.
setvbuf(stdout, nil, _IONBF, 0)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let originalKeyWindow = application.keyWindow
let useSystemWindow = CommandLine.arguments.contains("--system-window")
let output = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
var failures = 0
func check(_ condition: Bool, _ name: String) {
    print(condition ? "PASS" : "FAIL", name)
    if !condition { failures += 1 }
}
func spin(_ seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}
DispatchQueue.global().asyncAfter(deadline: .now() + 45) { print("FAIL timeout"); exit(1) }

final class Player {
    let web: WKWebView
    let window: NSWindow
    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        let type: NSWindow.Type = useSystemWindow ? NSWindow.self : QAWebWindow.self
        window = type.init(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 800),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
    }
    func eval(_ script: String) -> Any? {
        var done = false
        var value: Any?
        web.evaluateJavaScript(script) { result, error in
            if let error { print("JavaScript error:", error.localizedDescription); failures += 1 }
            value = result
            done = true
        }
        spin(5) { done }
        check(done, "JavaScript completes")
        return value
    }
    func capture(_ name: String) -> Int {
        var done = false
        var green = 0
        web.takeSnapshot(with: nil) { image, _ in
            if let tiff = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                // Sample a coarse grid: a transparent dialog has zero green samples.
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                        if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           c.greenComponent > 0.9, c.redComponent < 0.1, c.blueComponent < 0.1 { green += 1 }
                    }
                }
                if let output, let png = bitmap.representation(using: .png, properties: [:]) {
                    try! png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
                }
            }
            done = true
        }
        spin(5) { done }
        check(done, "snapshot completes")
        return green
    }
    func close() {
        web.stopLoading()
        window.contentView = nil
        window.close()
    }
}

let html = """
<!doctype html><style>
body { background: white; color: black }
dialog { width: 500px; height: 400px; background: #00ff00; color: black }
dialog::backdrop { background: rgba(20,12,10,.6) }
@keyframes panel-in { from { opacity: 0; transform: scale(.98) translateY(-4px) }
 to { opacity: 1; transform: scale(1) translateY(0) } }
dialog[open] { animation: panel-in 220ms cubic-bezier(.16,1,.3,1) }
</style><h1>Package page</h1><button id="open" onclick="document.querySelector('dialog').showModal()">Choose date</button>
<dialog><h1>Calendar</h1><button id="day" onclick="document.querySelector('#chosen').textContent='25 November 2026'">25</button>
<p id="chosen">No date selected</p><button onclick="document.querySelector('dialog').close()">Done</button></dialog>
<script>window.framesSeen=0;function tick(){framesSeen++;requestAnimationFrame(tick)}requestAnimationFrame(tick)</script>
"""
let first = Player()
let second = Player()
for player in [first, second] {
    player.web.loadHTMLString(html, baseURL: URL(string: "https://qa.invalid/"))
}
spin(1)
for (index, player) in [first, second].enumerated() {
    check(player.eval("document.readyState") as? String == "complete", "player \(index + 1) loads")
    check(player.eval("document.hidden") as? Bool == false, "offscreen page is visible to WebKit")
    check(player.eval("framesSeen > 0") as? Bool == true, "requestAnimationFrame advances")
    check(NSScreen.screens.allSatisfy { !$0.frame.intersects(player.window.frame) }, "host remains outside every screen")
    check(!player.window.isKeyWindow && !player.window.isMainWindow, "host never takes focus")
}
for attempt in 1...2 {
    _ = first.eval("document.querySelector('#open').click(); true")
    spin(0.8)
    check(first.eval("document.getAnimations().length === 0 && getComputedStyle(document.querySelector('dialog')).opacity === '1'") as? Bool == true,
          "dialog entrance finishes on open \(attempt)")
    check(first.capture("dialog-\(attempt)") > 500, "screenshot contains the dialog on open \(attempt)")
    check(second.capture("other-player-\(attempt)") == 0, "other player is unaffected")
    // Use the same native event path as BrowserAgentExecutor, not a script click.
    let point = first.eval("JSON.stringify((()=>{let r=document.querySelector('#day').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})())") as? String ?? "{}"
    let coords = (try? JSONSerialization.jsonObject(with: Data(point.utf8))) as? [String: Double] ?? [:]
    var local = CGPoint(x: coords["x"] ?? 0, y: coords["y"] ?? 0)
    if !first.web.isFlipped { local.y = first.web.bounds.height - local.y }
    let location = first.web.convert(local, to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: first.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        if type == .leftMouseDown { first.web.mouseDown(with: event) } else { first.web.mouseUp(with: event) }
    }
    spin(0.1)
    check(first.eval("document.querySelector('#chosen').textContent") as? String == "25 November 2026", "native input selects a date")
    _ = first.eval("document.querySelector('dialog').close(); document.querySelector('#chosen').textContent='No date selected'; true")
}
first.window.orderOut(nil)
spin(0.2)
check(!first.window.occlusionState.contains(.visible), "ordered-out window does not claim visibility")
first.close()
second.close()
check(application.keyWindow === originalKeyWindow, "original key window is unchanged")
print("\(failures) failures")
exit(failures == 0 ? 0 : 1)
