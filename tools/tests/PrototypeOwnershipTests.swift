import Foundation

// The owners of the work Prototype Studio starts (AR-19): the shipping PrototypeSession (the sync checks, the sync preview and the hand-off
// preparation) over a prototype saved in a temporary project, and the shipping PrototypeHandoffRun (the creation of the feature). A tap
// starts work the owner keeps; a second start replaces or is refused; an owner that goes away is not held by its own work.

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
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
    let trade = PrototypeHandoff.Item(id: "trade", name: "Trade", kind: .screen, files: ["screens/trade.js"], components: [], alsoChangedInCode: [])
    let changes = PrototypeHandoff.Changes(baselineVersion: 3, items: [trade], history: [], codeChanged: [])
    let context = PrototypeHandoffRun.Context(root: FileManager.default.temporaryDirectory, folder: FileManager.default.temporaryDirectory,
                                              slug: "shop", title: "Shop", version: 4, components: [], theme: nil, changes: changes,
                                              reference: "shop", siteRelative: "site")
    let run = PrototypeHandoffRun(context: context, record: { _ in })
    check(run.draft != nil, "the run has a draft to create the feature from")

    // Start: the feature is written once, however often the button is pressed; the window is told once.
    PrototypeFeatureWriter.hold = true
    var told: [String] = []
    run.startCreate(into: FeatureStore()) { told.append($0.slug) }
    run.startCreate(into: FeatureStore()) { _ in told.append("second") }
    check(await waitFor { PrototypeFeatureWriter.gate != nil && run.creating }, "the writer is under way and the run shows that it works")
    check(PrototypeFeatureWriter.writes == 1, "a second press while it works wrote nothing more")
    PrototypeFeatureWriter.release()
    check(await waitFor { !run.creating && run.created != nil }, "the creation ends with the feature")
    check(told == ["shop-sync"], "and the window was told once, with the feature (\(told))")

    // A failure is said and the window is not told.
    let again = PrototypeHandoffRun(context: context, record: { _ in })
    PrototypeFeatureWriter.failure = "The feature could not be created."
    var toldAgain = false
    again.startCreate(into: FeatureStore()) { _ in toldAgain = true }
    check(await waitFor { !again.creating && again.createFailure != nil }, "a creation that fails says why")
    check(!toldAgain && again.created == nil, "and nobody is told that a feature exists")
    again.close()
    run.close()
}

@MainActor func run() async throws {
    try await sessionChecks()
    try await releaseChecks()
    await handoffChecks()
    print(failures == 0 ? "All prototype ownership checks passed." : "\(failures) prototype ownership check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

Task { do { try await run() } catch { print("FAIL \(error)"); exit(1) } }
RunLoop.main.run()
