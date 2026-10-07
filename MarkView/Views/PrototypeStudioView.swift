import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
    /// What Point sends about the element: its HTML, or its HTML and a screenshot of it.
    @AppStorage("prototypePickScreenshot") private var pickScreenshot = true
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
                Text("The assistant plans the screens, builds the shell, then writes the screens side by side. Everything it does is listed here.")
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
        return VStack(alignment: .leading, spacing: 6) {
            Text(message.text)
                .uiFont(size: 11).foregroundColor(VSDark.text)
                .textSelection(.enabled)
            if !message.images.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 90, maxHeight: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
        }
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
                Picker("", selection: $pickScreenshot) {
                    Text("HTML").tag(false)
                    Text("HTML + screenshot").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .help("What the assistant gets about the pointed-at element")
                if pickScreenshot, let shot = session.pickShot, let image = NSImage(data: shot) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            } else if session.pickMode {
                Text("Click an element in the preview.").uiFont(size: 10).foregroundColor(VSDark.blue)
            }
            if !session.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.attachments) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: attachment.image).resizable().scaledToFill().frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Button { session.removeAttachment(attachment.id) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.white).shadow(radius: 1)
                                }
                                .buttonStyle(.plain).padding(2)
                            }
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 6) {
                TextEditor(text: $draft)
                    .uiFont(size: 12)
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .focused($draftFocused)
                    .padding(4).background(RoundedRectangle(cornerRadius: 5).fill(VSDark.bgInput))
                    .disabled(!session.hasSite || session.isBusy)
                    .onPasteCommand(of: [.image, .png, .tiff, .fileURL]) { _ in
                        // Images on the pasteboard become attachments; a text paste has no image and is left alone.
                        if !session.attachFromPasteboard() { pasteText() }
                    }
                    .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                        for provider in providers where provider.canLoadObject(ofClass: NSImage.self) {
                            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                                guard let image = object as? NSImage, let png = PrototypeImages.pngData(from: image) else { return }
                                Task { @MainActor in session.attach([png]) }
                            }
                        }
                        return true
                    }
                Menu {
                    Button("Choose image…") { chooseImages() }
                    Button("Paste image from clipboard") { session.attachFromPasteboard() }
                } label: {
                    Image(systemName: "paperclip").uiFont(size: 13).foregroundColor(VSDark.textDim)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(!session.hasSite || session.isBusy)
                .help("Send an image with your request: paste it (⌘V), drop it here, or choose a file")
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
                    .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.attachments.isEmpty)
                              || session.isBusy || !session.hasSite)
            }
        }
        .padding(10)
    }

    private func submit() {
        session.send(draft, withScreenshot: pickScreenshot)
        draft = ""
    }

    /// A paste with no image: put the clipboard's text into the draft, as the editor would have.
    private func pasteText() {
        if let text = NSPasteboard.general.string(forType: .string) { draft += text }
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        session.attach(panel.urls.compactMap { PrototypeImages.image(at: $0) })
    }
}

// MARK: - Progress

/// What a running assistant is doing: the current step, the time so far and a list of its actions
/// (files read, searches, files being written), so a long run never looks like a hang.
struct PrototypeProgressView: View {
    @ObservedObject var session: PrototypeSession
    var maxLogHeight: CGFloat

    @ViewBuilder
    private func screenIcon(_ state: PrototypeAI.ScreenState) -> some View {
        switch state {
        case .queued: Image(systemName: "circle").uiFont(size: 10).foregroundColor(VSDark.textDim)
        case .writing: ProgressView().controlSize(.mini).scaleEffect(0.7)
        case .done: Image(systemName: "checkmark.circle.fill").uiFont(size: 11).foregroundColor(VSDark.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").uiFont(size: 11).foregroundColor(VSDark.red)
        }
    }

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
            if let phase = session.phase {
                Text(phase).uiFont(size: 10, weight: .semibold).foregroundColor(VSDark.blue).fixedSize(horizontal: false, vertical: true)
            }
            if !session.screens.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(session.screens) { screen in
                        HStack(spacing: 6) {
                            screenIcon(screen.state).frame(width: 14)
                            Text(screen.name).uiFont(size: 11).foregroundColor(screen.state == .queued ? VSDark.textDim : VSDark.text)
                                .lineLimit(1)
                            if case .failed(let problem) = screen.state {
                                Text(problem).uiFont(size: 9).foregroundColor(VSDark.red).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 5).fill(VSDark.bgInput.opacity(0.6)))
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
          var el = e.target, r = el.getBoundingClientRect();
          box.style.display = 'none';  // the highlight must not be in the screenshot
          window.webkit.messageHandlers.mvPick.postMessage({
            selector: path(el), tag: el.tagName.toLowerCase(),
            text: (el.innerText || el.value || '').trim().slice(0, 200),
            html: el.outerHTML.slice(0, 800), screen: location.hash || '',
            rect: { x: r.left, y: r.top, w: r.width, h: r.height }
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

        /// A screenshot of the pointed-at element, kept with the pick; sent only if the reviewer chose HTML + screenshot.
        private func snapshot(of pick: PrototypeAI.Pick) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, let webView = self.webView else { return }
                let config = WKSnapshotConfiguration()
                config.rect = pick.rect.intersection(webView.bounds)
                guard config.rect.width > 1, config.rect.height > 1 else { return }
                config.snapshotWidth = NSNumber(value: Double(min(config.rect.width * 2, 1600)))
                webView.takeSnapshot(with: config) { image, _ in
                    guard let image, let png = PrototypeImages.pngData(from: image) else { return }
                    Task { @MainActor in
                        if self.session.pick?.selector == pick.selector { self.session.pickShot = png }
                    }
                }
            }
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let name = message.name, body = message.body
            Task { @MainActor in
                if name == "mvError", let text = body as? String {
                    session.report(error: String(text.prefix(300)))
                } else if name == "mvPick", let info = body as? [String: Any] {
                    func field(_ key: String) -> String { info[key] as? String ?? "" }
                    let box = info["rect"] as? [String: Any] ?? [:]
                    func number(_ key: String) -> CGFloat { CGFloat((box[key] as? NSNumber)?.doubleValue ?? 0) }
                    let rect = CGRect(x: number("x"), y: number("y"), width: number("w"), height: number("h"))
                    let pick = PrototypeAI.Pick(selector: field("selector"), tag: field("tag"), text: field("text"),
                                                html: field("html"), screen: field("screen"), rect: rect)
                    session.pick = pick
                    session.pickMode = false
                    snapshot(of: pick)
                }
            }
        }
    }
}
