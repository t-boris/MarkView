import SwiftUI
import WebKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The conversation of a discussion as a web page (`Editor/discussion.html`): each answer drawn in the form that fits it.
/// Swift sends the turns and the live answer; the page requests drawing saves and Markdown copies.
struct DiscussionThreadView: NSViewRepresentable {
    var turns: [DiscussionTurn]
    var live: DiscussionStore.Live?
    @EnvironmentObject private var theme: WindowTheme

    static var pageURL: URL? { Bundle.main.url(forResource: "discussion", withExtension: "html", subdirectory: "Editor") }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WebHost.makeConfiguration(
            handlers: [.message("discussion", context.coordinator.messages)],
            userScripts: [
                // `mvBridge.send` in the page validates every message against the contract (AR-28).
                context.coordinator.messages.contract.userScript,
                // The first paint already has this window's theme; later changes arrive through `mvSetTheme`.
                WKUserScript(source: theme.firstPaintScript, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            ])
        let view = WebHost.makeWebView(configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = view
        if let page = Self.pageURL { view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(turns: turns, live: live, theme: theme.webArguments)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        /// The page's messages (channel "discussion" of `bridge-contract.json`).
        let messages = TypedWebBridge(channel: "discussion")
        private var ready = false
        private var sentTurns: [DiscussionTurn]?
        private var sentLive: DiscussionStore.Live??
        private var sentTheme: WebThemeArguments?
        private var wanted: (turns: [DiscussionTurn], live: DiscussionStore.Live?, theme: WebThemeArguments)?

        func update(turns: [DiscussionTurn], live: DiscussionStore.Live?, theme: WebThemeArguments) {
            wanted = (turns, live, theme)
            flush()
        }

        private func flush() {
            guard ready, let view, let wanted else { return }
            if sentTheme != wanted.theme { sentTheme = wanted.theme; call("window.mvSetTheme", wanted.theme.list, on: view) }
            if sentTurns != wanted.turns {
                sentTurns = wanted.turns
                // The page takes the turns as one JSON text and parses it itself.
                call("window.mvSetTurns", [Self.json(wanted.turns.map { ["question": $0.question, "answer": $0.answer] })], on: view)
            }
            if sentLive == nil || sentLive! != wanted.live {
                sentLive = .some(wanted.live)
                if let live = wanted.live {
                    call("window.mvSetLive", [Self.json(["question": live.question, "text": live.text, "status": live.status])], on: view)
                } else {
                    call("window.mvSetLive", [NSNull()], on: view)
                }
            }
        }

        /// Calls a function of the discussion page (`JS.call`: the arguments are JSON, never script text).
        private func call(_ function: String, _ args: [Any], on view: WKWebView) {
            guard let script = JS.call(function, args: args) else { return }
            view.evaluateJavaScript(script)
        }

        /// A plain JSON value as text. Takes no `Any` downcasts: an empty array casts to every array type, which once recursed forever.
        private static func json(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return "[]" }
            return String(data: data, encoding: .utf8) ?? "[]"
        }

        override init() {
            super.init()
            messages.on(DiscussionMessage.Ready.self) { [weak self] _ in
                guard let self else { return }
                ready = true
                sentTurns = nil; sentLive = nil; sentTheme = nil
                flush()
            }
            messages.on(DiscussionMessage.Copy.self) { message in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.payload.text, forType: .string)
            }
            messages.on(DiscussionMessage.Save.self) { message in
                let save = message.payload
                let bytes = save.base64 == true ? Data(base64Encoded: save.data) : save.data.data(using: .utf8)
                guard let bytes else { return }
                DispatchQueue.main.async { Self.save(bytes, suggested: save.name) }
            }
        }

        private static func save(_ data: Data, suggested: String) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggested
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                try? data.write(to: url, options: .atomic)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else if action.targetFrame == nil {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
