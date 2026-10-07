import AppKit
import SwiftUI
import WebKit

/// The tab of Prototype Studio: the live prototype on the left, the review conversation on the right.
/// "Point" lets the reviewer click an element in the preview and say what to do with it.
struct PrototypeStudioView: View {
    @ObservedObject var session: PrototypeSession
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var draft = ""
    @StateObject private var dictation = DictationController()
    @AppStorage(WhisperClient.apiKeyStorage) private var openAIKey = ""
    @AppStorage("prototypeChatWidth") private var chatWidth = 340.0
    @State private var dragStartWidth: Double?
    @FocusState private var draftFocused: Bool

    private static let widthRange: ClosedRange<Double> = 260...760

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                previewHeader
                Divider().background(VSDark.border)
                if session.hasSite {
                    PrototypePreview(session: session)
                } else {
                    placeholder
                }
            }
            resizeHandle
            conversation.frame(width: chatWidth)
        }
        .background(VSDark.bg)
        .onDisappear { dictation.cancel() }
        .onAppear { if !session.hasSite && !session.isBusy && session.manifest.version == 0 { session.generate() } }
    }

    /// The divider between preview and conversation; dragging it left widens the conversation.
    private var resizeHandle: some View {
        Rectangle().fill(VSDark.border).frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? chatWidth
                    dragStartWidth = start
                    chatWidth = min(max(start - value.translation.width, Self.widthRange.lowerBound), Self.widthRange.upperBound)
                }
                .onEnded { _ in dragStartWidth = nil })
            .help("Drag to resize the conversation")
    }

    // MARK: Preview

    private var previewHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.angled").uiFont(size: 10).foregroundColor(VSDark.blue)
            Text(session.manifest.title).uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text).lineLimit(1)
            if session.manifest.version > 0 {
                Text("v\(session.manifest.version)\(session.manifest.approved ? " · approved" : "")")
                    .uiFont(size: 10).foregroundColor(session.manifest.approved ? VSDark.green : VSDark.textDim)
            }
            if !session.runtimeErrors.isEmpty {
                Label("\(session.runtimeErrors.count)", systemImage: "exclamationmark.triangle.fill")
                    .uiFont(size: 10).foregroundColor(VSDark.orange)
                    .help(session.runtimeErrors.joined(separator: "\n"))
            }
            Spacer()
            Toggle(isOn: $session.pickMode) {
                Label("Point", systemImage: "cursorarrow.click.2")
            }
            .toggleStyle(.button).controlSize(.small).disabled(!session.hasSite || session.isBusy)
            .help("Click an element in the preview to say what should change about it")
            if session.manifest.version > 1 {
                Menu {
                    ForEach(session.manifest.history.reversed(), id: \.version) { entry in
                        Button("v\(entry.version): \(entry.instruction.isEmpty ? "Initial build" : String(entry.instruction.prefix(50)))") {
                            session.revert(to: entry.version)
                        }
                        .disabled(entry.version == session.manifest.version)
                    }
                } label: { Label("Versions", systemImage: "clock.arrow.circlepath") }
                .controlSize(.small).menuIndicator(.hidden).fixedSize().disabled(session.isBusy)
                .help("Go back to an earlier version")
            }
            Button { workspaceManager.openHTMLInBrowser(session.siteIndex) } label: {
                Image(systemName: "globe")
            }
            .buttonStyle(.plain).foregroundColor(VSDark.textDim).disabled(!session.hasSite)
            .help("Open the prototype in a browser tab")
            Button { NSWorkspace.shared.activateFileViewerSelecting([session.siteFolder]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain).foregroundColor(VSDark.textDim)
            .help("Show the prototype files in Finder")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(VSDark.bgSidebar)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            if session.isBusy {
                Text("Building the prototype takes a few minutes. Everything the assistant does is listed here.")
                    .uiFont(size: 11).foregroundColor(VSDark.textDim)
                PrototypeProgressView(session: session, maxLogHeight: 260).frame(maxWidth: 480)
            } else {
                Image(systemName: "rectangle.on.rectangle.angled").uiFont(size: 28).foregroundColor(VSDark.textDim)
                Text("No prototype files yet.").uiFont(size: 12).foregroundColor(VSDark.textDim)
            }
            if !session.isBusy && session.manifest.version == 0 {
                Button("Build the prototype") { session.generate() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(session.messages) { message in
                            bubble(message).id(message.id)
                        }
                        if session.isBusy && session.hasSite {
                            PrototypeProgressView(session: session, maxLogHeight: 150).id("stage")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: session.messages.count) { _ in
                    if let last = session.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider().background(VSDark.border)
            composer
        }
        .background(VSDark.bgSidebar)
    }

    private func bubble(_ message: PrototypeSession.Message) -> some View {
        let color: Color = message.role == .user ? VSDark.bgActive : message.role == .error ? VSDark.red.opacity(0.18) : VSDark.bg
        return Text(message.text)
            .uiFont(size: 11).foregroundColor(VSDark.text)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(color))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pick = session.pick {
                HStack(spacing: 6) {
                    Image(systemName: "scope").foregroundColor(VSDark.blue)
                    Text(pick.text.isEmpty ? pick.selector : "“\(pick.text.prefix(40))” · \(pick.tag)")
                        .uiFont(size: 10).foregroundColor(VSDark.text).lineLimit(1)
                    Spacer()
                    Button { session.pick = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(VSDark.textDim)
                }
                .padding(6).background(RoundedRectangle(cornerRadius: 5).fill(VSDark.selection.opacity(0.5)))
            } else if session.pickMode {
                Text("Click an element in the preview.").uiFont(size: 10).foregroundColor(VSDark.blue)
            }
            HStack(alignment: .top, spacing: 6) {
                TextEditor(text: $draft)
                    .uiFont(size: 12)
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .focused($draftFocused)
                    .padding(4).background(RoundedRectangle(cornerRadius: 5).fill(VSDark.bgInput))
                    .disabled(!session.hasSite || session.isBusy)
                if openAIKey.isEmpty {
                    Button { DDESettingsWindow.show(workspace: workspaceManager) } label: {
                        Image(systemName: "mic").uiFont(size: 13).foregroundColor(VSDark.textDim)
                    }
                    .buttonStyle(.plain).padding(.top, 4)
                    .help("Set up voice input in DDE Settings")
                    .accessibilityLabel("Set up voice input")
                } else {
                    DictationButton(dictation: dictation) { transcript, window in
                        DictationInsertion.insert(transcript, window: window, fieldFocused: draftFocused, text: &draft)
                    }
                    .padding(.top, 2)
                }
            }
            DictationStatusView(dictation: dictation) { DDESettingsWindow.show(workspace: workspaceManager) }
            HStack {
                Button {
                    session.approveAndExport()
                } label: { Label("Approve & export", systemImage: "checkmark.seal") }
                .controlSize(.small).disabled(!session.hasSite || session.isBusy)
                .help("Write SPEC.md and pack the prototype, the specification and the review history into a zip")
                if let archive = session.archive {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([archive]) } label: {
                        Label("Show zip", systemImage: "archivebox")
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("Send") { submit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isBusy || !session.hasSite)
            }
        }
        .padding(10)
    }

    private func submit() {
        session.send(draft)
        draft = ""
    }
}

// MARK: - Progress

/// What a running assistant is doing: the current step, the time so far and a list of its actions
/// (files read, searches, files being written), so a long run never looks like a hang.
struct PrototypeProgressView: View {
    @ObservedObject var session: PrototypeSession
    var maxLogHeight: CGFloat

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text((session.stage ?? "Working") + "…").uiFont(size: 11, weight: .medium).foregroundColor(VSDark.text).lineLimit(2)
                Spacer()
                if let started = session.runStarted {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(started))
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                            .uiFont(size: 10, design: .monospaced).foregroundColor(VSDark.textDim)
                    }
                }
                Button("Stop") { session.cancel() }.controlSize(.small)
            }
            if !session.activity.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(session.activity) { line in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(Self.clock.string(from: line.time))
                                        .uiFont(size: 9, design: .monospaced).foregroundColor(VSDark.textDim)
                                    Text(line.text).uiFont(size: 10).foregroundColor(VSDark.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(line.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: maxLogHeight)
                    .background(RoundedRectangle(cornerRadius: 5).fill(VSDark.bgInput.opacity(0.6)))
                    .onChange(of: session.activity.count) { _ in
                        if let last = session.activity.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

// MARK: - Preview web view

/// Shows `site/index.html`. A user script marks the element under the pointer while `pickMode` is on and
/// reports the click; another reports JavaScript errors so the assistant can fix them.
private struct PrototypePreview: NSViewRepresentable {
    @ObservedObject var session: PrototypeSession

    private static let pickScript = """
    (function () {
      var on = false, box = document.createElement('div');
      box.style.cssText = 'position:fixed;pointer-events:none;border:2px solid #0a84ff;background:rgba(10,132,255,.14);z-index:2147483647;display:none';
      function path(el) {
        var parts = [];
        while (el && el.nodeType === 1 && el !== document.body) {
          var s = el.tagName.toLowerCase();
          if (el.id) { parts.unshift(s + '#' + el.id); break; }
          var cls = (typeof el.className === 'string' && el.className.trim()) ? el.className.trim().split(/\\s+/).slice(0, 2).join('.') : '';
          if (cls) s += '.' + cls;
          var i = 1, sib = el;
          while ((sib = sib.previousElementSibling)) if (sib.tagName === el.tagName) i++;
          parts.unshift(s + ':nth-of-type(' + i + ')');
          el = el.parentElement;
        }
        return parts.join(' > ');
      }
      document.addEventListener('DOMContentLoaded', function () { document.documentElement.appendChild(box); });
      document.addEventListener('mouseover', function (e) {
        if (!on) return;
        var r = e.target.getBoundingClientRect();
        box.style.display = 'block'; box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
        box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
      }, true);
      ['click', 'mousedown', 'mouseup', 'submit'].forEach(function (type) {
        document.addEventListener(type, function (e) {
          if (!on) return;
          e.preventDefault(); e.stopPropagation();
          if (type !== 'click') return;
          var el = e.target;
          window.webkit.messageHandlers.mvPick.postMessage({
            selector: path(el), tag: el.tagName.toLowerCase(),
            text: (el.innerText || el.value || '').trim().slice(0, 200),
            html: el.outerHTML.slice(0, 800), screen: location.hash || ''
          });
        }, true);
      });
      window.__mvPick = function (v) {
        on = v; if (!v) box.style.display = 'none';
        document.documentElement.style.cursor = v ? 'crosshair' : '';
      };
      window.addEventListener('error', function (e) {
        window.webkit.messageHandlers.mvError.postMessage((e.message || 'Error') + (e.lineno ? ' (' + (e.filename || '').split('/').pop() + ':' + e.lineno + ')' : ''));
      });
      window.addEventListener('unhandledrejection', function (e) {
        window.webkit.messageHandlers.mvError.postMessage('Unhandled promise rejection: ' + (e.reason && e.reason.message || e.reason));
      });
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.add(context.coordinator, name: "mvPick")
        controller.add(context.coordinator, name: "mvError")
        controller.addUserScript(WKUserScript(source: Self.pickScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.load(session: session, keepingScreen: false)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.session = session
        if coordinator.loadedToken != session.reloadToken {
            coordinator.load(session: session, keepingScreen: true)
        }
        coordinator.applyPickMode(session.pickMode)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var session: PrototypeSession
        weak var webView: WKWebView?
        var loadedToken = -1
        private var pickMode = false

        init(session: PrototypeSession) { self.session = session }

        /// Loads index.html; after a change the screen the reviewer was on stays selected.
        func load(session: PrototypeSession, keepingScreen: Bool) {
            guard let webView else { return }
            loadedToken = session.reloadToken
            let index = session.siteIndex
            let reload = { (hash: String) in
                var url = index
                if !hash.isEmpty, var parts = URLComponents(url: index, resolvingAgainstBaseURL: false) {
                    parts.fragment = String(hash.drop(while: { $0 == "#" }))
                    url = parts.url ?? index
                }
                webView.loadFileURL(url, allowingReadAccessTo: session.siteFolder)
            }
            if keepingScreen {
                webView.evaluateJavaScript("location.hash") { value, _ in reload(value as? String ?? "") }
            } else {
                reload("")
            }
        }

        func applyPickMode(_ on: Bool) {
            pickMode = on
            webView?.evaluateJavaScript("window.__mvPick && window.__mvPick(\(on))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { applyPickMode(pickMode) }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let name = message.name, body = message.body
            Task { @MainActor in
                if name == "mvError", let text = body as? String {
                    session.report(error: String(text.prefix(300)))
                } else if name == "mvPick", let info = body as? [String: Any] {
                    func field(_ key: String) -> String { info[key] as? String ?? "" }
                    session.pick = PrototypeAI.Pick(selector: field("selector"), tag: field("tag"), text: field("text"),
                                                    html: field("html"), screen: field("screen"))
                    session.pickMode = false
                }
            }
        }
    }
}
