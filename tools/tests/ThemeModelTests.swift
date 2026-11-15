import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}
func ratio(_ a: ThemeColor, _ b: ThemeColor) -> String { String(format: "%.2f", ThemeColor.contrast(a, b)) }

// Names for the ids the checks use (a theme is its id; there is no list of themes in Swift any more).
extension AppTheme {
    static let darcula = AppTheme("darcula"), midnight = AppTheme("midnight"), graphite = AppTheme("graphite")
    static let tokyoNight = AppTheme("tokyo-night"), carbonRed = AppTheme("carbon-red"), nord = AppTheme("nord")
    static let forest = AppTheme("forest"), paper = AppTheme("paper"), daylight = AppTheme("daylight")
}

// MARK: the themes that ship, read from the Themes folder next to this program (as the app reads its bundle)
guard let builtInFolder = ThemeCatalog.bundledFolder else { print("FAIL: no Themes folder"); exit(1) }
let library = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: nil)
func def(_ id: String) -> ThemeDefinition { library.definition(id)! }
func palette(_ theme: AppTheme, accent: ThemeColor? = nil) -> ThemePalette { ThemePalette.make(def(theme.id), accent: accent) }

let presets: [AppTheme] = [.darcula, .midnight, .graphite, .tokyoNight, .carbonRed, .nord, .forest, .paper, .daylight]
let lightPresets: [AppTheme] = [.paper, .daylight]
let classics: [AppTheme] = [.classicDark, .classicLight]
let everyBuiltIn = classics + presets

// MARK: colour basics
check(ThemeColor(hex: "#12ab34")?.rgb == 0x12AB34, "lower-case hex with # parses")
check(ThemeColor(hex: "12AB34")?.hex == "#12AB34", "hex without # parses and prints upper case")
for bad in ["", "#12", "zzzzzz", "#1234567", "12 456", "#12AB3G"] { check(ThemeColor(hex: bad) == nil, "'\(bad)' is not a colour") }
check(abs(ThemeColor.contrast(ThemeColor(0x000000), ThemeColor(0xFFFFFF)) - 21) < 0.01, "black on white is 21:1")
check(abs(ThemeColor.contrast(ThemeColor(0x777777), ThemeColor(0x777777)) - 1) < 0.001, "a colour on itself is 1:1")
check(ThemeColor(0xFFFFFF).readableText.rgb == 0x000000 && ThemeColor(0x000000).readableText.rgb == 0xFFFFFF, "readable text flips")
check(ThemeColor(0x000000).mixed(with: ThemeColor(0xFFFFFF), fraction: 0.5).rgb == 0x808080, "mixing halfway")
check(ThemeColor(0xAB12CD).cssHex == "#ab12cd", "the pages get lower-case #rrggbb")

// MARK: the catalog of built-in themes is the files in Resources/Themes
check(library.ignored.isEmpty, "no built-in theme file is ignored: \(library.ignored.map { "\($0.file): \($0.reason)" })")
check(library.themes.map(\.id) == everyBuiltIn.map(\.id), "the built-in themes come in picker order: \(library.themes.map(\.id))")
check(library.themes.allSatisfy { $0.source == .builtIn }, "every shipped theme is built in")
check(Set(library.themes.map(\.name)).count == library.themes.count && library.themes.allSatisfy { !$0.summary.isEmpty }, "every theme has its own name and a summary")
for t in lightPresets { check(!def(t.id).isDark, "\(t.id) is light even when macOS is dark") }
for t in presets.filter({ !lightPresets.contains($0) }) + [.classicDark] { check(def(t.id).isDark, "\(t.id) is dark even when macOS is light") }
check(!def("classic-light").isDark, "Classic Light is light")
check(library.resolve(.system, systemIsDark: true).definition.id == "classic-dark" &&
      library.resolve(.system, systemIsDark: false).definition.id == "classic-light", "System draws Classic Dark or Classic Light")
check(library.resolve(.system, systemIsDark: true).missing == nil, "System is never reported as missing")
let gone = library.resolve(AppTheme("sunset"), systemIsDark: false)
check(gone.definition.id == "classic-dark" && gone.missing == "sunset", "an id nobody has is shown as Classic Dark and named")
check(library.resolve(.midnight, systemIsDark: false).definition.id == "midnight" && library.resolve(.midnight, systemIsDark: false).missing == nil,
      "a known theme resolves to itself")

let rowsMidnight = library.choices(current: .midnight)
check(rowsMidnight.map(\.theme) == [.system] + presets, "picker lists System and every preset: \(rowsMidnight.map(\.id))")
let rowsClassic = library.choices(current: .classicDark)
check(rowsClassic.first?.theme == .classicDark && rowsClassic.count == presets.count + 2, "Classic is listed while active")
check(library.choices(current: .system).first?.theme == .system, "Classic is not listed while it is not active")
check(rowsMidnight.first?.name == "System" && rowsMidnight.contains { $0.name == "Tokyo Night" }, "rows carry the names from the files")
check(library.name(of: .tokyoNight) == "Tokyo Night" && library.name(of: .system) == "System" && library.name(of: AppTheme("x-y")) == "x-y",
      "the name of a theme, of System and of an unknown id")

// MARK: every theme file gives a native palette and complete web tokens
let tokenKeys: [String: Set<String>] = Dictionary(uniqueKeysWithValues: ThemeSchema.groups.map { ($0.key, Set($0.value)) })
func checkPayload(_ theme: ThemeDefinition) {
    let id = theme.id
    let web = try! JSONSerialization.jsonObject(with: Data(theme.webPayload.utf8)) as! [String: Any]
    check(web["id"] as? String == id, "\(id): the payload names the theme")
    check(web["mode"] as? String == (theme.isDark ? "dark" : "light"), "\(id): the payload says dark or light")
    for (group, keys) in tokenKeys {
        let tokens = web[group] as? [String: String] ?? [:]
        // The terminal's background, foreground, cursor and selection follow the accent and are worked out by the page, unless a theme states them.
        let required = group == "term" ? keys.subtracting(["background", "foreground", "cursor", "selectionBackground"]) : keys
        check(Set(tokens.keys).isSubset(of: keys) && required.isSubset(of: Set(tokens.keys)),
              "\(id): web.\(group) has its tokens (missing \(required.subtracting(tokens.keys).sorted()))")
        for (key, value) in tokens where ThemeColor(hex: value) == nil || value != value.lowercased() || value.count != 7 {
            check(false, "\(id): web.\(group).\(key) is #rrggbb (\(value))")
        }
    }
    let base = web["base"] as? [String: String] ?? [:]
    let p = ThemePalette.make(theme)
    check(base["bg"] == p.bg.cssHex && base["panel"] == p.bgSidebar.cssHex && base["text"] == p.text.cssHex && base["accent"] == p.defaultAccent.cssHex,
          "\(id): the web base colours are the native ones (one definition)")
    check(!theme.webPayload.contains("\n") && !theme.webPayload.contains("<"), "\(id): the payload is one line of JSON without markup")
}
for theme in library.themes { checkPayload(theme) }
check(!def("classic-dark").web.vars.isEmpty && !def("classic-dark").web.ownAccentVars.isEmpty && def("classic-dark").web.mermaidBuiltIn &&
      def("classic-dark").web.chart?.count == 8, "Classic keeps its exact page values")
check(presets.allSatisfy { def($0.id).web.vars.isEmpty && !def($0.id).web.mermaidBuiltIn }, "the presets state tokens only")

// MARK: legibility of every preset (criterion 6) and Classic's own text
for theme in everyBuiltIn {
    let p = palette(theme)
    let strict = !classics.contains(theme)
    for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar), ("input", p.bgInput), ("hover", p.bgHover), ("active", p.bgActive)] {
        check(ThemeColor.contrast(p.text, surface) >= 4.5, "\(theme.id) text on \(name) is \(ratio(p.text, surface))")
        check(ThemeColor.contrast(p.textBright, surface) >= 4.5, "\(theme.id) bright text on \(name) is \(ratio(p.textBright, surface))")
    }
    check(ThemeColor.contrast(p.text, p.selection) >= 4.5, "\(theme.id) text on selection is \(ratio(p.text, p.selection))")
    check(ThemeColor.contrast(p.onAccent, p.badge) >= 4.5, "\(theme.id) text on badge is \(ratio(p.onAccent, p.badge))")
    check(p.isDark == def(theme.id).isDark, "\(theme.id) palette dark flag matches")
    guard strict else { continue }
    for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar)] {
        check(ThemeColor.contrast(p.textDim, surface) >= 4.5, "\(theme.id) dim text on \(name) is \(ratio(p.textDim, surface))")
        for (cn, c) in [("accent", p.blue), ("green", p.green), ("orange", p.orange), ("yellow", p.yellow),
                        ("purple", p.purple), ("red", p.red), ("cyan", p.cyan)] {
            check(ThemeColor.contrast(c, surface) >= 4.5, "\(theme.id) \(cn) on \(name) is \(ratio(c, surface))")
        }
    }
    check(ThemeColor.contrast(p.border, p.bg) >= 1.3, "\(theme.id) border is visible on the background (\(ratio(p.border, p.bg)))")
    check(ThemeColor.contrast(p.bgActive, p.bg) >= 1.15, "\(theme.id) the active row is distinguishable (\(ratio(p.bgActive, p.bg)))")
}

// Base colours approved in DEC-003.
let approved: [(AppTheme, UInt32, UInt32, UInt32, UInt32)] = [
    (.darcula, 0x2B2B2B, 0x323232, 0xE0E0E0, 0xE6A15C), (.midnight, 0x151C2B, 0x1D2738, 0xE5EBF5, 0x79B8FF),
    (.graphite, 0x202124, 0x2A2C30, 0xE8EAED, 0xB39DDB), (.paper, 0xFFFCF5, 0xF2EDE3, 0x292724, 0x315E9B),
    (.nord, 0x2E3440, 0x353C4A, 0xE5E9F0, 0x88C0D0), (.forest, 0x1E2A22, 0x26352B, 0xDDD8C0, 0xA7C080),
    (.daylight, 0xF7F9FC, 0xE8EDF4, 0x1F2933, 0x0F766E)]
for (theme, bg, panel, text, accent) in approved {
    let n = def(theme.id).native
    check(n.bg.rgb == bg && n.bgSidebar.rgb == panel && n.text.rgb == text && n.accent.rgb == accent, "\(theme.id) keeps its approved base colours")
    let p = palette(theme)
    check(p.bg.rgb == bg && p.bgSidebar.rgb == panel && p.text.rgb == text && p.accent.rgb == accent, "\(theme.id) palette uses them")
}

// MARK: Classic is the look before themes (DEC-004)
let cd = palette(.classicDark), cl = palette(.classicLight)
check(cd.bg.rgb == 0x1E1E1E && cd.bgSidebar.rgb == 0x252526 && cd.blue.rgb == 0x569CD6 && cd.badge.rgb == 0x007ACC && cd.selection.rgb == 0x264F78,
      "Classic Dark keeps the VS Code Dark+ colours")
check(cl.bg.rgb == 0xFFFFFF && cl.bgSidebar.rgb == 0xF3F3F3 && cl.cyan.rgb == 0x0070C1 && cl.selection.rgb == 0xADD6FF,
      "Classic Light keeps the Light+ colours")

// MARK: accent
let plain = palette(.midnight)
let pink = ThemeColor(0xFF4D9A)
let custom = palette(.midnight, accent: pink)
check(custom.accent == pink && custom.badge == pink, "the accent override is the accent and the badge fill")
check(custom.selection != plain.selection, "the selection follows the accent")
check(custom.defaultAccent.rgb == 0x79B8FF, "the default accent is still known")
let dark = palette(.midnight, accent: ThemeColor(0x101828))
check(ThemeColor.contrast(dark.blue, dark.bg) >= 4.5 && ThemeColor.contrast(dark.blue, dark.bgSidebar) >= 4.5,
      "an unreadable accent is lightened where it is text (\(ratio(dark.blue, dark.bg)))")
let pale = palette(.paper, accent: ThemeColor(0xFFF2B0))
check(ThemeColor.contrast(pale.blue, pale.bg) >= 4.5, "a pale accent on Paper is darkened where it is text (\(ratio(pale.blue, pale.bg)))")
check(ThemeColor.contrast(pale.onAccent, pale.badge) >= 4.5, "text on a pale badge is readable")
let paleDay = palette(.daylight, accent: ThemeColor(0xFFF2B0))
check(ThemeColor.contrast(paleDay.blue, paleDay.bg) >= 4.5 && ThemeColor.contrast(paleDay.blue, paleDay.bgSidebar) >= 4.5,
      "a pale accent on Daylight is darkened where it is text (\(ratio(paleDay.blue, paleDay.bg)))")
let darkForest = palette(.forest, accent: ThemeColor(0x14301C))
check(ThemeColor.contrast(darkForest.blue, darkForest.bg) >= 4.5, "a dark accent on Forest is lightened where it is text (\(ratio(darkForest.blue, darkForest.bg)))")
check(palette(.classicDark, accent: pink).blue != cd.blue, "Classic takes an accent too")

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
check(palette(.midnight, accent: s.activeOverride).accent.rgb == 0x79B8FF, "after a reset the default accent is in use")
s.select(.system)
check(ThemePalette.make(library.resolve(s.theme, systemIsDark: true).definition, accent: s.activeOverride).accent.rgb == 0x569CD6,
      "System uses the Classic accent")

// MARK: stored names (every value an earlier version wrote still decodes)
let oldNames: [(stored: String, id: String)] = [
    ("classicDark", "classic-dark"), ("classicLight", "classic-light"), ("darcula", "darcula"), ("midnight", "midnight"),
    ("graphite", "graphite"), ("tokyoNight", "tokyo-night"), ("carbonRed", "carbon-red"), ("nord", "nord"), ("forest", "forest"),
    ("paper", "paper"), ("daylight", "daylight"), ("system", "system")]
func decode(_ json: String) -> WindowThemeSettings? { try? JSONDecoder().decode(WindowThemeSettings.self, from: Data(json.utf8)) }
for (stored, id) in oldNames {
    let decoded = decode(##"{"theme":"\##(stored)","accents":{"\##(stored)":"#123456"}}"##)
    check(decoded?.theme.id == id, "the stored name \(stored) is the theme \(id)")
    check(decoded?.accentOverride(for: AppTheme(id)) == ThemeColor(0x123456), "the accent stored under \(stored) is kept")
    if id != "system" { check(library.definition(id) != nil, "\(stored) still names a shipped theme") }
    let encoded = try! JSONEncoder().encode(WindowThemeSettings(theme: AppTheme(id)))
    check(String(decoding: encoded, as: UTF8.self).contains("\"\(id)\""), "\(id) is stored under its id")
}
check(AppTheme(stored: "tokyoNight") == .tokyoNight && AppTheme(stored: "tokyo-night") == .tokyoNight, "both spellings give the same theme")
for bad in ["", "Has Space", "a_b", "-lead", "trail-", "a--b", String(repeating: "a", count: 41), "ABC"] {
    check(AppTheme(stored: bad) == nil, "'\(bad)' cannot be a theme id")
}
check(decode(##"{"theme":"ocean","accents":{"ocean":"#0A0B0C"}}"##)?.theme.id == "ocean", "a well-formed id with no theme behind it is kept")

// MARK: coding
var full = WindowThemeSettings(theme: .graphite)
full.setAccent(ThemeColor(0x123456))
full.select(.paper)
full.setAccent(ThemeColor(0xABCDEF))
let data = try! JSONEncoder().encode(full)
check((try? JSONDecoder().decode(WindowThemeSettings.self, from: data)) == full, "settings survive a round trip")
for theme in [AppTheme.tokyoNight, .carbonRed, .nord, .forest, .daylight] {
    let settings = WindowThemeSettings(theme: theme, accents: [theme: pink])
    let encoded = try! JSONEncoder().encode(settings)
    check((try? JSONDecoder().decode(WindowThemeSettings.self, from: encoded)) == settings, "\(theme.id) and its custom accent survive a relaunch")
}
check(decode(#"{"theme":"nope!","accents":{}}"#)?.theme == .classicDark, "a name that cannot be an id becomes Classic Dark")
check(decode(##"{"theme":"paper","accents":{"paper":"#12","midnight":"#0A0B0C","x y":"#ffffff"}}"##)?.accents == [.midnight: ThemeColor(0x0A0B0C)],
      "unreadable accents and names that cannot be ids are dropped")
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
d.set(Data(##"{"theme":"bo gus","accents":{"paper":"#112233"}}"##.utf8), forKey: ThemeSettingsStore.lastChangedKey)
check(st.startingSettings().theme == .classicLight, "a record that names no possible theme is not used")
d.set(42, forKey: ThemeSettingsStore.lastChangedKey)
check(st.startingSettings().theme == .classicLight, "a record of the wrong type is not used")

// MARK: user themes, from a folder of the person's own files
let workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("theme-model-tests-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workFolder) }
let userFolder = workFolder.appendingPathComponent("themes", isDirectory: true)
try! FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
func write(_ name: String, _ text: String, in folder: URL = userFolder) {
    try! Data(text.utf8).write(to: folder.appendingPathComponent(name))
}
func themeJSON(_ id: String, native: String, extra: String = "") -> String {
    #"{"schema":1,"id":"\#(id)","name":"\#(id.capitalized)","summary":"A test theme","native":{\#(native)}\#(extra)}"#
}
let oceanNative = ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##
let sandNative = ##""bg":"#FBF6EC","bgSidebar":"#F0E8D8","text":"#2B2A28","accent":"#9A4F1B""##
write("ocean.json", themeJSON("ocean", native: oceanNative))
write("sand.json", themeJSON("sand", native: sandNative, extra: #","order":15,"picker":"listed""#))
write("pinned.json", themeJSON("pinned", native: oceanNative, extra: ##","web":{"syn":{"keyword":"#FF00FF"},"t":{"codeBg":"#0A121A"}}"##))
let withUser = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: userFolder)
check(withUser.ignored.isEmpty, "valid user themes are not reported: \(withUser.ignored)")
check(withUser.themes.count == everyBuiltIn.count + 3, "three user themes join the built-in ones")
check(withUser.themes.map(\.order) == withUser.themes.map(\.order).sorted(), "the list is in order")
check(withUser.themes.map(\.id).firstIndex(of: "sand") == 2, "order puts a user theme among the built-in ones (\(withUser.themes.map(\.id)))")
check(withUser.themes.first { $0.id == "ocean" }?.source == .user(file: "ocean.json"), "a user theme knows its file")
check(withUser.choices(current: .midnight).contains { $0.theme == AppTheme("ocean") && $0.name == "Ocean" }, "a user theme is a row of the picker")
check(withUser.resolve(AppTheme("ocean"), systemIsDark: false).definition.id == "ocean", "a user theme resolves")
for id in ["ocean", "sand", "pinned"] {
    let t = withUser.definition(id)!
    checkPayload(t)
    let p = ThemePalette.make(t)
    for (name, surface) in [("bg", p.bg), ("sidebar", p.bgSidebar), ("input", p.bgInput), ("hover", p.bgHover), ("active", p.bgActive)] {
        check(ThemeColor.contrast(p.text, surface) >= 4.5, "\(id): derived surface \(name) keeps the text readable (\(ratio(p.text, surface)))")
    }
    for (cn, c) in [("green", p.green), ("orange", p.orange), ("yellow", p.yellow), ("purple", p.purple), ("red", p.red), ("cyan", p.cyan), ("dim", p.textDim)] {
        check(ThemeColor.contrast(c, p.bg) >= 4.5 && ThemeColor.contrast(c, p.bgSidebar) >= 4.5, "\(id): derived \(cn) is readable on both backgrounds")
    }
    check(t.web.vars.isEmpty && t.web.ownAccentVars.isEmpty && t.web.chart == nil && !t.web.mermaidBuiltIn, "\(id): no exact page values")
    let codeBackgrounds = [t.web.t["codeBg"]!, t.web.t["preBg"]!]
    for group in [t.web.syn, t.web.structure] {
        for (key, value) in group where key != "count" {
            for background in codeBackgrounds {
                check(ThemeColor.contrast(value, background) >= 4.5, "\(id): token \(key) reads on the code background (\(ratio(value, background)))")
            }
        }
    }
    for key in ["textSecondary", "textTertiary", "secondary", "danger", "success", "warning", "h2", "h3"] {
        check(ThemeColor.contrast(t.web.t[key]!, p.bg) >= 4.5, "\(id): t.\(key) reads on the page background (\(ratio(t.web.t[key]!, p.bg)))")
    }
}
check(withUser.definition("ocean")!.isDark && !withUser.definition("sand")!.isDark, "dark or light follows the background")
let pinned = withUser.definition("pinned")!
check(pinned.web.syn["keyword"]?.rgb == 0xFF00FF && pinned.web.t["codeBg"]?.rgb == 0x0A121A, "a token a file gives wins over derivation")
check(pinned.web.syn["string"]?.rgb != 0xFF00FF && pinned.web.t["preBg"] == withUser.definition("ocean")!.web.t["preBg"],
      "the tokens it does not give are derived as for any other theme")
check(withUser.definition("ocean")!.webPayload == ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: userFolder).definition("ocean")!.webPayload,
      "the same file gives the same payload")

// MARK: files that cannot be used are reported with their reason, never skipped silently
let problemFolder = workFolder.appendingPathComponent("problems", isDirectory: true)
try! FileManager.default.createDirectory(at: problemFolder, withIntermediateDirectories: true)
let good = oceanNative
let problems: [(file: String, text: String, reason: String)] = [
    ("broken.json", "{ not json", "not a JSON object"),
    ("array.json", "[1, 2]", "not a JSON object"),
    ("noschema.json", #"{"id":"noschema","name":"X","native":{}}"#, "no schema version"),
    ("future.json", #"{"schema":2,"id":"future","name":"X","native":{}}"#, "newer"),
    ("zero.json", #"{"schema":0,"id":"zero","name":"X","native":{}}"#, "not a known version"),
    ("badid.json", themeJSON("Bad_Id", native: good), "lower-case letters"),
    ("mismatch.json", themeJSON("other", native: good), "named \"mismatch.json\""),
    ("noname.json", ##"{"schema":1,"id":"noname","native":{"bg":"#000000"}}"##, "\"name\""),
    ("nonative.json", #"{"schema":1,"id":"nonative","name":"X"}"#, "\"native\" is missing"),
    ("missingkey.json", themeJSON("missingkey", native: ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5""##), "native.accent"),
    ("badcolour.json", themeJSON("badcolour", native: ##""bg":"red","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##), "#RRGGBB"),
    ("shortcolour.json", themeJSON("shortcolour", native: ##""bg":"#000","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#4FC3F7""##), "#RRGGBB"),
    ("unknownnative.json", themeJSON("unknownnative", native: good + ##","glow":"#FFFFFF""##), "\"glow\""),
    ("unknowntop.json", themeJSON("unknowntop", native: good, extra: #","css":"body{display:none}""#), "unknown key \"css\""),
    ("lowtext.json", themeJSON("lowtext", native: ##""bg":"#202020","bgSidebar":"#242424","text":"#2A2A2A","accent":"#4FC3F7""##), "contrast"),
    ("lowaccent.json", themeJSON("lowaccent", native: ##""bg":"#0B1620","bgSidebar":"#101F2C","text":"#E6EEF5","accent":"#0C1722""##), "\"accent\""),
    ("cssvalue.json", themeJSON("cssvalue", native: good, extra: #","web":{"t":{"codeBg":"red; background:url(https://x.test/a)"}}"#), "#RRGGBB"),
    ("unknowntoken.json", themeJSON("unknowntoken", native: good, extra: ##","web":{"syn":{"glow":"#FFFFFF"}}"##), "\"glow\""),
    ("varsindata.json", themeJSON("varsindata", native: good, extra: ##","web":{"vars":{"--bg-primary":"#000000"}}"##), "only allowed in the themes that ship"),
    ("chartshort.json", themeJSON("chartshort", native: good, extra: ##","web":{"chart":["#000000"]}"##), "8 colours"),
    ("picker.json", themeJSON("picker", native: good, extra: #","picker":"hidden""#), "\"picker\""),
    ("order.json", themeJSON("order", native: good, extra: #","order":-1"#), "\"order\""),
    ("classic-dark.json", themeJSON("classic-dark", native: good), "built-in theme"),
    ("huge.json", themeJSON("huge", native: good, extra: #","summary":"\#(String(repeating: "x", count: 70_000))""#), "larger than"),
]
for item in problems { write(item.file, item.text, in: problemFolder) }
write("notes.txt", "this is not a theme file", in: problemFolder)
write("fine.json", themeJSON("fine", native: good), in: problemFolder)
write("unreadable.json", themeJSON("unreadable", native: good), in: problemFolder)
chmod(problemFolder.appendingPathComponent("unreadable.json").path, 0o000)
let before = Dictionary(uniqueKeysWithValues: problems.map { ($0.file, try! Data(contentsOf: problemFolder.appendingPathComponent($0.file))) })
let checked = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: problemFolder)
check(checked.themes.map(\.id).contains("fine"), "a good file next to bad ones is used")
check(checked.themes.count == everyBuiltIn.count + 1, "no bad file becomes a theme (\(checked.themes.count - everyBuiltIn.count) user themes)")
for item in problems {
    let found = checked.ignored.first { $0.file == item.file }
    check(found != nil, "\(item.file) is reported, not skipped")
    check(found?.reason.contains(item.reason) == true, "\(item.file): the reason names the problem (wanted \"\(item.reason)\", got \"\(found?.reason ?? "-")\")")
}
check(checked.ignored.first { $0.file == "unreadable.json" }?.reason.contains("cannot be read") == true, "an unreadable file is reported")
check(!checked.ignored.contains { $0.file == "notes.txt" || $0.file == "fine.json" }, "a file that is not .json is not a theme file, and a good one is not reported")
check(checked.ignored.count == problems.count + 1, "exactly the bad files are reported (\(checked.ignored.map(\.file)))")
for item in problems { check((try? Data(contentsOf: problemFolder.appendingPathComponent(item.file))) == before[item.file], "\(item.file) is left exactly as it was") }
chmod(problemFolder.appendingPathComponent("unreadable.json").path, 0o644)

// MARK: limits and odd folders
let crowdedFolder = workFolder.appendingPathComponent("crowded", isDirectory: true)
try! FileManager.default.createDirectory(at: crowdedFolder, withIntermediateDirectories: true)
for number in 0..<(ThemeLibrary.userFileLimit + 2) {
    write(String(format: "t%03d.json", number), themeJSON(String(format: "t%03d", number), native: good), in: crowdedFolder)
}
let crowded = ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: crowdedFolder)
check(crowded.themes.count == everyBuiltIn.count + ThemeLibrary.userFileLimit, "no more than \(ThemeLibrary.userFileLimit) user files are read")
check(crowded.ignored.count == 2 && crowded.ignored.allSatisfy { $0.reason.contains("more than \(ThemeLibrary.userFileLimit)") }, "the files beyond the limit are reported")
check(ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: workFolder.appendingPathComponent("absent")).ignored.isEmpty, "a missing themes folder is not a problem")
check(ThemeLibrary.load(builtInFolder: builtInFolder, userFolder: problemFolder.appendingPathComponent("fine.json")).ignored.count == 1,
      "a themes 'folder' that is a file is reported")
let noBuiltIn = ThemeLibrary.load(builtInFolder: nil, userFolder: nil)
check(noBuiltIn.themes.isEmpty && noBuiltIn.ignored.count == 1, "an app without its built-in folder says so")

// MARK: adding a built-in theme is adding one file
let extendedFolder = workFolder.appendingPathComponent("builtin", isDirectory: true)
try! FileManager.default.copyItem(at: builtInFolder, to: extendedFolder)
write("aurora.json", themeJSON("aurora", native: ##""bg":"#10201C","bgSidebar":"#162A25","text":"#E3F2EC","accent":"#5CE0B8""##, extra: ##","order":105"##), in: extendedFolder)
let extended = ThemeLibrary.load(builtInFolder: extendedFolder, userFolder: nil)
check(extended.themes.count == library.themes.count + 1 && extended.ignored.isEmpty, "one more file is one more theme")
check(extended.themes.last?.id == "aurora", "it is listed in its place with nothing else edited")
check(extended.choices(current: .midnight).map(\.theme.id).last == "aurora", "and it is a row of the picker")
let aurora = ThemePalette.make(extended.definition("aurora")!)
check(aurora.isDark && ThemeColor.contrast(aurora.text, aurora.bg) >= 4.5, "and it draws")

if failures == 0 { print("theme model checks passed") } else { print("\(failures) failure(s)"); exit(1) }
