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

    // MARK: - The rendered page

    struct Finding: Equatable {
        enum Kind: String { case blank, loading, error, unbuilt }
        var id: String
        var name: String
        var route: String
        var kind: Kind
        var sample: String
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
                                           sample: String((item["sample"] as? String ?? "").prefix(100))))
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
        }
    }

    /// Defines `window.__mvAudit()`, which returns a promise of `{checked, skipped, problems: [{id, name, route, kind, sample}]}`.
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

      // What the page shows now: its text chunks (flagged when they sit in the shell's chrome), its visual elements
      // outside the chrome, whether a loading indicator or an alert card is on screen.
      function inspect() {
        var chunks = [], visual = 0, loading = false, alertText = '';
        function walk(node, chrome) {
          if (node.nodeType === 3) {
            var text = node.nodeValue.replace(/\s+/g, ' ').trim();
            if (text) chunks.push({ t: text, c: chrome });
            return;
          }
          if (node.nodeType !== 1) return;
          var tag = node.tagName.toLowerCase();
          if (SKIP.test(tag) || node.id === 'mv-highlight' || !shown(node)) return;
          var inChrome = chrome || node.matches(CHROME);
          if (!inChrome) {
            if (VISUAL.test(tag)) visual++;
            if (node.matches(LOADING)) loading = true;
            if (node.matches('[role="status"]') && /load|загруз/i.test((node.getAttribute('aria-label') || '') + ' ' + node.textContent)) loading = true;
            if (node.matches('[role="alert"]') && !alertText) alertText = node.textContent.replace(/\s+/g, ' ').trim();
          }
          for (var child = node.firstChild; child; child = child.nextSibling) walk(child, inChrome);
        }
        if (document.body) walk(document.body, false);
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

        // Text that most routes share belongs to the shell; with few routes only the chrome elements count.
        var counts = {}, minVisual = Infinity;
        seen.forEach(function (entry) {
          var once = {};
          entry.page.chunks.forEach(function (chunk) { once[chunk.t] = true; });
          Object.keys(once).forEach(function (text) { counts[text] = (counts[text] || 0) + 1; });
          minVisual = Math.min(minVisual, entry.page.visual);
        });
        var many = seen.length >= 4, threshold = Math.max(3, Math.ceil(seen.length * 0.8));
        function shell(chunk) { return chunk.c || (many && counts[chunk.t] >= threshold); }

        var problems = [];
        seen.forEach(function (entry) {
          var page = entry.page;
          var own = page.chunks.filter(function (chunk) { return !shell(chunk); }).map(function (chunk) { return chunk.t; }).join(' ');
          var visual = page.visual - (many ? minVisual : 0);
          var kind = '', sample = own;
          if (page.loading) { kind = 'loading'; }
          else if (page.alert && own.length < 400) { kind = 'error'; sample = page.alert; }
          else if (own.length === 0 && visual <= 0) { kind = 'blank'; }
          else if (own.length < 250 && visual <= 0 && UNBUILT.test(own)) { kind = 'unbuilt'; }
          if (kind) problems.push({ id: entry.screen.id || '', name: entry.screen.name || '', route: entry.screen.route, kind: kind, sample: sample.slice(0, 100) });
        });
        return { checked: seen.length, skipped: plan.length - routes.length, problems: problems };
      }

      window.__mvAudit = function () { return run(); };
    })();
    """#
}
