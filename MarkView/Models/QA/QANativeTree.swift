import CoreGraphics
import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-008, DEC-012, DEC-023, REQ-003, REQ-008): the native player's view of an application as plain
// values: the elements read through Accessibility, the text the assistant is shown for them (references, names, limits), the keys it may
// press and the measurements for the review. A secure field's value is never part of the text. Foundation only; checked by
// tools/tests/qa-native-tests.sh.

/// One element of an application's window, as read through Accessibility.
struct QANativeElement: Equatable {
    /// Names the live element inside one reading; the reading layer maps it back to the application's own element.
    var id = 0
    /// The Accessibility role (`AXButton`) and subrole (`AXSecureTextField`).
    var role = ""
    var subrole = ""
    var title = ""
    var description = ""
    /// Text for fields, labels and pop-ups; `checked`, `unchecked` or `mixed` for a checkbox; `expanded` or `collapsed` for a disclosure
    /// triangle. Never read for a secure field.
    var value = ""
    var placeholder = ""
    var enabled = true
    var focused = false
    var selected = false
    /// In screen points, origin at the top left of the main display (as Accessibility reports it).
    var frame: CGRect? = nil
    var identifier = ""
    /// The element offers the press action (read only for roles where that makes the element something to click).
    var hasPress = false
    /// A name the application itself links to the element (its title element, or the text inside a control that has no title).
    var labelText = ""
    var children: [QANativeElement] = []
    var childCount: Int = 0
    var omittedChildren: Int = 0
}

/// One entry of the application's menu bar: a menu item that can be pressed.
struct QANativeMenuEntry: Equatable {
    var id = 0
    /// The menu titles from the menu bar down to the item: `["File", "Reset"]`.
    var path: [String]
    var enabled = true
}

// MARK: - Roles

enum QANativeRoles {
    /// Elements a person operates; each gets a reference.
    static let controls: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXSlider",
        "AXLink", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXMenuItem", "AXMenuBarItem",
    ]
    /// Controls whose size the review judges (menu items and rows are not targets of their own).
    static let targets: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXSlider",
        "AXLink", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell",
    ]
    /// Roles that are not made something to click by a press action.
    static let neverPress: Set<String> = [
        "AXWindow", "AXApplication", "AXMenuBar", "AXMenu", "AXScrollArea", "AXScrollBar", "AXSplitGroup", "AXSplitter", "AXTabGroup",
        "AXToolbar", "AXSheet", "AXDrawer", "AXTable", "AXOutline", "AXList",
    ]
    /// Roles whose value is read: the others have none worth showing. (A secure field's value is never read, whatever its role.)
    static let valued: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXStaticText", "AXHeading",
        "AXIncrementor", "AXDisclosureTriangle",
    ]
    /// Roles asked whether they can be pressed: the ones that are only something to click when they say so.
    static let pressProbed: Set<String> = ["AXCell", "AXGroup", "AXImage", "AXStaticText", "AXUnknown", "AXLayoutItem", "AXLayoutArea", "AXHeading"]
    /// Controls whose children are not read: they only repeat the control (a text run, the label inside a button, the items of a pop-up).
    static let leaves: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXSlider",
        "AXStaticText", "AXHeading", "AXLink", "AXImage", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXScrollBar", "AXSplitter",
        "AXValueIndicator", "AXProgressIndicator", "AXBusyIndicator", "AXMenuItem",
    ]
    /// Controls named by the text inside them when they have no title of their own (SwiftUI buttons, WebKit links).
    static let namedByContent: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXLink", "AXMenuButton"]
    /// Controls named by a label placed next to them when they have no name of their own.
    static let namedByNeighbour: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXCheckBox", "AXSlider", "AXIncrementor", "AXColorWell",
    ]
    /// Containers that are worth a line even without a name, because they tell what the controls inside belong to.
    static let alwaysShown: Set<String> = ["AXTable", "AXOutline", "AXList", "AXTabGroup", "AXToolbar", "AXSheet", "AXPopover", "AXDrawer"]
    /// The buttons every window has, which carry no title of their own, by subrole.
    static let windowControls: [String: String] = [
        "AXCloseButton": "Close", "AXMinimizeButton": "Minimize", "AXZoomButton": "Zoom", "AXFullScreenButton": "Full screen",
    ]
    /// Never shown, whatever they hold.
    static let silent: Set<String> = ["AXScrollBar", "AXSplitter", "AXValueIndicator", "AXBusyIndicator", "AXProgressIndicator", "AXMenuBar", "AXMenu"]

    /// The name the assistant is shown for a role.
    static func kind(role: String, subrole: String, inTabGroup: Bool) -> String {
        switch role {
        case "AXButton": return "button"
        case "AXCheckBox": return subrole == "AXSwitch" || subrole == "AXToggle" ? "switch" : "checkbox"
        case "AXRadioButton": return inTabGroup ? "tab" : "radio button"
        case "AXTextField": return subrole == "AXSearchField" ? "search field" : "text field"
        case "AXTextArea": return "text area"
        case "AXPopUpButton": return "pop-up"
        case "AXMenuButton": return "menu button"
        case "AXComboBox": return "combo box"
        case "AXSlider": return "slider"
        case "AXLink": return "link"
        case "AXDisclosureTriangle": return "disclosure triangle"
        case "AXIncrementor": return "stepper"
        case "AXColorWell": return "color well"
        case "AXMenuItem": return "menu item"
        case "AXMenuBarItem": return "menu"
        case "AXRow": return "row"
        case "AXCell": return "cell"
        case "AXStaticText": return "text"
        case "AXHeading": return "heading"
        case "AXImage": return "image"
        case "AXGroup": return "group"
        case "AXScrollArea": return "scroll area"
        case "AXTable": return "table"
        case "AXOutline": return "outline"
        case "AXList": return "list"
        case "AXTabGroup": return "tab group"
        case "AXToolbar": return "toolbar"
        case "AXSheet": return "sheet"
        case "AXWindow": return "window"
        case "AXSplitGroup": return "split view"
        case "AXWebArea": return "web content"
        case "AXRadioGroup": return "radio group"
        default:
            // `AXLayoutArea` → `layout area`; an empty or odd role stays readable.
            let name = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
            if name.isEmpty { return "element" }
            var words = ""
            for character in name {
                if character.isUppercase, !words.isEmpty { words.append(" ") }
                words.append(character.lowercased())
            }
            return words
        }
    }
}

// MARK: - The tree, flattened and named

/// One element of the tree with what the assistant needs to know about it.
struct QANativeNode {
    /// The element without its children.
    var element: QANativeElement
    var kind: String
    /// 1 for an element directly in the window.
    var depth: Int
    var parent: Int?
    var children: [Int] = []
    var interactive = false
    /// Static text: shown with its text and no reference.
    var textual = false
    var secure = false
    /// What the element is called: its title, else description, else placeholder, else a label next to it, else the text inside it.
    var name = ""
    var text = ""
    /// Text that already names a row or a cell is not shown a second time.
    var hidden = false
    var insideScrollArea = false
}

enum QANativeTree {
    /// The elements in reading order (a parent before its children), named. Elements deeper than `maxDepth` are not part of it and are
    /// counted in `tooDeep` when they would have been something to show.
    static func flatten(_ roots: [QANativeElement], maxDepth: Int = QANativeSnapshot.maxDepth, includeHitTargets: Bool = false) -> (nodes: [QANativeNode], tooDeep: Int) {
        var nodes: [QANativeNode] = []
        var tooDeep = 0

        func shownContent(_ element: QANativeElement) -> Int {
            let facts = classify(element, inTabGroup: false)
            return (facts.interactive || facts.textual ? 1 : 0) + element.children.reduce(0) { $0 + shownContent($1) }
        }

        func visit(_ element: QANativeElement, depth: Int, parent: Int?, parentRole: String, inScroll: Bool) {
            if depth > maxDepth { tooDeep += shownContent(element); return }
            let facts = classify(element, inTabGroup: parentRole == "AXTabGroup")
            var stripped = element
            stripped.children = []
            let index = nodes.count
            var node = QANativeNode(element: stripped, kind: facts.kind, depth: depth, parent: parent)
            let hitTarget = includeHitTargets && ["AXCell", "AXStaticText"].contains(element.role)
                && (element.frame.map { $0.width > 0 && $0.height > 0 } ?? false)
            node.interactive = facts.interactive || hitTarget
            node.textual = facts.textual && !hitTarget
            node.secure = element.role == "AXTextField" && element.subrole == "AXSecureTextField"
            node.insideScrollArea = inScroll
            if facts.textual { node.text = [element.value, element.title, element.description].first { !clean($0).isEmpty }.map(clean) ?? "" }
            nodes.append(node)
            if let parent { nodes[parent].children.append(index) }
            // Unnamed layout wrappers are not semantic nesting. Electron commonly has many before a real panel.
            let meaningful = facts.interactive || facts.textual || !element.title.isEmpty || !element.description.isEmpty
                || QANativeRoles.alwaysShown.contains(element.role)
            for child in element.children {
                visit(child, depth: depth + (meaningful ? 1 : 0), parent: index, parentRole: element.role, inScroll: inScroll || element.role == "AXScrollArea")
            }
        }
        for root in roots { visit(root, depth: 1, parent: nil, parentRole: "", inScroll: false) }
        name(&nodes)
        return (nodes, tooDeep)
    }

    static func classify(_ element: QANativeElement, inTabGroup: Bool) -> (kind: String, interactive: Bool, textual: Bool) {
        let interactive = QANativeRoles.controls.contains(element.role) || element.role == "AXRow"
            || (element.hasPress && !QANativeRoles.neverPress.contains(element.role))
        let textual = !interactive && (element.role == "AXStaticText" || element.role == "AXHeading")
        return (QANativeRoles.kind(role: element.role, subrole: element.subrole, inTabGroup: inTabGroup), interactive, textual)
    }

    /// One line of plain text: runs of white space become one space, quotes become apostrophes (the name is shown inside quotes).
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    // MARK: Names

    private static func name(_ nodes: inout [QANativeNode]) {
        // Pass 1: what the element says about itself.
        for index in nodes.indices where !nodes[index].textual {
            let element = nodes[index].element
            var candidates = [element.title, element.description, element.placeholder]
            // A pop-up is titled with the choice it shows: that is its value, not its name.
            if element.role == "AXPopUpButton" || element.role == "AXComboBox", clean(element.title) == clean(element.value) { candidates[0] = "" }
            candidates.append(element.labelText)
            if element.role == "AXStaticText" { candidates.append(element.value) }
            nodes[index].name = candidates.map(clean).first { !$0.isEmpty } ?? QANativeRoles.windowControls[element.subrole] ?? ""
        }
        // A layout region can be inspected by the visible caption immediately inside it.
        for index in nodes.indices where nodes[index].element.role == "AXGroup" && nodes[index].name.isEmpty {
            let captions = nodes[index].children.compactMap { child -> String? in
                let node = nodes[child]
                guard node.element.role == "AXStaticText", node.text.rangeOfCharacter(from: .letters) != nil else { return nil }
                return node.text
            }.prefix(3)
            nodes[index].name = clip(captions.joined(separator: " | "), QANativeSnapshot.maxName)
        }
        // Pass 2: a label next to a field, and the text inside a row or a cell.
        for index in nodes.indices where nodes[index].interactive && nodes[index].name.isEmpty {
            let role = nodes[index].element.role
            if QANativeRoles.namedByNeighbour.contains(role), let label = neighbourLabel(of: index, in: nodes) {
                nodes[index].name = label
                continue
            }
            // The text view inside a scroll area that the application names is that area's text.
            if role == "AXTextArea", let parent = nodes[index].parent, nodes[parent].element.role == "AXScrollArea", !nodes[parent].name.isEmpty {
                nodes[index].name = nodes[parent].name
                continue
            }
            let inside = innerText(of: index, in: nodes)
            if !inside.isEmpty {
                nodes[index].name = inside
                for child in descendants(of: index, in: nodes) where nodes[child].textual || (role == "AXCell" && nodes[child].element.role == "AXStaticText") { nodes[child].hidden = true }
            }
        }
    }

    private static func descendants(of index: Int, in nodes: [QANativeNode]) -> [Int] {
        var found: [Int] = []
        func walk(_ i: Int) { for child in nodes[i].children { found.append(child); walk(child) } }
        walk(index)
        return found
    }

    private static func innerText(of index: Int, in nodes: [QANativeNode]) -> String {
        let pieces = descendants(of: index, in: nodes).compactMap { (nodes[$0].textual || nodes[$0].element.role == "AXStaticText") && !nodes[$0].text.isEmpty ? nodes[$0].text : nil }.prefix(4)
        return clip(pieces.joined(separator: " | "), QANativeSnapshot.maxName)
    }

    /// The static text next to a field that most likely labels it: to its left on the same row, or just above it. Without frames, the text
    /// that comes right before it.
    private static func neighbourLabel(of index: Int, in nodes: [QANativeNode]) -> String? {
        let siblings = nodes[index].parent.map { nodes[$0].children } ?? nodes.indices.filter { nodes[$0].parent == nil }
        guard let position = siblings.firstIndex(of: index) else { return nil }
        func labelText(_ node: QANativeNode) -> String {
            var text = node.text
            while text.hasSuffix(":") || text.hasSuffix(" ") { text.removeLast() }
            return clip(text, QANativeSnapshot.maxName)
        }
        let field = nodes[index].element.frame
        var best: (distance: CGFloat, text: String)?
        for other in siblings where other != index {
            let candidate = nodes[other]
            guard candidate.textual, !candidate.hidden, !labelText(candidate).isEmpty, let field, let frame = candidate.element.frame else { continue }
            let sameRow = min(frame.maxY, field.maxY) - max(frame.minY, field.minY) > 0
            let left = frame.maxX <= field.minX + 4 && sameRow
            let above = frame.maxY <= field.minY + 4 && field.minY - frame.maxY < 32 && min(frame.maxX, field.maxX) - max(frame.minX, field.minX) > 0
            guard left || above else { continue }
            let distance = left ? field.minX - frame.maxX : field.minY - frame.maxY
            if best == nil || distance < best!.distance { best = (distance, labelText(candidate)) }
        }
        if let best { return best.text }
        // Where a frame is missing there is no geometry to go by: the text right before the field.
        for other in siblings[..<position].reversed() where nodes[other].textual && !nodes[other].hidden && !labelText(nodes[other]).isEmpty {
            return field == nil || nodes[other].element.frame == nil ? labelText(nodes[other]) : nil
        }
        return nil
    }
}

// MARK: - What the assistant is shown

struct QANativeSnapshot: Equatable {
    /// What a reference stands for.
    struct Target: Equatable {
        /// The `QANativeElement.id` or `QANativeMenuEntry.id` it was made from.
        var id: Int
        /// `button "Sign in"`: how the result of an action names the element.
        var summary: String
        var kind: String
        var secure: Bool
        var isMenuEntry: Bool
    }

    var text: String
    /// `e12` → what it stands for. Assigned afresh by every `render`.
    var refs: [String: Target]

    static let maxElements = 400
    static let maxDepth = 14
    static let maxMenuEntries = 120
    static let maxName = 80
    static let maxText = 160
    static let maxValue = 200

    /// The text of one look at the application: a few header lines, the window as an indented tree, the menu bar. Every control (and every
    /// menu entry) has a reference `[e12]`; static text is shown with its text and none. The order is the order of the application's own
    /// tree, so one look at the same window gives the same text. Past the limits, controls come before long text, and the end says how
    /// much was left out. `omitted` is what the reader itself could not read.
    static func render(app: String, windowTitle: String, elements: [QANativeElement], menus: [QANativeMenuEntry], omitted: Int = 0, scoped: Bool = false) -> QANativeSnapshot {
        var lines: [String] = []
        var refs: [String: Target] = [:]
        var counter = 0
        var assigned: [String: String] = [:]
        func reference(_ target: Target) -> String {
            let key = "\(target.isMenuEntry):\(target.id)"
            if let existing = assigned[key] { return existing }
            counter += 1
            let ref = "e\(counter)"
            refs[ref] = target
            assigned[key] = ref
            return ref
        }

        lines.append("Application: \(QANativeTree.clip(QANativeTree.clean(app), 120))")
        let title = QANativeTree.clean(windowTitle)
        lines.append(title.isEmpty ? "Window: (untitled)" : "Window: \"\(QANativeTree.clip(title, 120))\"")
        lines.append("A native macOS application. Every [eN] reference is valid for this look only. click presses a control or chooses a menu entry, fill types into a field, select chooses an item of a pop-up, key sends a key such as cmd+shift+n.")
        lines.append("inspect (ref) reads a container without changing the app; empty ref returns to the whole window. amount skips that many direct children for continuation. Incomplete observations do not prove controls are absent.")
        lines.append("Window content:")

        if scoped { lines.append("Text and cells with real Accessibility frames also have pointer refs. Click only the target called for by the task; a text ref does not prove the app assigns it an action. inspect with empty ref returns to the whole window.") }
        let (nodes, tooDeep) = QANativeTree.flatten(elements, includeHitTargets: scoped)
        var kept = Set<Int>()
        let interactive = nodes.indices.filter { nodes[$0].interactive && !nodes[$0].hidden }
        // The window's own title is shown by the header, not once more as text.
        let texts = nodes.indices.filter {
            let node = nodes[$0]
            return (node.textual && !node.hidden && !node.text.isEmpty && !(node.depth == 1 && node.text == title)) || isNamedImage(node)
        }
        var inspectable = Set(nodes.indices.filter {
            let node = nodes[$0]
            return !node.secure && (node.element.omittedChildren > 0 || ["AXWebArea", "AXTable", "AXOutline", "AXList"].contains(node.element.role)
                || (node.element.role == "AXGroup" && !node.name.isEmpty && node.name.lowercased() != "n/a" && !node.children.isEmpty))
        })
        if interactive.count + texts.count > maxElements {
            inspectable.formUnion(nodes.indices.filter { ["AXTable", "AXOutline", "AXWebArea"].contains(nodes[$0].element.role) })
        }
        var inDenseTable = [Bool](repeating: false, count: nodes.count)
        var inTable = [Bool](repeating: false, count: nodes.count)
        var hasDenseTable = false
        for index in nodes.indices {
            let table = ["AXTable", "AXOutline", "AXList"].contains(nodes[index].element.role)
            let dense = table && (nodes[index].element.childCount > 24 || nodes[index].element.omittedChildren > 0)
            hasDenseTable = hasDenseTable || dense
            inDenseTable[index] = dense || (nodes[index].parent.map { inDenseTable[$0] } ?? false)
            inTable[index] = table || (nodes[index].parent.map { inTable[$0] } ?? false)
        }
        kept = Set(inspectable.sorted().prefix(maxElements))
        if !scoped, hasDenseTable {
            for index in interactive where !inDenseTable[index] && kept.count < maxElements { kept.insert(index) }
            for index in texts where !inDenseTable[index] && kept.count < maxElements { kept.insert(index) }
        }
        for index in interactive where kept.count < maxElements { kept.insert(index) }
        let byLength = texts.sorted { (nodes[$0].text.count, $0) < (nodes[$1].text.count, $1) }
        for index in byLength where kept.count < maxElements { kept.insert(index) }
        let leftOut = Set(interactive + texts).subtracting(kept).count + tooDeep + omitted

        // Keep a compact route to later panels before the long table body. The assistant's prompt may truncate that body.
        let navigation = inspectable.sorted().filter { index in
            let node = nodes[index]
            return kept.contains(index) && (["AXWebArea", "AXTable", "AXOutline", "AXList"].contains(node.element.role)
                || node.children.contains { ["AXGroup", "AXTable", "AXOutline", "AXList", "AXScrollArea"].contains(nodes[$0].element.role) })
        }
        if !navigation.isEmpty {
            lines.append("Inspection regions (read-only routes, valid for this look):")
            for index in navigation {
                let node = nodes[index]
                let name = QANativeTree.clip(node.name, maxName)
                let summary = name.isEmpty ? node.kind : "\(node.kind) \"\(name)\""
                let ref = reference(Target(id: node.element.id, summary: summary, kind: node.kind, secure: false, isMenuEntry: false))
                lines.append("[\(ref)] \(summary); \(node.element.childCount) direct children, \(node.element.omittedChildren) unread")
            }
        }
        // A prompt can end before the later panels even when their inspection routes fit.
        // Keep current controls and compact row state together; repetitive grid bodies remain inspectable.
        if !scoped {
            if hasDenseTable {
                let controls = nodes.indices.filter { kept.contains($0) && !inDenseTable[$0] && nodes[$0].interactive
                    && !["AXRow", "AXCell", "AXStaticText"].contains(nodes[$0].element.role) && !nodes[$0].hidden }
                let labels = texts.filter { kept.contains($0) && !inTable[$0] && !nodes[$0].hidden }
                let rows = nodes.indices.filter { kept.contains($0) && !inDenseTable[$0] && nodes[$0].element.role == "AXRow" && !nodes[$0].hidden }
                let captions = inspectable.filter { kept.contains($0) && !inDenseTable[$0] && nodes[$0].element.role == "AXGroup" }
                let items = Set(controls + labels + rows + captions).sorted { (nodes[$0].depth, $0) < (nodes[$1].depth, $1) }
                var overview: [String] = []
                var remaining = 3600
                var omittedOverview = 0
                for index in items {
                    let node = nodes[index]
                    let line: String
                    if node.interactive || inspectable.contains(index) {
                        let name = QANativeTree.clip(node.name, maxName)
                        let summary = name.isEmpty ? node.kind : "\(node.kind) \"\(name)\""
                        let ref = reference(Target(id: node.element.id, summary: summary, kind: node.kind, secure: node.secure, isMenuEntry: false))
                        line = "[\(ref)] \(summary)" + valueSuffix(node) + stateSuffix(node)
                    } else {
                        line = "\(node.kind) \"\(QANativeTree.clip(node.text, maxName))\""
                    }
                    if line.count + 1 <= remaining {
                        overview.append(line)
                        remaining -= line.count + 1
                    } else { omittedOverview += 1 }
                }
                if !overview.isEmpty {
                    lines.append("Current window overview (dense table details are below or available with inspect):")
                    lines.append(contentsOf: overview)
                    if omittedOverview > 0 { lines.append("[… \(omittedOverview) overview items omitted; inspect their current region]") }
                }
            }
        }
        // A container is shown when something inside it is.
        var shown = Set<Int>()
        for index in kept {
            var up = nodes[index].parent
            while let parent = up {
                if !nodes[parent].interactive, isShownContainer(nodes[parent]) { shown.insert(parent) }
                up = nodes[parent].parent
            }
        }
        var level = [Int](repeating: 0, count: nodes.count)
        var printedAny = false
        for index in nodes.indices {
            if let parent = nodes[index].parent { level[index] = level[parent] + (kept.contains(parent) || shown.contains(parent) ? 1 : 0) }
            guard kept.contains(index) || shown.contains(index) else { continue }
            let node = nodes[index]
            let indent = String(repeating: "  ", count: level[index])
            var line = node.kind
            if node.interactive || inspectable.contains(index) {
                let name = QANativeTree.clip(node.name, maxName)
                let summary = name.isEmpty ? node.kind : "\(node.kind) \"\(name)\""
                line = "[\(reference(Target(id: node.element.id, summary: summary, kind: node.kind, secure: node.secure, isMenuEntry: false)))] \(summary)"
                line += valueSuffix(node)
                if inspectable.contains(index) {
                    line += " (inspectable, direct children: \(node.element.childCount), unread children: \(node.element.omittedChildren))"
                }
            } else if node.textual {
                line += " \"\(QANativeTree.clip(node.text, maxText))\""
            } else if !node.name.isEmpty {
                line += " \"\(QANativeTree.clip(node.name, maxName))\""
            }
            line += stateSuffix(node)
            lines.append(indent + line)
            printedAny = true
        }
        if !printedAny { lines.append("(the window shows no readable elements)") }
        if leftOut > 0 { lines.append("[… \(leftOut) more elements]") }

        if !menus.isEmpty {
            lines.append("Menu bar:")
            for entry in menus.prefix(maxMenuEntries) {
                let path = entry.path.map { QANativeTree.clip(QANativeTree.clean($0), maxName) }.joined(separator: " > ")
                let ref = reference(Target(id: entry.id, summary: "menu item \"\(path)\"", kind: "menu item", secure: false, isMenuEntry: true))
                lines.append("[\(ref)] \(path)" + (entry.enabled ? "" : " (disabled)"))
            }
            if menus.count > maxMenuEntries { lines.append("[… \(menus.count - maxMenuEntries) more menu entries]") }
        }
        return QANativeSnapshot(text: lines.joined(separator: "\n"), refs: refs)
    }

    private static func isNamedImage(_ node: QANativeNode) -> Bool {
        node.element.role == "AXImage" && !node.interactive && !node.name.isEmpty
    }

    private static func isShownContainer(_ node: QANativeNode) -> Bool {
        if node.textual || QANativeRoles.silent.contains(node.element.role) || node.element.role == "AXWindow" { return false }
        return !node.name.isEmpty || QANativeRoles.alwaysShown.contains(node.element.role)
    }

    /// The value of a control, for the line of its reference. A secure field's value is never shown, whatever the element carries.
    private static func valueSuffix(_ node: QANativeNode) -> String {
        if node.secure { return " (secure field, value hidden)" }
        let value = QANativeTree.clip(QANativeTree.clean(node.element.value), maxValue)
        guard !value.isEmpty else { return "" }
        switch node.element.role {
        case "AXCheckBox", "AXDisclosureTriangle": return " (\(value))"
        default: return " = \"\(value)\""
        }
    }

    private static func stateSuffix(_ node: QANativeNode) -> String {
        var states: [String] = []
        if node.interactive, !node.element.enabled { states.append("disabled") }
        if node.element.focused { states.append("focused") }
        if node.element.selected { states.append("selected") }
        return states.isEmpty ? "" : " (" + states.joined(separator: ", ") + ")"
    }
}

// MARK: - Keys

struct QANativeKey: Equatable {
    /// Bit masks of the Quartz event flags (`CGEventFlags`), so the posting layer can pass `rawValue` on.
    struct Modifiers: OptionSet, Equatable {
        let rawValue: UInt64
        static let shift = Modifiers(rawValue: 0x0002_0000)
        static let control = Modifiers(rawValue: 0x0004_0000)
        static let option = Modifiers(rawValue: 0x0008_0000)
        static let command = Modifiers(rawValue: 0x0010_0000)
    }

    /// The virtual key code (`kVK_…`) of a key of the US layout.
    var code: UInt16
    var modifiers: Modifiers
}

enum QANativeKeys {
    /// `cmd+shift+n`, `Enter`, `Escape`, `Tab`, `Down`, `a`: modifiers and one key, joined by `+`, case ignored.
    ///
    /// Modifiers: `cmd` `command`, `shift`, `alt` `option` `opt`, `ctrl` `control`. Keys: a letter, a digit, one of ``- = [ ] \ ; ' , . / ` ``
    /// (or `minus`, `plus` (shift and the key of `=`)), `enter` `return`, `escape` `esc`, `tab`, `space`, `delete` `backspace`,
    /// `forwarddelete`, `up` `down` `left` `right` (also `arrowup`…), `home` `end` `pageup` `pagedown`, `f1`…`f12`. Case does not make a
    /// letter a capital: ask for `shift` itself. The codes are those of the US layout; a shortcut reaches the application by key code, so
    /// the application sees the same letter whatever layout is active only for command shortcuts.
    static func parse(_ text: String) -> QANativeKey? {
        var spec = text.trimmingCharacters(in: .whitespaces).lowercased()
        if spec.isEmpty { return nil }
        if spec == "+" { spec = "plus" } else if spec.hasSuffix("++") { spec = String(spec.dropLast(2)) + "+plus" }
        let parts = spec.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var modifiers: QANativeKey.Modifiers = []
        for part in parts.dropLast() {
            guard let modifier = modifierNames[part] else { return nil }
            modifiers.insert(modifier)
        }
        if keyName == "plus" { modifiers.insert(.shift) }
        guard let code = keyCodes[keyName] else { return nil }
        return QANativeKey(code: code, modifiers: modifiers)
    }

    static let modifierNames: [String: QANativeKey.Modifiers] = [
        "cmd": .command, "command": .command, "shift": .shift, "alt": .option, "option": .option, "opt": .option, "ctrl": .control, "control": .control,
    ]

    static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "plus": 24, "9": 25, "7": 26, "-": 27, "minus": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
        "enter": 36, "return": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53, "forwarddelete": 117,
        "left": 123, "arrowleft": 123, "right": 124, "arrowright": 124, "down": 125, "arrowdown": 125, "up": 126, "arrowup": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}

// MARK: - Evidence for the review

enum QANativeEvidence {
    /// A control smaller than this on both sides is a small target (points).
    static let smallTarget: CGFloat = 24

    /// What the window shows by measure, in the vocabulary of the page evidence. Only what Accessibility can tell is measured; the rest
    /// stays zero. A target is small when both of its sides are under 24 pt (an ordinary push button is 22 pt high and wide enough to hit).
    /// When something reaches past the window's right edge, `horizontalScrollPixels` carries how far, so the summary reports it.
    static func make(from elements: [QANativeElement], windowFrame: CGRect) -> QAPageEvidence {
        let (nodes, _) = QANativeTree.flatten(elements, maxDepth: Int.max)
        var evidence = QAPageEvidence()
        func note(_ tally: inout QAPageEvidence.Tally, _ sample: String) {
            tally.count += 1
            if tally.samples.count < QAPageEvidence.maxSamples { tally.samples.append(QANativeTree.clip(sample, QAPageEvidence.sampleLimit)) }
        }
        func describe(_ node: QANativeNode, size: Bool) -> String {
            var text = node.name.isEmpty ? node.kind : "\(node.kind) \"\(QANativeTree.clip(node.name, 40))\""
            if let frame = node.element.frame {
                if size { text += " \(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))pt" }
                text += " @\(Int((frame.minX - windowFrame.minX).rounded())),\(Int((frame.minY - windowFrame.minY).rounded()))"
            }
            return text
        }

        var beyond = Set<Int>()
        var overshoot: CGFloat = 0
        for index in nodes.indices {
            let node = nodes[index]
            let element = node.element
            if node.interactive, node.name.isEmpty, QANativeRoles.targets.contains(element.role) || element.hasPress || element.role == "AXRow" {
                note(&evidence.unlabeledControls, describe(node, size: false))
            }
            guard let frame = element.frame, frame.width > 0, frame.height > 0 else { continue }
            if QANativeRoles.targets.contains(element.role), QANativeRoles.windowControls[element.subrole] == nil, element.enabled,
               frame.width < smallTarget, frame.height < smallTarget {
                note(&evidence.smallTargets, describe(node, size: true))
            }
            // The outermost elements past the edge; what a scroll area holds is meant to be scrolled to.
            if !node.insideScrollArea, element.role != "AXWindow", frame.maxX > windowFrame.maxX + 1 {
                beyond.insert(index)
                if let parent = node.parent, beyond.contains(parent) { continue }
                note(&evidence.beyondRightEdge, describe(node, size: false) + " right edge at \(Int((frame.maxX - windowFrame.minX).rounded()))pt")
                overshoot = max(overshoot, frame.maxX - windowFrame.maxX)
            }
        }
        if evidence.beyondRightEdge.count > 0 { evidence.horizontalScrollPixels = Int(overshoot.rounded(.up)) }
        return evidence
    }
}
