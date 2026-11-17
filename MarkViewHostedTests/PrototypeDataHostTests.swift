import AppKit
import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

extension EditorHostTests {
    @MainActor func testPrototypeImageAttachments() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        func makeImage(_ width: Int, _ height: Int) -> NSImage {
            let image = NSImage(size: NSSize(width: width, height: height))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            image.unlockFocus()
            return image
        }

        // Normalising to PNG, the pasteboard and the limits are checked in image-attachments-tests.sh; here is where Prototype Studio
        // keeps the images it sends.
        let png = ImageAttachments.pngData(from: makeImage(200, 100))!
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proto-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let saved = try PrototypeImages.save(png, in: tmp)
        check(saved.deletingLastPathComponent().lastPathComponent == "attachments" && saved.pathExtension == "png", "saved under attachments/")
        check(saved.deletingLastPathComponent().deletingLastPathComponent().path == tmp.path, "attachments/ is in the prototype's folder")
        check((try Data(contentsOf: saved)) == png, "saved bytes are the PNG")
        let other = try PrototypeImages.save(png, in: tmp)
        check(other != saved, "every image is a new file")
    }
}

extension EditorHostTests {
    func testPrototypeReferences() throws {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + detail, line: line)
        }
        // MARK: String

        check(PrototypeReference.scheme == "markview" && PrototypeReference.host == "prototype", "scheme and host")
        check(PrototypeReference.storageFolder == "docs/prototypes" && PrototypeReference.storageFolder == PrototypeFiles.storageFolder,
              "the storage folder is PrototypeFiles' (DEC-006)")
        check(PrototypeReference.legacyStorageFolder == ".dde/prototypes" && PrototypeReference.legacyStorageFolder == PrototypeFiles.legacyStorageFolder,
              "the legacy storage folder is PrototypeFiles'")
        check(PrototypeReference.string(slug: "order-tracking") == "markview://prototype/order-tracking", "the reference string")
        check(PrototypeReference.parse(PrototypeReference.string(slug: "shop-2")) == "shop-2", "a reference string parses back to its slug")

        // MARK: Accepted forms

        let forms: [(String, String)] = [
            ("markview://prototype/shop", "URI"),
            ("markview://prototype/shop/", "URI with trailing slash"),
            ("MARKVIEW://Prototype/shop", "URI scheme and host are case-insensitive"),
            ("  markview://prototype/shop\n", "surrounding whitespace is trimmed"),
            ("shop", "bare slug"),
            ("docs/prototypes/shop", "project-relative path"),
            ("docs/prototypes/shop/", "project-relative path with trailing slash"),
            ("./docs/prototypes/shop", "project-relative path with a leading dot"),
            ("docs/prototypes/shop/site", "the site folder"),
            ("docs/prototypes/shop/site/", "the site folder with trailing slash"),
            ("docs/prototypes/shop/versions/v3", "a version folder"),
            ("/Users/boris/github.com/App/docs/prototypes/shop", "absolute path"),
            ("/Users/boris/github.com/App/docs/prototypes/shop/site", "absolute path to the site"),
            ("/Users/boris/github.com/App/docs/prototypes/shop/versions/v12/", "absolute path to a version"),
            (".dde/prototypes/shop", "legacy project-relative path"),
            (".dde/prototypes/shop/", "legacy project-relative path with trailing slash"),
            ("./.dde/prototypes/shop", "legacy project-relative path with a leading dot"),
            (".dde/prototypes/shop/site", "the legacy site folder"),
            (".dde/prototypes/shop/versions/v3", "a legacy version folder"),
            ("/Users/boris/github.com/App/.dde/prototypes/shop", "legacy absolute path"),
            ("/Users/boris/github.com/App/.dde/prototypes/shop/site", "legacy absolute path to the site"),
            ("/Users/boris/github.com/App/.dde/prototypes/shop/versions/v12/", "legacy absolute path to a version"),
            ("markview://prototype/shop/versions/v2", "URI with a version folder"),
        ]
        for (text, name) in forms {
            check(PrototypeReference.parse(text) == "shop", "parses \(name): \(text.debugDescription)", "\(String(describing: PrototypeReference.parse(text)))")
        }
        check(PrototypeReference.parse("order_tracking-2") == "order_tracking-2", "a slug may hold dashes and underscores")
        check(PrototypeReference.parse("заказы") == "заказы", "a slug may hold non-ASCII letters, as PrototypeFiles.slug makes them")

        // MARK: Version: read, reported, never required

        check(PrototypeReference.components("docs/prototypes/shop/versions/v3") == .init(slug: "shop", version: 3), "the version folder is reported")
        check(PrototypeReference.components("/x/docs/prototypes/shop/versions/v12/") == .init(slug: "shop", version: 12), "a multi-digit version is read")
        check(PrototypeReference.components("/x/.dde/prototypes/shop/versions/v4") == .init(slug: "shop", version: 4), "a legacy version folder is reported")
        check(PrototypeReference.components("markview://prototype/shop")?.version == nil, "a plain reference carries no version")
        check(PrototypeReference.components("docs/prototypes/shop/site")?.version == nil, "the site is the latest version")

        // MARK: Rejected

        let rejected: [(String, String)] = [
            ("", "empty"),
            ("   ", "blank"),
            ("markview://prototype/", "URI without a slug"),
            ("markview://prototype", "URI without a path"),
            ("markview://feature/shop", "another host"),
            ("https://prototype/shop", "another scheme"),
            ("markview:prototype/shop", "not a URI"),
            ("markview://prototype/shop/site/index.html", "a file inside the site"),
            ("markview://prototype/shop/prototype.json", "the manifest"),
            ("markview://prototype/shop/versions", "versions without a number"),
            ("markview://prototype/shop/versions/3", "a version without v"),
            ("markview://prototype/shop/versions/v0", "version zero"),
            ("markview://prototype/shop/versions/vX", "a non-numeric version"),
            ("markview://prototype/shop/versions/v1/index.html", "a file inside a version"),
            ("markview://prototype/../shop", "dot-dot in the URI"),
            ("markview://prototype/shop/..", "dot-dot after the slug"),
            (".dde/prototypes/../shop", "dot-dot in a relative path"),
            ("/x/../.dde/prototypes/shop", "dot-dot before the storage folder"),
            ("/x/.dde/prototypes/shop/../other", "dot-dot after the slug in an absolute path"),
            ("..", "dot-dot alone"),
            ("../shop", "a parent path"),
            ("a/b", "a path that is not the storage layout"),
            ("docs/.dde/prototypes/shop", "a relative path that does not start with a storage folder"),
            ("src/docs/prototypes/shop", "a relative path that does not start with the storage folder"),
            ("docs/prototypes", "the storage folder alone"),
            ("docs/prototypes/", "the storage folder alone with a slash"),
            ("/x/docs/prototypes", "an absolute storage folder without a slug"),
            ("docs/prototypes/.hidden", "a hidden name"),
            ("docs/prototypes/shop/other", "another folder under the prototype"),
            ("docs/prototypes/shop/site/x", "a file under the site"),
            ("docs/prototypes/shop/site/index.html", "a file inside the site, path form"),
            ("docs/features/shop", "another folder under docs"),
            ("prototypes/shop", "the storage folder without docs"),
            (".dde/prototypes", "the legacy storage folder alone"),
            ("/x/.dde/prototypes", "an absolute legacy storage folder without a slug"),
            (".dde/prototypes/shop/other", "another folder under a legacy prototype"),
            ("docs/prototypes/../shop", "dot-dot in a docs path"),
            ("shop v3", "a slug with a space"),
            ("shop?x=1", "a slug with a query"),
            ("shop#top", "a slug with a fragment"),
            ("a\\b", "a backslash"),
            (".dde/other/shop", "another folder under .dde"),
        ]
        for (text, name) in rejected {
            check(PrototypeReference.parse(text) == nil, "rejects \(name): \(text.debugDescription)", "\(String(describing: PrototypeReference.parse(text)))")
        }
    }
}

extension EditorHostTests {
    func testPrototypeThemeDiscovery() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        // Themes found in copied stylesheets (feature "Themes in a prototype made from code", REQ-001).
        do {
            let strikedesk = """
            :root { --bg: #111; }
            /* the first theme */
            [data-theme="dark"] { --bg: #000; }
            [data-theme='midnight'], html[data-theme=midnight] .panel { --bg: #001; }
            @media (min-width: 800px) { :root[data-theme="terminal"] { --bg: #020; } }
            body[data-theme="tastytrade"] { --bg: #123; }
            [data-theme="dark"] .card { color: red; }
            """
            let found = PrototypeThemes.scan(stylesheets: [strikedesk])
            check(found?.attribute == "data-theme" && found?.ids == ["dark", "midnight", "terminal", "tastytrade"],
                  "ids in order of first appearance, root forms and bare attribute, without repeats: \(String(describing: found))")
            check(PrototypeThemes.scan(stylesheets: [":root { --a: 1 } .card { color: red }"]) == nil, "no theme selector, no theme")
            check(PrototypeThemes.scan(stylesheets: ["[data-theme=\"dark\"] { color: #fff }"]) == nil, "an attribute that selects one value is not a theme switch")
            check(PrototypeThemes.scan(stylesheets: [".card[data-theme=\"a\"] {} .box[data-theme=\"b\"] {} main [data-theme=\"c\"] {}"]) == nil,
                  "an attribute on a component or below the root is not a root theme")
            check(PrototypeThemes.scan(stylesheets: ["/* [data-theme=\"a\"] {} [data-theme=\"b\"] {} */ .x { y: z }"]) == nil, "selectors in comments do not count")
            check(PrototypeThemes.scan(stylesheets: ["[data-theme=\"a\"] {}", "[data-theme=\"b\"] {} [data-theme=\"a\"] {}"])?.ids == ["a", "b"],
                  "themes are collected across stylesheets")
            let mixed = PrototypeThemes.scan(stylesheets: ["[data-density=\"compact\"] {} [data-density=\"roomy\"] {} [data-color-scheme=\"light\"] {} [data-color-scheme=\"dark\"] {} [data-color-scheme=\"sepia\"] {}"])
            check(mixed?.attribute == "data-color-scheme" && mixed?.ids == ["light", "dark", "sepia"], "only theme-like attributes count, the one with most values wins: \(String(describing: mixed))")
            check(PrototypeThemes.scan(stylesheets: ["[data-bs-theme=\"light\"] {} [data-bs-theme=\"dark\"] {}"])?.attribute == "data-bs-theme", "data-bs-theme is a theme attribute")

            // The record keeps what is still valid.
            let ids = (attribute: "data-theme", ids: ["dark", "midnight", "tastytrade"])
            let fresh = PrototypeThemes.record(found: ids, defaultID: "tastytrade", previous: nil)
            check(fresh == PrototypeFiles.ThemeRecord(attribute: "data-theme", ids: ids.ids, defaultID: "tastytrade", chosen: nil) && fresh?.effective == "tastytrade",
                  "the default the build recorded is the effective theme before any choice")
            check(PrototypeThemes.record(found: ids, defaultID: nil, previous: nil)?.effective == nil, "no recorded default and no choice keeps the prototype's own look")
            check(PrototypeThemes.record(found: ids, defaultID: "neon", previous: nil)?.defaultID == nil, "a default that is not among the themes is dropped")
            var chosen = fresh!; chosen.chosen = "midnight"
            check(chosen.effective == "midnight", "the choice wins over the default")
            let after = PrototypeThemes.record(found: ids, defaultID: nil, previous: chosen)
            check(after?.chosen == "midnight" && after?.defaultID == "tastytrade", "a sync keeps the choice and the earlier default: \(String(describing: after))")
            let gone = PrototypeThemes.record(found: (attribute: "data-theme", ids: ["dark", "light"]), defaultID: nil, previous: chosen)
            check(gone?.chosen == nil && gone?.defaultID == nil && gone?.effective == nil, "a choice that no longer exists is dropped")
            check(PrototypeThemes.record(found: (attribute: "data-mode", ids: ["a", "b"]), defaultID: nil, previous: chosen)?.chosen == nil,
                  "a choice for another attribute is dropped")
            check(PrototypeThemes.record(found: nil, defaultID: "x", previous: chosen) == nil, "no themes found, no record")

            // StrikeDesk: `dark` is the base look with no selector, so the planner's ids add it and give the order.
            let scanned3 = (attribute: "data-theme", ids: ["midnight", "tastytrade", "terminal"])
            let planned = PrototypeThemes.record(found: scanned3, planned: ["dark", "midnight", "terminal", "tastytrade"], defaultID: "tastytrade", previous: nil)
            check(planned?.ids == ["dark", "midnight", "terminal", "tastytrade"] && planned?.effective == "tastytrade", "the planner adds the base theme and the order: \(String(describing: planned))")
            check(PrototypeThemes.record(found: scanned3, planned: ["dark"], defaultID: nil, previous: nil)?.ids == ["dark", "midnight", "tastytrade", "terminal"],
                  "ids the planner did not list still come from the stylesheets")
            check(PrototypeThemes.record(found: nil, planned: ["a", "b"], defaultID: "a", previous: nil) == nil, "the planner alone cannot create a picker")
            var original = planned!; original.chosen = ""
            check(original.effective == nil, "the empty choice is the original look: no attribute")
            check(PrototypeThemes.record(found: scanned3, planned: ["dark"], defaultID: nil, previous: original)?.chosen == "", "a sync keeps the original-look choice")

            // The scripts never paste text raw.
            let hostile = PrototypeThemes.startScript(attribute: "data-theme", id: "a\"); alert(1); (\"")
            check(!hostile.contains("alert(1); (\"") || hostile.contains("\\\"); alert(1); (\\\""), "ids are JSON-escaped in the start script: \(hostile)")

            // Codable: an old manifest has no themes.
            let old = #"{"title":"T","slug":"t","brief":"","sources":[]}"#.data(using: .utf8)!
            let manifest = try? JSONDecoder().decode(PrototypeFiles.Manifest.self, from: old)
            check(manifest != nil && manifest?.themes == nil, "a manifest without themes still decodes")
            if var m = manifest {
                m.themes = fresh
                let round = (try? JSONEncoder().encode(m)).flatMap { try? JSONDecoder().decode(PrototypeFiles.Manifest.self, from: $0) }
                check(round?.themes == fresh, "the record round-trips through the manifest")
            }

            // Reading a site: the stylesheets linked from index.html come first, the rest by path.
            let fm = FileManager.default
            let site = fm.temporaryDirectory.appendingPathComponent("mv-themes-" + UUID().uuidString)
            defer { try? fm.removeItem(at: site) }
            func put(_ path: String, _ text: String) throws {
                let url = site.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            try put("index.html", "<link rel=\"stylesheet\" href=\"original/b/second.css\"><link rel=\"stylesheet\" href=\"original/a/first.css\"><link rel=\"stylesheet\" href=\"styles.css\">")
            try put("original/a/first.css", "[data-theme=\"two\"] {}")
            try put("original/b/second.css", "[data-theme=\"one\"] {}")
            try put("original/c/unlinked.css", "[data-theme=\"three\"] {}")
            try put("original/fonts/f.woff2", "x")
            try put("styles.css", "[data-theme=\"never\"] {}")
            let scanned = PrototypeThemes.scan(site: site)
            check(scanned?.ids == ["one", "two", "three"], "linked stylesheets first in link order, then the rest; styles.css is not an original: \(String(describing: scanned))")
            check(PrototypeThemes.scan(site: site.appendingPathComponent("nowhere")) == nil, "a site without originals has no themes")
        }
    }
}

extension EditorHostTests {
    func testPrototypeFixRoundAnalysis() {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        // 1. The files a problem names.
        let blank = PrototypeAudit.message(for: .init(id: "trade", name: "Trade", route: "/widgets/trade", kind: .blank, sample: ""))
        check(PrototypeAudit.files(in: blank) == ["screens/trade.js"], "a screen finding names its script: \(PrototypeAudit.files(in: blank))")
        check(PrototypeAudit.files(in: "TypeError: Attempted to assign to readonly property. (app.js:93)") == ["app.js"], "a runtime error names its file")
        check(PrototypeAudit.files(in: "boom (screens/trade.js:12) after screens/home.js ran") == ["screens/trade.js", "screens/home.js"], "order of appearance, no repeats")
        check(PrototypeAudit.files(in: "ResizeObserver loop completed with undelivered notifications.").isEmpty, "an error without a file names none")
        check(PrototypeAudit.files(in: "x (original/theme.css:3)") == ["original/theme.css"], "the pattern itself does not judge the folder")
        let existing: Set<String> = ["app.js", "screens/trade.js", "screens/home.js", "data.js"]
        let problems = [blank, "TypeError: x (app.js:93)", "y (original/theme.css:3)", "z (screens/ghost.js:1)", blank,
                        "Screen \"Home\" (#/, screens/home.js) is a placeholder"]
        check(PrototypeAudit.fixFiles(problems: problems, existing: existing) == ["screens/trade.js", "app.js", "screens/home.js"],
              "only files of the prototype, once each, in order: \(PrototypeAudit.fixFiles(problems: problems, existing: existing))")
        check(PrototypeAudit.directFixLimit == 3, "up to three files go to one run")

        // 2. The loader defect, as strikedesk's trade.js wrote it.
        let trade = """
        App.register({
          id: 'trade',
          render: function (ctx) {
            var root = h('div', { className: 'sd-widget' });
            function draw() {
              var layout = h('div', { className: 'layout' });
              root.replaceChildren(toolbar(), layout);
            }
            function drawLoading() { root.replaceChildren(h('div', 'Chain Loading…')); setTimeout(draw, 350); }
            root.append(App.load(function () { var content = h('div'); draw(); content.append.apply(content, Array.from(root.childNodes)); return content; }));
            return root;
          }
        });
        """
        let hit = PrototypeAudit.loadProblem(id: "trade", content: trade)
        check(hit != nil, "the strikedesk trade.js pattern is found")
        check(hit?.hasPrefix("screens/trade.js:") == true && hit?.contains("root.replaceChildren(") == true && hit?.contains("through draw()") == true,
              "the message names the file, the call and the function: \(hit ?? "nil")")
        check(PrototypeAudit.files(in: hit ?? "") == ["screens/trade.js"], "the lint message points to the screen file for the fix round")

        // The host is cleared before the callback returns and the callback takes the host or its children: directly, with innerHTML or
        // textContent, with an arrow function, and through two levels of calls.
        check(PrototypeAudit.loadProblem(id: "a", content: "host.append(App.load(() => { host.innerHTML = ''; return host; }));") != nil, "innerHTML, then the host is returned")
        check(PrototypeAudit.loadProblem(id: "a", content: "const el = h('div'); el.appendChild(App.load(function () { el.textContent = ''; const kids = [...el.children]; return wrap(kids); }));") != nil,
              "textContent, then the children are taken")
        let deep = """
        const draw = () => { paint(); };
        function paint() { box.replaceChildren(a, b); }
        box.append(App.load(() => { draw(); const out = h('div'); out.append(box.firstChild); return out; }));
        """
        check(PrototypeAudit.loadProblem(id: "a", content: deep) != nil, "a call two levels down")

        // What is fine: the shapes the other screens of strikedesk use.
        let activity = """
        function draw() { root.replaceChildren(toolbar, rows); }
        return App.load(function () { draw(); return root; });
        """
        check(PrototypeAudit.loadProblem(id: "activity", content: activity) == nil, "the loader is returned, not appended to the cleared element")
        let roll = """
        host.append(App.load(() => {
          const content = h('div');
          content.replaceChildren(a, b);
          return content;
        }));
        """
        check(PrototypeAudit.loadProblem(id: "roll", content: roll) == nil, "the callback clears its own content, not the host")
        check(PrototypeAudit.loadProblem(id: "x", content: "root.append(App.load(() => build()));\nfunction later() { root.replaceChildren(); }") == nil,
              "a function the callback never calls may clear the host")
        check(PrototypeAudit.loadProblem(id: "x", content: "// root.append(App.load(() => { root.innerHTML = ''; return root; }))\nconst a = 1;") == nil, "a comment is not code")
        check(PrototypeAudit.loadProblem(id: "x", content: "root.append(App.load(() => build()));\nroot.innerHTML == '';") == nil, "a comparison is not an assignment")
        check(PrototypeAudit.loadProblem(id: "x", content: "App.register({id: 'x', render() { return h('div'); }});") == nil, "no loader, no finding")

        // BUG-064: shapes of the vivaa client-web-app that 5.13.1 flagged although the screens work.
        let retry = """
        let slot = h('div');
        function loadAnswer() {
          slot.replaceChildren(App.load(async () => {
            try { return await fetchRows(); }
            catch (_) { return h('div', {}, h('button', { onClick: () => loadAnswer() }, 'Try again')); }
          }));
        }
        """
        check(PrototypeAudit.loadProblem(id: "gallery", content: retry) == nil, "a retry handler inside the callback runs later, not before the callback returns")
        let nested = """
        tab.replaceChildren(App.load(async () => {
          const orders = await DB.list('Order');
          const draw = () => tab.replaceChildren(table(orders));
          return h('div', {}, orders.map(o => cover(o)), h('button', { onClick: function () { draw(); } }, 'Refresh'));
        }));
        function cover(o) { return h('img', {}); }
        """
        check(PrototypeAudit.loadProblem(id: "orders", content: nested) == nil, "function literals inside the callback are not read")
        // The host's children are taken, and the host is cleared only by a click handler, which runs long after the callback returned.
        let handler = """
        box.append(App.load(() => {
          const reset = h('button', { onClick: () => box.replaceChildren(rows) }, 'Reset');
          return [...box.children].length ? reset : h('div', {}, reset);
        }));
        """
        check(PrototypeAudit.loadProblem(id: "handler", content: handler) == nil, "clearing inside a click handler is not clearing before the callback returns")
        let drawsIn = """
        root.append(App.load(() => { paint(); }));
        function paint() { root.replaceChildren(a, b); }
        """
        check(PrototypeAudit.loadProblem(id: "drawsin", content: drawsIn) == nil, "a callback that draws into the host and takes nothing from it leaves a working screen")
        let quoted = "root.append(App.load(() => { const s = 'x => { root.replaceChildren(); return root }'; return h('p', {}, s); }));"
        check(PrototypeAudit.loadProblem(id: "q", content: quoted) == nil, "text inside a string is not code")
    }
}
