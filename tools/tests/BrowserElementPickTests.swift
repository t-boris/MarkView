import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    if !ok { failures += 1; print("FAIL: \(name)") }
}

let object: [String: Any] = [
    "rect": ["x": 10, "y": 20.5, "width": 300, "height": 40],
    "html": "<button class=\"buy\">Buy</button>", "selector": "main > button.buy",
    "tag": "button.buy", "url": "https://example.com/shop", "title": "Shop", "text": "Buy",
]
let element = PickedElement(object)
check(element != nil && element?.height == 40 && element?.y == 20.5, "parses the rectangle")
check(PickedElement(["rect": ["x": 0, "y": 0, "width": 0, "height": 5]]) == nil, "an empty element is refused")
check(PickedElement(["html": "<p>"]) == nil, "no rectangle is refused")

let shot = URL(fileURLWithPath: "/tmp/element-1.png")
let message = BrowserElementPick.message(for: element!, screenshot: shot)
check(message.contains("Page: https://example.com/shop"), "names the page")
check(message.contains("Selector: main > button.buy"), "names the selector")
check(message.contains("Screenshot: /tmp/element-1.png"), "gives the screenshot path")
check(message.hasSuffix("<button class=\"buy\">Buy</button>"), "ends with the HTML")
check(!BrowserElementPick.message(for: element!, screenshot: nil).contains("Screenshot:"), "no screenshot line without one")

let long = String(repeating: "a", count: BrowserElementPick.maxHTML + 50)
let cut = BrowserElementPick.truncated(long)
check(cut.hasPrefix(String(repeating: "a", count: BrowserElementPick.maxHTML)) && cut.contains("50 more characters"), "cuts long HTML and says so")
check(BrowserElementPick.truncated("<p>x</p>") == "<p>x</p>", "short HTML is kept")

if failures == 0 { print("browser element pick: all checks passed") } else { exit(1) }
