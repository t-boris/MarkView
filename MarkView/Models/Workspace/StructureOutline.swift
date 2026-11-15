import Foundation

/// The structure of a JSON or YAML file for the Contents panel: its keys, nested, each with the line it
/// sits on so a click can jump there. Foundation only, checked in `tools/tests/structure-outline-tests.sh`.
enum StructureOutline {
    /// A step of a key path: an object key or an array index (the tree viewer addresses nodes this way).
    enum Step: Equatable {
        case key(String)
        case index(Int)
    }

    struct Item: Equatable, Identifiable {
        let id: Int
        let title: String
        /// 1-based line in the file.
        let line: Int
        let depth: Int
        /// Where the key sits from the root: `["services", "web", "ports", 0]`.
        var path: [Step] = []

        /// The path as JSON, as the page's tree viewer stores it in `data-path`.
        var pathJSON: String {
            let parts: [Any] = path.map { step in
                switch step {
                case .key(let name): return name
                case .index(let number): return number
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: parts), let text = String(data: data, encoding: .utf8) else { return "[]" }
            return text
        }
    }

    static let maximumItems = 3000
    static let jsonExtensions: Set<String> = ["json", "jsonc", "json5", "geojson"]
    static let yamlExtensions: Set<String> = ["yml", "yaml"]

    static func supports(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return jsonExtensions.contains(ext) || yamlExtensions.contains(ext)
    }

    static func items(for url: URL, text: String) -> [Item] {
        yamlExtensions.contains(url.pathExtension.lowercased()) ? yaml(text) : json(text)
    }

    // MARK: JSON

    /// Object keys down to `maxDepth` levels, and "[n]" for the objects and arrays inside an array.
    static func json(_ text: String, maxDepth: Int = 5) -> [Item] {
        var items: [Item] = []
        // One entry per open container: true = object, false = array; with the next array index.
        var stack: [(isObject: Bool, index: Int, current: Step?)] = []
        var expectKey = false
        var line = 1
        let bytes = Array(text.utf8)
        var i = 0
        func add(_ title: String, _ line: Int, _ depth: Int) {
            if depth < maxDepth, items.count < maximumItems {
                items.append(Item(id: items.count, title: title, line: line, depth: depth, path: stack.compactMap(\.current)))
            }
        }
        while i < bytes.count, items.count < maximumItems {
            let byte = bytes[i]
            switch byte {
            case UInt8(ascii: "\n"): line += 1; i += 1
            case UInt8(ascii: "\""):
                let startLine = line
                var j = i + 1
                var raw: [UInt8] = []
                while j < bytes.count, bytes[j] != UInt8(ascii: "\"") {
                    if bytes[j] == UInt8(ascii: "\\"), j + 1 < bytes.count { raw.append(bytes[j]); j += 1 }
                    if bytes[j] == UInt8(ascii: "\n") { line += 1 }
                    raw.append(bytes[j]); j += 1
                }
                i = j + 1
                if let top = stack.last, top.isObject, expectKey {
                    // A key when a colon follows.
                    var k = i
                    while k < bytes.count, [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n")].contains(bytes[k]) {
                        if bytes[k] == UInt8(ascii: "\n") { line += 1 }
                        k += 1
                    }
                    if k < bytes.count, bytes[k] == UInt8(ascii: ":") {
                        let name = String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\\\"", with: "\"")
                        stack[stack.count - 1].current = .key(name)
                        add(name, startLine, stack.count - 1)
                        expectKey = false
                        i = k + 1
                    }
                }
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                if let top = stack.last, !top.isObject {
                    stack[stack.count - 1].current = .index(top.index)
                    add("[\(top.index)]", line, stack.count - 1)
                    stack[stack.count - 1].index += 1
                }
                stack.append((byte == UInt8(ascii: "{"), 0, nil))
                expectKey = byte == UInt8(ascii: "{")
                i += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if !stack.isEmpty { stack.removeLast() }
                expectKey = false
                i += 1
            case UInt8(ascii: ","):
                if let top = stack.last, top.isObject { expectKey = true }
                i += 1
            case UInt8(ascii: "/") where i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "/"):
                while i < bytes.count, bytes[i] != UInt8(ascii: "\n") { i += 1 }      // a // comment (jsonc)
            default: i += 1
            }
        }
        return items
    }

    // MARK: YAML

    /// Mapping keys by indentation; block scalars (`|`, `>`) are skipped, so their text is not read as keys.
    static func yaml(_ text: String) -> [Item] {
        var items: [Item] = []
        var levels: [(column: Int, name: String, dashes: Int)] = []
        var skipBelow: Int?
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if items.count >= maximumItems { break }
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            if let skip = skipBelow {
                if indent > skip { continue }
                skipBelow = nil
            }
            if trimmed.hasPrefix("#") { continue }
            if trimmed == "---" || trimmed.hasPrefix("--- ") { levels = []; continue }
            // "- - key:" style: each dash moves the key two columns right.
            var rest = Substring(trimmed)
            var column = indent
            var dashes = 0
            while rest.hasPrefix("- ") || rest == "-" {
                dashes += 1
                rest = rest.dropFirst(rest.hasPrefix("- ") ? 2 : 1)
                column += 2
                while rest.hasPrefix(" ") { rest = rest.dropFirst(); column += 1 }
            }
            // A list item (with a key or without) counts among the dashes under its parent key.
            var itemIndex: Int?
            if dashes > 0 {
                while let last = levels.last, last.column >= column { levels.removeLast() }
                if !levels.isEmpty {
                    itemIndex = levels[levels.count - 1].dashes
                    levels[levels.count - 1].dashes += 1
                }
            }
            guard let key = keyOf(rest) else { continue }
            while let last = levels.last, last.column >= column { levels.removeLast() }
            var path = levels.map { Step.key($0.name) }
            if let itemIndex { path.append(.index(itemIndex)) }
            path.append(.key(key))
            items.append(Item(id: items.count, title: key, line: offset + 1, depth: levels.count, path: path))
            levels.append((column, key, 0))
            let value = rest.dropFirst(key.count).drop(while: { $0 == "\"" || $0 == "'" || $0 == " " }).dropFirst().trimmingCharacters(in: .whitespaces)
            if let first = value.first, "|>".contains(first), value.dropFirst().allSatisfy({ "+-0123456789 ".contains($0) }) || value.count == 1 {
                skipBelow = column
            }
        }
        return items
    }

    /// The key at the start of a YAML line (`name:`, `"quoted key":`), or nil when the line is not a key.
    static func keyOf(_ line: Substring) -> String? {
        if line.hasPrefix("\"") || line.hasPrefix("'") {
            let quote = line.first!
            let body = line.dropFirst()
            guard let close = body.firstIndex(of: quote) else { return nil }
            let after = body[body.index(after: close)...].drop(while: { $0 == " " })
            guard after.hasPrefix(":") else { return nil }
            return String(body[..<close])
        }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon]
        guard !key.isEmpty, !key.hasPrefix("#"), !key.hasPrefix("{"), !key.hasPrefix("["),
              line.index(after: colon) == line.endIndex || line[line.index(after: colon)] == " " else { return nil }
        return String(key).trimmingCharacters(in: .whitespaces)
    }
}
