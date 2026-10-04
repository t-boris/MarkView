import AppKit
import Foundation
import WebKit

/// The app side of `BrowserAgentTools`: a Unix socket in the user's temporary folder that the
/// `--mcp-browser` processes of this app's terminals connect to. A request names the window
/// (`register`) and a tool; the tool runs in that window's browser tab (`BrowserAgentExecutor`).
@MainActor
enum BrowserControlServer {
    /// Window id → the window's tab for agents (shown, made when there is none).
    private static var windows: [UUID: () -> BrowserSession?] = [:]
    private static var listening: String?

    /// The socket path of this app process, listening once started.
    static var socketPath: String? {
        if let listening { return listening }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mv-browser-\(ProcessInfo.processInfo.processIdentifier).sock").path
        guard listen(at: path) else { return nil }
        listening = path
        return path
    }

    static func register(_ id: UUID, browser: @escaping () -> BrowserSession?) {
        windows[id] = browser
    }

    static func unregister(_ id: UUID) {
        windows[id] = nil
    }

    /// The arguments that start this binary as the MCP server for window `id`.
    static func mcpArguments(window id: UUID) -> (command: String, args: [String])? {
        guard let socket = socketPath, let executable = Bundle.main.executablePath else { return nil }
        return (executable, ["--mcp-browser", "--socket", socket, "--window", id.uuidString])
    }

    // MARK: - Socket

    private static func listen(at path: String) -> Bool {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = BrowserAgentTools.unixAddress(path) else { return false }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            NSLog("[MarkView] browser control socket unavailable at \(path)")
            return false
        }
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                DispatchQueue.global(qos: .userInitiated).async { serve(client) }
            }
        }
        thread.name = "MarkView browser control"
        thread.start()
        return true
    }

    /// One connection: a request line in, a reply line out.
    private nonisolated static func serve(_ client: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        guard let line = BrowserAgentTools.readLine(client),
              let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            close(client)
            return
        }
        let window = (request["window"] as? String).flatMap(UUID.init(uuidString:))
        let tool = request["tool"] as? String ?? ""
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        nonisolated(unsafe) let sendableArguments = arguments
        Task { @MainActor in
            let reply = await perform(tool, sendableArguments, window: window)
            let data = (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = BrowserAgentTools.writeAll(client, data + Data("\n".utf8))
                close(client)
            }
        }
    }

    private static func perform(_ tool: String, _ arguments: [String: Any], window: UUID?) async -> BrowserAgentTools.Reply {
        guard TerminalBrowserBridge.isEnabled else {
            return .error("MarkView's browser for terminals is turned off (globe menu → Open Terminal Links in MarkView).")
        }
        guard let window, let provider = windows[window] else {
            return .error("The MarkView window that started this terminal is closed.")
        }
        guard let session = provider() else { return .error("No browser tab is available in that window.") }
        return await BrowserAgentExecutor.run(tool, arguments, in: session)
    }
}

/// Performs the agent tools on a browser tab's web view.
@MainActor
enum BrowserAgentExecutor {
    static func run(_ tool: String, _ args: [String: Any], in session: BrowserSession) async -> BrowserAgentTools.Reply {
        session.agentControlled = true
        let web = session.webView
        switch tool {
        case "browser_navigate":
            guard let raw = args["url"] as? String, let url = BrowserAddress.url(from: raw) ?? URL(string: raw) else {
                return .error("A URL is required.")
            }
            session.load(url)
            await settle(session, started: true)
            return status(session)
        case "browser_snapshot":
            return await script(web, Scripts.snapshot, [:]) { value in
                guard let text = value as? String, let data = text.data(using: .utf8),
                      let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
                let elements = (page["elements"] as? [String] ?? []).joined(separator: "\n")
                return "URL: \(page["url"] ?? "")\nTitle: \(page["title"] ?? "")\n\n## Elements\n\(elements.isEmpty ? "(none)" : elements)\n\n## Text\n\(page["text"] ?? "")"
            }
        case "browser_click":
            let reply = await script(web, Scripts.find + Scripts.click, ["a": args]) { $0 as? String ?? "" }
            guard !reply.isError else { return reply }
            await settle(session, started: false)
            return BrowserAgentTools.Reply(text: reply.text + "\n" + status(session).text)
        case "browser_type":
            let reply = await script(web, Scripts.find + Scripts.type, ["a": args]) { $0 as? String ?? "" }
            if (args["submit"] as? Bool) == true, !reply.isError { await settle(session, started: false) }
            return reply
        case "browser_press_key":
            let reply = await script(web, Scripts.pressKey, ["key": args["key"] as? String ?? ""]) { $0 as? String ?? "" }
            await settle(session, started: false)
            return reply
        case "browser_evaluate":
            guard let body = args["script"] as? String, !body.isEmpty else { return .error("A script is required.") }
            return await script(web, "return JSON.stringify(await (async () => { \(body)\n })(), null, 1) ?? 'undefined';", [:]) {
                $0 as? String ?? "undefined"
            }
        case "browser_screenshot":
            return await screenshot(web)
        case "browser_console":
            let clear = (args["clear"] as? Bool) == true
            let reply = await script(web, Scripts.console, ["clear": clear]) { $0 as? String ?? "" }
            let dialogs = session.agentDialogs.map { "dialog: " + $0 }
            if clear { session.agentDialogs = [] }
            let text = ([reply.text] + dialogs).filter { !$0.isEmpty }.joined(separator: "\n")
            return BrowserAgentTools.Reply(text: text.isEmpty ? "(no console messages)" : text, isError: reply.isError)
        case "browser_wait_for":
            let limit = min(max((args["timeout_ms"] as? Int) ?? 10_000, 0), 60_000)
            let deadline = Date().addingTimeInterval(Double(limit) / 1000)
            guard let text = args["text"] as? String, !text.isEmpty else {
                try? await Task.sleep(nanoseconds: UInt64(limit) * 1_000_000)
                return status(session)
            }
            while Date() < deadline {
                let found = try? await web.callAsyncJavaScript("return (document.body ? document.body.innerText : '').includes(t);",
                                                               arguments: ["t": text], in: nil, contentWorld: .page) as? Bool
                if found == true { return BrowserAgentTools.Reply(text: "Found “\(text)”.") }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return .error("“\(text)” did not appear within \(limit) ms.")
        case "browser_back":
            guard web.canGoBack else { return .error("There is no previous page.") }
            web.goBack()
            await settle(session, started: true)
            return status(session)
        case "browser_reload":
            session.reload()
            await settle(session, started: true)
            return status(session)
        default:
            return .error("Unknown tool \(tool).")
        }
    }

    /// Wait until the page has loaded (at most 30 s). `started`: a load was just asked for; else
    /// give an action a moment to start one.
    private static func settle(_ session: BrowserSession, started: Bool) async {
        try? await Task.sleep(nanoseconds: started ? 150_000_000 : 350_000_000)
        let deadline = Date().addingTimeInterval(30)
        while session.webView.isLoading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func status(_ session: BrowserSession) -> BrowserAgentTools.Reply {
        if let error = session.loadError { return .error("Could not load \(session.url?.absoluteString ?? "the page"): \(error)") }
        return BrowserAgentTools.Reply(text: "Page: \(session.webView.url?.absoluteString ?? "") — \(session.webView.title ?? "")")
    }

    private static func script(_ web: WKWebView, _ body: String, _ arguments: [String: Any],
                               format: (Any?) -> String) async -> BrowserAgentTools.Reply {
        do {
            let value = try await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
            let text = format(value)
            if text.hasPrefix("ERROR: ") { return .error(String(text.dropFirst(7))) }
            return BrowserAgentTools.Reply(text: text)
        } catch {
            return .error("JavaScript error: \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)")
        }
    }

    private static func screenshot(_ web: WKWebView) async -> BrowserAgentTools.Reply {
        guard web.window != nil, web.bounds.width > 0 else {
            return .error("The browser tab is not visible in its window, so it cannot be captured.")
        }
        guard let image = try? await web.takeSnapshot(configuration: nil),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return .error("The screenshot failed.")
        }
        return BrowserAgentTools.Reply(text: "Screenshot of \(web.url?.absoluteString ?? "the page")", pngBase64: png.base64EncodedString())
    }

    /// Page-side scripts (run with `callAsyncJavaScript` in the page's world).
    enum Scripts {
        static let snapshot = #"""
        const out = [];
        let n = window.__mvRefCounter || 0;
        const visible = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
          return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
        const sel = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=switch],[role=combobox],[contenteditable=true],[onclick]';
        for (const el of document.querySelectorAll(sel)) {
          if (out.length >= 300) break;
          if (!visible(el)) continue;
          let ref = el.getAttribute('data-mv-ref');
          if (!ref) { ref = 'e' + (++n); el.setAttribute('data-mv-ref', ref); }
          const tag = el.tagName.toLowerCase();
          const role = el.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'input' ? 'input:' + (el.type || 'text') : tag);
          const name = (el.getAttribute('aria-label') || el.innerText || el.placeholder || el.title || el.name || '').trim().replace(/\s+/g, ' ').slice(0, 80);
          let extra = '';
          if (tag === 'a') extra += ' -> ' + el.getAttribute('href');
          if (el.type === 'checkbox' || el.type === 'radio') extra += el.checked ? ' [checked]' : ' [unchecked]';
          else if ((tag === 'input' || tag === 'textarea' || tag === 'select') && el.value) extra += ' value="' + String(el.value).slice(0, 60) + '"';
          if (el.disabled) extra += ' (disabled)';
          out.push('[' + ref + '] ' + role + ' "' + name + '"' + extra);
        }
        window.__mvRefCounter = n;
        const text = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').slice(0, 15000);
        return JSON.stringify({ url: location.href, title: document.title, text, elements: out });
        """#

        static let find = #"""
        const find = (a) => {
          if (a.ref) return document.querySelector('[data-mv-ref="' + a.ref + '"]');
          if (a.selector) return document.querySelector(a.selector);
          if (a.text) {
            // Buttons and links by their text; fields by placeholder, aria-label or <label>.
            const t = a.text.trim().toLowerCase();
            const name = e => (e.getAttribute('aria-label') || e.placeholder || (e.labels && e.labels[0] && e.labels[0].innerText)
              || e.innerText || (e.type === 'submit' || e.type === 'button' ? e.value : '') || e.title || '').trim().toLowerCase();
            const all = [...document.querySelectorAll('a,button,input,textarea,select,[contenteditable=true],[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],summary')];
            return all.find(e => name(e) === t) || all.find(e => name(e).includes(t));
          }
          return null;
        };
        const describe = (el) => el.tagName.toLowerCase() + ' "' + (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || '').trim().replace(/\s+/g, ' ').slice(0, 60) + '"';
        const el = find(a);
        if (!el) return 'ERROR: No element matches ' + JSON.stringify(a.ref || a.selector || a.text || '(nothing given)') + '. Take a new browser_snapshot.';
        el.scrollIntoView({ block: 'center', inline: 'center' });
        """#

        static let click = #"""
        if (el.disabled) return 'ERROR: ' + describe(el) + ' is disabled.';
        if (el.focus) el.focus();
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
          el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
        }
        el.click();
        return 'Clicked ' + describe(el) + '.';
        """#

        static let type = #"""
        const value = String(a.value ?? '');
        el.focus();
        if (el.isContentEditable) {
          el.textContent = a.append ? el.textContent + value : value;
          el.dispatchEvent(new InputEvent('input', { bubbles: true }));
        } else if ('value' in el) {
          const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
            : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
          setter.call(el, a.append ? el.value + value : value);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        } else {
          return 'ERROR: ' + describe(el) + ' does not take text.';
        }
        if (a.submit) {
          const init = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
          const go = el.dispatchEvent(new KeyboardEvent('keydown', init));
          el.dispatchEvent(new KeyboardEvent('keyup', init));
          if (go && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
          return 'Typed into ' + describe(el) + ' and submitted.';
        }
        return 'Typed into ' + describe(el) + '.';
        """#

        static let pressKey = #"""
        const el = document.activeElement || document.body;
        const named = { Enter: 13, Escape: 27, Tab: 9, Backspace: 8, Delete: 46, Space: 32, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39, Home: 36, End: 35, PageUp: 33, PageDown: 34 };
        const code = named[key] || (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
        const init = { key: key === 'Space' ? ' ' : key, keyCode: code, which: code, bubbles: true, cancelable: true };
        const go = el.dispatchEvent(new KeyboardEvent('keydown', init));
        if (key.length === 1) el.dispatchEvent(new KeyboardEvent('keypress', init));
        el.dispatchEvent(new KeyboardEvent('keyup', init));
        if (go && key === 'Enter' && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
        return 'Pressed ' + key + ' on ' + el.tagName.toLowerCase() + '.';
        """#

        static let console = #"""
        const log = window.__mvConsole || [];
        const text = log.join('\n');
        if (clear) log.length = 0;
        return text;
        """#
    }
}
