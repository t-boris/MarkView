import AppKit
import CoreGraphics
import Foundation
import ImageIO
#if canImport(MarkView)
@testable import MarkView
#endif

/// The native QA behavior shared by the isolated app host and the optional fixture driver.
@MainActor
func runQANativeBehaviorChecks(check: (String, Bool) -> Void) {
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
              rows.text.contains("row \"Alice | alice@example.com\"") && countOf(rows.text, "alice@example.com") == 1 && rows.text.contains("row \"Bob\" (selected)"))
        check("rows: a table is shown as the frame of its rows", rows.text.contains("table (inspectable") && rows.refs.values.contains { $0.kind == "table" })
        let pressable = render([el("AXGroup", "", press: true, [el("AXStaticText", value: "Open settings")]), el("AXGroup", "", [el("AXStaticText", value: "Plain")])])
        check("rows: pressable groups remain clickable and captioned groups become inspectable",
              pressable.text.contains("[e1] group \"Open settings\"") && pressable.text.contains("text \"Plain\"")
              && pressable.text.contains("(inspectable"))
        check("rows: a disabled control and a focused one say so",
              render([el("AXButton", "Off", enabled: false)]).text.contains("[e1] button \"Off\" (disabled)")
              && render([el("AXTextField", desc: "Q", focused: true)]).text.contains("(focused)"))
        check("rows: a named container is shown above what it holds", render([el("AXGroup", "Settings", [el("AXButton", "Save")])]).text.contains("group \"Settings\" (inspectable")
              && render([el("AXGroup", "Settings", [el("AXButton", "Save")])]).text.contains("button \"Save\""))
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

    // REQ-018: layout depth is not semantic depth; scoped text/cell refs use actual AX geometry.
    do {
        var deep = el("AXButton", "Late panel action")
        for _ in 0..<35 { deep = el("AXGroup", "", [deep]) }
        check("dense: unnamed physical wrappers do not hide a real control", render([deep]).text.contains("Late panel action"))
        let partial = QANativeElement(id: 991, role: "AXTable", title: "Chain", childCount: 100, omittedChildren: 76)
        let snapshot = render([partial, el("AXButton", "Positions")])
        check("dense: an omitted table is inspectable and a later panel remains reachable", snapshot.refs.values.contains { $0.id == 991 }
            && snapshot.text.contains("unread children: 76") && snapshot.text.contains("Positions"))
        let scoped = QANativeSnapshot.render(app: "Demo", windowTitle: "Chain", elements: [
            el("AXStaticText", value: "ACTIVITY", frame: CGRect(x: 10, y: 20, width: 80, height: 20)),
            el("AXCell", "", frame: CGRect(x: 100, y: 20, width: 60, height: 20), [el("AXStaticText", value: "4.70")]),
            el("AXTextField", sub: "AXSecureTextField", desc: "Password", value: "never-expose"),
        ], menus: [], scoped: true)
        check("dense: inspected text and prices have pointer refs from geometry", scoped.refs.values.contains { $0.summary == "text \"ACTIVITY\"" }
            && scoped.refs.values.contains { $0.summary == "cell \"4.70\"" })
        let tabGroup = el("AXGroup", "ACTIVITY", [el("AXStaticText", value: "ACTIVITY", frame: CGRect(x: 10, y: 20, width: 80, height: 20))])
        let tabOverview = render([tabGroup])
        let tabScoped = QANativeSnapshot.render(app: "Demo", windowTitle: "Activity", elements: [tabGroup], menus: [], scoped: true)
        check("native group tab: the overview exposes an inspection route and its scoped label has a pointer ref",
              tabOverview.refs.values.contains { $0.summary == "group \"ACTIVITY\"" }
              && tabScoped.refs.values.contains { $0.summary == "text \"ACTIVITY\"" })
        check("dense: inspected secure values stay hidden", !scoped.text.contains("never-expose"))
        let denseTable = QANativeElement(id: 70001, role: "AXTable", title: "Long chain", children: (0..<350).map { el("AXStaticText", value: String(repeating: "quote ", count: 20) + String($0)) }, childCount: 350)
        let later = QANativeElement(id: 70002, role: "AXTable", title: "Positions", childCount: 1)
        let indexed = render([denseTable, later])
        check("dense: a later panel's inspection ref precedes the long body", String(indexed.text.prefix(2000)).contains("Positions"))
    }

    // MARK: - Keys

    // REQ-018: one current prompt must retain facts from panels on both sides of a dense table.
    do {
        let chain = el("AXTable", "Option chain", (0..<24).map { row in
            el("AXRow", "", (0..<8).map { column in
                el("AXButton", "Contract \(row), quote column \(column), bid / ask / quantity")
            })
        })
        var pagedChain = chain
        pagedChain.childCount = 100
        pagedChain.omittedChildren = 76
        let accountRows = (0..<18).map { column in
            el("AXColumn", "", (0..<6).map { row in
                el("AXCell", "Account metric column \(column), row \(row), current balance", press: true)
            })
        }
        let controls = [
            el("AXComboBox", desc: "Underlying", value: "SPX"),
            el("AXPopUpButton", "Status: Connected PAPER"),
            el("AXGroup", "Accounts overview", [el("AXTable", "Accounts", [el("AXRow", "Individual PAPER")]+accountRows)]),
            el("AXPopUpButton", desc: "Visible strikes", value: "96"),
            pagedChain,
            el("AXGroup", "POSITIONS", [el("AXImage")]),
            el("AXGroup", "Positions", [
                el("AXCheckBox", "Active accounts only", value: "checked"),
                el("AXTable", "Holdings", [el("AXRow", "", [
                    el("AXButton", "SPX 0 strategies 0 legs 1 working"),
                    el("AXButton", "Legs of working order 100203"),
                ])]),
            ]),
            el("AXTextField", sub: "AXSecureTextField", desc: "Password", value: "no-overview-secret"),
        ]
        let snapshot = render(controls)
        let prefix = String(snapshot.text.prefix(QAStepPrompt.maxSnapshot))
        check("prompt boundary: current account and late holding state coexist", prefix.contains("Individual PAPER") && prefix.contains("Active accounts only")
              && prefix.contains("0 strategies 0 legs 1 working") && prefix.contains("working order 100203"))
        check("prompt boundary: current connection and chain controls coexist", prefix.contains("Status: Connected PAPER") && prefix.contains("Visible strikes") && prefix.contains("96"))
        check("prompt boundary: account cells do not hide later panel captions", prefix.contains("POSITIONS"))
        check("prompt boundary: full and scoped inspection routes remain current", prefix.contains("Inspection regions") && snapshot.refs.values.contains { $0.id == pagedChain.id })
        check("prompt boundary: no secure value is summarized", !snapshot.text.contains("no-overview-secret"))
    }

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

}
