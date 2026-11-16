import AppKit
import SwiftUI

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

/// The colour at the middle of a rendered image, as 0xRRGGBB in sRGB (the image is redrawn into an sRGB bitmap first).
func centre(_ image: NSImage?) -> UInt32? {
    guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let offset = ((cg.height / 2) * cg.width + cg.width / 2) * 4
    return UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
}

/// A view that fills itself with its window's background colour, read from the environment.
struct Probe: View {
    @Environment(\.palette) private var palette
    var body: some View { palette.bg.frame(width: 40, height: 40) }
}

// Names for the ids the checks use (a theme is its id; the themes themselves are the files in MarkView/Resources/Themes).
extension AppTheme {
    static let darcula = AppTheme("darcula"), midnight = AppTheme("midnight"), graphite = AppTheme("graphite")
    static let tokyoNight = AppTheme("tokyo-night"), carbonRed = AppTheme("carbon-red"), nord = AppTheme("nord")
    static let forest = AppTheme("forest"), paper = AppTheme("paper"), daylight = AppTheme("daylight")
}

func freshStore() -> ThemeSettingsStore {
    let name = "window-theme-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return ThemeSettingsStore(defaults: defaults)
}

/// Runs the main run loop until `done` holds (a theme catalog reloads off the main thread and tells its windows afterwards).
@MainActor func spin(_ what: String, until done: () -> Bool) {
    let limit = Date().addingTimeInterval(5)
    while !done() && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(done(), "timed out waiting for \(what)")
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    // The shipped themes only: a window of this program never reads the real themes folder of the person running it.
    let catalog = ThemeCatalog(userFolder: nil)
    check(catalog.library.ignored.isEmpty && catalog.library.themes.count == 11, "the shipped themes are all there")
    let outFolder = CommandLine.arguments.count > 1 && !CommandLine.arguments[1].isEmpty ? CommandLine.arguments[1] : nil

    // Project transparency persists independently and is shared by windows of the same project.
    let transparencyName = "transparency-test-\(UUID().uuidString)"
    let transparencyDefaults = UserDefaults(suiteName: transparencyName)!
    let projectA = URL(fileURLWithPath: "/tmp/project-a", isDirectory: true)
    let projectB = URL(fileURLWithPath: "/tmp/project-b", isDirectory: true)
    let transparency = ProjectTransparencyStore(defaults: transparencyDefaults)
    transparency.set(0.45, for: projectA)
    check(transparency.value(for: projectA) == 0.45 && transparency.value(for: projectB) == 0, "projects have independent transparency")
    let restoredTransparency = ProjectTransparencyStore(defaults: transparencyDefaults)
    check(restoredTransparency.value(for: projectA) == 0.45, "project transparency survives relaunch")
    transparency.set(0.2, for: nil)
    check(transparency.value(for: nil) == 0, "a window without a project cannot change a project")
    transparencyDefaults.removePersistentDomain(forName: transparencyName)

    // MARK: windows are independent (criterion 3)
    let store = freshStore()
    let a = WindowTheme(store: store, catalog: catalog), b = WindowTheme(store: store, catalog: catalog)
    check(a.settings.theme == .classicDark && b.settings.theme == .classicDark, "windows start as Classic Dark with nothing saved")
    a.select(.midnight)
    check(a.settings.theme == .midnight && a.webID == "midnight" && a.isDark, "window A takes Midnight")
    check(b.settings.theme == .classicDark && b.webID == "classic-dark", "window B is not changed by A")
    b.select(.paper)
    check(b.webID == "paper" && !b.isDark && a.webID == "midnight", "B takes Paper and A keeps Midnight")
    a.setAccent(ThemeColor(0xFF4D9A))
    check(a.palette.model.accent.rgb == 0xFF4D9A && b.palette.model.accent.rgb == 0x315E9B, "an accent in A does not change B")
    check(a.webAccent == "#FF4D9A" && b.webAccent == nil, "the web payload carries the accent only where it was chosen")
    check(a.webArguments.id == "midnight" && a.webArguments.accent == "#FF4D9A" && a.webArguments.list.count == 3 &&
          b.webArguments.id == "paper" && b.webArguments.accent == nil && b.webArguments.list[1] is NSNull, "web call arguments: id, accent, theme")
    let tail = a.webArguments.payload
    let sent = (try? JSONSerialization.jsonObject(with: Data(tail.utf8))) as? [String: Any]
    check(sent?["id"] as? String == "midnight" && sent?["mode"] as? String == "dark" && (sent?["t"] as? [String: String])?.isEmpty == false,
          "the web call carries the whole theme as JSON")
    check((sent?["base"] as? [String: String])?["bg"] == "#151c2b", "and it is the theme's own colours")
    let attributes = a.htmlAttributes
    check(attributes.hasPrefix(##"data-preset="midnight" data-theme="dark" data-accent="#FF4D9A" data-theme-tokens=""##) &&
          b.htmlAttributes.hasPrefix(##"data-preset="paper" data-theme="light" data-theme-tokens=""##), "html attributes for the first paint")
    let escaped = attributes.components(separatedBy: #"data-theme-tokens=""#).last.map { String($0.dropLast()) } ?? ""
    check(!escaped.contains("\"") && !escaped.contains("<") &&
          escaped.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&") == tail,
          "the tokens in the page text are the same JSON, escaped for an attribute")
    let script = a.firstPaintScript
    check(script.contains("setAttribute('data-preset', \"midnight\")") && script.contains("setAttribute('data-accent', \"#FF4D9A\")") &&
          script.contains("setAttribute('data-theme-tokens', \"{") && !script.contains("\n"), "first-paint script sets the same attributes")

    // MARK: accents are remembered per appearance (DEC-002)
    a.select(.graphite)
    check(a.webAccent == nil, "Graphite has no accent of its own yet")
    a.select(.midnight)
    check(a.webAccent == "#FF4D9A", "Midnight gets its accent back")
    a.setAccent(nil)
    check(a.webAccent == nil && a.settings.accentOverride(for: .midnight) == nil, "reset removes the override")

    // MARK: a new window inherits the last change with every accent (DEC-005)
    let s2 = freshStore()
    let first = WindowTheme(store: s2, catalog: catalog)
    first.select(.paper); first.setAccent(ThemeColor(0x00AA00)); first.select(.darcula); first.setAccent(ThemeColor(0x123456))
    let second = WindowTheme(store: s2, catalog: catalog)
    check(second.settings == first.settings, "a new window starts from the last change, accents included")
    second.select(.graphite)
    check(first.settings.theme == .darcula, "the new window is independent of the first")
    let third = WindowTheme(store: s2, catalog: catalog)
    check(third.settings.theme == .graphite && third.settings.accentOverride(for: .paper)?.rgb == 0x00AA00,
          "the next window follows the newest change")

    // MARK: restoring a saved window is not a change anyone made
    let s3 = freshStore()
    let seed = WindowTheme(store: s3, catalog: catalog); seed.select(.midnight)
    let restored = WindowTheme(store: s3, catalog: catalog)
    restored.restore(WindowThemeSettings(theme: .paper, accents: [.paper: ThemeColor(0xABCDEF)]))
    check(restored.settings.theme == .paper && restored.webAccent == "#ABCDEF", "a restored window shows its saved theme and accent")
    check(WindowTheme(store: s3, catalog: catalog).settings.theme == .midnight, "restoring does not become the starting value of new windows")

    // MARK: the window's own appearance
    func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
    }
    let w1 = makeWindow(), w2 = makeWindow()
    let t1 = WindowTheme(store: freshStore(), catalog: catalog), t2 = WindowTheme(store: freshStore(), catalog: catalog)
    t1.attach(w1); t2.attach(w2)
    t1.select(.darcula); t2.select(.paper)
    check(w1.appearance?.name == .darkAqua, "a dark preset gives its window the dark appearance")
    check(w2.appearance?.name == .aqua, "Paper gives its window the light appearance")
    t1.select(.system)
    check(w1.appearance == nil, "System leaves the window on the macOS appearance")
    t1.select(.classicLight)
    check(w1.appearance?.name == .aqua, "Classic Light is light")
    t2.detach(w2); t2.select(.midnight)
    check(w2.appearance?.name == .aqua, "a detached window is left alone")

    // MARK: two windows render with two palettes at the same time (criteria 2 and 3)
    @MainActor func render<V: View>(_ view: V) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return renderer.nsImage
    }
    let ta = WindowTheme(store: freshStore(), catalog: catalog), tb = WindowTheme(store: freshStore(), catalog: catalog)
    ta.select(.darcula); tb.select(.paper)
    let imageA = render(Probe().windowThemed(ta)), imageB = render(Probe().windowThemed(tb))
    check(centre(imageA) == 0x2B2B2B, "a view in a Darcula window draws the Darcula background (got \(String(describing: centre(imageA))))")
    check(centre(imageB) == 0xFFFCF5, "a view in a Paper window draws the Paper background (got \(String(describing: centre(imageB))))")
    ta.select(.midnight)
    check(centre(render(Probe().windowThemed(ta))) == 0x151C2B, "the view follows a theme change at once")
    check(centre(render(Probe().windowThemed(tb))) == 0xFFFCF5, "and the other window does not")
    ta.select(.nord); tb.select(.daylight)
    check(centre(render(Probe().windowThemed(ta))) == 0x2E3440, "a view in a Nord window draws the Nord background")
    check(centre(render(Probe().windowThemed(tb))) == 0xF7F9FC, "a view in a Daylight window draws the Daylight background")
    ta.select(.forest)
    check(centre(render(Probe().windowThemed(ta))) == 0x1E2A22, "a view in a Forest window draws the Forest background")

    // MARK: the picker draws in every theme and lists what it should
    for theme in [AppTheme.classicDark, .darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .nord, .forest, .paper, .daylight] {
        let t = WindowTheme(store: freshStore(), catalog: catalog)
        t.select(theme)
        let image = render(ThemePickerView().windowThemed(t))
        check((image?.size.width ?? 0) >= 300 && (image?.size.height ?? 0) > 200, "the picker renders for \(theme)")
        if let outFolder, let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: outFolder, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: outFolder).appendingPathComponent("picker-\(theme.id).png"))
        }
    }
    // MARK: a theme file of the person's own is a theme of the window (DEC-003)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("window-theme-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func put(_ name: String, _ text: String) { try? Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
    func themeFile(_ id: String, bg: String) -> String {
        ##"{"schema":1,"id":"\##(id)","name":"\##(id.capitalized)","summary":"mine","native":{"bg":"\##(bg)","bgSidebar":"#16222E","text":"#E6EEF5","accent":"#4FC3F7"}}"##
    }
    put("ocean.json", themeFile("ocean", bg: "#0B1620"))
    put("broken.json", "{ not json")
    let own = ThemeCatalog(userFolder: folder)
    check(own.library.definition("ocean") != nil && own.library.ignored.map(\.file) == ["broken.json"], "the person's folder is read and the bad file is reported")
    let mine = WindowTheme(store: freshStore(), catalog: own)
    mine.select(AppTheme("ocean"))
    check(mine.webID == "ocean" && mine.isDark && mine.palette.model.bg.rgb == 0x0B1620 && mine.webArguments.payload.contains(#""id":"ocean""#),
          "a user theme draws natively and is sent to the web pages by the same data")
    check(centre(render(Probe().windowThemed(mine))) == 0x0B1620, "a view in a user-theme window draws the file's background")
    check(own.library.choices(current: .system).contains { $0.name == "Ocean" } && render(ThemePickerView().windowThemed(mine)) != nil,
          "the picker lists it and draws with the notice of the ignored file")

    // A stored theme that is not there is shown as Classic Dark, said once, and comes back with its file.
    let ghost = WindowTheme(settings: WindowThemeSettings(theme: AppTheme("ghost")), store: freshStore(), catalog: own)
    check(ghost.webID == "classic-dark" && ghost.settings.theme == AppTheme("ghost") && own.missing == ["ghost"], "an unknown stored theme is shown as Classic Dark and reported")
    let again = WindowTheme(settings: WindowThemeSettings(theme: AppTheme("ghost")), store: freshStore(), catalog: own)
    check(again.webID == "classic-dark" && own.missing == ["ghost"], "and reported once")
    put("ghost.json", themeFile("ghost", bg: "#201830"))
    put("late.json", themeFile("late", bg: "#102030"))
    var reloaded = false
    Task { @MainActor in await own.reload(); reloaded = true }
    spin("the catalog to reload") { reloaded }
    check(own.library.definition("late") != nil && own.library.definition("ghost") != nil && own.missing.isEmpty, "a file added while the app runs is found, and the missing theme is no longer missing")
    spin("the windows to follow the catalog") { ghost.webID == "ghost" }
    check(ghost.webID == "ghost" && ghost.palette.model.bg.rgb == 0x201830 && again.webID == "ghost", "windows that had stored it draw it as soon as it is there")
    try? FileManager.default.removeItem(at: folder.appendingPathComponent("ghost.json"))
    reloaded = false
    Task { @MainActor in await own.reload(); reloaded = true }
    spin("the catalog to reload again") { reloaded }
    spin("the window to fall back") { ghost.webID == "classic-dark" }
    check(ghost.settings.theme == AppTheme("ghost") && own.missing == ["ghost"], "a deleted file falls back again, and the choice is kept for when the file returns")

    let system = SystemAppearance.shared
    check(system.isDark == (NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua), "system appearance is read")

    if failures == 0 { print("window theme checks passed") } else { print("\(failures) failure(s)"); exit(1) }
}
