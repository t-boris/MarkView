import Foundation
import WebKit

/// The application connection policy of a session (REQ-006, §11): the page reaches its own development server, local
/// `data:`/`blob:` resources and the addresses the person allowed explicitly — nothing else. It is enforced by a content
/// rule list in WebKit for every load (documents, scripts, styles, images, fonts, sockets) and, for fetch and XHR, again by
/// the session before a request may pass. The model's connections are a separate policy (`StudioModelPolicy`).
enum StudioConnectionPolicy {
    /// The rule list as WebKit's content blocker JSON: block everything, then let the allowed addresses through.
    static func ruleListJSON(appOrigin: StudioBridge.Origin, allowed: [String]) -> String {
        var rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        func allow(_ filter: String) {
            rules.append(["trigger": ["url-filter": filter], "action": ["type": "ignore-previous-rules"]])
        }
        for scheme in ["data", "blob", "about"] { allow("^\(scheme):") }
        let loopback: Set<String> = ["localhost", "127.0.0.1"]
        let hosts = loopback.contains(appOrigin.host) ? ["localhost", "127\\.0\\.0\\.1"] : [escape(appOrigin.host)]
        for host in hosts {
            allow("^https?://\(host):\(appOrigin.port)/")
            allow("^wss?://\(host):\(appOrigin.port)/")
            if appOrigin.port == 80 || appOrigin.port == 443 { allow("^https?://\(host)/") }
        }
        for pattern in allowed {
            if let filter = filter(forAllowed: pattern) { allow(filter) }
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `https://fonts.googleapis.com/*` → `^https://fonts\.googleapis\.com/`; `https://*.example.com/*` allows its
    /// subdomains. A pattern of the app's own origin (`/locales/*`) needs no rule. nil for anything that is not an
    /// http(s) address.
    static func filter(forAllowed pattern: String) -> String? {
        let text = pattern.trimmingCharacters(in: .whitespaces)
        guard let schemeEnd = text.range(of: "://") else { return nil }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        guard ["http", "https", "ws", "wss"].contains(scheme) else { return nil }
        let rest = text[schemeEnd.upperBound...]
        let hostPart = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !hostPart.isEmpty, hostPart.range(of: #"^(\*\.)?[A-Za-z0-9.\-]+(:\d{1,5})?$"#, options: .regularExpression) != nil else { return nil }
        var host = escape(hostPart.lowercased())
        if host.hasPrefix("\\*\\.") { host = "[a-z0-9.-]*\\." + host.dropFirst(4) }
        return "^\(scheme)://\(host)/"
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if ".*+?^$()[]{}|\\".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }

    @MainActor
    static func compile(identifier: String, json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    @MainActor
    static func remove(identifier: String) {
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
    }

    /// Data requests a server-rendering framework makes to its own server for navigation, refresh and form actions
    /// (BUG-070): Next.js server-component payloads and server actions, Remix loaders, SvelteKit data and actions, Nuxt
    /// payloads and islands, Astro islands and actions. They belong to the development server, never to the simulation.
    static func isFrameworkRequest(_ url: URL, headers: [String: String]) -> Bool {
        let names = Set(headers.keys.map { $0.lowercased() })
        let marked: Set<String> = ["rsc", "next-action", "next-router-state-tree", "next-router-prefetch", "x-sveltekit-action"]
        if !names.isDisjoint(with: marked) { return true }
        let query = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name))
        if !query.isDisjoint(with: ["_rsc", "_data", "x-sveltekit-invalidated"]) { return true }
        let path = url.path
        if ["/__nuxt_island/", "/_server-islands/", "/_actions/"].contains(where: { path.hasPrefix($0) }) { return true }
        return path.hasSuffix("/__data.json") || path.hasSuffix("/_payload.json") || path.hasSuffix(".data")
    }

    /// Headers added to a framework request so the development server renders it afresh: Next.js serves cached server
    /// fetches in development unless the request says `no-cache`.
    static let frameworkRequestHeaders = ["cache-control": "no-cache"]

    /// Requests of the page that may go to their address without asking the simulation: the development server's own
    /// files (modules, styles, pictures, hot reload) and JSON files the app folder serves as they are.
    static func isDevelopmentResource(_ url: URL, appFolder: URL) -> Bool {
        let path = url.path
        // BUG-079: webpack's and Rspack's lazy compilation (`POST /lazy-compilation-using-…` tells the server which modules
        // to build), webpack-dev-server's own routes, Rsbuild's and Parcel's, and the stack-frame lookups of the overlays.
        let prefixes = ["/@vite/", "/@fs/", "/@id/", "/@react-refresh", "/node_modules/", "/__vite_ping", "/_next/", "/__nextjs",
                        "/sockjs-node", "/__webpack_hmr", "/__webpack_dev_server__", "/__open-in-editor", "/@vite-plugin",
                        "/lazy-compilation-using-", "/webpack-dev-server", "/__rspack", "/rsbuild-hmr", "/__rsbuild", "/__parcel",
                        "/__open-stack-frame-in-editor", "/__get-internal-source", "/__original-stack-frame"]
        if prefixes.contains(where: { path.hasPrefix($0) }) || path.contains(".hot-update.") { return true }
        let ext = (path as NSString).pathExtension.lowercased()
        let files: Set<String> = ["js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "css", "scss", "sass", "less", "svg", "png",
                                  "jpg", "jpeg", "gif", "webp", "avif", "ico", "woff", "woff2", "ttf", "otf", "eot", "map", "html",
                                  "htm", "txt", "wasm", "mp4", "webm", "mp3", "wav", "webmanifest"]
        if files.contains(ext) { return true }
        if ext == "json" {
            let relative = String(path.drop { $0 == "/" }).removingPercentEncoding ?? ""
            guard !relative.isEmpty, !relative.contains(".."), !relative.hasPrefix("node_modules") else { return false }
            for base in ["public", "static", ""] {
                let file = (base.isEmpty ? appFolder : appFolder.appendingPathComponent(base)).appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: file.path) { return true }
            }
        }
        return false
    }
}

/// The model connection policy (§11), separate from the application's: the project assistant reads the project only
/// (read-only tools or sandbox), without web access, and never receives confidential fields, headers or credential shapes.
enum StudioModelPolicy {
    static let description = "The assistant reads the project's files only (read-only), has no web access and never sees "
        + "confidential fields, headers or credentials: they are replaced by [redacted] before anything is sent."
}
