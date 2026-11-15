import Foundation

/// The editor page keeps a few choices of the person in `localStorage`: the document text size, the width of the X-Ray details and
/// of the code notes, and whether the X-Ray details are hidden. WebKit hands one `localStorage` to every window's page, so a choice
/// made in one window would be the one every other window reads next. Each window keeps its own copy instead, in its `WindowUIState`
/// (so the session restores it): the page asks its own copy first, and the shared store is only where a window with no choice of its
/// own starts from (the last choice anywhere), exactly as `WindowUIState` seeds the native values.
enum EditorWindowPrefs {
    /// The only keys a window keeps for itself. Everything else the editor stores (a research map's view per document, an output
    /// language) is about a document or a setting, not about the window.
    static let keys = [
        "markview-font-size",
        "markview-xray-details-hidden",
        "markview-xray-details-width",
        "markview-code-notes-width"
    ]
    static let maxValueLength = 32

    /// Where `WindowUIState` files the value of one of the keys.
    static func stateKey(_ key: String) -> String { "editor.\(key)" }

    /// The page is not trusted to send anything but one of the keys with a short value.
    static func accepts(key: String, value: String) -> Bool {
        keys.contains(key) && value.count <= maxValueLength
    }

    /// The script that goes into the editor page ahead of every other script, with this window's own values (`values`: key to value).
    static func script(values: [String: String]) -> String {
        let known = values.filter { accepts(key: $0.key, value: $0.value) }
        return """
        (function () {
          var keys = \(json(keys)), own = \(json(known));
          var proto = Storage.prototype, read = proto.getItem, write = proto.setItem;
          function mine(storage, key) { return storage === window.localStorage && keys.indexOf(key) >= 0; }
          proto.getItem = function (key) {
            if (!mine(this, key)) return read.call(this, key);
            if (!Object.prototype.hasOwnProperty.call(own, key)) own[key] = read.call(this, key);
            return own[key];
          };
          proto.setItem = function (key, value) {
            write.call(this, key, value);
            if (!mine(this, key)) return;
            own[key] = String(value);
            try { window.webkit.messageHandlers.bridge.postMessage({ type: 'editorWindowPref', payload: { key: key, value: own[key] } }); } catch (e) {}
          };
        })();
        """
    }

    /// JSON that is safe inside a `<script>` element.
    private static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text.replacingOccurrences(of: "</", with: "<\\/")
    }
}
