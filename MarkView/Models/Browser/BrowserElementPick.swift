import Foundation

/// An element the user picked in a browser tab (`markview-pick-element.js`).
struct PickedElement: Equatable {
    var url: String
    var title: String
    var tag: String
    var selector: String
    var html: String
    var text: String
    /// Viewport rectangle in points.
    var x: Double, y: Double, width: Double, height: Double

    init?(_ object: [String: Any]) {
        guard let rect = object["rect"] as? [String: Any],
              let x = (rect["x"] as? NSNumber)?.doubleValue, let y = (rect["y"] as? NSNumber)?.doubleValue,
              let width = (rect["width"] as? NSNumber)?.doubleValue, let height = (rect["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        self.x = x; self.y = y; self.width = width; self.height = height
        url = object["url"] as? String ?? ""
        title = object["title"] as? String ?? ""
        tag = object["tag"] as? String ?? ""
        selector = object["selector"] as? String ?? ""
        html = object["html"] as? String ?? ""
        text = object["text"] as? String ?? ""
    }
}

enum BrowserElementPick {
    /// The longest HTML pasted into an agent's input; the rest is cut and said so.
    static let maxHTML = 8_000

    /// The text pasted into an agent: where the element is, its screenshot (an image path the
    /// agent attaches) and its HTML.
    static func message(for element: PickedElement, screenshot: URL?) -> String {
        var lines = ["Element picked in the MarkView browser: \(element.tag)"]
        if !element.url.isEmpty { lines.append("Page: \(element.url)") }
        if !element.selector.isEmpty { lines.append("Selector: \(element.selector)") }
        if let screenshot { lines.append("Screenshot: \(screenshot.path)") }
        lines.append("HTML:")
        lines.append(truncated(element.html))
        return lines.joined(separator: "\n")
    }

    static func truncated(_ html: String) -> String {
        guard html.count > maxHTML else { return html }
        return String(html.prefix(maxHTML)) + "\n… (HTML cut: \(html.count - maxHTML) more characters)"
    }

    /// Where element screenshots are kept (the same place as pasted images).
    static func screenshotURL(now: Date = Date()) -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarkView/pasted-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("element-\(Int(now.timeIntervalSince1970 * 1000)).png")
    }
}
