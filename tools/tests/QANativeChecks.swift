import AppKit
import CoreGraphics
import Foundation
import ImageIO

// Checks for the native player of the End-to-End QA feature (MarkView/Models/QANativeTree.swift, QANativeAccessibility.swift,
// QANativeCapture.swift, QANativeActor.swift, QANativeFactory.swift), run by tools/tests/qa-native-tests.sh. The first part is pure: the text the
// assistant is shown for an application's tree, its limits, the secure-field rule, the keys, the evidence and the permission rules. The second
// part (live) drives the fixture application Tests/Fixtures/qa-native-demo with a real QANativeActor, without ever bringing it to the front:
// it is passed as the first argument, and left out when there is none.

// MARK: - Fixtures

var nextID = 0

func el(_ role: String, _ title: String = "", sub: String = "", desc: String = "", value: String = "", placeholder: String = "",
        frame: CGRect? = nil, enabled: Bool = true, focused: Bool = false, selected: Bool = false, press: Bool = false, label: String = "",
        _ children: [QANativeElement] = []) -> QANativeElement {
    nextID += 1
    return QANativeElement(id: nextID, role: role, subrole: sub, title: title, description: desc, value: value, placeholder: placeholder, enabled: enabled,
                           focused: focused, selected: selected, frame: frame, hasPress: press, labelText: label, children: children)
}

func lines(_ snapshot: QANativeSnapshot) -> [String] { snapshot.text.components(separatedBy: "\n") }

func render(_ elements: [QANativeElement], menus: [QANativeMenuEntry] = [], title: String = "Demo", omitted: Int = 0) -> QANativeSnapshot {
    QANativeSnapshot.render(app: "Demo (com.example.demo)", windowTitle: title, elements: elements, menus: menus, omitted: omitted)
}

/// The tree the fixture application shows through Accessibility (read from the real one), with the frames it has.
func demoWindow(secretValue: String = "") -> [QANativeElement] {
    [
        el("AXStaticText", value: "Name", frame: CGRect(x: 16, y: 40, width: 80, height: 17)),
        el("AXTextField", frame: CGRect(x: 100, y: 38, width: 240, height: 24)),
        el("AXStaticText", value: "Password", frame: CGRect(x: 16, y: 70, width: 80, height: 17)),
        el("AXTextField", sub: "AXSecureTextField", desc: "Password", value: secretValue, frame: CGRect(x: 100, y: 68, width: 240, height: 24)),
        el("AXStaticText", value: "Role", frame: CGRect(x: 16, y: 100, width: 80, height: 17)),
        el("AXPopUpButton", desc: "Role", value: "Viewer", frame: CGRect(x: 96, y: 96, width: 120, height: 27)),
        el("AXCheckBox", "Remember me", value: "unchecked", frame: CGRect(x: 100, y: 130, width: 140, height: 20)),
        el("AXButton", "Sign in", frame: CGRect(x: 16, y: 160, width: 90, height: 26)),
        el("AXStaticText", value: "Not signed in", frame: CGRect(x: 116, y: 164, width: 230, height: 17)),
        el("AXScrollArea", desc: "Notes", frame: CGRect(x: 16, y: 200, width: 328, height: 76), [
            el("AXTextArea", value: "Note line 1\nNote line 2", frame: CGRect(x: 16, y: 200, width: 311, height: 560)),
            el("AXScrollBar", frame: CGRect(x: 330, y: 200, width: 14, height: 76)),
        ]),
        el("AXButton", sub: "AXCloseButton", frame: CGRect(x: 8, y: 8, width: 14, height: 16)),
        el("AXButton", sub: "AXMinimizeButton", frame: CGRect(x: 28, y: 8, width: 14, height: 16)),
        el("AXButton", sub: "AXZoomButton", frame: CGRect(x: 48, y: 8, width: 14, height: 16)),
        el("AXStaticText", value: "Demo"),
    ]
}

func countOf(_ text: String, _ part: String) -> Int { text.components(separatedBy: part).count - 1 }

/// How many references (`[e12]`) a text holds; the header's own `[eN]` is not one.
func referenceCount(_ text: String) -> Int {
    (try? NSRegularExpression(pattern: "\\[e[0-9]+\\]"))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? -1
}

// MARK: - What the assistant is shown

do {
    let snapshot = render(demoWindow(), menus: [
        QANativeMenuEntry(id: 900, path: ["QA Native Demo", "Quit QA Native Demo"]),
        QANativeMenuEntry(id: 901, path: ["File", "Reset"]),
        QANativeMenuEntry(id: 902, path: ["File", "Close Window"], enabled: false),
    ])
    let text = snapshot.text
    check("render: the header names the application and the window", lines(snapshot)[0] == "Application: Demo (com.example.demo)" && lines(snapshot)[1] == "Window: \"Demo\"")
    check("render: the header says refs are valid for one look and how to act", text.contains("valid for this look only") && text.contains("click") && text.contains("select") && text.contains("key"))
    check("render: a field is named by the label to its left", text.contains("[e1] text field \"Name\""))
    check("render: a secure field says its value is hidden", text.contains("[e2] text field \"Password\" (secure field, value hidden)"))
    check("render: a pop-up is named by its description, not by the choice it shows", text.contains("[e3] pop-up \"Role\" = \"Viewer\""))
    check("render: a checkbox shows its state", text.contains("[e4] checkbox \"Remember me\" (unchecked)"))
    check("render: a button has a name", text.contains("[e5] button \"Sign in\""))
    check("render: static text has its text and no reference", text.contains("text \"Not signed in\"") && !lines(snapshot).contains { $0.contains("text \"Not signed in\"") && $0.contains("[e") })
    check("render: the labels next to the fields are shown as text", text.contains("text \"Name\"") && text.contains("text \"Password\"") && text.contains("text \"Role\""))
    check("render: the system's window buttons are named", text.contains("button \"Close\"") && text.contains("button \"Minimize\"") && text.contains("button \"Zoom\""))
    check("render: the window's own title text is not repeated", !lines(snapshot).contains { $0.hasSuffix("text \"Demo\"") })
    check("render: a text area in a scroll area is named by it", text.contains("scroll area \"Notes\"") && text.contains("text area \"Notes\" = \"Note line 1 Note line 2\""))
    check("render: a scroll bar is not shown", !text.contains("scroll bar"))
    check("render: the menu bar lists the entries with their path and a reference", text.contains("Menu bar:") && text.contains("] QA Native Demo > Quit QA Native Demo") && text.contains("] File > Reset"))
    check("render: a disabled menu entry says so", text.contains("File > Close Window (disabled)"))
    let reset = snapshot.refs.first { $0.value.summary == "menu item \"File > Reset\"" }
    check("render: a menu entry's reference stands for the entry", reset?.value.id == 901 && reset?.value.isMenuEntry == true)
    check("render: a reference stands for its element", snapshot.refs["e5"]?.summary == "button \"Sign in\"" && snapshot.refs["e2"]?.secure == true && snapshot.refs["e1"]?.secure == false)
    check("render: references are consecutive from e1", Set(snapshot.refs.keys) == Set((1...snapshot.refs.count).map { "e\($0)" }))
    check("render: the same window gives the same text", render(demoWindow(), menus: []).text == render(demoWindow(), menus: []).text
          && referenceCount(render(demoWindow()).text) == 9)
}

do {
    // The secure field's value is not read by the reader, and the text refuses it even when it is handed in.
    let secret = "hunter2-very-secret"
    let snapshot = render(demoWindow(secretValue: secret))
    check("secure: a value that was handed in is never shown", !snapshot.text.contains(secret) && !snapshot.refs.values.contains { $0.summary.contains(secret) })
    check("secure: the line still says it is a secure field", snapshot.text.contains("(secure field, value hidden)"))
    let named = render([el("AXTextField", "PIN", sub: "AXSecureTextField", value: "4711")])
    check("secure: whatever its name, a secure field shows no value", !named.text.contains("4711") && named.text.contains("[e1] text field \"PIN\" (secure field, value hidden)"))
    let search = render([el("AXTextField", sub: "AXSearchField", desc: "Search", value: "cats")])
    check("secure: a search field is an ordinary field", search.text.contains("[e1] search field \"Search\" = \"cats\""))
}

do {
    check("names: the title comes first, then the description, then the placeholder",
          render([el("AXButton", "T", desc: "D", placeholder: "P")]).text.contains("button \"T\"")
          && render([el("AXButton", "", desc: "D", placeholder: "P")]).text.contains("button \"D\"")
          && render([el("AXTextField", "", placeholder: "P")]).text.contains("text field \"P\""))
    check("names: the label the application links is used", render([el("AXTextField", label: "Email")]).text.contains("text field \"Email\""))
    check("names: a label above a field names it", render([
        el("AXStaticText", value: "Email", frame: CGRect(x: 10, y: 10, width: 80, height: 16)),
        el("AXTextField", frame: CGRect(x: 10, y: 30, width: 200, height: 22)),
    ]).text.contains("text field \"Email\""))
    check("names: the label's colon is dropped", render([el("AXStaticText", value: "City:"), el("AXTextField")]).text.contains("text field \"City\""))
    check("names: without frames the text right before the field names it", render([el("AXStaticText", value: "Zip"), el("AXTextField")]).text.contains("text field \"Zip\""))
    let farLabel = render([
        el("AXStaticText", value: "Far", frame: CGRect(x: 400, y: 300, width: 40, height: 16)),
        el("AXTextField", frame: CGRect(x: 10, y: 30, width: 200, height: 22)),
    ])
    check("names: a label that is not beside the field does not name it", lines(farLabel).contains("[e1] text field"))
    check("names: a control with no name is shown with its kind only", render([el("AXButton")]).text.contains("[e1] button") && !render([el("AXButton")]).text.contains("[e1] button \""))
    check("names: quotes in a name do not break the line", render([el("AXButton", "Say \"hi\"")]).text.contains("[e1] button \"Say 'hi'\""))
    check("names: a long name is cut", render([el("AXButton", String(repeating: "n", count: 200))]).text.contains(String(repeating: "n", count: 79) + "…\""))
    check("names: a pop-up with no description of its own takes the label beside it", render([
        el("AXStaticText", value: "Role"), el("AXPopUpButton", "Viewer", value: "Viewer"),
    ]).text.contains("pop-up \"Role\" = \"Viewer\""))
    check("names: a switch is named like a checkbox", render([el("AXCheckBox", "Wi-Fi", sub: "AXSwitch", value: "checked")]).text.contains("switch \"Wi-Fi\" (checked)"))
    check("names: a tab in a tab group is a tab", render([el("AXTabGroup", "", [el("AXRadioButton", "General", selected: true), el("AXRadioButton", "Advanced")])]).text
          .contains("[e1] tab \"General\" (selected)"))
}

do {
    let rows = render([el("AXTable", "", [
        el("AXRow", "", [el("AXCell", "", [el("AXStaticText", value: "Alice"), el("AXStaticText", value: "alice@example.com")])]),
        el("AXRow", "", selected: true, [el("AXCell", "", [el("AXStaticText", value: "Bob")])]),
    ])])
    check("rows: a row is named by the text inside it and that text is not shown twice",
          rows.text.contains("[e1] row \"Alice | alice@example.com\"") && countOf(rows.text, "alice@example.com") == 1 && rows.text.contains("[e2] row \"Bob\" (selected)"))
    check("rows: a table is shown as the frame of its rows", rows.text.contains("table\n  [e1] row"))
    let pressable = render([el("AXGroup", "", press: true, [el("AXStaticText", value: "Open settings")]), el("AXGroup", "", [el("AXStaticText", value: "Plain")])])
    check("rows: a group with a press action is something to click, a plain one is not",
          pressable.text.contains("[e1] group \"Open settings\"") && pressable.text.contains("text \"Plain\"") && !pressable.text.contains("[e2]"))
    check("rows: a disabled control and a focused one say so",
          render([el("AXButton", "Off", enabled: false)]).text.contains("[e1] button \"Off\" (disabled)")
          && render([el("AXTextField", desc: "Q", focused: true)]).text.contains("(focused)"))
    check("rows: a named container is shown above what it holds", render([el("AXGroup", "Settings", [el("AXButton", "Save")])]).text.contains("group \"Settings\"\n  [e1] button \"Save\""))
    check("rows: an unnamed container adds no line", !render([el("AXGroup", "", [el("AXButton", "Save")])]).text.contains("group"))
    check("rows: an empty window says so", render([]).text.contains("(the window shows no readable elements)"))
    check("rows: a long text is cut", render([el("AXStaticText", value: String(repeating: "w", count: 500))]).text.contains(String(repeating: "w", count: 159) + "…\""))
}

// MARK: - Limits

do {
    let buttons = (0..<450).map { el("AXButton", "Button \($0)") }
    let texts = (0..<200).map { el("AXStaticText", value: "Paragraph \($0)") }
    let many = render(buttons + texts)
    check("limits: at most 400 elements are shown", referenceCount(many.text) == 400 && many.refs.count == 400)
    check("limits: controls come before text", many.text.contains("button \"Button 399\"") && !many.text.contains("button \"Button 400\"") && !many.text.contains("text \"Paragraph"))
    check("limits: the end says how many were left out", lines(many).last == "[… 250 more elements]")

    let fewButtons = (0..<100).map { el("AXButton", "B\($0)") }
    let longAndShort = (0..<300).map { el("AXStaticText", value: "Short \($0)") } + (0..<300).map { el("AXStaticText", value: String(repeating: "long text ", count: 12) + "\($0)") }
    let mixed = render(fewButtons + longAndShort)
    check("limits: with room left, short text is kept and the long paragraphs go first",
          referenceCount(mixed.text) == 100 && countOf(mixed.text, "Short ") == 300 && countOf(mixed.text, "long text") == 0 && lines(mixed).last == "[… 300 more elements]")

    // Nesting: an element at depth 14 is shown, one at depth 15 is left out and counted.
    func nested(_ depth: Int, leaf: QANativeElement) -> QANativeElement {
        var inner = leaf
        for level in stride(from: depth - 1, through: 1, by: -1) { inner = el("AXGroup", "Level \(level)", [inner]) }
        return inner
    }
    let atLimit = render([nested(14, leaf: el("AXButton", "Deep"))])
    let beyond = render([nested(15, leaf: el("AXButton", "Deeper"))])
    check("limits: depth 14 is shown", atLimit.text.contains("button \"Deep\"") && !atLimit.text.contains("more elements"))
    check("limits: depth 15 is left out and counted", !beyond.text.contains("Deeper") && lines(beyond).last == "[… 1 more elements]")
    check("limits: what the reader could not read is counted too", lines(render([el("AXButton", "A")], omitted: 7)).last == "[… 7 more elements]")

    let menus = (0..<130).map { QANativeMenuEntry(id: 1000 + $0, path: ["Menu", "Item \($0)"]) }
    let big = render([el("AXButton", "A")], menus: menus)
    check("limits: 120 menu entries are shown, the rest are counted", countOf(big.text, "] Menu > Item") == 120 && lines(big).last == "[… 10 more menu entries]" && big.refs.count == 121)
}

// MARK: - Keys

do {
    check("keys: cmd+shift+n", QANativeKeys.parse("cmd+shift+n") == QANativeKey(code: 45, modifiers: [.command, .shift]))
    check("keys: names and case are free", QANativeKeys.parse("Cmd+Shift+N") == QANativeKeys.parse("command+SHIFT+n") && QANativeKeys.parse("Cmd+Shift+N") != nil)
    check("keys: Enter, Escape, Tab, Down, a", QANativeKeys.parse("Enter") == QANativeKey(code: 36, modifiers: []) && QANativeKeys.parse("Escape") == QANativeKey(code: 53, modifiers: [])
          && QANativeKeys.parse("Tab") == QANativeKey(code: 48, modifiers: []) && QANativeKeys.parse("Down") == QANativeKey(code: 125, modifiers: [])
          && QANativeKeys.parse("a") == QANativeKey(code: 0, modifiers: []))
    check("keys: aliases", QANativeKeys.parse("Return")?.code == 36 && QANativeKeys.parse("esc")?.code == 53 && QANativeKeys.parse("ArrowUp")?.code == 126 && QANativeKeys.parse("backspace")?.code == 51
          && QANativeKeys.parse("space")?.code == 49 && QANativeKeys.parse("F5")?.code == 96 && QANativeKeys.parse("pagedown")?.code == 121)
    check("keys: option and control", QANativeKeys.parse("alt+left") == QANativeKey(code: 123, modifiers: [.option]) && QANativeKeys.parse("ctrl+opt+1") == QANativeKey(code: 18, modifiers: [.control, .option]))
    check("keys: a capital letter is not a shift", QANativeKeys.parse("A") == QANativeKey(code: 0, modifiers: []) && QANativeKeys.parse("Cmd+N") == QANativeKey(code: 45, modifiers: [.command]))
    check("keys: plus is shift and the key of =", QANativeKeys.parse("cmd++") == QANativeKey(code: 24, modifiers: [.command, .shift]) && QANativeKeys.parse("plus") == QANativeKey(code: 24, modifiers: [.shift])
          && QANativeKeys.parse("cmd+-") == QANativeKey(code: 27, modifiers: [.command]) && QANativeKeys.parse("cmd+,") == QANativeKey(code: 43, modifiers: [.command]))
    check("keys: what is not a key is refused", ["", "  ", "cmd+", "+a", "hyper+a", "cmd+nokey", "ab", "cmd+shift", "enter+a"].allSatisfy { QANativeKeys.parse($0) == nil })
    check("keys: the modifier bits are those of the Quartz event flags",
          QANativeKey.Modifiers.command.rawValue == CGEventFlags.maskCommand.rawValue && QANativeKey.Modifiers.shift.rawValue == CGEventFlags.maskShift.rawValue
          && QANativeKey.Modifiers.option.rawValue == CGEventFlags.maskAlternate.rawValue && QANativeKey.Modifiers.control.rawValue == CGEventFlags.maskControl.rawValue)
    check("keys: every key code is used once for one character", Set(QANativeKeys.keyCodes.filter { $0.key.count == 1 }.values).count == QANativeKeys.keyCodes.filter { $0.key.count == 1 }.count)
}

// MARK: - Evidence

do {
    let window = CGRect(x: 100, y: 100, width: 400, height: 300)
    let tree = [
        el("AXButton", "x", frame: CGRect(x: 110, y: 120, width: 16, height: 16)),
        el("AXButton", "OK", frame: CGRect(x: 110, y: 150, width: 90, height: 22)),
        el("AXCheckBox", "Opt", frame: CGRect(x: 110, y: 180, width: 14, height: 14)),
        el("AXButton", "off", frame: CGRect(x: 110, y: 200, width: 10, height: 10), enabled: false),
        el("AXButton", sub: "AXCloseButton", frame: CGRect(x: 108, y: 108, width: 14, height: 16)),
        el("AXButton", "", frame: CGRect(x: 200, y: 200, width: 60, height: 30)),
        el("AXGroup", "", frame: CGRect(x: 300, y: 250, width: 240, height: 30), [el("AXButton", "In", frame: CGRect(x: 480, y: 250, width: 60, height: 30))]),
        el("AXScrollArea", frame: CGRect(x: 110, y: 300, width: 380, height: 80), [el("AXButton", "Far", frame: CGRect(x: 700, y: 300, width: 60, height: 30))]),
        el("AXStaticText", value: "label", frame: CGRect(x: 110, y: 100, width: 5, height: 5)),
    ]
    let evidence = QANativeEvidence.make(from: tree, windowFrame: window)
    check("evidence: controls under 24x24 pt are small targets, an ordinary button is not", evidence.smallTargets.count == 2
          && evidence.smallTargets.samples.contains { $0.hasPrefix("button \"x\" 16x16pt @10,20") } && evidence.smallTargets.samples.contains { $0.hasPrefix("checkbox \"Opt\" 14x14pt") })
    check("evidence: a disabled control and the window's own buttons are not counted", !evidence.smallTargets.samples.contains { $0.contains("off") || $0.contains("Close") })
    check("evidence: a control with no name is unlabeled", evidence.unlabeledControls.count == 1 && evidence.unlabeledControls.samples == ["button @100,100"])
    check("evidence: the outermost element past the right edge is counted once, what scrolls is not", evidence.beyondRightEdge.count == 1
          && evidence.beyondRightEdge.samples.first?.hasPrefix("group @200,150") == true && evidence.beyondRightEdge.samples.first?.hasSuffix("right edge at 440pt") == true)
    check("evidence: the reach past the edge is told as the width over", evidence.horizontalScrollPixels == 40 && evidence.summary.contains("elements past the right edge: 1"))
    check("evidence: what cannot be measured stays empty", evidence.smallText.count == 0 && evidence.lowContrast.count == 0 && evidence.clipped.count == 0 && evidence.skippedHeadings.count == 0
          && evidence.loadMilliseconds == nil)
    let clean = QANativeEvidence.make(from: demoWindow(), windowFrame: CGRect(x: 0, y: 0, width: 360, height: 292))
    check("evidence: the fixture window is clean", clean.isClean)
    check("evidence: samples are limited", QANativeEvidence.make(from: (0..<20).map { el("AXButton", "b\($0)", frame: CGRect(x: 0, y: 0, width: 10, height: 10)) }, windowFrame: window).smallTargets.samples.count == QAPageEvidence.maxSamples)
}

// MARK: - Permissions, addresses

do {
    typealias Permissions = QANativePermissions
    check("permissions: all four combinations", Permissions.status(accessibility: true, screenRecording: true) == .granted
          && Permissions.status(accessibility: false, screenRecording: true) == .accessibilityMissing
          && Permissions.status(accessibility: true, screenRecording: false) == .screenRecordingMissing && Permissions.status(accessibility: false, screenRecording: false) == .both)
    check("permissions: what is missing", Permissions.Status.both.missing == [.accessibility, .screenRecording] && Permissions.Status.granted.missing.isEmpty
          && Permissions.Status.screenRecordingMissing.missing == [.screenRecording])
    func name(_ error: QANativeError?) -> String {
        switch error { case .accessibilityNotGranted?: return "accessibility"; case .screenRecordingNotGranted?: return "screen"; case nil: return "none"; default: return "other" }
    }
    check("permissions: a missing permission is the error that stops the launch", name(Permissions.Status.granted.error) == "none" && name(Permissions.Status.accessibilityMissing.error) == "accessibility"
          && name(Permissions.Status.screenRecordingMissing.error) == "screen" && name(Permissions.Status.both.error) == "accessibility")
    check("permissions: the errors say where to allow it", (QANativeError.accessibilityNotGranted.errorDescription ?? "").contains("Accessibility")
          && (QANativeError.screenRecordingNotGranted.errorDescription ?? "").contains("Screen"))
    check("permissions: the deep links open the privacy pages", Permissions.systemSettingsURL(for: .accessibility).absoluteString.hasSuffix("Privacy_Accessibility")
          && Permissions.systemSettingsURL(for: .screenRecording).absoluteString.hasSuffix("Privacy_ScreenCapture"))
    check("address: the bundle identifier is read from the address", QANativeActor.bundleIdentifier(from: "com.example.App") == "com.example.App"
          && QANativeActor.bundleIdentifier(from: " app://com.example.App/Untitled%20window ") == "com.example.App" && QANativeActor.bundleIdentifier(from: "app://com.example.App") == "com.example.App")
}

// MARK: - Live: the fixture application, driven by a real player

/// The reference of the first line that holds `part`.
func ref(_ observation: QAObservation?, _ part: String) -> String? {
    guard let line = observation?.snapshot.components(separatedBy: "\n").first(where: { $0.contains(part) }),
          let open = line.range(of: "[e"), let close = line.range(of: "]", range: open.upperBound..<line.endIndex) else { return nil }
    return String(line[line.index(after: open.lowerBound)..<close.lowerBound])
}

@MainActor
func live(fixture: URL) async {
    let started = Date()
    guard QANativePermissions.current == .granted else {
        print("skip live: this process has no \(QANativePermissions.current.missing.map { $0 == .accessibility ? "Accessibility" : "Screen Recording" }.joined(separator: " and ")) permission")
        return
    }
    let identifier = "com.markview.qa-native-demo"
    func request(_ address: String) -> QADriverRequest { QADriverRequest(actor: nil, app: QAApp(id: "demo", name: "Demo"), address: address, login: nil) }
    let password = "secret"   // the fixture's own default: a made-up one, and never the Keychain
    let credentials = QACredentials(username: "Tester", password: password)

    // A launch that cannot happen is an error, and nothing is started.
    let missing = QANativeActor(request: request("com.markview.qa-native-demo.missing"), credentials: credentials, config: .init(bringToFront: false))
    var notInstalled = false
    do { try await missing.open("com.markview.qa-native-demo.missing") } catch QANativeError.notInstalled { notInstalled = true } catch {}
    check("live: an application that is not installed is an error", notInstalled)
    check("live: nothing was launched for it", NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty)

    let player = QANativeActor(request: request(identifier), credentials: credentials, config: .init(bringToFront: false, launchTimeout: 15))
    do {
        let opening = Date()
        try await player.open(identifier)
        check("live: the application is launched and shows its window (\(String(format: "%.1f", Date().timeIntervalSince(opening))) s)", true)
    } catch {
        check("live: the application is launched (\(error.localizedDescription))", false)
        await player.close()
        return
    }
    let processes = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    check("live: one instance of its own is running", processes.count == 1)
    guard let launched = processes.first else { await player.close(); return }

    func look() async -> QAObservation? { try? await player.observe() }
    func act(_ action: QAAction) async -> String? { try? await player.perform(action) }
    func has(_ observation: QAObservation?, _ part: String) -> Bool { observation?.snapshot.contains(part) == true }

    guard let first = await look() else { check("live: the window can be read", false); await player.close(); return }
    check("live: the window is read", first.title == "QA Native Demo" && first.address == "app://\(identifier)/QA%20Native%20Demo")
    check("live: the form is shown with names and values", has(first, "text field \"Name\"") && has(first, "(secure field, value hidden)") && has(first, "pop-up \"Role\" = \"Viewer\"")
          && has(first, "checkbox \"Remember me\" (unchecked)") && has(first, "button \"Sign in\"") && has(first, "text \"Not signed in\"") && has(first, "text area \"Notes\""))
    check("live: the menu bar is listed, the Apple menu is not", has(first, "] File > Reset") && has(first, "] Edit > Select All") && !has(first, "Apple >") && !has(first, "Recent Items"))
    check("live: the system's window buttons are named", has(first, "button \"Close\"") && has(first, "button \"Zoom\""))

    guard let nameRef = ref(first, "text field \"Name\""), let passwordRef = ref(first, "text field \"Password\""), let signInRef = ref(first, "button \"Sign in\"") else {
        check("live: the references of the form were found", false)
        await player.close()
        return
    }
    let clickMark = await player.inputMark(for: QAAction(kind: .click, ref: signInRef))
    let fieldMark = await player.inputMark(for: QAAction(kind: .fill, ref: nameRef, text: "{{password}}"))
    check("live: input markers locate the native control and field", clickMark.target != nil && fieldMark.target != nil && clickMark.target != fieldMark.target)
    check("live: marker labels do not repeat typed values", fieldMark.label == "Type text")
    // A wrong password first, typed as plain text; then the real one through the placeholder.
    let filled = await act(QAAction(kind: .fill, ref: nameRef, text: "{{username}}"))
    check("live: a text field is filled with the player's user name", filled?.hasPrefix("Typed into text field \"Name\"") == true)
    _ = await act(QAAction(kind: .fill, ref: passwordRef, text: "not-the-password"))
    _ = await act(QAAction(kind: .click, ref: signInRef))
    let wrong = await look()
    check("live: a wrong password is refused by the application", has(wrong, "text \"Wrong password\"") && has(wrong, "text field \"Name\" = \"Tester\""))
    let typed = await act(QAAction(kind: .fill, ref: passwordRef, text: "{{password}}"))
    let pressed = await act(QAAction(kind: .click, ref: signInRef))
    let signedIn = await look()
    check("live: the password placeholder is filled by the player and signs in", has(signedIn, "text \"Signed in as Tester\"") && has(signedIn, "(secure field, value hidden)"))
    check("live: what the player answers never repeats the password", [filled, typed, pressed].allSatisfy { $0 != nil && !$0!.contains(password) } && typed?.contains("Typed into") == true && pressed?.hasPrefix("Pressed button") == true)
    check("live: no look shows the password", !(signedIn?.snapshot.contains(password) ?? true) && signedIn?.address.contains(password) == false)

    // A key reaches the application: cmd+r is File > Reset, so the form is cleared.
    let keyed = await act(QAAction(kind: .key, text: "cmd+r"))
    let afterKey = await look()
    check("live: a key shortcut is pressed in the application", keyed == "Pressed cmd+r" && has(afterKey, "text \"Not signed in\"") && has(afterKey, "text field \"Name\"") && !has(afterKey, "= \"Tester\""))

    // The password never gets to the assistant, even when the page shows it.
    if let again = ref(afterKey, "text field \"Name\"") {
        _ = await act(QAAction(kind: .fill, ref: again, text: "{{password}}"))
        let shown = await look()
        check("live: a password that the page shows is scrubbed from the look", has(shown, "text field \"Name\" = \"" + QACredentials.mask + "\"") && !has(shown, password))
    }

    // A pop-up and a checkbox.
    let current = (await look()) ?? first
    if let roleRef = ref(current, "pop-up \"Role\""), let rememberRef = ref(current, "checkbox \"Remember me\"") {
        let chose = await act(QAAction(kind: .select, ref: roleRef, text: "editor"))
        let editor = await look()
        check("live: a pop-up item is chosen by its title, ignoring case", chose?.hasPrefix("Chose Editor") == true && has(editor, "pop-up \"Role\" = \"Editor\""))
        _ = await act(QAAction(kind: .select, ref: ref(editor, "pop-up \"Role\"") ?? roleRef, text: "dmi"))
        check("live: a part of the title will do", has(await look(), "pop-up \"Role\" = \"Admin\""))
        var refused = ""
        do { _ = try await player.perform(QAAction(kind: .select, ref: ref(await look(), "pop-up \"Role\"") ?? roleRef, text: "Owner")) } catch { refused = error.localizedDescription }
        check("live: a choice that does not exist lists the choices", refused.contains("The choices are: Viewer, Editor, Admin"))
        _ = await act(QAAction(kind: .click, ref: ref(await look(), "checkbox \"Remember me\"") ?? rememberRef))
        check("live: a checkbox is pressed", has(await look(), "checkbox \"Remember me\" (checked)"))
    } else {
        check("live: the pop-up and the checkbox were found", false)
    }

    // The menu entry.
    if let resetRef = ref((await look()) ?? first, "] File > Reset") {
        let reset = await act(QAAction(kind: .click, ref: resetRef))
        let afterMenu = await look()
        check("live: a menu entry is pressed", reset?.hasPrefix("Pressed menu item \"File > Reset\"") == true && has(afterMenu, "text \"Not signed in\"") && has(afterMenu, "pop-up \"Role\" = \"Viewer\"")
              && has(afterMenu, "checkbox \"Remember me\" (unchecked)"))
    } else {
        check("live: the menu entry was found", false)
    }

    // The picture, the measures and scrolling.
    let before = await player.screenshot()
    var size = (0, 0)
    if let before, let source = CGImageSourceCreateWithData(before as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { size = (image.width, image.height) }
    check("live: a picture of the window is a PNG of plausible size", before != nil && before!.starts(with: [0x89, 0x50, 0x4E, 0x47]) && (300...800).contains(size.0) && (240...700).contains(size.1) && before!.count > 2000)
    let evidence = await player.measure()
    check("live: the window is measured and clean", evidence != nil && evidence!.isClean)
    let down = await act(QAAction(kind: .scroll, direction: "down"))
    try? await Task.sleep(nanoseconds: 700_000_000)
    let scrolled = await player.screenshot()
    check("live: the notes scroll down and the picture shows it", down?.hasPrefix("Scrolled down") == true && scrolled != nil && scrolled != before)
    let up = await act(QAAction(kind: .scroll, direction: "up"))
    check("live: and up", up?.hasPrefix("Scrolled up") == true)
    let top = await act(QAAction(kind: .scroll, direction: "up"))
    check("live: at the top it says so", top == "The view is already at the top.")

    // What a native application cannot do.
    var refusals: [String] = []
    for action in [QAAction(kind: .navigate, url: "https://example.com"), QAAction(kind: .http, url: "/x", method: "GET")] {
        do { _ = try await player.perform(action) } catch { refusals.append(error.localizedDescription) }
    }
    check("live: navigate and http are not available", refusals.count == 2 && refusals.allSatisfy { $0.hasSuffix("is not available for a native application.") })
    var armed = true
    do { try await player.arm(QAFault(urlPattern: "/x", mode: .fail)) } catch { armed = false }
    let hits = await player.faultHits()
    check("live: a network fault cannot be armed, and none is ever met", !armed && hits == 0)
    var unknown = ""
    do { _ = try await player.perform(QAAction(kind: .click, ref: "e9999")) } catch { unknown = error.localizedDescription }
    check("live: a reference that is not on the screen is an error", unknown.contains("not an element"))
    var notAKey = ""
    do { _ = try await player.perform(QAAction(kind: .key, text: "cmd+nokey")) } catch { notAKey = error.localizedDescription }
    check("live: a key that does not exist is an error", notAKey.contains("is not a key"))
    let waited = await act(QAAction(kind: .wait, amount: 50))
    check("live: waiting waits", waited == "Waited 50 ms")

    // The player never took the focus, and closing ends exactly its own process.
    check("live: the application was never brought to the front", !launched.isActive)
    await player.close()
    var gone = false
    for _ in 0..<40 where !gone { gone = launched.isTerminated; if !gone { try? await Task.sleep(nanoseconds: 100_000_000) } }
    check("live: closing ends the process", gone && NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty)
    var afterClose = ""
    do { _ = try await player.observe() } catch { afterClose = error.localizedDescription }
    let pictureAfterClose = await player.screenshot()
    check("live: a closed player answers that it is not open, and has no picture", afterClose == QANativeError.notOpen.errorDescription && pictureAfterClose == nil)
    await player.close()
    check("live: closing twice is harmless", true)
    print(String(format: "live part took %.1f s", Date().timeIntervalSince(started)))
}

/// Two players of one scenario use the same application (DEC-012): each gets an instance of its own, with a state of its own, and they act in
/// turns; closing one leaves the other running.
@MainActor
func liveTwoPlayers() async {
    let identifier = "com.markview.qa-native-demo"
    let request = QADriverRequest(actor: nil, app: QAApp(id: "demo", name: "Demo"), address: identifier, login: nil)
    let ann = QANativeActor(request: request, credentials: QACredentials(username: "Ann", password: "secret"), config: .init(bringToFront: false, launchTimeout: 15))
    let bob = QANativeActor(request: request, credentials: QACredentials(username: "Bob", password: "secret"), config: .init(bringToFront: false, launchTimeout: 15))
    func signIn(_ player: QANativeActor) async -> QAObservation? {
        guard let first = try? await player.observe(), let name = ref(first, "text field \"Name\""), let password = ref(first, "text field \"Password\""),
              let button = ref(first, "button \"Sign in\"") else { return nil }
        _ = try? await player.perform(QAAction(kind: .fill, ref: name, text: "{{username}}"))
        _ = try? await player.perform(QAAction(kind: .fill, ref: password, text: "{{password}}"))
        _ = try? await player.perform(QAAction(kind: .click, ref: button))
        return try? await player.observe()
    }
    do {
        try await ann.open(identifier)
        try await bob.open(identifier)
    } catch {
        check("live two players: both are launched (\(error.localizedDescription))", false)
        await ann.close()
        await bob.close()
        return
    }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    check("live two players: two instances of the same application run, one per player", running.count == 2 && Set(running.map(\.processIdentifier)).count == 2)
    let annSignedIn = await signIn(ann)
    check("live two players: the first player signs in", annSignedIn?.snapshot.contains("text \"Signed in as Ann\"") == true)
    let bobBefore = try? await bob.observe()
    check("live two players: the second player's instance is untouched by it", bobBefore?.snapshot.contains("text \"Not signed in\"") == true)
    let bobSignedIn = await signIn(bob)
    check("live two players: the second player signs in as someone else", bobSignedIn?.snapshot.contains("text \"Signed in as Bob\"") == true)
    let annAfter = try? await ann.observe()
    check("live two players: the first player's instance still says its own name", annAfter?.snapshot.contains("text \"Signed in as Ann\"") == true && annAfter?.snapshot.contains("Bob") == false)
    await ann.close()
    var remaining = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    for _ in 0..<40 where remaining.count != 1 { try? await Task.sleep(nanoseconds: 100_000_000); remaining = NSRunningApplication.runningApplications(withBundleIdentifier: identifier) }
    check("live two players: closing one player ends only its instance", remaining.count == 1)
    let bobKept = try? await bob.observe()
    check("live two players: the other player carries on", bobKept?.snapshot.contains("text \"Signed in as Bob\"") == true)
    await bob.close()
    var none = false
    for _ in 0..<40 where !none { none = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty; if !none { try? await Task.sleep(nanoseconds: 100_000_000) } }
    check("live two players: nothing is left running", none)
}

/// A user-owned single-instance application remains alive after a QA player attaches and closes.
@MainActor
func liveAttached(fixture: URL, identifier: String, singleInstance: Bool) async {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    let userApp: NSRunningApplication
    do { userApp = try await NSWorkspace.shared.openApplication(at: fixture, configuration: config) }
    catch { check("attached: start fixture (\(error.localizedDescription))", false); return }
    let request = QADriverRequest(actor: nil, app: QAApp(id: "demo", name: "Demo"), address: identifier, login: nil)
    let player = QANativeActor(request: request, credentials: QACredentials(username: nil, password: nil), config: .init(bringToFront: false, launchTimeout: 15))
    do {
        try await player.open(identifier)
        let observed = try await player.observe()
        check("attached: reads the already-running application's window", observed.title == "QA Native Demo")
        if singleInstance {
            let second = QANativeActor(request: request, credentials: QACredentials(username: nil, password: nil), config: .init(bringToFront: false))
            var rejected = false
            do { try await second.open(identifier) } catch { rejected = error.localizedDescription.contains("another QA player") }
            await second.close()
            check("attached: another player cannot share the same process", rejected && !userApp.isTerminated)
        }
        await player.close()
        check("attached: closing QA leaves the user's process running", !userApp.isTerminated)
        await player.close()
        check("attached: closing twice leaves the user's process running", !userApp.isTerminated)
    } catch { check("attached: player connects (\(error.localizedDescription))", false); await player.close() }
    userApp.terminate()
    for _ in 0..<40 where !userApp.isTerminated { try? await Task.sleep(nanoseconds: 100_000_000) }
    if !userApp.isTerminated { userApp.forceTerminate() }
}

if CommandLine.arguments.count > 1, !CommandLine.arguments[1].isEmpty {
    await live(fixture: URL(fileURLWithPath: CommandLine.arguments[1]))
    if QANativePermissions.current == .granted {
        await liveTwoPlayers()
        await liveAttached(fixture: URL(fileURLWithPath: CommandLine.arguments[1]), identifier: "com.markview.qa-native-demo", singleInstance: false)
        if CommandLine.arguments.count > 2, !CommandLine.arguments[2].isEmpty {
            await liveAttached(fixture: URL(fileURLWithPath: CommandLine.arguments[2]), identifier: "com.markview.qa-native-single", singleInstance: true)
        }
    }
} else {
    print("skip live: no fixture application given")
}

finish("QA native")
