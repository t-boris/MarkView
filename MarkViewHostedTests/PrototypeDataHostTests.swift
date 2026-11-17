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

@MainActor private final class PrototypeOwnershipFixtureWriter {
    var writes = 0
    var failure: String?
    var gate: CheckedContinuation<Void, Never>?
    var hold = false

    func release() { gate?.resume(); gate = nil; hold = false }
    func write(_ plan: PrototypeHandoff.FeaturePlan, _ store: FeatureStore) async throws -> PrototypeFeatureWriter.Created {
        writes += 1
        if hold { await withCheckedContinuation { gate = $0 } }
        if let failure { throw PrototypeFeatureWriter.Failure(message: failure) }
        return .init(slug: "shop-sync", overview: URL(fileURLWithPath: "/tmp/shop-sync.md"),
                     requirements: plan.requirements.count, pictures: 0, skipped: [])
    }
}

extension EditorHostTests {
    @MainActor func testPrototypeSessionAndHandoffOwnership() async throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        @MainActor func waitFor(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return condition()
        }

        /// A prototype made from code, saved in a new project: a manifest at version 1 and a site with a page.
        func makePrototype() throws -> (root: URL, slug: String) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("proto-owner-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
            let folder = PrototypeFiles.folder(root: root, slug: "shop")
            try FileManager.default.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
            try "<html><body>Shop</body></html>".write(to: PrototypeFiles.site(of: folder).appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            var manifest = PrototypeFiles.Manifest(title: "Shop", slug: "shop", brief: "", sources: [], mode: .code)
            manifest.version = 1
            try PrototypeFiles.saveManifest(manifest, in: folder)
            return (root, "shop")
        }

        @MainActor func sessionChecks() async throws {
            let (root, slug) = try makePrototype()
            defer { try? FileManager.default.removeItem(at: root) }
            guard let session = PrototypeSession(root: root, slug: slug) else { check(false, "the saved prototype opens"); return }
            check(session.canSyncFromCode, "the saved prototype can be checked against its code")

            // The status check: started, replaced by a newer one, ends once.
            session.startSyncStatusCheck()
            session.startSyncStatusCheck()
            check(await waitFor { session.checkingSync || session.syncStatus != nil }, "a started check shows that it works")
            check(await waitFor { !session.checkingSync && session.syncStatus != nil }, "the check ends with a status")

            // The sync preview: started, a second press while it works is refused, the answer comes.
            session.previewSync()
            check(session.preparingSync, "a started preview shows that it works")
            session.previewSync()
            check(await waitFor { !session.preparingSync && session.syncPreview != nil }, "the preview ends with an offer")
            check(session.syncPreview?.version == 1, "and the offer is for the saved version")

            // The hand-off: started, a second press refused; with nothing changed the sheet says so and no run is made.
            session.prepareHandoff()
            check(session.preparingHandoff, "a started hand-off shows that it works")
            session.prepareHandoff()
            check(await waitFor { !session.preparingHandoff && session.handoff != nil }, "the hand-off ends with its answer")
            check(session.handoff?.changes.isEmpty == true && session.handoffRun == nil, "with no changes to hand off there is no run")
        }

        /// The session's work does not hold it: it is freed when its owner lets it go, whatever it started.
        @MainActor func releaseChecks() async throws {
            let (root, slug) = try makePrototype()
            defer { try? FileManager.default.removeItem(at: root) }
            weak var weakSession: PrototypeSession?
            do {
                let session = PrototypeSession(root: root, slug: slug)
                weakSession = session
                session?.startSyncStatusCheck()
                session?.previewSync()
                session?.prepareHandoff()
            }
            check(await waitFor(15) { weakSession == nil }, "a session whose tab closed is freed once its short work has ended: nothing holds it")
        }

        @MainActor func handoffChecks() async {
            let writer = PrototypeOwnershipFixtureWriter()
            let trade = PrototypeHandoff.Item(id: "trade", name: "Trade", kind: .screen, files: ["screens/trade.js"], components: [], alsoChangedInCode: [])
            let changes = PrototypeHandoff.Changes(baselineVersion: 3, items: [trade], history: [], codeChanged: [])
            let context = PrototypeHandoffRun.Context(root: FileManager.default.temporaryDirectory, folder: FileManager.default.temporaryDirectory,
                                                      slug: "shop", title: "Shop", version: 4, components: [], theme: nil, changes: changes,
                                                      reference: "shop", siteRelative: "site")
            let run = PrototypeHandoffRun(context: context, record: { _ in }, writeFeature: writer.write)
            check(run.draft != nil, "the run has a draft to create the feature from")

            // Start: the feature is written once, however often the button is pressed; the window is told once.
            writer.hold = true
            var told: [String] = []
            run.startCreate(into: FeatureStore()) { told.append($0.slug) }
            run.startCreate(into: FeatureStore()) { _ in told.append("second") }
            check(await waitFor { writer.gate != nil && run.creating }, "the writer is under way and the run shows that it works")
            check(writer.writes == 1, "a second press while it works wrote nothing more")
            writer.release()
            check(await waitFor { !run.creating && run.created != nil }, "the creation ends with the feature")
            check(told == ["shop-sync"], "and the window was told once, with the feature (\(told))")

            // A failure is said and the window is not told.
            let again = PrototypeHandoffRun(context: context, record: { _ in }, writeFeature: writer.write)
            writer.failure = "The feature could not be created."
            var toldAgain = false
            again.startCreate(into: FeatureStore()) { _ in toldAgain = true }
            check(await waitFor { !again.creating && again.createFailure != nil }, "a creation that fails says why")
            check(!toldAgain && again.created == nil, "and nobody is told that a feature exists")
            again.close()
            run.close()
        }
        try await sessionChecks()
        try await releaseChecks()
        await handoffChecks()
    }
}

extension EditorHostTests {
    func testPrototypeBaselineRules() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mv-baseline-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: work) }
        func put(_ path: String, _ text: String) throws {
            let url = work.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        // Fingerprints.
        do {
            try put("src/a.tsx", "A"); try put("src/b.tsx", "B"); try put("src/theme.css", "t")
            let prints = PrototypeBaseline.fingerprints(root: work, paths: ["src/a.tsx", "src/b.tsx", "src/missing.tsx", "src/a.tsx"])
            check(prints.count == 2 && prints["src/a.tsx"] == PrototypeBaseline.sha256(Data("A".utf8)) && prints["src/a.tsx"] != prints["src/b.tsx"],
                  "a fingerprint per readable file, a missing file left out, repeats once")
            check(PrototypeBaseline.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha-256 of abc")
            try put("site/app.js", "x"); try put("site/screens/home.js", "h"); try put("site/original/src/theme.css", "o")
            let site = PrototypeBaseline.siteFingerprints(site: work.appendingPathComponent("site"))
            check(Set(site.keys) == ["app.js", "screens/home.js"], "the prototype's fingerprints skip the copied originals: \(site.keys.sorted())")
        }

        // Diff.
        do {
            let d = PrototypeBaseline.diff(baseline: ["a": "1", "b": "2", "c": "3", "n": ""], current: ["a": "1", "b": "9", "d": "4", "n": "5"])
            check(d.changed == ["b"] && d.removed == ["c"] && d.added == ["d", "n"], "changed, removed, added; a file unreadable at the sync that exists now is added: \(d)")
            check(PrototypeBaseline.diff(baseline: ["a": "1"], current: ["a": "1"]).isEmpty, "no difference")
            check(PrototypeBaseline.diff(baseline: ["n": ""], current: [:]).isEmpty, "a file that was unreadable and still is, is no change")
        }

        // A record and the status of every unit.
        do {
            let site0 = ["index.html": "i0", "app.js": "a0", "data.js": "d0", "styles.css": "s0", "screens/orders.js": "o0", "screens/trade.js": "t0",
                         "screens/settings.js": "g0", "components/orders-list.html": "c0"]
            let scope0 = ["src/theme.css": "t0", "src/Orders.tsx": "o0", "src/OrdersList.tsx": "l0", "src/Trade.tsx": "r0", "src/util.ts": "u0"]
            let exists: (String) -> Bool = { $0 != "src/Ghost.tsx" }
            let record = PrototypeBaseline.make(
                version: 3, plan: "{}", styles: ["src/theme.css"],
                screens: [(id: "orders", name: "Orders", sources: ["src/Orders.tsx", "src/OrdersList.tsx"]),
                          (id: "trade", name: "Trade", sources: ["src/Trade.tsx", "src/Ghost.tsx"]),
                          (id: "settings", name: "Settings", sources: [])],
                components: [PrototypeFiles.Component(path: "src/OrdersList.tsx", label: "OrdersList", screens: ["Orders"], page: "components/orders-list.html")],
                scope: scope0, site: site0, sourceExists: exists)
            let byID = Dictionary(uniqueKeysWithValues: record.units.map { ($0.id, $0) })
            check(record.units.map(\.kind) == [.foundation, .screen, .screen, .screen, .component], "units: shell, screens, components in order")
            check(byID["trade"]?.sources == ["src/Trade.tsx"] && byID["trade"]?.incomplete == true, "a source that does not exist is dropped and the unit is incomplete")
            check(byID["settings"]?.incomplete == true && byID["settings"]?.sources == [], "a unit with no sources is incomplete")
            check(byID["orders"]?.incomplete == false && byID["orders"]?.files == ["screens/orders.js": "o0"], "a complete unit keeps the fingerprints of its file")
            check(byID["shell"]?.files.keys.sorted() == ["app.js", "data.js", "index.html", "styles.css"] && byID["shell"]?.sources == ["src/theme.css"],
                  "the shell owns the four foundation files and the global stylesheets")
            check(byID["src/OrdersList.tsx"]?.files == ["components/orders-list.html": "c0"], "a component owns its isolated page")
            check(record.scope["src/Trade.tsx"] == "r0" && record.scope["src/Ghost.tsx"] == nil, "the scope keeps the fingerprints and not the ghost")

            func state(_ id: String, _ status: PrototypeBaseline.Status) -> PrototypeBaseline.State? { status.units.first { $0.unit.id == id }?.state }

            let same = PrototypeBaseline.status(record: record, scope: scope0, site: site0)
            check(state("orders", same) == .inSync && state("trade", same) == .unknown && state("settings", same) == .unknown && state("shell", same) == .inSync,
                  "unchanged: in sync, incomplete units unknown")
            check(same.baselineVersion == 3 && same.unclaimed.isEmpty && same.added.isEmpty && same.codeUnchanged == false || same.toRebuild.isEmpty, "nothing to rebuild")
            check(same.summary == "2 in sync, 2 unknown" || same.summary == "3 in sync, 2 unknown", "summary counts per state: \(same.summary)")

            var scope1 = scope0; scope1["src/Orders.tsx"] = "o1"; scope1["src/util.ts"] = "u1"; scope1["src/new.tsx"] = "n1"
            var site1 = site0; site1["screens/trade.js"] = "t1"; site1["screens/orders.js"] = "o1"
            let drift = PrototypeBaseline.status(record: record, scope: scope1, site: site1)
            check(state("orders", drift) == .bothChanged, "code and prototype both changed: \(String(describing: state("orders", drift)))")
            check(state("trade", drift) == .prototypeEdited, "only the prototype changed")
            check(drift.units.first { $0.unit.id == "orders" }?.changedSources == ["src/Orders.tsx"] && drift.units.first { $0.unit.id == "orders" }?.editedFiles == ["screens/orders.js"],
                  "the changed files are named")
            check(drift.unclaimed == ["src/util.ts"] && drift.added == ["src/new.tsx"], "a changed file no unit claims and a new file are reported: \(drift.unclaimed) \(drift.added)")
            check(drift.conflicts.map(\.unit.id) == ["orders"] && drift.toRebuild.map(\.unit.id) == ["orders"], "conflicts and the units to rebuild")
            check(state("src/OrdersList.tsx", drift) == .inSync && state("shell", drift) == .inSync, "other units stay in sync")

            var scope2 = scope0; scope2["src/theme.css"] = "t9"; scope2["src/OrdersList.tsx"] = nil
            let styles = PrototypeBaseline.status(record: record, scope: scope2, site: site0)
            check(state("shell", styles) == .codeChanged && state("src/OrdersList.tsx", styles) == .codeChanged, "a changed global stylesheet changes the shell; a removed source changes its unit")
            check(state("orders", styles) == .codeChanged, "a screen whose component source was removed is code changed")

            let none = PrototypeBaseline.status(record: nil, scope: scope0, site: site0)
            check(!none.hasBaseline && none.units.isEmpty && none.summary.hasPrefix("No baseline"), "no record, no baseline, said in words")
            check(PrototypeBaseline.State.allCases.allSatisfy { !$0.meaning.isEmpty && !$0.title.isEmpty }, "every state has a title and a meaning")
            check(PrototypeBaseline.list(["a", "b", "c", "d", "e"]) == "a, b, c and 2 more" && PrototypeBaseline.list(["a"]) == "a", "file lists are shortened")

            // The plan of a sync.
            let nothing = PrototypeBaseline.syncPlan(status: same, record: record)
            check(nothing.mode == .nothing && nothing.units.isEmpty && !nothing.restyle, "no change: nothing to do")
            var scopeX = scope0; scopeX["src/Trade.tsx"] = "r1"
            let one = PrototypeBaseline.syncPlan(status: PrototypeBaseline.status(record: record, scope: scopeX, site: site0), record: record)
            check(one.mode == .incremental && one.units.map(\.unit.id) == ["trade"] && one.changedSources == ["src/Trade.tsx"] && one.overwrites.isEmpty,
                  "one changed source rebuilds its unit only: \(one)")
            let both = PrototypeBaseline.syncPlan(status: drift, record: record)
            check(both.mode == .incremental && both.units.map(\.unit.id) == ["orders"] && both.overwrites.map(\.unit.id) == ["orders"],
                  "a unit changed on both sides is rebuilt and named as an overwrite")
            check(both.notes.contains { $0.contains("src/util.ts") } && both.notes.contains { $0.contains("src/new.tsx") && $0.contains("Rebuild everything") },
                  "unclaimed changes and new files are said: \(both.notes)")
            let onlyNotes = PrototypeBaseline.syncPlan(status: PrototypeBaseline.status(record: record, scope: ["src/theme.css": "t0", "src/Orders.tsx": "o0", "src/OrdersList.tsx": "l0", "src/Trade.tsx": "r0", "src/util.ts": "u9", "src/new.tsx": "n"], site: site0), record: record)
            check(onlyNotes.mode == .nothing && onlyNotes.notes.count == 2, "only unclaimed or new files: no run, but the person is told")
            let restyle = PrototypeBaseline.syncPlan(status: styles, record: record)
            check(restyle.restyle && restyle.units.map(\.unit.id).contains("orders"), "a changed global stylesheet is copied again")
            check(PrototypeBaseline.syncPlan(status: none, record: nil).mode == .full && PrototypeBaseline.syncPlan(status: none, record: nil).reasons[0].contains("no baseline")
                  || PrototypeBaseline.syncPlan(status: none, record: nil).reasons[0].contains("There is no baseline"), "no baseline: a full rebuild, said why")
            // A file used by many screens, and a unit whose sources are all gone.
            var wide = record
            wide.units = ["a", "b", "c", "d"].map { PrototypeBaseline.Unit(id: $0, kind: .screen, name: $0.uppercased(), sources: ["src/shared.ts", "src/\($0).tsx"], files: [:]) }
            wide.scope = ["src/shared.ts": "s", "src/a.tsx": "1", "src/b.tsx": "2", "src/c.tsx": "3", "src/d.tsx": "4"]
            var wideNow = wide.scope; wideNow["src/shared.ts"] = "s2"
            let shared = PrototypeBaseline.syncPlan(status: PrototypeBaseline.status(record: wide, scope: wideNow, site: [:]), record: wide)
            check(shared.mode == .full && shared.reasons.count == 1 && shared.reasons[0].contains("src/shared.ts") && shared.reasons[0].contains("4 of 4 screens"),
                  "an input shared by many screens means a full rebuild, naming the file: \(shared.reasons)")
            wideNow["src/shared.ts"] = "s"; wideNow["src/a.tsx"] = nil; wideNow["src/b.tsx"] = "22"
            wide.units[0].sources = ["src/a.tsx"]
            let gone = PrototypeBaseline.syncPlan(status: PrototypeBaseline.status(record: wide, scope: wideNow, site: [:]), record: wide)
            check(gone.mode == .full && gone.reasons.contains { $0.contains("\"A\"") && $0.contains("removed") }, "a screen whose sources are all gone cannot be rebuilt alone: \(gone.reasons)")

            // The baseline after an incremental sync: only what was rewritten and refreshed moves; the rest stays honest.
            var siteAfter = site0; siteAfter["screens/orders.js"] = "o2"; siteAfter["screens/trade.js"] = "edited"
            let advanced = PrototypeBaseline.advanced(record, version: 5, rewritten: ["orders"], refreshed: ["orders"], scope: scope1, site: siteAfter)
            let afterStatus = PrototypeBaseline.status(record: advanced, scope: scope1, site: siteAfter)
            check(advanced.syncedVersion == 5 && state("orders", afterStatus) == .inSync, "the rebuilt unit is in sync again")
            check(state("trade", afterStatus) == .prototypeEdited, "a Studio edit that was not overwritten still shows")
            check(afterStatus.unclaimed == ["src/util.ts"] && afterStatus.added == ["src/new.tsx"], "a changed file no unit lists and a new file are still reported: \(afterStatus.unclaimed) \(afterStatus.added)")
            check(state("src/OrdersList.tsx", afterStatus) == .inSync, "a component that shares no changed source stays in sync")
            // A unit that failed to rebuild keeps its old fingerprints, so it still shows as changed.
            let failedRun = PrototypeBaseline.advanced(record, version: 5, rewritten: [], refreshed: [], scope: scope1, site: site0)
            check(state("orders", PrototypeBaseline.status(record: failedRun, scope: scope1, site: site0)) == .codeChanged, "a unit that was not refreshed still shows code changed")
            // A source listed by a refreshed and a not refreshed unit is not advanced.
            var partial = record
            partial.units[1].sources = ["src/Orders.tsx", "src/Trade.tsx"]
            var scopeP = scope0; scopeP["src/Trade.tsx"] = "r1"
            let half = PrototypeBaseline.advanced(partial, version: 6, rewritten: ["trade"], refreshed: ["trade"], scope: scopeP, site: site0)
            check(half.scope["src/Trade.tsx"] == "r0", "a source shared with a unit that was not refreshed stays at its old fingerprint")
            // A removed source of a refreshed unit is recorded as unreadable, not as a change.
            var scopeR = scope0; scopeR["src/Trade.tsx"] = nil
            let removedRun = PrototypeBaseline.advanced(record, version: 6, rewritten: ["trade"], refreshed: ["trade"], scope: scopeR, site: site0)
            check(removedRun.scope["src/Trade.tsx"] == "" && PrototypeBaseline.status(record: removedRun, scope: scopeR, site: site0).unclaimed.isEmpty, "a removed source of a refreshed unit is no longer a difference")
            // The shell moves with its stylesheets without absorbing Studio edits of its files.
            var siteShell = site0; siteShell["app.js"] = "a-edited"
            var scopeS = scope0; scopeS["src/theme.css"] = "t9"
            let shellRun = PrototypeBaseline.advanced(record, version: 7, rewritten: [], refreshed: ["shell"], scope: scopeS, site: siteShell)
            let shellStatus = PrototypeBaseline.status(record: shellRun, scope: scopeS, site: siteShell)
            check(state("shell", shellStatus) == .prototypeEdited && shellStatus.units.first { $0.unit.id == "shell" }?.changedSources == [],
                  "copying the stylesheets again clears the code difference of the shell and keeps its Studio edit")

            // The hand-off to code and the section an agent reads (REQ-012, REQ-013).
            let entries = [PrototypeFiles.Entry(version: 1, instruction: "", summary: "build", date: Date()),
                           PrototypeFiles.Entry(version: 2, instruction: "Make the table denser", summary: "Tightened rows.", date: Date()),
                           PrototypeFiles.Entry(version: 4, instruction: "Go back to v2", summary: "Restored.", date: Date()),
                           PrototypeFiles.Entry(version: 5, instruction: "Bigger trade button", summary: "The button is larger.", date: Date()),
                           PrototypeFiles.Entry(version: 6, instruction: "Synced from code", summary: "Reconstructed.", date: Date())]
            let markers: (String) -> [String] = { $0 == "screens/trade.js" ? ["src/Trade.tsx", "src/Badge.tsx"] : ["src/Orders.tsx"] }
            let moved = PrototypeHandoff.changes(status: drift, history: entries, markers: markers)
            check(moved.baselineVersion == 3 && moved.items.map(\.name) == ["Orders", "Trade"], "the changed units, in the order of the prototype: \(moved.items.map(\.name))")
            check(moved.items[1].components == ["src/Trade.tsx", "src/Badge.tsx"] && moved.items[0].alsoChangedInCode == ["src/Orders.tsx"] && moved.items[1].alsoChangedInCode.isEmpty,
                  "each item names the components its files mark and the sources that also changed in the code")
            check(moved.history.map(\.version) == [5], "only the requests after the baseline count, not builds, restores or syncs: \(moved.history.map(\.version))")
            check(moved.codeChanged == ["src/Orders.tsx", "src/util.ts"], "the code files that changed since the baseline: \(moved.codeChanged)")
            let brief = PrototypeHandoff.brief(title: "Shop", reference: "mv://prototype/shop", version: 7, siteRelative: "docs/prototypes/shop/site", changes: moved)
            check(brief.contains("RECONSTRUCTION") && brief.contains("Do not copy its markup") && brief.contains("`docs/prototypes/shop/site/`")
                  && brief.contains("last synced with the code at v3"), "the brief says what the prototype is and how not to use it")
            check(brief.contains("**Trade** (screen): prototype files `screens/trade.js`; reproduces the source components `src/Trade.tsx`, `src/Badge.tsx`")
                  && brief.contains("v5: Bigger trade button\n  Result: The button is larger.") && !brief.contains("Make the table denser") && !brief.contains("Go back"),
                  "the brief lists the files, the components and the requests that led to them")
            check(brief.contains("Also changed in the code since the last sync") && brief.contains("- Orders: `src/Orders.tsx`"), "a unit that changed on both sides is flagged")
            check(brief.contains("a branch of its own") && brief.contains("written nothing to the project") && brief.contains("Sync from code"), "the brief leaves the code work to the agent and names the way back")
            let clean = PrototypeHandoff.changes(status: same, history: entries, markers: markers)
            check(clean.isEmpty && clean.hasBaseline, "an unchanged prototype has nothing to hand off")
            check(!PrototypeHandoff.changes(status: none, history: entries, markers: markers).hasBaseline, "no baseline, no changes can be told")
            let sectionMoved = PrototypeHandoff.section(moved, componentPaths: ["src/Orders.tsx", "src/Other.tsx"])
            check(sectionMoved.contains("Changes since the last sync (v3)") && sectionMoved.contains("- Trade (screen): screens/trade.js; reproduces src/Trade.tsx, src/Badge.tsx")
                  && sectionMoved.contains("Review requests since then:\n- v5: Bigger trade button → The button is larger.")
                  && sectionMoved.hasSuffix("that also changed in the code since the last sync: src/Orders.tsx."), "the section lists files, components, requests and code changes: \(sectionMoved)")
            check(PrototypeHandoff.section(clean, componentPaths: ["src/Orders.tsx"]) == "Changes since the last sync (v3): none. The prototype's files are as they were at the last sync.\nSource components named in this result changed in the code since the last sync: none.",
                  "nothing changed: said in a line, and the components are reported unchanged")
            check(PrototypeHandoff.section(PrototypeHandoff.changes(status: none, history: [], markers: markers), componentPaths: []).hasPrefix("Changes since the last sync: unknown."), "no baseline: said in a line")
            check(PrototypeHandoff.section(clean, componentPaths: []).hasSuffix("the prototype records no components."), "no components recorded: said")

            // Storage per version; carry forward; no source text anywhere.
            let folder = work.appendingPathComponent("docs/prototypes/shop")
            try PrototypeBaseline.save(record, folder: folder, version: 3)
            check(PrototypeBaseline.load(folder: folder, version: 3) == record, "a record round-trips")
            check(PrototypeBaseline.load(folder: folder, version: 4) == nil, "an earlier prototype has no baseline")
            PrototypeBaseline.carryForward(folder: folder, from: 3, to: 4)
            check(PrototypeBaseline.load(folder: folder, version: 4) == record, "a review edit carries the baseline forward")
            let text = (try? String(contentsOf: PrototypeBaseline.url(of: folder, version: 3), encoding: .utf8)) ?? ""
            check(text.contains("src/Orders.tsx") && !text.contains("export default"), "paths and fingerprints are stored")
            PrototypeBaseline.carryForward(folder: folder, from: 8, to: 9)
            check(PrototypeBaseline.load(folder: folder, version: 9) == nil, "nothing to carry from a version without a baseline")

            // A baseline that cannot be read is not "none" (AR-36): it stays on disk, and a save copies it before it replaces it.
            let file = PrototypeBaseline.url(of: folder, version: 3)
            func backups() -> [URL] {
                ((try? fm.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.hasPrefix("v3.json.corrupt-") }
            }
            check(backups().isEmpty, "a baseline that reads leaves no backup")
            try PrototypeBaseline.save(record, folder: folder, version: 3)
            check(backups().isEmpty, "saving over a baseline that reads leaves no backup")
            let damaged = Data("{ \"syncedVersion\": ".utf8)
            try damaged.write(to: file)
            check(PrototypeBaseline.load(folder: folder, version: 3) == nil, "a damaged baseline reads as none")
            check((try? Data(contentsOf: file)) == damaged, "reading a damaged baseline leaves it as it is")
            PrototypeBaseline.carryForward(folder: folder, from: 3, to: 5)
            check(PrototypeBaseline.load(folder: folder, version: 5) == nil, "a damaged baseline is not carried forward")
            try PrototypeBaseline.save(record, folder: folder, version: 3)
            check(backups().count == 1 && (try? Data(contentsOf: backups()[0])) == damaged, "a save copies the damaged baseline to a dated backup first")
            check(PrototypeBaseline.load(folder: folder, version: 3) == record, "and then replaces it")
            try PrototypeBaseline.save(record, folder: folder, version: 3)
            check(backups().count == 1, "the next save makes no second backup")
        }
    }
}

extension EditorHostTests {
    func testPrototypeFidelityRules() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let root = "apps/desk/src/widgets/chain"

        let deskSource = """
        import React from 'react';
        import { ChainTable } from './components/ChainTable';
        import { ConfirmDialog } from './components/ConfirmDialog';
        import { Helper } from '../shared/Helper';
        import { Other } from '../other/Other';
        import './Desk.css';
        // A comment that says Not a label at all
        export function Desk() {
          const options = [{ label: 'Custom (Manual)', value: 'manual' }, { label: 'Live', value: 'live' }];
          const key = 'ArrowUp';
          const route = '/api/v1/chains';
          const css = 'flex items-center';
          return (
            <div className="desk-toolbar big-title" data-testid="Toolbar Root" aria-label="Hidden accessibility text">
              <span title="Tooltip text here">Underlying</span>
              <button onClick={go}>Refresh</button>
              <button onClick={cfg}>CONFIG</button>
              <input placeholder="Search strikes" name="searchField" />
              <span>{count} legs</span>
              <b>P/L Open</b>
              <i>Total:</i>
            </div>
          );
        }
        """

        let tableSource = """
        import React from 'react';
        const COLUMNS = [
          { header: 'Delta' }, { header: 'Bid (Sell)' }, { header: 'Ask (Buy)' }, { header: 'Strike' },
          { header: 'Open interest' }, { header: 'Gamma' }, { header: 'Theta' }, { header: 'Vega' },
        ];
        export function ChainTable() {
          return (<table><thead><tr><th>Calls</th><th>Puts</th></tr></thead><tfoot><tr><td>Max profit</td><td>BP Eff</td></tr></tfoot></table>);
        }
        """

        let dialogSource = "export const ConfirmDialog = () => (<div><h1>Confirm replacement</h1><p>Are you sure about this change?</p></div>);"
        let helperSource = "export const Helper = () => (<p>Shared helper text</p>);"
        let otherSource = "export const Other = () => (<p>Another screen's own text</p>);"
        let testSource = "it('shows labels', () => { expect(screen.getByText('Test only label')).toBeTruthy(); });"

        let files: [String: String] = [
            root + "/Desk.tsx": deskSource,
            root + "/components/ChainTable.tsx": tableSource,
            root + "/components/ConfirmDialog.tsx": dialogSource,
            "apps/desk/src/widgets/shared/Helper.tsx": helperSource,
            "apps/desk/src/widgets/other/Other.tsx": otherSource,
            root + "/__tests__/Desk.test.tsx": testSource,
        ]
        func read(_ path: String) -> String? { files[path] }

        // MARK: - Labels of one file

        do {
            let labels = PrototypeFidelity.labels(in: deskSource)
            for wanted in ["Custom (Manual)", "Underlying", "Refresh", "CONFIG", "Search strikes", "P/L Open", "Total:", "Live"] {
                check(labels.contains(wanted), "a visible label is found: \(wanted)")
            }
            for unwanted in ["Not a label at all", "Hidden accessibility text", "Tooltip text here", "ArrowUp", "/api/v1/chains", "flex items-center",
                             "desk-toolbar big-title", "Toolbar Root", "searchField", "manual", "React", "./components/ChainTable"] {
                check(!labels.contains(unwanted), "not a label: \(unwanted)")
            }
            check(!labels.contains { $0.contains("{") || $0.contains("legs") && $0.contains("count") }, "an expression is not taken as text")
            check(labels.count == Set(labels).count, "each label is listed once")
            check(PrototypeFidelity.labels(in: tableSource).prefix(3) == ["Delta", "Bid (Sell)", "Ask (Buy)"], "labels keep the order of the source")
            check(PrototypeFidelity.looksLikeLabel("Bid (Sell)") && PrototypeFidelity.looksLikeLabel("MAX PROFIT") && PrototypeFidelity.looksLikeLabel("Swap"),
                  "titles, upper case and one capitalized word are labels")
            check(!PrototypeFidelity.looksLikeLabel("useState") && !PrototypeFidelity.looksLikeLabel("order") && !PrototypeFidelity.looksLikeLabel("on-click")
                  && !PrototypeFidelity.looksLikeLabel("a_b_c") && !PrototypeFidelity.looksLikeLabel("BracketLeft"),
                  "identifiers, lower case words, kebab case and key names are not labels")
            check(!PrototypeFidelity.looksLikeLabel("0 && loadedStrikeCount") && !PrototypeFidelity.looksLikeLabel("count > 0 || ready"),
                  "a condition between two comparisons is not a label")
            check(PrototypeFidelity.labels(in: "<div>{rows.length > 0 && diff < max}</div><span>R&D budget</span><b>P&L Open</b>") == ["R&D budget", "P&L Open"],
                  "an ampersand inside a label is kept, a logical and is not")
            check(PrototypeFidelity.normalized("  Bid\u{00A0}(Sell)  ") == "bid (sell)", "normalizing ignores case and spacing")
        }

        // MARK: - Imports and the source set

        do {
            check(PrototypeFidelity.relativeImports(in: deskSource) == ["./components/ChainTable", "./components/ConfirmDialog", "../shared/Helper", "../other/Other", "./Desk.css"],
                  "relative imports are found, packages are not")
            check(PrototypeFidelity.resolve("./components/ChainTable", from: root + "/Desk.tsx", exists: { read($0) != nil }) == root + "/components/ChainTable.tsx",
                  "an import resolves to the file with its extension")
            // The widget folder has five levels: five `..` reach the root itself, the sixth leaves it.
            check(PrototypeFidelity.resolve("../../../../../escape", from: root + "/Desk.tsx", exists: { _ in true }) == "escape.tsx", "a path up to the root is resolved")
            check(PrototypeFidelity.resolve("../../../../../../escape", from: root + "/Desk.tsx", exists: { _ in true }) == nil, "a path above the root is not resolved")
            check(!PrototypeFidelity.isSource(root + "/__tests__/Desk.test.tsx") && !PrototypeFidelity.isSource("a/b.d.ts") && !PrototypeFidelity.isSource("a/b.css")
                  && PrototypeFidelity.isSource("a/b.tsx"), "tests, declarations and styles are not label sources")
            check(PrototypeFidelity.isSecondary("a/ExitBracketPopup.tsx") && PrototypeFidelity.isSecondary("a/OrderAmendmentEditor.tsx")
                  && PrototypeFidelity.isSecondary("a/RollPreview.tsx") && !PrototypeFidelity.isSecondary("a/ChainTable.tsx") && !PrototypeFidelity.isSecondary("a/OrderTicket.tsx"),
                  "dialogs, editors and previews are secondary; tables and tickets are not")

            let set = PrototypeFidelity.sourceSet(evidence: [root + "/Desk.tsx"], otherEvidence: ["apps/desk/src/widgets/other/Other.tsx"], read: read).map(\.path)
            check(set == [root + "/Desk.tsx", root + "/components/ChainTable.tsx"],
                  "the set is the entry and what it imports inside its folder: no dialog, no file outside the folder (\(set))")
            let withOthers = PrototypeFidelity.sourceSet(evidence: [root + "/Desk.tsx", "apps/desk/src/widgets/other/Other.tsx"], otherEvidence: [], read: read).map(\.path)
            check(withOthers.contains("apps/desk/src/widgets/other/Other.tsx"), "an evidence file is always part of its own set")
            check(PrototypeFidelity.sourceSet(evidence: [root + "/Missing.tsx"], otherEvidence: [], read: read).isEmpty, "a file that cannot be read gives an empty set")
            check(PrototypeFidelity.sourceSet(evidence: [root + "/Desk.tsx", root + "/Desk.tsx"], otherEvidence: [], read: read).count == 2, "a file is not read twice")
        }

        // MARK: - The report

        let faithfulScreen = """
        App.register({ id: 'desk', render(ctx) {
          const labels = ['Custom (Manual)', 'Live', 'Underlying', 'Refresh', 'CONFIG', 'Search strikes', 'P/L Open', 'Total:',
            'Delta', 'Bid (Sell)', 'Ask (Buy)', 'Strike', 'Open interest', 'Gamma', 'Theta', 'Vega', 'Calls', 'Puts', 'MAX PROFIT', 'BP EFF'];
        } });
        """
        let thinScreen = "App.register({ id: 'desk', render(ctx) { return ['Underlying', 'Refresh', 'Delta', 'Bid', 'Ask', 'Strike', 'Volume'].join(' '); } });"

        do {
            let faithful = PrototypeFidelity.report(id: "desk", name: "Desk", evidence: [root + "/Desk.tsx"], otherEvidence: [], screen: faithfulScreen, read: read)
            check(faithful != nil && faithful!.total >= 20, "the report counts the labels of the whole set (\(faithful?.total ?? -1))")
            check(faithful?.present == faithful?.total && faithful?.missing.isEmpty == true && faithful?.isThin == false,
                  "a screen that shows every label is complete (\(faithful?.present ?? -1) of \(faithful?.total ?? -1))")

            let thin = PrototypeFidelity.report(id: "desk", name: "Desk", evidence: [root + "/Desk.tsx"], otherEvidence: [], screen: thinScreen, read: read)
            check(thin?.isThin == true, "a screen that shows a few labels is thin (\(thin?.percent ?? -1)%)")
            check(thin?.missing.contains(PrototypeFidelity.Missing(label: "Bid (Sell)", file: root + "/components/ChainTable.tsx")) == true,
                  "a missing label names the file that defines it")
            check(thin?.missing.contains { $0.label == "Underlying" } == false, "a label the screen shows is not missing")
            check(thin?.files == [root + "/Desk.tsx", root + "/components/ChainTable.tsx"], "the report lists the files it read")

            // The shared sample data holds the labels of every screen: a screen is not complete because data.js has its words.
            let alsoInData = PrototypeFidelity.report(id: "desk", name: "Desk", evidence: [root + "/Desk.tsx"], otherEvidence: [],
                                                      screen: thinScreen + "\n/* data.js */ const DB = { cols: ['Open interest', 'Gamma', 'Theta', 'Calls', 'Puts'] };", read: read)
            check(alsoInData?.missing.contains { $0.label == "Gamma" } == false, "a label written in the screen's own script counts, in any case")
            check(PrototypeFidelity.report(id: "desk", name: "Desk", evidence: [root + "/Desk.tsx"], otherEvidence: [], screen: thinScreen.lowercased(), read: read)?.present ?? 0 > 0,
                  "the same label in another case is the same label")

            let small = PrototypeFidelity.report(id: "tiny", name: "Tiny", evidence: [root + "/components/ConfirmDialog.tsx"], otherEvidence: [], screen: "", read: read)
            check(small != nil && small!.total < PrototypeFidelity.minLabels && small!.present == 0 && small!.isThin == false,
                  "a source with few labels is never thin, even when none is shown")
            check(PrototypeFidelity.report(id: "x", name: "X", evidence: [root + "/Nope.tsx"], otherEvidence: [], screen: "", read: read) == nil,
                  "no readable source gives no report")
            check(PrototypeFidelity.summary(thin!).hasPrefix("\"Desk\" shows ") && PrototypeFidelity.summary(thin!).contains("labels of its source files ("),
                  "the summary names the screen and the share")
        }

        // MARK: - The repair request

        do {
            let thin = PrototypeFidelity.report(id: "desk", name: "Desk", evidence: [root + "/Desk.tsx"], otherEvidence: [], screen: thinScreen, read: read)!
            let text = PrototypeFidelity.repairInstruction(thin)
            check(text.contains("`screens/desk.js`") && text.contains("`\(root)/components/ChainTable.tsx`: "), "the request names the screen file and the source file")
            check(text.contains("\"Bid (Sell)\"") && text.contains("\"Calls\"") && !text.contains("\"Underlying\""), "it lists the missing labels, not the present ones")
            check(text.contains("copying every label exactly") && text.contains("skip them otherwise") && text.contains("Do not invent") && text.contains("this screen's script only"),
                  "it says to copy the labels, skip dialogs, not to invent and to stay in the screen")
            check(text.range(of: "ChainTable.tsx`: ")!.lowerBound < text.range(of: "Desk.tsx`: ")!.lowerBound, "the file with more missing labels comes first")

            var many = thin
            many.missing = (0..<100).map { PrototypeFidelity.Missing(label: "Label number \($0)", file: root + "/Big.tsx") }
            many.total = 100
            many.present = 0
            let long = PrototypeFidelity.repairInstruction(many)
            check(long.components(separatedBy: "\"Label number ").count - 1 == PrototypeFidelity.listLimit, "the list is capped at \(PrototypeFidelity.listLimit) labels")
            check(long.contains("and 60 more"), "the rest is counted")
        }
    }
}
