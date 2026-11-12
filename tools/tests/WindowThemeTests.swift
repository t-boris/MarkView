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

func freshStore() -> ThemeSettingsStore {
    let name = "window-theme-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return ThemeSettingsStore(defaults: defaults)
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
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
    let a = WindowTheme(store: store), b = WindowTheme(store: store)
    check(a.settings.theme == .classicDark && b.settings.theme == .classicDark, "windows start as Classic Dark with nothing saved")
    a.select(.midnight)
    check(a.settings.theme == .midnight && a.webID == "midnight" && a.isDark, "window A takes Midnight")
    check(b.settings.theme == .classicDark && b.webID == "classic-dark", "window B is not changed by A")
    b.select(.paper)
    check(b.webID == "paper" && !b.isDark && a.webID == "midnight", "B takes Paper and A keeps Midnight")
    a.setAccent(ThemeColor(0xFF4D9A))
    check(a.palette.model.accent.rgb == 0xFF4D9A && b.palette.model.accent.rgb == 0x315E9B, "an accent in A does not change B")
    check(a.webAccent == "#FF4D9A" && b.webAccent == nil, "the web payload carries the accent only where it was chosen")
    check(a.webArguments == "'midnight', '#FF4D9A'" && b.webArguments == "'paper', null", "web call arguments")
    check(a.htmlAttributes == ##"data-preset="midnight" data-theme="dark" data-accent="#FF4D9A""## &&
          b.htmlAttributes == ##"data-preset="paper" data-theme="light""##, "html attributes for the first paint")

    // MARK: accents are remembered per appearance (DEC-002)
    a.select(.graphite)
    check(a.webAccent == nil, "Graphite has no accent of its own yet")
    a.select(.midnight)
    check(a.webAccent == "#FF4D9A", "Midnight gets its accent back")
    a.setAccent(nil)
    check(a.webAccent == nil && a.settings.accentOverride(for: .midnight) == nil, "reset removes the override")

    // MARK: a new window inherits the last change with every accent (DEC-005)
    let s2 = freshStore()
    let first = WindowTheme(store: s2)
    first.select(.paper); first.setAccent(ThemeColor(0x00AA00)); first.select(.darcula); first.setAccent(ThemeColor(0x123456))
    let second = WindowTheme(store: s2)
    check(second.settings == first.settings, "a new window starts from the last change, accents included")
    second.select(.graphite)
    check(first.settings.theme == .darcula, "the new window is independent of the first")
    let third = WindowTheme(store: s2)
    check(third.settings.theme == .graphite && third.settings.accentOverride(for: .paper)?.rgb == 0x00AA00,
          "the next window follows the newest change")

    // MARK: restoring a saved window is not a change anyone made
    let s3 = freshStore()
    let seed = WindowTheme(store: s3); seed.select(.midnight)
    let restored = WindowTheme(store: s3)
    restored.restore(WindowThemeSettings(theme: .paper, accents: [.paper: ThemeColor(0xABCDEF)]))
    check(restored.settings.theme == .paper && restored.webAccent == "#ABCDEF", "a restored window shows its saved theme and accent")
    check(WindowTheme(store: s3).settings.theme == .midnight, "restoring does not become the starting value of new windows")

    // MARK: the window's own appearance
    func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.titled], backing: .buffered, defer: true)
    }
    let w1 = makeWindow(), w2 = makeWindow()
    let t1 = WindowTheme(store: freshStore()), t2 = WindowTheme(store: freshStore())
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
    let ta = WindowTheme(store: freshStore()), tb = WindowTheme(store: freshStore())
    ta.select(.darcula); tb.select(.paper)
    let imageA = render(Probe().windowThemed(ta)), imageB = render(Probe().windowThemed(tb))
    check(centre(imageA) == 0x2B2B2B, "a view in a Darcula window draws the Darcula background (got \(String(describing: centre(imageA))))")
    check(centre(imageB) == 0xFFFCF5, "a view in a Paper window draws the Paper background (got \(String(describing: centre(imageB))))")
    ta.select(.midnight)
    check(centre(render(Probe().windowThemed(ta))) == 0x151C2B, "the view follows a theme change at once")
    check(centre(render(Probe().windowThemed(tb))) == 0xFFFCF5, "and the other window does not")

    // MARK: the picker draws in every theme and lists what it should
    for theme in [AppTheme.classicDark, .darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .paper] {
        let t = WindowTheme(store: freshStore())
        t.select(theme)
        let image = render(ThemePickerView().windowThemed(t))
        check((image?.size.width ?? 0) >= 300 && (image?.size.height ?? 0) > 200, "the picker renders for \(theme)")
        if let outFolder, let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: outFolder, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: outFolder).appendingPathComponent("picker-\(theme.rawValue).png"))
        }
    }
    let system = SystemAppearance.shared
    check(system.isDark == (NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua), "system appearance is read")

    if failures == 0 { print("window theme checks passed") } else { print("\(failures) failure(s)"); exit(1) }
}
