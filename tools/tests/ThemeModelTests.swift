import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}
func ratio(_ a: ThemeColor, _ b: ThemeColor) -> String { String(format: "%.2f", ThemeColor.contrast(a, b)) }

let presets: [AppTheme] = [.darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .paper]

// MARK: colour basics
check(ThemeColor(hex: "#12ab34")?.rgb == 0x12AB34, "lower-case hex with # parses")
check(ThemeColor(hex: "12AB34")?.hex == "#12AB34", "hex without # parses and prints upper case")
for bad in ["", "#12", "zzzzzz", "#1234567", "12 456", "#12AB3G"] { check(ThemeColor(hex: bad) == nil, "'\(bad)' is not a colour") }
check(abs(ThemeColor.contrast(ThemeColor(0x000000), ThemeColor(0xFFFFFF)) - 21) < 0.01, "black on white is 21:1")
check(abs(ThemeColor.contrast(ThemeColor(0x777777), ThemeColor(0x777777)) - 1) < 0.001, "a colour on itself is 1:1")
check(ThemeColor(0xFFFFFF).readableText.rgb == 0x000000 && ThemeColor(0x000000).readableText.rgb == 0xFFFFFF, "readable text flips")
check(ThemeColor(0x000000).mixed(with: ThemeColor(0xFFFFFF), fraction: 0.5).rgb == 0x808080, "mixing halfway")

// MARK: appearances
check(AppTheme.paper.isDark(systemIsDark: true) == false, "Paper is light even when macOS is dark")
for t in presets.filter({ $0 != .paper }) + [.classicDark] { check(t.isDark(systemIsDark: false), "\(t) is dark even when macOS is light") }
check(AppTheme.system.isDark(systemIsDark: true) && !AppTheme.system.isDark(systemIsDark: false), "System follows macOS")
check(AppTheme.system.resolved(systemIsDark: true) == .classicDark && AppTheme.system.resolved(systemIsDark: false) == .classicLight,
      "System draws Classic Dark or Classic Light")
check(AppTheme.pickerChoices(current: .midnight) == [.system] + presets, "picker lists System and every preset")
check(AppTheme.pickerChoices(current: .classicDark).first == .classicDark && AppTheme.pickerChoices(current: .classicDark).count == presets.count + 2,
      "Classic is listed while active")
check(Set(AppTheme.allCases.map(\.webID)).count == AppTheme.allCases.count, "web ids are unique")

// MARK: legibility of every preset (criterion 6) and Classic's own text
for theme in presets + [.classicDark, .classicLight] {
    let p = ThemePalette.make(theme)
    let strict = theme.isPreset
    for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar), ("input", p.bgInput), ("hover", p.bgHover), ("active", p.bgActive)] {
        check(ThemeColor.contrast(p.text, surface) >= 4.5, "\(theme) text on \(name) is \(ratio(p.text, surface))")
        check(ThemeColor.contrast(p.textBright, surface) >= 4.5, "\(theme) bright text on \(name) is \(ratio(p.textBright, surface))")
    }
    check(ThemeColor.contrast(p.text, p.selection) >= 4.5, "\(theme) text on selection is \(ratio(p.text, p.selection))")
    check(ThemeColor.contrast(p.onAccent, p.badge) >= 4.5, "\(theme) text on badge is \(ratio(p.onAccent, p.badge))")
    check(p.isDark == theme.isDark(systemIsDark: true), "\(theme) palette dark flag matches")
    guard strict else { continue }
    for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar)] {
        check(ThemeColor.contrast(p.textDim, surface) >= 4.5, "\(theme) dim text on \(name) is \(ratio(p.textDim, surface))")
        for (cn, c) in [("accent", p.blue), ("green", p.green), ("orange", p.orange), ("yellow", p.yellow),
                        ("purple", p.purple), ("red", p.red), ("cyan", p.cyan)] {
            check(ThemeColor.contrast(c, surface) >= 4.5, "\(theme) \(cn) on \(name) is \(ratio(c, surface))")
        }
    }
    check(ThemeColor.contrast(p.border, p.bg) >= 1.3, "\(theme) border is visible on the background (\(ratio(p.border, p.bg)))")
    check(ThemeColor.contrast(p.bgActive, p.bg) >= 1.15, "\(theme) the active row is distinguishable (\(ratio(p.bgActive, p.bg)))")
}

// Base colours approved in DEC-003.
let approved: [(AppTheme, UInt32, UInt32, UInt32, UInt32)] = [
    (.darcula, 0x2B2B2B, 0x323232, 0xE0E0E0, 0xE6A15C), (.midnight, 0x151C2B, 0x1D2738, 0xE5EBF5, 0x79B8FF),
    (.graphite, 0x202124, 0x2A2C30, 0xE8EAED, 0xB39DDB), (.paper, 0xFFFCF5, 0xF2EDE3, 0x292724, 0x315E9B)]
for (theme, bg, panel, text, accent) in approved {
    let b = ThemePalette.webBase(theme)
    check(b.bg.rgb == bg && b.panel.rgb == panel && b.text.rgb == text && b.accent.rgb == accent, "\(theme) keeps its approved base colours")
    let p = ThemePalette.make(theme)
    check(p.bg.rgb == bg && p.bgSidebar.rgb == panel && p.text.rgb == text && p.accent.rgb == accent, "\(theme) palette uses them")
}

// MARK: Classic is the look before themes (DEC-004)
let cd = ThemePalette.make(.classicDark), cl = ThemePalette.make(.classicLight)
check(cd.bg.rgb == 0x1E1E1E && cd.bgSidebar.rgb == 0x252526 && cd.blue.rgb == 0x569CD6 && cd.badge.rgb == 0x007ACC && cd.selection.rgb == 0x264F78,
      "Classic Dark keeps the VS Code Dark+ colours")
check(cl.bg.rgb == 0xFFFFFF && cl.bgSidebar.rgb == 0xF3F3F3 && cl.cyan.rgb == 0x0070C1 && cl.selection.rgb == 0xADD6FF,
      "Classic Light keeps the Light+ colours")
check(ThemePalette.make(.system).bg == cd.bg, "an unresolved System palette is Classic Dark")

// MARK: accent
let plain = ThemePalette.make(.midnight)
let pink = ThemeColor(0xFF4D9A)
let custom = ThemePalette.make(.midnight, accent: pink)
check(custom.accent == pink && custom.badge == pink, "the accent override is the accent and the badge fill")
check(custom.selection != plain.selection, "the selection follows the accent")
check(custom.defaultAccent.rgb == 0x79B8FF, "the default accent is still known")
let dark = ThemePalette.make(.midnight, accent: ThemeColor(0x101828))
check(ThemeColor.contrast(dark.blue, dark.bg) >= 4.5 && ThemeColor.contrast(dark.blue, dark.bgSidebar) >= 4.5,
      "an unreadable accent is lightened where it is text (\(ratio(dark.blue, dark.bg)))")
let pale = ThemePalette.make(.paper, accent: ThemeColor(0xFFF2B0))
check(ThemeColor.contrast(pale.blue, pale.bg) >= 4.5, "a pale accent on Paper is darkened where it is text (\(ratio(pale.blue, pale.bg)))")
check(ThemeColor.contrast(pale.onAccent, pale.badge) >= 4.5, "text on a pale badge is readable")
check(ThemePalette.make(.classicDark, accent: pink).blue != cd.blue, "Classic takes an accent too")

// MARK: per-appearance accent memory (DEC-002)
var s = WindowThemeSettings(theme: .midnight)
s.setAccent(ThemeColor(0xFF0000))
s.select(.paper)
check(s.activeOverride == nil, "Paper starts with its default accent")
s.setAccent(ThemeColor(0x00AA00))
s.select(.midnight)
check(s.activeOverride?.rgb == 0xFF0000, "returning to Midnight restores its accent")
s.setAccent(nil)
check(s.activeOverride == nil && s.accentOverride(for: .paper)?.rgb == 0x00AA00, "resetting clears only the active appearance")
check(s.effectiveAccent(systemIsDark: true).rgb == 0x79B8FF, "after a reset the default accent is in use")
s.select(.system)
check(s.effectiveAccent(systemIsDark: false).rgb == 0x569CD6, "System uses the Classic accent")

// MARK: coding
var full = WindowThemeSettings(theme: .graphite)
full.setAccent(ThemeColor(0x123456))
full.select(.paper)
full.setAccent(ThemeColor(0xABCDEF))
let data = try! JSONEncoder().encode(full)
check((try? JSONDecoder().decode(WindowThemeSettings.self, from: data)) == full, "settings survive a round trip")
for theme in [AppTheme.tokyoNight, .carbonRed] {
    let settings = WindowThemeSettings(theme: theme, accents: [theme: pink])
    let encoded = try! JSONEncoder().encode(settings)
    check((try? JSONDecoder().decode(WindowThemeSettings.self, from: encoded)) == settings, "\(theme) and its custom accent survive a relaunch")
}
func decode(_ json: String) -> WindowThemeSettings? { try? JSONDecoder().decode(WindowThemeSettings.self, from: Data(json.utf8)) }
check(decode(#"{"theme":"nope","accents":{}}"#)?.theme == .classicDark, "an unknown appearance becomes Classic Dark")
check(decode(##"{"theme":"paper","accents":{"paper":"#12","midnight":"#0A0B0C","x":"#ffffff"}}"##)?.accents == [.midnight: ThemeColor(0x0A0B0C)],
      "unreadable accents and unknown appearances are dropped")
check(decode(#"{"theme":"paper"}"#)?.theme == .paper, "a missing accents map is empty")
check(decode(#"{"theme":3,"accents":[1]}"#)?.theme == .classicDark, "wrong types give the fallback")

// MARK: starting settings, upgrade and inheritance (criteria 4 and 5, DEC-004, DEC-005)
func store() -> (ThemeSettingsStore, UserDefaults) {
    let name = "theme-model-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return (ThemeSettingsStore(defaults: d), d)
}
var (st, d) = store()
check(st.startingSettings().theme == .classicDark, "nothing saved (today's default) starts as Classic Dark")
d.set("light", forKey: ThemeSettingsStore.legacyKey)
check(st.startingSettings().theme == .classicLight, "a saved light setting stays light (Classic Light)")
d.set("dark", forKey: ThemeSettingsStore.legacyKey)
check(st.startingSettings().theme == .classicDark, "a saved dark setting stays dark (Classic Dark)")
d.set("system", forKey: ThemeSettingsStore.legacyKey)
check(st.startingSettings().theme == .classicDark, "a saved system setting keeps today's dark look")
d.set("purple", forKey: ThemeSettingsStore.legacyKey)
check(st.startingSettings().theme == .classicDark, "an unreadable legacy value falls back to Classic Dark")
d.set(42, forKey: ThemeSettingsStore.legacyKey)
check(st.startingSettings().theme == .classicDark, "a legacy value of the wrong type falls back to Classic Dark")

d.set("light", forKey: ThemeSettingsStore.legacyKey)
st.remember(full)
check(st.startingSettings() == full, "the last change wins over the legacy setting and keeps every accent (DEC-005)")
var newWindow = st.startingSettings()
newWindow.select(.darcula)
newWindow.setAccent(ThemeColor(0x010203))
check(st.startingSettings() == full, "changing a window does not change the stored value until it is remembered")
st.remember(newWindow)
check(st.startingSettings().accentOverride(for: .paper)?.rgb == 0xABCDEF && st.startingSettings().theme == .darcula,
      "the next window gets the newest theme with the whole collection")

d.set(Data("not json".utf8), forKey: ThemeSettingsStore.lastChangedKey)
check(st.startingSettings().theme == .classicLight, "an unreadable last-changed record falls back to the legacy setting")
d.set(Data(##"{"theme":"bogus","accents":{"paper":"#112233"}}"##.utf8), forKey: ThemeSettingsStore.lastChangedKey)
check(st.startingSettings().theme == .classicLight, "a record that names no known appearance is not used")
d.set(42, forKey: ThemeSettingsStore.lastChangedKey)
check(st.startingSettings().theme == .classicLight, "a record of the wrong type is not used")

// The web token file repeats the base colours of every appearance (editor, panel, text, accent); both sides must agree.
let tokenFile = "MarkView/Resources/Editor/vendor/js/markview-themes.js"
if let js = try? String(contentsOfFile: tokenFile, encoding: .utf8) {
    let hex = "(#[0-9A-Fa-f]{6})"
    let pattern = "'([a-z-]+)': \\{ base: \\{ bg: '\(hex)', panel: '\(hex)', text: '\(hex)', accent: '\(hex)' \\}"
    let regex = try! NSRegularExpression(pattern: pattern)
    var seen = Set<String>()
    for match in regex.matches(in: js, range: NSRange(js.startIndex..., in: js)) {
        func group(_ i: Int) -> String { String(js[Range(match.range(at: i), in: js)!]) }
        let id = group(1)
        guard let theme = AppTheme.allCases.first(where: { $0 != .system && $0.webID == id }) else {
            check(false, "the web token file names an appearance the app does not know: \(id)"); continue
        }
        seen.insert(id)
        let base = ThemePalette.webBase(theme)
        check(ThemeColor(hex: group(2))?.rgb == base.bg.rgb, "\(id): editor background is the same in Swift and in the web tokens")
        check(ThemeColor(hex: group(3))?.rgb == base.panel.rgb, "\(id): panel background is the same in Swift and in the web tokens")
        check(ThemeColor(hex: group(4))?.rgb == base.text.rgb, "\(id): text is the same in Swift and in the web tokens")
        check(ThemeColor(hex: group(5))?.rgb == base.accent.rgb, "\(id): accent is the same in Swift and in the web tokens")
    }
    check(seen == Set(AppTheme.allCases.filter { $0 != .system }.map(\.webID)), "the web token file has a base for every appearance (found \(seen.sorted()))")
} else {
    check(false, "the web token file can be read from the repository root: \(tokenFile)")
}

if failures == 0 { print("theme model checks passed") } else { print("\(failures) failure(s)"); exit(1) }
