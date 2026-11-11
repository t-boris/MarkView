import ApplicationServices
import CoreGraphics
import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-008, DEC-012, DEC-023): the thin layer over the Accessibility API that lets the native player see
// and operate one application by process id. It reads the focused window and the menu bar into `QANativeElement`s (never the value of a secure
// field), keeps the live element behind every reference of the current look, and acts on it: press, type, choose, scroll, press a key. Every
// call runs on a serial queue of its own, never on the caller's thread, and every call to the application has a timeout, so an application that
// hangs costs a look a few seconds and never hangs MarkView. Only the pure model (`QANativeTree.swift`) is checked on its own; this layer is
// checked against a real application by the live part of tools/tests/qa-native-tests.sh.

final class QANativeAccessibility: @unchecked Sendable {
    /// What one look at the application read.
    struct Reading {
        var windowTitle: String
        var windowFrame: CGRect?
        var elements: [QANativeElement]
        var menus: [QANativeMenuEntry]
        /// Elements that were not read: past the depth, the count or the time allowed.
        var omitted: Int
    }

    /// An application that does not answer within this many seconds (per call) is given up on.
    static let messagingTimeout: Float = 2
    /// A whole look takes at most this long.
    static let readBudget: TimeInterval = 8
    static let maxElementsRead = 1500
    static let maxMenuEntriesRead = 300
    static let maxMenuDepth = 3
    /// More text than this in a text area is not fetched: it is a document, not a value.
    static let longestValueRead = 20_000

    private let pid: pid_t
    private let application: AXUIElement
    private let queue = DispatchQueue(label: "markview.qa-native.accessibility", qos: .userInitiated)
    /// The live element behind each element or menu entry of the last look, and what each reference of that look stands for.
    private var handles: [Int: AXUIElement] = [:]
    private var targets: [String: QANativeSnapshot.Target] = [:]

    init(pid: pid_t) {
        self.pid = pid
        application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
    }

    // MARK: Running on the queue

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: The application as a whole

    /// Asks applications that keep their tree switched off until an assistive tool shows up (Electron, Chromium) to switch it on. Other
    /// applications answer that they do not know the attribute, which is fine.
    func prepare() async {
        _ = try? await run { _ = AXUIElementSetAttributeValue(self.application, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
    }

    func hasWindow() async -> Bool {
        (try? await run { !self.windows().isEmpty }) ?? false
    }

    /// Brings the application to the front, with its window on top. True when it was not in front already.
    func bringToFront() async -> Bool {
        (try? await run {
            if self.bool(self.application, "AXFrontmost") == true { return false }
            AXUIElementSetAttributeValue(self.application, "AXFrontmost" as CFString, kCFBooleanTrue)
            if let window = self.targetWindow() { AXUIElementPerformAction(window, "AXRaise" as CFString) }
            return true
        }) ?? false
    }

    // MARK: Looking

    /// Reads the window the person would be working in and the menu bar. Replaces the elements the last look's references stood for.
    func read() async throws -> Reading {
        try await run {
            guard let window = self.targetWindow() else {
                if self.windows().isEmpty, self.string(self.application, "AXRole").isEmpty {
                    throw QANativeError.failed("The application does not answer. It may be busy or have stopped.")
                }
                throw QANativeError.failed("The application has no window to look at.")
            }
            let reader = Reader(deadline: Date().addingTimeInterval(Self.readBudget))
            var elements: [QANativeElement] = []
            let title = self.string(window, "AXTitle")
            let frame = self.frame(of: window)
            for child in self.children(of: window) {
                if let element = self.read(child, depth: 1, reader) { elements.append(element) }
            }
            if reader.count == 0 && reader.failures > 0 { throw QANativeError.failed("The application does not answer. It may be busy or have stopped.") }
            let menus = self.readMenus(reader)
            self.handles = reader.handles
            self.targets = [:]
            return Reading(windowTitle: title, windowFrame: frame, elements: elements, menus: menus, omitted: reader.omitted)
        }
    }

    /// Tells which element or menu entry each reference of the text just shown stands for.
    func publish(_ refs: [String: QANativeSnapshot.Target]) async {
        _ = try? await run { self.targets = refs }
    }

    private final class Reader {
        let deadline: Date
        var count = 0
        var omitted = 0
        var failures = 0
        var nextID = 1
        var handles: [Int: AXUIElement] = [:]

        init(deadline: Date) { self.deadline = deadline }

        var exhausted: Bool { count >= QANativeAccessibility.maxElementsRead || Date() >= deadline || failures >= 3 }

        func take(_ element: AXUIElement) -> Int {
            let id = nextID
            nextID += 1
            handles[id] = element
            return id
        }
    }

    private static let elementAttributes = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXPlaceholderValue", "AXEnabled", "AXFocused", "AXSelected", "AXPosition", "AXSize",
        "AXIdentifier", "AXChildren",
    ]

    private func read(_ element: AXUIElement, depth: Int, _ reader: Reader) -> QANativeElement? {
        if reader.exhausted { reader.omitted += 1; return nil }
        guard let values = self.values(element, Self.elementAttributes) else { reader.failures += 1; return nil }
        reader.failures = 0
        reader.count += 1
        var node = QANativeElement()
        node.id = reader.take(element)
        node.role = string(values[0])
        node.subrole = string(values[1])
        node.title = string(values[2])
        node.description = string(values[3])
        node.placeholder = string(values[4])
        node.enabled = bool(values[5]) ?? true
        node.focused = bool(values[6]) ?? false
        node.selected = bool(values[7]) ?? false
        node.frame = frame(position: values[8], size: values[9])
        node.identifier = string(values[10])
        let children = (values[11] as? [AXUIElement]) ?? []

        // A secure field's value is never asked for: it is not read, so it cannot get anywhere.
        let secure = node.role == "AXTextField" && node.subrole == "AXSecureTextField"
        if QANativeRoles.valued.contains(node.role), !secure { readValue(of: element, into: &node) }
        if QANativeRoles.pressProbed.contains(node.role) { node.hasPress = actionNames(of: element).contains("AXPress") }
        if node.title.isEmpty, node.description.isEmpty, node.placeholder.isEmpty { node.labelText = label(of: element, role: node.role, children: children) }

        if QANativeRoles.leaves.contains(node.role) { return node }
        if depth >= QANativeSnapshot.maxDepth { reader.omitted += children.count; return node }
        for child in children {
            if let read = self.read(child, depth: depth + 1, reader) { node.children.append(read) }
        }
        return node
    }

    private func readValue(of element: AXUIElement, into node: inout QANativeElement) {
        if node.role == "AXTextArea", let length = number(copy(element, "AXNumberOfCharacters")), length > Double(Self.longestValueRead) {
            node.value = "(\(Int(length)) characters)"
            return
        }
        let raw = copy(element, "AXValue")
        if let text = raw as? String { node.value = text; return }
        guard let value = number(raw) else { return }
        switch node.role {
        case "AXCheckBox": node.value = value == 0 ? "unchecked" : value == 2 ? "mixed" : "checked"
        case "AXRadioButton": node.selected = node.selected || value == 1
        case "AXDisclosureTriangle": node.value = value == 0 ? "collapsed" : "expanded"
        default: node.value = value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
        }
    }

    /// A name for a control that has none of its own: the element the application links as its title, or the text inside it.
    private func label(of element: AXUIElement, role: String, children: [AXUIElement]) -> String {
        if QANativeRoles.namedByNeighbour.contains(role), let linked = copy(element, "AXTitleUIElement"), CFGetTypeID(linked) == AXUIElementGetTypeID() {
            let label = unsafeBitCast(linked, to: AXUIElement.self)
            let text = string(copy(label, "AXValue"))
            return text.isEmpty ? string(copy(label, "AXTitle")) : text
        }
        guard QANativeRoles.namedByContent.contains(role) else { return "" }
        func firstText(_ elements: [AXUIElement], depth: Int) -> String {
            for child in elements.prefix(8) {
                switch string(copy(child, "AXRole")) {
                case "AXStaticText":
                    let text = string(copy(child, "AXValue"))
                    if !text.isEmpty { return text }
                case "AXGroup" where depth < 2:
                    let text = firstText(self.children(of: child), depth: depth + 1)
                    if !text.isEmpty { return text }
                default: break
                }
            }
            return ""
        }
        return firstText(children, depth: 0)
    }

    // MARK: The menu bar

    /// Every leaf item of the menus, in order, with its path. The Apple menu is left out: it is the system's, and lists the person's recent files.
    private func readMenus(_ reader: Reader) -> [QANativeMenuEntry] {
        guard let bar = copy(application, "AXMenuBar") else { return [] }
        var entries: [QANativeMenuEntry] = []
        let items = children(of: unsafeBitCast(bar, to: AXUIElement.self))
        for (index, item) in items.enumerated() {
            let title = string(copy(item, "AXTitle"))
            if title.isEmpty || (index == 0 && title == "Apple") { continue }
            readMenu(of: item, path: [title], depth: 1, into: &entries, reader)
        }
        return entries
    }

    private func readMenu(of owner: AXUIElement, path: [String], depth: Int, into entries: inout [QANativeMenuEntry], _ reader: Reader) {
        for menu in children(of: owner) where string(copy(menu, "AXRole")) == "AXMenu" {
            for item in children(of: menu) {
                if reader.exhausted || entries.count >= Self.maxMenuEntriesRead { reader.omitted += 1; continue }
                guard let values = self.values(item, ["AXTitle", "AXEnabled", "AXChildren"]) else { reader.failures += 1; continue }
                let title = string(values[0])
                if title.isEmpty { continue }   // a separator
                let hasSubmenu = !((values[2] as? [AXUIElement]) ?? []).isEmpty
                if hasSubmenu {
                    if depth < Self.maxMenuDepth, title != "Services" { readMenu(of: item, path: path + [title], depth: depth + 1, into: &entries, reader) }
                } else {
                    entries.append(QANativeMenuEntry(id: reader.take(item), path: path + [title], enabled: bool(values[1]) ?? true))
                }
            }
        }
    }

    // MARK: Acting

    /// Read geometry from the same live handles used for input, never from field values.
    func inputFrame(ref: String, kind: QAActionKind) async -> (CGRect, CGRect)? {
        try? await run {
            guard let window = self.targetWindow(), let viewport = self.frame(of: window) else { return nil }
            let element: AXUIElement?
            if kind == .scroll { element = self.mainScrollArea(in: window) }
            else if kind == .key { element = self.copy(self.application, "AXFocusedUIElement").map { unsafeBitCast($0, to: AXUIElement.self) } }
            else { element = try? self.lookup(ref).0 }
            guard let element, let frame = self.frame(of: element) else { return nil }
            return (frame, viewport)
        }
    }

    /// Presses the element; text fields and text areas get the focus instead; what answers to no press is clicked with the mouse at its centre.
    func click(_ ref: String) async throws -> String {
        try await run {
            let (element, target) = try self.lookup(ref)
            try self.requireEnabled(element, target)
            let role = self.string(self.copy(element, "AXRole"))
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role),
               AXUIElementSetAttributeValue(element, "AXFocused" as CFString, kCFBooleanTrue) == .success {
                return "Focused \(target.summary)"
            }
            let pressed = AXUIElementPerformAction(element, "AXPress" as CFString)
            if pressed == .success { return "Pressed \(target.summary)" }
            if pressed == .invalidUIElement { throw QANativeError.failed(Self.gone(target)) }
            if role == "AXRow", AXUIElementSetAttributeValue(element, "AXSelected" as CFString, kCFBooleanTrue) == .success { return "Selected \(target.summary)" }
            guard let frame = self.frame(of: element), frame.width > 0, frame.height > 0 else {
                throw QANativeError.failed("\(target.summary) does not answer to a press and has no place on the screen to click.")
            }
            self.postClick(at: CGPoint(x: frame.midX, y: frame.midY))
            return "Clicked \(target.summary)"
        }
    }

    /// Puts the text in the field: the focus first, then the value. When the field does not take the value (or shows something else after),
    /// the text is typed with key events. A secure field's value is never read back, and the answer never repeats the text.
    func fill(_ ref: String, text: String) async throws -> String {
        try await run {
            let (element, target) = try self.lookup(ref)
            try self.requireEnabled(element, target)
            guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(self.string(self.copy(element, "AXRole"))) else {
                throw QANativeError.failed("\(target.summary) is not a field that takes text.")
            }
            AXUIElementSetAttributeValue(element, "AXFocused" as CFString, kCFBooleanTrue)
            let set = AXUIElementSetAttributeValue(element, "AXValue" as CFString, text as CFString)
            if set == .invalidUIElement { throw QANativeError.failed(Self.gone(target)) }
            let shown = set == .success && (target.secure || self.string(self.copy(element, "AXValue")) == text)
            if shown { return "Typed into \(target.summary)" }
            self.postKey(QANativeKey(code: 0, modifiers: .command))   // select all, so that the typing replaces what is there
            self.postText(text)
            return "Typed into \(target.summary)"
        }
    }

    /// Chooses an item of a pop-up (or a pop-up menu button) by its title: exactly, ignoring case, else by a part of it. The pop-up is opened
    /// first, because an item of a closed menu answers to a press and does nothing; a menu that is still open after a failure is cancelled.
    func select(_ ref: String, option: String) async throws -> String {
        try await run {
            let (element, target) = try self.lookup(ref)
            try self.requireEnabled(element, target)
            let role = self.string(self.copy(element, "AXRole"))
            if role == "AXComboBox" {
                guard AXUIElementSetAttributeValue(element, "AXValue" as CFString, option as CFString) == .success else {
                    throw QANativeError.failed("\(target.summary) did not take \"\(option)\".")
                }
                return "Chose \(option) in \(target.summary)"
            }
            guard role == "AXPopUpButton" || role == "AXMenuButton" else { throw QANativeError.failed("\(target.summary) is not a list of choices.") }
            // The menu takes a moment to appear, and one that is closing from the last choice ignores the press: a choice that did not take is
            // tried once more.
            let wanted = option.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for _ in 0..<2 {
                AXUIElementPerformAction(element, "AXPress" as CFString)
                var items: [(element: AXUIElement, title: String)] = []
                for _ in 0..<6 where items.isEmpty {
                    Thread.sleep(forTimeInterval: 0.1)
                    items = self.menuItems(of: element)
                }
                let chosen = items.first { $0.title.lowercased() == wanted } ?? items.first { $0.title.lowercased().contains(wanted) }
                guard let chosen else {
                    self.cancelMenu(of: element)
                    let titles = items.map(\.title).joined(separator: ", ")
                    throw QANativeError.failed("There is no such choice in \(target.summary). The choices are: \(titles.isEmpty ? "(none could be read)" : titles)")
                }
                let pressed = AXUIElementPerformAction(chosen.element, "AXPress" as CFString) == .success
                // A pop-up shows the choice that was made once its menu has closed (a fifth of a second).
                var shown = pressed && role == "AXMenuButton"
                for _ in 0..<20 where pressed && !shown {
                    shown = self.string(self.copy(element, "AXValue")) == chosen.title
                    if !shown { Thread.sleep(forTimeInterval: 0.05) }
                }
                if shown { return "Chose \(chosen.title) in \(target.summary)" }
                self.cancelMenu(of: element)
            }
            throw QANativeError.failed("\(target.summary) did not take the choice \"\(option)\".")
        }
    }

    private func menuItems(of popup: AXUIElement) -> [(element: AXUIElement, title: String)] {
        var found: [(AXUIElement, String)] = []
        for menu in children(of: popup) where string(copy(menu, "AXRole")) == "AXMenu" {
            for item in children(of: menu) {
                let title = string(copy(item, "AXTitle"))
                if !title.isEmpty { found.append((item, title)) }
            }
        }
        return found
    }

    private func cancelMenu(of popup: AXUIElement) {
        for menu in children(of: popup) where string(copy(menu, "AXRole")) == "AXMenu" { AXUIElementPerformAction(menu, "AXCancel" as CFString) }
    }

    /// Scrolls the biggest scroll area of the window by about a page: by its scroll bar, else by its page action, else with a wheel event
    /// over it. Says what happened, including that the view was already at the end.
    func scroll(up: Bool) async throws -> String {
        try await run {
            guard let window = self.targetWindow(), let area = self.mainScrollArea(in: window) else {
                throw QANativeError.failed("There is nothing to scroll in this window.")
            }
            let bar = self.copy(area, "AXVerticalScrollBar").map { unsafeBitCast($0, to: AXUIElement.self) }
            let before = bar.flatMap { self.number(self.copy($0, "AXValue")) }
            let end = up ? "top" : "bottom"
            if let bar, let before {
                // One page is the visible part of the content, a little less: the share of the way the scroll bar has to go.
                var step = 0.25
                if let visible = self.frame(of: area)?.height, let content = self.size(self.copy(area, "AXContentSize"))?.height, content > visible {
                    step = min(max(0.8 * visible / (content - visible), 0.02), 1)
                }
                let target = min(max(before + (up ? -step : step), 0), 1)
                if target == before { return "The view is already at the \(end)." }
                if AXUIElementSetAttributeValue(bar, "AXValue" as CFString, NSNumber(value: target)) == .success,
                   let after = self.number(self.copy(bar, "AXValue")), after != before { return "Scrolled \(up ? "up" : "down")" }
            }
            let action = up ? "AXScrollUpByPage" : "AXScrollDownByPage"
            if AXUIElementPerformAction(area, action as CFString) == .success {
                guard let bar else { return "Scrolled \(up ? "up" : "down")" }
                if self.number(self.copy(bar, "AXValue")) != before { return "Scrolled \(up ? "up" : "down")" }
            }
            guard let frame = self.frame(of: area) else { throw QANativeError.failed("The view could not be scrolled.") }
            self.postWheel(at: CGPoint(x: frame.midX, y: frame.midY), up: up)
            return "Scrolled \(up ? "up" : "down") with the mouse wheel"
        }
    }

    /// Presses the key (with its modifiers) in the application.
    func press(_ key: QANativeKey) async throws {
        try await run { self.postKey(key) }
    }

    /// The live element and what it was shown as, behind a reference of the last look.
    private func lookup(_ ref: String) throws -> (element: AXUIElement, target: QANativeSnapshot.Target) {
        guard let target = targets[ref], let element = handles[target.id] else {
            throw QANativeError.failed("\"\(ref)\" is not an element of the current view. Look again before using a reference.")
        }
        return (element, target)
    }

    private func requireEnabled(_ element: AXUIElement, _ target: QANativeSnapshot.Target) throws {
        if bool(element, "AXEnabled") == false { throw QANativeError.failed("\(target.summary) is disabled.") }
    }

    private static func gone(_ target: QANativeSnapshot.Target) -> String { "\(target.summary) is not there any more. Look again." }

    // MARK: Events

    private func postKey(_ key: QANativeKey) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.code), keyDown: down) else { continue }
            event.flags = CGEventFlags(rawValue: key.modifiers.rawValue)
            event.postToPid(pid)
        }
    }

    /// Types text as Unicode key events, a few characters per event, never splitting a surrogate pair.
    private func postText(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + 16, units.count)
            if end < units.count, end - start > 1, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[start..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.postToPid(pid)
            }
            Thread.sleep(forTimeInterval: 0.005)
            start = end
        }
    }

    private func postClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .privateState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.04)
        }
    }

    private func postWheel(at point: CGPoint, up: Bool) {
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .privateState), units: .line, wheelCount: 1, wheel1: up ? 5 : -5, wheel2: 0, wheel3: 0) else { return }
        event.location = point
        event.postToPid(pid)
    }

    // MARK: Windows

    private func windows() -> [AXUIElement] {
        copy(application, "AXWindows") as? [AXUIElement] ?? []
    }

    /// The window the person is working in: the focused one, else a modal one (a dialog that holds the others), else the main window, else the first.
    private func targetWindow() -> AXUIElement? {
        if let focused = copy(application, "AXFocusedWindow") { return unsafeBitCast(focused, to: AXUIElement.self) }
        let all = windows()
        if let modal = all.first(where: { bool($0, "AXModal") == true }) { return modal }
        if let main = copy(application, "AXMainWindow") { return unsafeBitCast(main, to: AXUIElement.self) }
        return all.first
    }

    private func mainScrollArea(in window: AXUIElement) -> AXUIElement? {
        var best: (area: AXUIElement, size: CGFloat)?
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth <= QANativeSnapshot.maxDepth else { return }
            for child in children(of: element) {
                let role = string(copy(child, "AXRole"))
                if role == "AXScrollArea" {
                    let size = frame(of: child).map { $0.width * $0.height } ?? 0
                    if best == nil || size > best!.size { best = (child, size) }
                }
                if !QANativeRoles.leaves.contains(role) { walk(child, depth: depth + 1) }
            }
        }
        walk(window, depth: 1)
        return best?.area
    }

    // MARK: Reading attributes

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    /// Several attributes in one call to the application; a missing one is nil. Nil as a whole when the application did not answer.
    private func values(_ element: AXUIElement, _ attributes: [String]) -> [CFTypeRef?]? {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result) == .success,
              let array = result else { return nil }
        return (0..<CFArrayGetCount(array)).map { index -> CFTypeRef? in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            let item = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(unsafeBitCast(item, to: AXValue.self)) == .axError { return nil }
            return item
        }
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        return AXUIElementCopyActionNames(element, &names) == .success ? (names as? [String]) ?? [] : []
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        copy(element, "AXChildren") as? [AXUIElement] ?? []
    }

    private func string(_ value: CFTypeRef?) -> String {
        value as? String ?? ""
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        string(copy(element, attribute))
    }

    private func bool(_ value: CFTypeRef?) -> Bool? {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        bool(copy(element, attribute))
    }

    private func number(_ value: CFTypeRef?) -> Double? {
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    private func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) ? size : nil
    }

    private func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, CFGetTypeID(position) == AXValueGetTypeID(), let size = self.size(size) else { return nil }
        var origin = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        frame(position: copy(element, "AXPosition"), size: copy(element, "AXSize"))
    }
}
