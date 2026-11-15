import Foundation

/// Checks that a built prototype screen is real (BUG-053).
///
/// Two layers, both local and free of any assistant:
/// - `stubProblem` reads the text of a screen the assistant just wrote and refuses a file that is only a comment, never
///   registers the screen, has no render function or is a short placeholder, so the build retries it or reports it as failed
///   instead of accepting it.
/// - `script` runs in the Studio preview after a build, a sync or a revision: it opens every screen of `App.plan` in turn,
///   waits until the page settles and reports the screens that render nothing, stay on their loading indicator, end in an
///   error card or are placeholders. Without it only the first screen was ever rendered, and a screen whose page stayed
///   empty threw no JavaScript error, so nothing reported it.
enum PrototypeAudit {
    // MARK: - The written file

    /// Why `content` cannot be the screen `id`, or nil when it looks like a screen.
    static func stubProblem(id: String, content: String) -> String? {
        let code = withoutComments(content)
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "the file has no code, only comments or nothing" }
        if !code.contains("App.register") { return "it never calls App.register, so the screen does not exist" }
        if !code.contains("render") { return "it registers no render function" }
        if trimmed.count < placeholderLimit,
           let found = code.range(of: placeholderWords, options: [.regularExpression, .caseInsensitive]) {
            return "it is a placeholder (\"\(code[found])\")"
        }
        return nil
    }

    /// A real screen is far longer; only code this short is searched for the words of a placeholder.
    static let placeholderLimit = 400
    static let placeholderWords = #"not (yet )?implemented|coming soon|under construction|\btodo\b|\bstub\b|\bplaceholder\b|не реализован"#

    /// `source` without its `//` and `/* */` comments; quotes and template literals are respected so a URL in a string survives.
    static func withoutComments(_ source: String) -> String {
        var out = ""
        var quote: Character?
        var chars = Array(source)
        chars.append("\0")
        var i = 0
        while i < chars.count - 1 {
            let c = chars[i], next = chars[i + 1]
            if let open = quote {
                out.append(c)
                if c == "\\" && next != "\0" { out.append(next); i += 2; continue }
                if c == open { quote = nil }
                i += 1
            } else if c == "/" && next == "/" {
                while i < chars.count - 1 && chars[i] != "\n" { i += 1 }
            } else if c == "/" && next == "*" {
                i += 2
                while i < chars.count - 1 && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                out.append(" ")
            } else {
                if c == "\"" || c == "'" || c == "`" { quote = c }
                out.append(c)
                i += 1
            }
        }
        return out
    }

    // MARK: - The loader defect (BUG-062, narrowed by BUG-064)

    /// Why the screen `content` ends up empty although it renders. The element a loading container sits in (`root.append(App.load(...))`)
    /// is cleared by code that runs before the callback of `App.load` returns (`root.replaceChildren(...)`, `root.innerHTML = ...`, in the
    /// callback or in a function it calls), and the callback then returns the host or takes its children (`root.childNodes`) into what it
    /// returns. Clearing takes the container out of the page; `App.load` then puts the returned element into that detached container, so the
    /// content that was in the host leaves the page with it and nothing is shown, with no JavaScript error (strikedesk's trade.js).
    ///
    /// Clearing alone is not the defect: a callback that draws into the host itself and returns nothing, or a retry handler that redraws the
    /// host later (a function literal inside the callback, which does not run before it returns), leaves a working screen (BUG-064: such
    /// shapes made seven screens of the vivaa client-web-app look broken, one of them the gallery). Nil when the file has no such pattern.
    /// A text scan, not a parser: it follows calls to functions the file defines, up to `loadCallDepth` levels, and reads nothing inside
    /// function literals; what it misses the preview check finds when the screen renders blank.
    static func loadProblem(id: String, content: String) -> String? {
        let code = withoutComments(content)
        guard code.contains("App") && code.contains("load") else { return nil }
        let hosts = loadHosts(in: code)
        guard !hosts.isEmpty else { return nil }
        let functions = functionBodies(in: code)
        for host in hosts {
            guard let body = callbackBody(of: host.callback, functions: functions) else { continue }
            let own = withoutFunctionLiterals(body)
            guard takesHost(host.name, in: own) else { continue }
            let clearing = clearsChildren(of: host.name)
            if let hit = firstMatch(clearing, in: own) {
                return loadMessage(id: id, host: host.name, how: hit, through: nil)
            }
            // Calls the callback makes before it returns to functions the file defines, followed breadth first.
            var seen = Set<String>(), queue = calledNames(in: own).filter { functions[$0] != nil }.map { ($0, 1) }
            while !queue.isEmpty {
                let (name, depth) = queue.removeFirst()
                guard seen.insert(name).inserted, let function = functions[name] else { continue }
                let inner = withoutFunctionLiterals(function)
                if let hit = firstMatch(clearing, in: inner) { return loadMessage(id: id, host: host.name, how: hit, through: name) }
                if depth < loadCallDepth { queue += calledNames(in: inner).filter { functions[$0] != nil }.map { ($0, depth + 1) } }
            }
        }
        return nil
    }

    private static let loadCallDepth = 4

    private static func loadMessage(id: String, host: String, how: String, through function: String?) -> String {
        let via = function.map { " (through \($0)())" } ?? ""
        return "screens/\(id).js: the callback of App.load runs `\(how)`\(via) on `\(host)`, the element the loading container is appended " +
            "to, and then returns `\(host)` or its child nodes. Clearing the host takes the container out of the page, so what the callback " +
            "returns goes into a detached element and the screen stays empty. Build the content in a new element and return that from the " +
            "callback; leave the children of `\(host)` alone."
    }

    /// The text of the callback's own body: a function literal's block or expression, or the body of the named function it refers to.
    /// `arguments` is the text of the call's arguments, starting at its "(".
    private static func callbackBody(of arguments: String, functions: [String: String]) -> String? {
        let inner = String(arguments.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        let heads = [#"^(?:async\s+)?function\s*[\w$]*\s*\([^)]*\)\s*\{"#,
                     #"^(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>\s*\{"#]
        for pattern in heads {
            guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: inner, range: NSRange(location: 0, length: (inner as NSString).length)) else { continue }
            let open = match.range.location + match.range.length - 1
            guard let close = closing(of: Array(inner.utf16), open: open) else { return nil }
            return (inner as NSString).substring(with: NSRange(location: open, length: close - open))
        }
        if let regex = try? NSRegularExpression(pattern: #"^(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>\s*"#),
           let match = regex.firstMatch(in: inner, range: NSRange(location: 0, length: (inner as NSString).length)) {
            // An expression body: up to the end of the argument.
            let rest = (inner as NSString).substring(from: match.range.location + match.range.length)
            return "{ return " + rest + " }"
        }
        if let regex = try? NSRegularExpression(pattern: #"^[A-Za-z_$][\w$]*$"#),
           regex.firstMatch(in: inner, range: NSRange(location: 0, length: (inner as NSString).length)) != nil { return functions[inner] }
        return nil
    }

    /// `body` with the blocks and expressions of the function literals inside it removed: what is left runs when the body runs.
    private static func withoutFunctionLiterals(_ body: String) -> String {
        let units = Array(body.utf16)
        func isWordUnit(_ u: UInt16) -> Bool { (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F || u == 0x24 }
        var out: [UInt16] = []
        var quote: UInt16?
        var i = 0
        while i < units.count {
            let c = units[i]
            if let q = quote {
                // The inside of a string is not code: the quotes stay, what they hold becomes blanks.
                if c == 0x5C, i + 1 < units.count { out.append(contentsOf: [0x20, 0x20]); i += 2; continue }
                if c == q { quote = nil; out.append(c) } else { out.append(0x20) }
                i += 1; continue
            }
            if c == 0x22 || c == 0x27 || c == 0x60 { quote = c; out.append(c); i += 1; continue }
            // `=>`: a block ({...}) or an expression up to the next delimiter at the same depth.
            if c == 0x3D, i + 1 < units.count, units[i + 1] == 0x3E {
                var j = i + 2
                while j < units.count, units[j] == 0x20 || units[j] == 0x0A || units[j] == 0x09 || units[j] == 0x0D { j += 1 }
                out.append(contentsOf: Array("=> 0".utf16))
                if j < units.count, units[j] == 0x7B, let close = closing(of: units, open: j) { i = close + 1; continue }
                i = skipExpression(units, from: j); continue
            }
            // `function ... (params) { ... }`
            if c == 0x66, i + 8 <= units.count, String(decoding: units[i..<(i + 8)], as: UTF16.self) == "function",
               i == 0 || !isWordUnit(units[i - 1]), i + 8 == units.count || !isWordUnit(units[i + 8]) {
                var j = i + 8
                while j < units.count, units[j] != 0x28, units[j] != 0x7B { j += 1 }
                if j < units.count, units[j] == 0x28, let params = closing(of: units, open: j) { j = params + 1 }
                while j < units.count, units[j] != 0x7B { j += 1 }
                if j < units.count, let close = closing(of: units, open: j) {
                    out.append(contentsOf: Array("function(){}".utf16)); i = close + 1; continue
                }
            }
            out.append(c); i += 1
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// The index after the expression that starts at `start`: the next `,` `;` or closing bracket at the same depth, or the end.
    private static func skipExpression(_ units: [UInt16], from start: Int) -> Int {
        var depth = 0
        var quote: UInt16?
        var i = start
        while i < units.count {
            let c = units[i]
            if let q = quote {
                if c == 0x5C { i += 2; continue }
                if c == q { quote = nil }
            } else if c == 0x22 || c == 0x27 || c == 0x60 {
                quote = c
            } else if c == 0x28 || c == 0x7B || c == 0x5B {
                depth += 1
            } else if c == 0x29 || c == 0x7D || c == 0x5D {
                if depth == 0 { return i }
                depth -= 1
            } else if depth == 0, c == 0x2C || c == 0x3B {
                return i
            }
            i += 1
        }
        return units.count
    }

    /// Whether `text` returns the host or reads its child nodes: what lets the cleared host's content end up in the returned element.
    private static func takesHost(_ name: String, in text: String) -> Bool {
        let n = NSRegularExpression.escapedPattern(for: name)
        // `[...root.children]` has the dots of the spread before the name; `a.root.children` is another object.
        let patterns = [#"(?:(?<![\w$.])|(?<=\.\.\.))"# + n + #"\s*\.\s*(?:childNodes|children|firstChild|firstElementChild|lastChild|lastElementChild)\b"#,
                        #"\breturn\s+"# + n + #"(?![\w$]|\s*[.(\[=])"#]
        let ns = text as NSString
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
        }
    }

    /// One `host.append(App.load(...))`: the host's name and the text of the call's arguments (the callback).
    private struct LoadHost { var name: String; var callback: String }

    private static func loadHosts(in code: String) -> [LoadHost] {
        let pattern = #"([A-Za-z_$][\w$]*)\s*\.\s*(?:append|appendChild|prepend|replaceChildren)\s*\(\s*App\s*\.\s*load\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = code as NSString
        var out: [LoadHost] = []
        for match in regex.matches(in: code, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1))
            let open = match.range.location + match.range.length - 1   // the "(" of App.load(
            guard let close = closing(of: Array(code.utf16), open: open) else { continue }
            out.append(LoadHost(name: name, callback: text.substring(with: NSRange(location: open, length: close - open))))
        }
        return out
    }

    /// A regular expression for the ways `name` loses its children.
    private static func clearsChildren(of name: String) -> NSRegularExpression? {
        let n = NSRegularExpression.escapedPattern(for: name)
        return try? NSRegularExpression(pattern: #"(?<![\w$.])"# + n + #"\s*\.\s*(?:replaceChildren\s*\(|(?:innerHTML|textContent|innerText)\s*=(?!=))"#)
    }

    private static func firstMatch(_ regex: NSRegularExpression?, in text: String) -> String? {
        guard let regex else { return nil }
        let ns = text as NSString
        guard let found = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: found.range).trimmingCharacters(in: .whitespaces)
    }

    /// Names followed by "(" in `text`: candidates for the calls the code makes.
    private static func calledNames(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\w$.])([A-Za-z_$][\w$]*)\s*\("#) else { return [] }
        let ns = text as NSString
        var names: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The bodies of the functions a file defines by name (`function f() {}`, `const f = function () {}`, `const f = (a) => {}`).
    private static func functionBodies(in code: String) -> [String: String] {
        let patterns = [#"function\s+([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{"#,
                        #"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:function\s*[A-Za-z_$]*\s*\([^)]*\)|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)\s*\{"#]
        let text = code as NSString
        let units = Array(code.utf16)
        var out: [String: String] = [:]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: code, range: NSRange(location: 0, length: text.length)) {
                let name = text.substring(with: match.range(at: 1))
                let open = match.range.location + match.range.length - 1   // the "{"
                guard out[name] == nil, let close = closing(of: units, open: open) else { continue }
                out[name] = text.substring(with: NSRange(location: open, length: close - open))
            }
        }
        return out
    }

    /// The index of the bracket that closes the one at `open` (UTF-16 units), skipping strings and template literals; nil when it never closes.
    private static func closing(of units: [UInt16], open: Int) -> Int? {
        guard open < units.count else { return nil }
        var depth = 0
        var quote: UInt16?
        var i = open
        while i < units.count {
            let c = units[i]
            if let q = quote {
                if c == 0x5C { i += 2; continue }          // backslash
                if c == q { quote = nil }
            } else if c == 0x22 || c == 0x27 || c == 0x60 {  // " ' `
                quote = c
            } else if c == 0x28 || c == 0x7B || c == 0x5B {  // ( { [
                depth += 1
            } else if c == 0x29 || c == 0x7D || c == 0x5D {  // ) } ]
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Planning the fix round (BUG-062)

    /// More files than this and the assistant is not asked to fix them in one answer: each file gets a run of its own.
    static let directFixLimit = 3

    /// The prototype files a problem line points to: `screens/<id>.js` and the `(file.js:line)` of a JavaScript error, in the order
    /// found and without repeats. Paths are relative to the prototype folder, as the problem lines write them.
    static func files(in problem: String) -> [String] {
        let patterns = [#"screens/[A-Za-z0-9_.\-]+\.js"#,
                        #"\(((?:[A-Za-z0-9_.\-]+/)*[A-Za-z0-9_.\-]+\.(?:js|css|html)):\d+\)"#]
        let text = problem as NSString
        var found: [(Int, String)] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: problem, range: NSRange(location: 0, length: text.length)) {
                let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                found.append((range.location, text.substring(with: range)))
            }
        }
        var out: [String] = []
        for (_, path) in found.sorted(by: { $0.0 < $1.0 }) where !out.contains(path) { out.append(path) }
        return out
    }

    /// The files the whole list of problems points to that exist in the prototype (`existing`: its editable files), without repeats.
    static func fixFiles(problems: [String], existing: Set<String>) -> [String] {
        var out: [String] = []
        for problem in problems {
            for path in files(in: problem) where existing.contains(path) && !out.contains(path) { out.append(path) }
        }
        return out
    }

    // MARK: - The rendered page

    struct Finding: Equatable {
        enum Kind: String { case blank, loading, error, unbuilt, clipped }
        var id: String
        var name: String
        var route: String
        var kind: Kind
        var sample: String
        /// `clipped` only: the heights from the box that clips the content up to the first tall ancestor, where the height is lost.
        var detail = ""
    }

    struct Report: Equatable {
        /// Screens that were opened.
        var checked = 0
        var findings: [Finding] = []
    }

    /// The report the page posts; nil for anything that is not one.
    static func report(from payload: Any?) -> Report? {
        guard let object = payload as? [String: Any], object["error"] == nil else { return nil }
        var report = Report()
        report.checked = (object["checked"] as? NSNumber)?.intValue ?? 0
        for case let item as [String: Any] in object["problems"] as? [Any] ?? [] {
            guard let kind = (item["kind"] as? String).flatMap(Finding.Kind.init(rawValue:)) else { continue }
            report.findings.append(Finding(id: item["id"] as? String ?? "", name: item["name"] as? String ?? "",
                                           route: item["route"] as? String ?? "", kind: kind,
                                           sample: String((item["sample"] as? String ?? "").prefix(100)),
                                           detail: String((item["detail"] as? String ?? "").prefix(300))))
        }
        return report
    }

    /// One line for the fix round, in the words the assistant needs to find the cause.
    static func message(for finding: Finding) -> String {
        let name = finding.name.isEmpty ? finding.id : finding.name
        let head = "Screen \"\(name)\" (#\(finding.route), screens/\(finding.id).js)"
        switch finding.kind {
        case .blank:
            return head + " renders nothing: the page has no content besides the shell. Check that its render function, and the " +
                "callback of App.load, return the content to show and not an element that is already in the page."
        case .loading:
            return head + " is still on its loading indicator four seconds after it opened: the App.load callback never finishes."
        case .error:
            let shown = finding.sample.isEmpty ? "" : " (\"\(finding.sample)\")"
            return head + " ends in an error card\(shown) instead of its content: the App.load callback fails or returns something " +
                "that cannot be shown."
        case .unbuilt:
            let shown = finding.sample.isEmpty ? "" : " (\"\(finding.sample)\")"
            return head + " is a placeholder\(shown), not the screen the plan describes."
        case .clipped:
            // Built with += : a long chain of + makes the Swift 6.0 type checker give up.
            var text = head + " has content that is in the page but cannot be seen: it sits inside a box with no height (or no width) that hides its overflow"
            if !finding.sample.isEmpty { text += " (\"\(finding.sample)\")" }
            text += "."
            if !finding.detail.isEmpty { text += " Heights from that box up to the first tall ancestor: \(finding.detail)." }
            text += " A box sized with height:100% or flex:1 collapses when its parent has no definite height. Give the host of the screen "
            text += "a definite height (a flex column with min-height:0, or an explicit height such as calc(100vh - the header)), or let "
            text += "the content size itself. Keep the content; fix the layout."
            return text
        }
    }

    /// Defines `window.__mvAudit()`, which returns a promise of `{checked, skipped, problems: [{id, name, route, kind, sample, detail}]}`.
    /// Routes with parameters and the modal routes are skipped: they need a host or an argument. Text that every route shows
    /// is the shell, so a screen is measured by what it adds to it.
    static let script = #"""
    (function () {
      if (window.__mvAudit) return;
      var CHROME = 'header,nav,aside,footer,[role="navigation"],[role="banner"],[role="contentinfo"],[data-mv-chrome]';
      var SKIP = /^(script|style|noscript|template|head|link|meta|title)$/;
      var VISUAL = /^(img|svg|canvas|video|input|select|textarea|table|iframe|progress|meter)$/;
      var UNBUILT = /still being built|not (yet )?implemented|coming soon|not available yet|under construction|placeholder|\btodo\b|не реализован|в разработке/i;
      var LOADING = '.skeleton,[aria-busy="true"]';
      // A screen is reported as clipped when at least this much of its text is hidden by collapsed boxes and that is no less than what it shows.
      var CLIPPED_MIN = 150;

      function wait(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

      // Resolves once the page has been quiet for `quiet` ms, after at least `min` and at most `max` ms.
      function settle(min, quiet, max) {
        return new Promise(function (resolve) {
          var start = Date.now(), last = start;
          var observer = new MutationObserver(function () { last = Date.now(); });
          observer.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true });
          (function tick() {
            var now = Date.now();
            if ((now - start >= min && now - last >= quiet) || now - start >= max) { observer.disconnect(); resolve(); }
            else setTimeout(tick, 60);
          })();
        });
      }

      function shown(el) {
        var style = getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden') return false;
        return !el.hidden;
      }

      // A box that hides its overflow and has no height (or no width) shows nothing of what it holds, however much that is
      // (BUG-056); a box that is only short still scrolls or shows part of it. Things hidden on purpose are not reported.
      function collapsed(el) {
        var style = getComputedStyle(el);
        if (style.overflowX === 'visible' && style.overflowY === 'visible') return false;
        if (el.getAttribute('aria-hidden') === 'true' || el.inert) return false;
        var box = el.getBoundingClientRect();
        return box.height < 8 || box.width < 8;
      }

      function describe(el) {
        var classes = typeof el.className === 'string' ? el.className.trim().split(/\s+/).filter(Boolean).slice(0, 2) : [];
        return el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (classes.length ? '.' + classes.join('.') : '');
      }

      // Where the height is lost: the box that clips, then its ancestors, up to the first one that is tall.
      function heights(el) {
        var parts = [];
        for (var node = el, n = 0; node && node !== document.body && n < 6; node = node.parentElement, n++) {
          var height = Math.round(node.getBoundingClientRect().height);
          parts.push(describe(node) + ' ' + height + 'px');
          if (height >= 200) break;
        }
        return parts.join(' < ');
      }

      // What the page shows now: its text chunks (flagged when they sit in the shell's chrome, or inside a collapsed box),
      // its visual elements outside the chrome and outside collapsed boxes, whether a loading indicator or an alert card is on screen.
      function inspect() {
        var chunks = [], visual = 0, loading = false, alertText = '';
        function walk(node, chrome, clip) {
          if (node.nodeType === 3) {
            var text = node.nodeValue.replace(/\s+/g, ' ').trim();
            if (text) chunks.push({ t: text, c: chrome, x: clip });
            return;
          }
          if (node.nodeType !== 1) return;
          var tag = node.tagName.toLowerCase();
          if (SKIP.test(tag) || node.id === 'mv-highlight' || !shown(node)) return;
          // A header, nav, aside or footer inside <main> belongs to the screen (a widget whose root is an <aside>, a page header, tabs),
          // not to the shell around it (BUG-064).
          var inChrome = chrome || (node.matches(CHROME) && !(node.closest && node.closest('main,[role="main"]')));
          if (!inChrome && !clip && collapsed(node)) clip = { heights: heights(node) };
          if (!inChrome) {
            if (VISUAL.test(tag) && !clip) visual++;
            if (node.matches(LOADING)) loading = true;
            if (node.matches('[role="status"]') && /load|загруз/i.test((node.getAttribute('aria-label') || '') + ' ' + node.textContent)) loading = true;
            if (node.matches('[role="alert"]') && !alertText) alertText = node.textContent.replace(/\s+/g, ' ').trim();
          }
          for (var child = node.firstChild; child; child = child.nextSibling) walk(child, inChrome, clip);
        }
        if (document.body) walk(document.body, false, null);
        return { chunks: chunks, visual: visual, loading: loading, alert: alertText };
      }

      async function run() {
        var plan = (window.App && Array.isArray(App.plan)) ? App.plan : [];
        var routes = plan.filter(function (s) {
          return s && typeof s.route === 'string' && s.route.charAt(0) === '/' && s.route.indexOf(':') < 0 && s.route.indexOf('/modals/') !== 0;
        });
        var origin = location.hash;
        var seen = [];
        for (var i = 0; i < routes.length; i++) {
          var target = '#' + routes[i].route;
          if (location.hash !== target) location.hash = target;
          await settle(500, 350, 4000);
          seen.push({ screen: routes[i], page: inspect() });
        }
        if (location.hash !== origin) { location.hash = origin; await wait(50); }

        // Text that most routes share belongs to the shell; with few routes only the chrome elements count. The chrome's own text is
        // left out of the count (BUG-064): a screen whose heading or button repeats a navigation label ("Studio", "Sign in" on a
        // sign-in gate) would otherwise be read as the shell and reported as blank.
        var counts = {}, minVisual = Infinity;
        seen.forEach(function (entry) {
          var once = {};
          entry.page.chunks.forEach(function (chunk) { if (!chunk.c) once[chunk.t] = true; });
          Object.keys(once).forEach(function (text) { counts[text] = (counts[text] || 0) + 1; });
          minVisual = Math.min(minVisual, entry.page.visual);
        });
        var many = seen.length >= 4, threshold = Math.max(3, Math.ceil(seen.length * 0.8));
        function shell(chunk) { return chunk.c || (many && counts[chunk.t] >= threshold); }

        var problems = [];
        seen.forEach(function (entry) {
          var page = entry.page;
          var mine = page.chunks.filter(function (chunk) { return !shell(chunk); });
          var own = mine.filter(function (chunk) { return !chunk.x; }).map(function (chunk) { return chunk.t; }).join(' ');
          var hidden = mine.filter(function (chunk) { return chunk.x; });
          var hiddenLength = hidden.reduce(function (sum, chunk) { return sum + chunk.t.length; }, 0);
          var visual = page.visual - (many ? minVisual : 0);
          var kind = '', sample = own, detail = '';
          if (page.loading) { kind = 'loading'; }
          else if (page.alert && own.length < 400) { kind = 'error'; sample = page.alert; }
          else if (hiddenLength >= CLIPPED_MIN && hiddenLength >= own.length) { kind = 'clipped'; sample = hidden[0].t; detail = hidden[0].x.heights; }
          else if (own.length === 0 && visual <= 0) { kind = 'blank'; }
          else if (own.length < 250 && visual <= 0 && UNBUILT.test(own)) { kind = 'unbuilt'; }
          if (kind) problems.push({ id: entry.screen.id || '', name: entry.screen.name || '', route: entry.screen.route, kind: kind, sample: sample.slice(0, 100), detail: detail.slice(0, 300) });
        });
        return { checked: seen.length, skipped: plan.length - routes.length, problems: problems };
      }

      window.__mvAudit = function () { return run(); };
    })();
    """#
}
