import AppKit
import Foundation
import WebKit

/// The app side of `BrowserAgentTools`: a Unix socket in the user's temporary folder that the
/// `--mcp-browser` processes of this app's terminals connect to. A request names the window — by
/// id, or by the processes above the MCP server (its terminal's shell) — and a tool; the tool runs
/// in one of that window's browser tabs (`BrowserAgentExecutor`).
@MainActor
enum BrowserControlServer {
    /// What a window offers agents: its browser tabs, the active one, bringing one to the front,
    /// and opening a new one.
    struct Window {
        var tabs: () -> [BrowserSession]
        var active: () -> BrowserSession?
        var show: (BrowserSession) -> Void
        var open: (URL?, String?) -> BrowserSession
    }

    private static var windows: [UUID: Window] = [:]
    private static var listening: String?

    /// The socket path of this app process, listening once started.
    static var socketPath: String? {
        if let listening { return listening }
        let path = BrowserAgentTools.socketPath(forApp: ProcessInfo.processInfo.processIdentifier)
        guard listen(at: path) else { return nil }
        listening = path
        return path
    }

    /// Per agent and per Mac: give it the server when it starts from the AI panel (default on). Off
    /// for an agent whose organisation blocks MCP servers it does not list (BUG-025).
    static func agentToolsKey(_ tool: CLITool) -> String { "browser.agentTools." + tool.rawValue }

    static func agentToolsEnabled(_ tool: CLITool) -> Bool {
        UserDefaults.standard.object(forKey: agentToolsKey(tool)) as? Bool ?? true
    }

    static func register(_ id: UUID, _ window: Window) {
        windows[id] = window
        _ = socketPath
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
        let pids = (request["pids"] as? [Int] ?? []).map(Int32.init)
        let tool = request["tool"] as? String ?? ""
        nonisolated(unsafe) let arguments = request["arguments"] as? [String: Any] ?? [:]
        Task { @MainActor in
            let reply = await perform(tool, arguments, window: window, pids: pids)
            let data = (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = BrowserAgentTools.writeAll(client, data + Data("\n".utf8))
                close(client)
            }
        }
    }

    // MARK: - Tools

    private static func perform(_ tool: String, _ args: [String: Any], window id: UUID?, pids: [Int32]) async -> BrowserAgentTools.Reply {
        guard TerminalBrowserBridge.isEnabled else {
            return .error("MarkView's browser for terminals is turned off (globe menu → Open Terminal Links in MarkView).")
        }
        let windowID = id.flatMap { windows[$0] != nil ? $0 : nil } ?? TerminalBrowserBridge.windowID(forAncestors: pids)
        guard let windowID, let window = windows[windowID] else {
            return .error("The MarkView window of this terminal is closed, or this agent was not started in a MarkView terminal.")
        }
        switch tool {
        case "browser_tabs":
            return BrowserAgentTools.Reply(text: tabList(window))
        case "browser_open_tab":
            let url = (args["url"] as? String).flatMap { BrowserAddress.url(from: $0) ?? URL(string: $0) }
            let session = window.open(url, (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            session.agentLastUsed = Date()
            if url != nil { await BrowserAgentExecutor.settle(session, started: true) }
            return BrowserAgentTools.Reply(text: "Opened tab \(session.agentName)." + (url == nil ? "" : " " + BrowserAgentExecutor.status(session).text))
        default:
            let session: BrowserSession
            if let query = args["tab"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let tabs = window.tabs()
                guard let index = BrowserAgentTools.tabIndex(query, in: tabs.map { ($0.agentName, $0.displayTitle, $0.url?.absoluteString ?? "") }) else {
                    return .error("No single browser tab matches “\(query)”.\n" + tabList(window))
                }
                session = tabs[index]
            } else {
                session = window.active() ?? window.tabs().first ?? window.open(nil, nil)
            }
            guard !session.agentStopped else {
                return .error("The user stopped agent control of tab \(session.agentName). Do not retry; ask the user.")
            }
            window.show(session)
            session.agentLastUsed = Date()
            return await BrowserAgentExecutor.run(tool, args, in: session)
        }
    }

    private static func tabList(_ window: Window) -> String {
        let active = window.active()
        let tabs = window.tabs()
        guard !tabs.isEmpty else { return "No browser tabs are open; browser_open_tab opens one." }
        return tabs.map { tab in
            var line = "\(tab.agentName): \(tab.displayTitle) — \(tab.url?.absoluteString ?? "(empty)")"
            if tab === active { line += " [active]" }
            if tab.agentStopped { line += " [stopped by the user]" }
            return line
        }.joined(separator: "\n")
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
                return "Tab: \(session.agentName)\nURL: \(page["url"] ?? "")\nTitle: \(page["title"] ?? "")\n\n## Elements\n\(elements.isEmpty ? "(none)" : elements)\n\n## Text\n\(page["text"] ?? "")"
            }
        case "browser_click":
            return await click(args, in: session)
        case "browser_type":
            return await type(args, in: session)
        case "browser_press_key":
            let key = args["key"] as? String ?? ""
            guard !key.isEmpty else { return .error("A key is required.") }
            let reply: BrowserAgentTools.Reply
            if canUseNativeInput(web), let event = keyEvents(key, in: web) {
                withFocus(web) {
                    web.keyDown(with: event.down)
                    web.keyUp(with: event.up)
                }
                reply = BrowserAgentTools.Reply(text: "Pressed \(key).")
            } else {
                reply = await script(web, Scripts.pressKey, ["key": key]) { $0 as? String ?? "" }
            }
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

    // MARK: Real input (trusted events)

    /// Native events need the web view on screen in its window.
    private static func canUseNativeInput(_ web: WKWebView) -> Bool {
        web.window != nil && web.bounds.width > 0 && web.bounds.height > 0 && !web.isHiddenOrHasHiddenAncestor
    }

    /// A mouse click on the element's centre as the user's own (`isTrusted`) click; a script click
    /// when the tab is not on screen or something else covers the element.
    private static func click(_ args: [String: Any], in session: BrowserSession) async -> BrowserAgentTools.Reply {
        let web = session.webView
        let located = await script(web, Scripts.find + Scripts.locate, ["a": args]) { $0 as? String ?? "" }
        guard !located.isError, let data = located.text.data(using: .utf8),
              let target = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return located }
        let description = target["describe"] as? String ?? "the element"
        if (target["disabled"] as? Bool) == true { return .error("\(description) is disabled.") }
        let point = CGPoint(x: target["x"] as? Double ?? 0, y: target["y"] as? Double ?? 0)
        var how = "with a mouse click"
        if canUseNativeInput(web), (target["hit"] as? Bool) == true, let window = web.window {
            let location = windowPoint(point, in: web)
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                switch type {
                case .mouseMoved: web.mouseMoved(with: event)
                case .leftMouseDown: web.mouseDown(with: event)
                default: web.mouseUp(with: event)
                }
            }
        } else {
            let reply = await script(web, Scripts.find + Scripts.click, ["a": args]) { $0 as? String ?? "" }
            guard !reply.isError else { return reply }
            how = (target["hit"] as? Bool) == false ? "by script (another element covers it)" : "by script (the tab is not on screen)"
        }
        await settle(session, started: false)
        return BrowserAgentTools.Reply(text: "Clicked \(description) \(how).\n" + status(session).text)
    }

    /// Focus the field, select what it holds (unless appending), and type the text through the web
    /// view's text input as real keystrokes; a script sets the value when that did not take.
    private static func type(_ args: [String: Any], in session: BrowserSession) async -> BrowserAgentTools.Reply {
        let web = session.webView
        let value = args["value"] as? String ?? ""
        let prepared = await script(web, Scripts.find + Scripts.prepareTyping, ["a": args]) { $0 as? String ?? "" }
        guard !prepared.isError else { return prepared }
        var how = "as keystrokes"
        var typed = false
        if canUseNativeInput(web), let client = web as? NSTextInputClient {
            withFocus(web) { client.insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            let current = await script(web, Scripts.focusedValue, [:]) { $0 as? String ?? "" }
            typed = value.isEmpty || current.text.contains(value)
        }
        if !typed {
            let reply = await script(web, Scripts.find + Scripts.type, ["a": args.merging(["submit": false]) { $1 }]) { $0 as? String ?? "" }
            guard !reply.isError else { return reply }
            how = "by script"
        }
        if (args["submit"] as? Bool) == true {
            if canUseNativeInput(web), let enter = keyEvents("Enter", in: web) {
                withFocus(web) {
                    web.keyDown(with: enter.down)
                    web.keyUp(with: enter.up)
                }
            } else {
                _ = await script(web, Scripts.pressKey, ["key": "Enter"]) { $0 as? String ?? "" }
            }
            await settle(session, started: false)
            return BrowserAgentTools.Reply(text: "Typed into \(prepared.text) \(how) and pressed Enter.\n" + status(session).text)
        }
        return BrowserAgentTools.Reply(text: "Typed into \(prepared.text) \(how).")
    }

    /// Run `body` with the web view as its window's first responder (key events and text input go
    /// to the first responder), then give the focus back to where it was.
    private static func withFocus(_ web: WKWebView, _ body: () -> Void) {
        guard let window = web.window else { return body() }
        let previous = window.firstResponder
        if previous !== web { window.makeFirstResponder(web) }
        body()
        if let previous, previous !== web { window.makeFirstResponder(previous) }
    }

    /// A point in page (CSS) pixels of the visible viewport → the window's coordinates.
    private static func windowPoint(_ point: CGPoint, in web: WKWebView) -> CGPoint {
        let scale = web.pageZoom * web.magnification
        var local = CGPoint(x: point.x * scale, y: point.y * scale)
        if !web.isFlipped { local.y = web.bounds.height - local.y }
        return web.convert(local, to: nil)
    }

    private static func keyEvents(_ key: String, in web: WKWebView) -> (down: NSEvent, up: NSEvent)? {
        func function(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
        let named: [String: (code: UInt16, characters: String)] = [
            "Enter": (36, "\r"), "Return": (36, "\r"), "Tab": (48, "\t"), "Escape": (53, "\u{1b}"),
            "Backspace": (51, "\u{7f}"), "Delete": (117, function(NSDeleteFunctionKey)), "Space": (49, " "),
            "ArrowUp": (126, function(NSUpArrowFunctionKey)), "ArrowDown": (125, function(NSDownArrowFunctionKey)),
            "ArrowLeft": (123, function(NSLeftArrowFunctionKey)), "ArrowRight": (124, function(NSRightArrowFunctionKey)),
            "Home": (115, function(NSHomeFunctionKey)), "End": (119, function(NSEndFunctionKey)),
            "PageUp": (116, function(NSPageUpFunctionKey)), "PageDown": (121, function(NSPageDownFunctionKey)),
        ]
        guard let window = web.window else { return nil }
        guard let spec = named[key] ?? (key.count == 1 ? (0, key) : nil) else { return nil }
        func make(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: spec.characters,
                             charactersIgnoringModifiers: spec.characters, isARepeat: false, keyCode: spec.code)
        }
        guard let down = make(.keyDown), let up = make(.keyUp) else { return nil }
        return (down, up)
    }

    // MARK: Helpers

    /// Wait until the page has loaded (at most 30 s). `started`: a load was just asked for; else
    /// give an action a moment to start one.
    static func settle(_ session: BrowserSession, started: Bool) async {
        try? await Task.sleep(nanoseconds: started ? 150_000_000 : 350_000_000)
        let deadline = Date().addingTimeInterval(30)
        while session.webView.isLoading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static func status(_ session: BrowserSession) -> BrowserAgentTools.Reply {
        if let error = session.loadError { return .error("Could not load \(session.url?.absoluteString ?? "the page"): \(error)") }
        return BrowserAgentTools.Reply(text: "Tab \(session.agentName): \(session.webView.url?.absoluteString ?? "") — \(session.webView.title ?? "")")
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
          else if ((tag === 'input' || tag === 'textarea' || tag === 'select') && el.value && el.type !== 'password') extra += ' value="' + String(el.value).slice(0, 60) + '"';
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
        const describe = (el) => el.tagName.toLowerCase() + ' "' + (el.getAttribute('aria-label') || el.innerText || (el.type === 'password' ? '' : el.value) || el.placeholder || '').trim().replace(/\s+/g, ' ').slice(0, 60) + '"';
        const el = find(a);
        if (!el) return 'ERROR: No element matches ' + JSON.stringify(a.ref || a.selector || a.text || '(nothing given)') + '. Take a new browser_snapshot.';
        el.scrollIntoView({ block: 'center', inline: 'center' });
        """#

        /// The element's centre in viewport pixels, and whether a click there reaches it.
        static let locate = #"""
        const r = el.getBoundingClientRect();
        const x = r.left + r.width / 2, y = r.top + r.height / 2;
        const top = document.elementFromPoint(x, y);
        return JSON.stringify({ x, y, hit: !!top && (top === el || el.contains(top) || top.contains(el)),
                                disabled: !!el.disabled, describe: describe(el) });
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

        /// Focus the field and select its content, so typing replaces it (or put the caret at the end).
        static let prepareTyping = #"""
        el.focus();
        if (el.isContentEditable) {
          const range = document.createRange();
          range.selectNodeContents(el);
          if (a.append) range.collapse(false);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
        } else if ('value' in el && typeof el.select === 'function') {
          if (a.append) { try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {} } else { el.select(); }
        } else {
          return 'ERROR: ' + describe(el) + ' does not take text.';
        }
        return describe(el);
        """#

        static let focusedValue = #"""
        const el = document.activeElement;
        if (!el) return '';
        return el.isContentEditable ? el.textContent : String(el.value ?? '');
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
