import Foundation
import CoreGraphics

enum QAActionKind: String, Codable, CaseIterable {
    case click
    case fill
    case select
    case scroll
    case inspect
    case navigate
    case key
    case wait
    /// A request sent by the runner itself, for preparing data. Never a way to do what a person does in the page.
    case http
}

/// Recording-only annotation. Coordinates are fractions of the captured viewport, measured from its top left.
/// It deliberately carries no field value, credential, URL query or document text.
struct QAInputMark: Equatable {
    var kind: QAActionKind
    var target: CGRect? = nil
    var direction: String = ""
    var automaticScroll: String? = nil
    var failed = false

    var label: String {
        let action: String
        switch kind {
        case .click: action = "Click"
        case .fill: action = "Type text"
        case .select: action = "Select option"
        case .scroll: action = direction == "up" ? "Scroll ↑" : "Scroll ↓"
        case .navigate: action = "Open address"
        case .key: action = "Key input"
        case .inspect: action = "Inspect region"
        case .wait: action = "Wait"
        case .http: action = "HTTP request"
        }
        let scroll = automaticScroll.map { "Scroll \($0 == "up" ? "↑" : "↓") to target · " } ?? ""
        return scroll + action + (failed ? " · Failed" : "")
    }

    static func normalized(_ rect: CGRect, in viewport: CGRect) -> CGRect? {
        guard [rect.minX, rect.minY, rect.width, rect.height, viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy(\.isFinite),
              viewport.width > 0, viewport.height > 0, rect.width > 0, rect.height > 0 else { return nil }
        let visible = rect.intersection(viewport)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return CGRect(x: (visible.minX - viewport.minX) / viewport.width, y: (visible.minY - viewport.minY) / viewport.height,
                      width: visible.width / viewport.width, height: visible.height / viewport.height)
    }
}

