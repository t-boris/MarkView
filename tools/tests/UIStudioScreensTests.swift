import Foundation

// Checks of UIStudioScreens.swift (REQ-021, DEC-014): the saved list of screens, what is prepared for each, the status the menu shows,
// the staleness by source hashes, and the file's compatibility. Compiled into tools/tests/ui-studio-tests.sh.

func screenBookChecks() {
    func screen(_ name: String, route: String = "/x", selector: String = "#x", source: String = "src/x.tsx: X", main: Bool? = nil) -> StudioScreen {
        StudioScreen(name: name, route: route, selector: selector, description: "The \(name) screen", instructions: "Open it.", source: source, main: main)
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let home = screen("Home", route: "/", selector: "#home", source: "src/Home.tsx: Home; src/api/home.ts", main: true)
    let accounts = screen("Accounts", route: "/accounts", selector: "#accounts", source: "src/pages/Accounts.tsx", main: true)
    let about = screen("About", route: "/about", selector: "#about", source: "src/About.tsx", main: false)

    var book = StudioScreenBook(appFolder: "web")
    book.merge(found: [home, accounts, about], now: now)
    check("REQ-021 a new listing makes an empty entry per screen", book.entries.count == 3 && book.discovered == now
          && book.entries.allSatisfy { $0.scenarioID == nil && $0.status == nil })
    check("REQ-021 the main screens are the marked ones, in order", book.main.map(\.screen.name) == ["Home", "Accounts"])
    var unmarked = StudioScreenBook()
    unmarked.merge(found: (1...12).map { screen("S\($0)", route: "/s\($0)", selector: "#s\($0)") }, now: now)
    check("REQ-021 without a mark the first eight are the main ones", unmarked.main.count == StudioScreenBook.mainLimit && unmarked.main.first?.screen.name == "S1")
    var marked = StudioScreenBook()
    marked.merge(found: (1...12).map { screen("S\($0)", route: "/s\($0)", selector: "#s\($0)", main: true) }, now: now)
    check("REQ-021 never more than eight are prepared ahead, whatever the assistant marked", marked.main.count == StudioScreenBook.mainLimit)

    // A scenario id is stable for a screen, a legal file name, never a built-in id and different for screens of one name.
    let id = StudioScreenBook.scenarioID(for: home)
    check("REQ-021 the scenario id of a screen is stable and a safe file name",
          id == StudioScreenBook.scenarioID(for: home) && id.hasPrefix("screen-home-") && id == StudioStore.safeID(id) && !id.hasPrefix("builtin"), id)
    check("REQ-021 two screens with one name get two scenario ids",
          StudioScreenBook.scenarioID(for: screen("Home", route: "/a")) != StudioScreenBook.scenarioID(for: screen("Home", route: "/b")))
    check("REQ-021 a long or odd name still gives a legal id", StudioStore.safeID(StudioScreenBook.scenarioID(for: screen("Счёт / Accounts: " + String(repeating: "x", count: 200)))) == StudioScreenBook.scenarioID(for: screen("Счёт / Accounts: " + String(repeating: "x", count: 200))))

    // The status the menu shows.
    func state(_ entry: StudioScreenBook.Entry, preparing: Set<String> = [], current: [String: String] = [:]) -> StudioScreenBook.State {
        book.state(of: entry, preparing: preparing, current: current)
    }
    let first = book.entries[0]
    check("REQ-021 a screen nothing was prepared for is not prepared", state(first) == .notPrepared)
    check("REQ-021 a screen being prepared says so", state(first, preparing: [first.id]) == .preparing)
    book.markPrepared(first.id, scenarioID: id, sources: ["src/Home.tsx": "aaa", "src/api/home.ts": "bbb"], now: now)
    check("REQ-021 a saved scenario nobody opened is prepared and opens at once",
          state(book.entries[0]) == .prepared && state(book.entries[0]).opensAtOnce && book.entries[0].preparedAt == now)
    book.markVerified(first.id, now: now)
    check("REQ-021 a scenario that reached its screen is ready", state(book.entries[0]) == .ready && book.entries[0].verifiedAt == now)
    check("REQ-021 unchanged sources keep it ready", state(book.entries[0], current: ["src/Home.tsx": "aaa", "src/api/home.ts": "bbb"]) == .ready)
    check("REQ-021 a changed source file makes it need a refresh", state(book.entries[0], current: ["src/Home.tsx": "zzz", "src/api/home.ts": "bbb"]) == .needsRefresh)
    check("REQ-021 a deleted source file does too", state(book.entries[0], current: ["src/Home.tsx": "aaa", "src/api/home.ts": "deleted"]) == .needsRefresh)
    check("REQ-021 hashes not read yet are not a change", state(book.entries[0], current: [:]) == .ready)
    book.markFailed(accounts.id, "The scenario was refused: x")
    check("REQ-021 a failed screen says so and does not open at once", state(book.entries[1]) == .failed && !state(book.entries[1]).opensAtOnce && book.entries[1].failure?.hasPrefix("The scenario was refused") == true)

    // What is prepared ahead: only the main ones nothing was prepared for or whose sources changed; a failure is not retried by itself.
    check("REQ-021 only the main screens that are not ready are prepared ahead",
          book.pending(preparing: [], current: [:]).isEmpty)
    check("REQ-021 a changed source puts a main screen back in the queue",
          book.pending(preparing: [], current: ["src/Home.tsx": "zzz"]).map(\.screen.name) == ["Home"])
    var fresh = StudioScreenBook()
    fresh.merge(found: [home, accounts, about], now: now)
    check("REQ-021 a fresh list queues its main screens, not the others", fresh.pending(preparing: [], current: [:]).map(\.screen.name) == ["Home", "Accounts"])
    check("REQ-021 a screen being prepared is not queued twice", fresh.pending(preparing: [fresh.entries[0].id], current: [:]).map(\.screen.name) == ["Accounts"])

    // A new listing keeps what is prepared and drops what is gone.
    var relisted = book
    let renamed = screen("Home", route: "/", selector: "#home", source: "src/Home.tsx: Home; src/api/home.ts", main: true)
    var changedText = renamed
    changedText.description = "The home screen, now with a banner"
    relisted.merge(found: [changedText, about, screen("Billing", route: "/billing", selector: "#billing", main: true)], now: now.addingTimeInterval(60))
    check("REQ-021 a new listing keeps the scenario of a screen that is still there", relisted.entries.first?.scenarioID == id)
    check("REQ-021 a screen whose description changed is no longer verified, its scenario stays",
          relisted.entries.first?.status == .prepared && relisted.entries.first?.verifiedAt == nil)
    check("REQ-021 screens that are gone are dropped and new ones are empty",
          relisted.entries.map(\.screen.name) == ["Home", "About", "Billing"] && relisted.entries[2].scenarioID == nil)
    var same = book
    same.merge(found: [home, accounts, about], now: now.addingTimeInterval(60))
    check("REQ-021 the same listing changes nothing but the date", same.entries == book.entries && same.discovered == now.addingTimeInterval(60))

    // The evidence a screen names.
    check("REQ-021 the source files are read from the evidence text",
          StudioScreenBook.sourcePaths(of: home) == ["src/Home.tsx", "src/api/home.ts"], "\(StudioScreenBook.sourcePaths(of: home))")
    check("REQ-021 a path outside the project is not hashed",
          StudioScreenBook.sourcePaths(of: screen("A", source: "/etc/passwd.json; ../../secret.ts; ~/key.json; web/ok.tsx")) == ["web/ok.tsx"],
          "\(StudioScreenBook.sourcePaths(of: screen("A", source: "/etc/passwd.json; ../../secret.ts; ~/key.json; web/ok.tsx")))")
    check("REQ-021 at most eight sources are followed", StudioScreenBook.sourcePaths(of: screen("A", source: (1...20).map { "src/f\($0).ts" }.joined(separator: ", "))).count == 8)
    check("REQ-021 evidence without a file name names no source, so the screen is never stale",
          StudioScreenBook.sourcePaths(of: screen("A", source: "the checkout component")).isEmpty
            && !StudioScreenBook.isStale(StudioScreenBook.Entry(screen: screen("A"), scenarioID: "s", status: .prepared, sources: [:]), current: ["x": "y"]))

    // The file: round trip, an older list without the new fields, a newer version, and where it lives.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = (try? encoder.encode(book)) ?? Data()
    check("REQ-021 the list survives a round trip", (try? decoder.decode(StudioScreenBook.self, from: data)) == book)
    let oldScreens = ##"{"version":1,"appFolder":"","entries":[{"screen":{"name":"Home","route":"/","selector":"#h","description":"d","instructions":"i","source":"s"}}]}"##
    let old = try? decoder.decode(StudioScreenBook.self, from: Data(oldScreens.utf8))
    check("REQ-021 a list written before main and the statuses still decodes", old?.entries.first?.screen.main == nil && old?.entries.first?.status == nil)

    let root = tmp.appendingPathComponent("screens-store")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    check("REQ-021 the project's own application has screens.json, another folder its own file",
          StudioStore.screensURL(root, appFolder: "").lastPathComponent == "screens.json"
            && StudioStore.screensURL(root, appFolder: ".").lastPathComponent == "screens.json"
            && StudioStore.screensURL(root, appFolder: "apps/web").lastPathComponent == "screens-apps-web.json"
            && StudioStore.screensURL(root, appFolder: "").deletingLastPathComponent().path.hasSuffix(".markview/studio"))
    try? StudioStore.saveScreenBook(book, root: root)
    let loaded = StudioStore.loadScreenBook(root, appFolder: "web")
    check("REQ-021 the saved list is read back", loaded?.entries.count == 3 && loaded?.entries.first?.scenarioID == id)
    check("REQ-021 another application folder does not see it", StudioStore.loadScreenBook(root, appFolder: "api") == nil)
    var newer = book
    newer.version = StudioScreenBook.currentVersion + 1
    try? StudioStore.saveScreenBook(newer, root: root)
    check("REQ-021 a list of a newer version is ignored, not misread", StudioStore.loadScreenBook(root, appFolder: "web") == nil)

    // The prompt and the schema ask for the main mark; a list without it still reads.
    let rows: [[String: Any]] = [["name": "Home", "route": "/", "selector": "#h", "description": "d", "instructions": "i", "source": "s", "main": true],
                                 ["name": "About", "route": "/about", "selector": "#a", "description": "d", "instructions": "i", "source": "s"]]
    let parsed = StudioPrompts.screens(from: ["screens": rows, "notes": ""])
    check("REQ-021 the main mark is read, and its absence is not an error", parsed.count == 2 && parsed[0].main == true && parsed[1].main == nil)
    let schema = StudioPrompts.screensSchema
    let properties = ((((schema["properties"] as? [String: Any])?["screens"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
    check("REQ-021 the screens schema asks for the mark", properties["main"] != nil && StudioPrompts.screensSystem.contains("at most 8"))

    // A route with a placeholder names no page to load, so it is no page to expect.
    func screen(_ route: String) -> StudioScreen {
        StudioScreen(name: "S", route: route, selector: "#s", description: "d", instructions: "i", source: "s")
    }
    check("REQ-021 routes with a placeholder are told from concrete ones",
          ["/#/products/<productId>/sources", "/items/:id", "/post/{slug}", "/blog/[id]", "/#/accounts/<id>"].allSatisfy { screen($0).hasPlaceholderRoute && screen($0).expectedPath == nil }
            && ["/#/accounts", "/", "/index.html", "/a/b?x=1#top", "/#/products/prod-01/sources", "/tags/a:b"].allSatisfy { !screen($0).hasPlaceholderRoute && screen($0).expectedPath == $0 })

    // A prepared screen opens directly when its contracts are still the environment's; the records inside are not what decides it.
    var brokenSeed = StudioEnvironmentSpec()
    brokenSeed.entities = [StudioEntity(name: "items", fields: [StudioField(name: "name", type: "string", required: true)])]
    brokenSeed.seed = ["items": [.object(["id": .number(1)])]]
    var made = StudioScenario(id: "screen-home", name: "Home", kind: .custom)
    made.contractFingerprint = StudioScenarioCompatibility.fingerprint(made, spec: brokenSeed)
    check("REQ-021 a scenario made against the current contracts is current although the seed breaks its entity",
          StudioScenarioCompatibility.isCurrent(made, spec: brokenSeed) && !StudioScenarioCompatibility.problems(made, spec: brokenSeed).isEmpty)
    var changed = brokenSeed
    // The fingerprint covers the entities the scenario's data holds: making `name` optional is a changed contract.
    changed.entities = [StudioEntity(name: "items", fields: [StudioField(name: "name", type: "string", required: false)])]
    check("REQ-021 a scenario whose contracts changed is no longer current", !StudioScenarioCompatibility.isCurrent(made, spec: changed))
    made.contractFingerprint = ""
    check("REQ-021 a scenario saved without a fingerprint is treated as current", StudioScenarioCompatibility.isCurrent(made, spec: changed))
}
