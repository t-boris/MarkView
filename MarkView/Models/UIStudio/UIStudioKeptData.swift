import Foundation
import WebKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The page's cookies and storage kept for later restores (REQ-008, BUG-088): keeping, forgetting, putting them back into the emptied browser
/// store before the page loads, and carrying the sign-in over to a restore of the same test user. Owns what the last Keep left out and the
/// test user the browser data was last restored for.
@MainActor
final class StudioKeptData: ObservableObject {
    /// Unowned: the session owns this part. A task of this part starts through `session.startPartTask`, which holds the session until it ends.
    unowned let session: StudioSession

    /// What the last "Keep" left out of the kept cookies and storage, and why (names only, never values).
    @Published private(set) var keptSkipped: [String] = []

    /// Keeps the page's cookies (httpOnly ones included) and localStorage for later restores (REQ-008): a restore empties
    /// the browser storage, so the application would ask again (cookie consent). Cookies of the application's host only;
    /// entries that look confidential are left out and named, because environment.json may be committed. Replaces what
    /// was kept before.
    func keepBrowserData() {
        session.runWork("Keeping the page's cookies and storage") { session in
            guard let host = session.appURL?.host else { return }
            let cookies = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard let page = (try? await session.call("return window.__markviewStudio ? window.__markviewStudio.storage() : null;")) as? [String: Any]
            else {
                session.notice = "The page did not report its storage; nothing was kept. Wait until it has loaded and try again."
                return
            }
            let storage = StudioKeptBrowserData.storageEntries(page["entries"])
            let outcome = StudioKeptBrowserData.collect(cookies: cookies.map(StudioKeptCookie.init), storage: storage, appHost: host,
                                                        origin: session.appOrigin?.text, redactor: session.redactor)
            self.keptSkipped = outcome.skipped
            self.replaceKept(outcome.kept.isEmpty ? nil : outcome.kept)
            let kept = outcome.kept
            session.notice = "Kept \(kept.cookies.count) cookie\(kept.cookies.count == 1 ? "" : "s") and \(kept.localStorage.count) "
                + "localStorage entr\(kept.localStorage.count == 1 ? "y" : "ies") in .markview/studio/environment.json; they are set again after every restore."
                + (outcome.skipped.isEmpty ? "" : " Not kept because they look confidential: \(outcome.skipped.count).")
        }
    }

    func forgetKeptCookie(_ id: String) {
        updateKept { $0.cookies.removeAll { $0.id == id } }
    }

    func forgetKeptStorage(_ key: String) {
        updateKept { $0.localStorage.removeAll { $0.key == key } }
    }

    /// Forgets every kept cookie and storage entry; the next restore starts from empty browser storage again.
    func forgetKeptBrowserData() {
        keptSkipped = []
        replaceKept(nil)
    }

    private func updateKept(_ change: (inout StudioKeptBrowserData) -> Void) {
        guard var kept = session.spec.keptBrowserData else { return }
        change(&kept)
        replaceKept(kept.isEmpty ? nil : kept)
    }

    private func replaceKept(_ kept: StudioKeptBrowserData?) {
        var next = session.simulator.spec
        next.keptBrowserData = kept
        session.replaceEnvironment(next)
    }

    /// The kept cookies go back into the emptied store before the page loads (REQ-008).
    /// The test user the browser data was last restored for: its sign-in cookies are carried over to the next restore only for the
    /// same user, so a scenario of another role starts signed out.
    var restoredUser: StudioJSON?

    /// The cookies that keep the application signed in, when the page is signed in as the test user the new scenario also has
    /// (BUG-088). A page on its sign-in page has nothing to carry. They live in memory for the restore only, never on disk.
    func signInCookiesToCarry() async -> [HTTPCookie] {
        guard restoredUser == session.scenario.role.user, let host = session.appURL?.host,
              let path = session.webView.url?.path, !StudioLogFormat.isSignInPath(path) else { return [] }
        let cookies = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return (host == domain || host.hasSuffix("." + domain)) && StudioSignInCookies.isSignIn(name: cookie.name)
        }
    }

    func restoreKeptCookies() async {
        guard let cookies = session.spec.keptBrowserData?.cookies, !cookies.isEmpty, let host = session.appURL?.host else { return }
        let store = session.webView.configuration.websiteDataStore.httpCookieStore
        let now = Date()
        for cookie in cookies {
            guard let http = cookie.httpCookie(appHost: host, now: now) else { continue }
            await store.setCookie(http)
        }
    }

    init(session: StudioSession) {
        self.session = session
    }
}
