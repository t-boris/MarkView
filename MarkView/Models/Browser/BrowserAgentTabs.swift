import Foundation

/// A window's browser tabs as agents drive them: what the tool server (`AgentToolServer`) hands to the window's browser when a
/// `browser_*` tool is called. The window registers `run` as its `AgentToolWindow.browser`; the server knows no tab. `browser_tabs`
/// lists the tabs, `browser_open_tab` opens one, and every other tool runs in one tab (`BrowserAgentExecutor`).
@MainActor
struct BrowserAgentTabs {
    /// The window's browser tabs, in tab order.
    var tabs: () -> [BrowserSession]
    /// The browser tab in front, nil when a document is.
    var active: () -> BrowserSession?
    /// Bring a browser tab to the front.
    var show: (BrowserSession) -> Void
    /// Open a browser tab (an empty one for nil) with an agent name.
    var open: (URL?, String?) -> BrowserSession

    func run(_ tool: String, _ args: [String: Any]) async -> BrowserAgentTools.Reply {
        switch tool {
        case "browser_tabs":
            return BrowserAgentTools.Reply(text: tabList())
        case "browser_open_tab":
            let url = (args["url"] as? String).flatMap { BrowserAddress.url(from: $0) ?? URL(string: $0) }
            let session = open(url, (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            session.agentLastUsed = Date()
            if url != nil { await BrowserAgentExecutor.settle(session, started: true) }
            return BrowserAgentTools.Reply(text: "Opened tab \(session.agentName)." + (url == nil ? "" : " " + BrowserAgentExecutor.status(session).text))
        default:
            let session: BrowserSession
            if let query = args["tab"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let all = tabs()
                guard let index = BrowserAgentTools.tabIndex(query, in: all.map { ($0.agentName, $0.displayTitle, $0.url?.absoluteString ?? "") }) else {
                    return .error("No single browser tab matches “\(query)”.\n" + tabList())
                }
                session = all[index]
            } else {
                session = active() ?? tabs().first ?? open(nil, nil)
            }
            guard !session.agentStopped else {
                return .error("The user stopped agent control of tab \(session.agentName). Do not retry; ask the user.")
            }
            show(session)
            session.agentLastUsed = Date()
            return await BrowserAgentExecutor.run(tool, args, in: session)
        }
    }

    private func tabList() -> String {
        let front = active()
        let all = tabs()
        guard !all.isEmpty else { return "No browser tabs are open; browser_open_tab opens one." }
        return all.map { tab in
            var line = "\(tab.agentName): \(tab.displayTitle) — \(tab.url?.absoluteString ?? "(empty)")"
            if tab === front { line += " [active]" }
            if tab.agentStopped { line += " [stopped by the user]" }
            return line
        }.joined(separator: "\n")
    }
}
