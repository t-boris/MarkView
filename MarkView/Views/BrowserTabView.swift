import AppKit
import SwiftUI
import WebKit

/// A browser tab in the centre: navigation, address field, "Save as Markdown" into the
/// project, and the Preview Web App states shown until the app's page is up.
struct BrowserTabView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @ObservedObject var session: BrowserSession
    @State private var address = ""
    @State private var editingAddress = false
    @FocusState private var addressFocused: Bool
    @State private var saved: URL?
    @State private var savedHideTask: Task<Void, Never>?
    @State private var showPasswords = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if session.isLoading {
                GeometryReader { geometry in
                    Rectangle().fill(VSDark.blue)
                        .frame(width: geometry.size.width * max(0.05, session.progress), height: 2)
                }
                .frame(height: 2)
            } else {
                Divider().background(VSDark.border)
            }
            BrowserAgentBar(session: session)
            if let prompt = session.passwordPrompt { passwordPromptBar(prompt) }
            if let offer = session.fillOffer, session.passwordPrompt == nil { fillOfferBar(offer) }
            if let download = session.download { downloadBanner(download) }
            if let saved { savedBanner(saved) }
            if session.isPicking { noticeBar("Click an element to send it to the AI — Esc cancels", symbol: "cursorarrow.rays", color: VSDark.blue) }
            if let notice = session.pickNotice { noticeBar(notice, symbol: "checkmark.circle.fill", color: VSDark.green, dismiss: true) }
            ZStack {
                BrowserWebViewRepresentable(session: session)
                if let preview = session.preview {
                    placeholder { previewContent(preview) }
                } else if let error = session.loadError {
                    placeholder { errorContent(error) }
                } else if session.url == nil {
                    placeholder { emptyContent }
                }
            }
        }
        .background(VSDark.bg)
        .onAppear {
            address = session.url?.absoluteString ?? ""
            if session.url == nil && session.preview == nil { addressFocused = true }
        }
        .onChange(of: session.url) { url in
            if !addressFocused { address = url?.absoluteString ?? "" }
        }
        .sheet(item: Binding(get: { session.saveRequest.map(SaveRequest.init) },
                             set: { session.saveRequest = $0?.mode; if $0 == nil { session.saveFormat = .markdown } })) { request in
            SavePageMarkdownSheet(session: session, mode: request.mode, format: session.saveFormat,
                                  root: workspaceManager.rootNode?.url) { url in
                didSave(url)
            }
        }
        .sheet(isPresented: $showPasswords) { BrowserPasswordsSheet() }
    }

    private struct SaveRequest: Identifiable {
        let mode: PageCapture.Mode
        var id: String { mode.rawValue }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            iconButton("chevron.left", "Back", disabled: !session.canGoBack) { session.goBack() }
            iconButton("chevron.right", "Forward", disabled: !session.canGoForward) { session.goForward() }
            if session.isLoading {
                iconButton("xmark", "Stop loading") { session.stopLoading() }
            } else {
                iconButton("arrow.clockwise", "Reload (⌘R)") { session.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            HStack(spacing: 5) {
                Image(systemName: lockSymbol).uiFont(size: 10).foregroundColor(VSDark.textDim)
                TextField("Address, localhost:5173, or search", text: $address)
                    .textFieldStyle(.plain)
                    .uiFont(size: 11, design: .monospaced)
                    .focused($addressFocused)
                    .onSubmit(go)
                    .onExitCommand {
                        address = session.url?.absoluteString ?? ""
                        addressFocused = false
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(VSDark.bg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(addressFocused ? VSDark.blue : VSDark.border, lineWidth: 1))
            Button {
                if session.isPicking { session.cancelPick() } else { Task { await session.pickElement() } }
            } label: {
                Image(systemName: "cursorarrow.rays").uiFont(size: 12)
                    .foregroundColor(session.isPicking ? VSDark.blue : VSDark.text)
            }
            .buttonStyle(.plain)
            .disabled(session.url == nil)
            .help(session.isPicking ? "Cancel picking (Esc)"
                  : "Pick an element on the page: its screenshot and HTML go into the AI's input")
            Menu {
                Button("Save Selection as Markdown…") { session.saveRequest = .selection }
                Button("Save Page as Markdown…") { session.saveRequest = .page }
                Divider()
                Button("Save Page as PDF…") { session.saveFormat = .pdf; session.saveRequest = .page }
            } label: {
                Image(systemName: "square.and.arrow.down").uiFont(size: 12)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(session.url == nil)
            .help("Save the selected text as Markdown, or the whole page as a Markdown document or a PDF")
            Menu {
                if let offer = session.fillOffer {
                    ForEach(offer.usernames, id: \.self) { name in
                        Button("Fill \(name.isEmpty ? "saved login" : name)") { Task { await session.fillPassword(username: name) } }
                    }
                    Divider()
                }
                Button("Saved Passwords…") { showPasswords = true }
            } label: {
                Image(systemName: session.fillOffer == nil ? "key" : "key.fill").uiFont(size: 12)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Saved passwords: fill a login form, manage logins, import them from Chrome")
            Button { renameTab() } label: {
                Text(session.agentName).uiFont(size: 10, weight: .semibold, design: .monospaced)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(VSDark.bgActive).cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("This tab's name for agents (\"use tab \(session.agentName)\") — click to rename, e.g. Jira")
            iconButton("safari", "Open in the default browser", disabled: session.url == nil) {
                if let url = session.url { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(VSDark.bgSidebar)
    }

    private var lockSymbol: String {
        guard let url = session.url else { return "globe" }
        if let host = url.host, BrowserAddress.isLocal(host) { return "desktopcomputer" }
        return url.scheme == "https" ? "lock.fill" : "globe"
    }

    private func go() {
        guard let url = BrowserAddress.url(from: address) else { return }
        address = url.absoluteString
        addressFocused = false
        session.load(url)
    }

    /// Rename the tab for agents: a short unique name ("Jira", "Billing").
    private func renameTab() {
        let alert = NSAlert()
        alert.messageText = "Name this tab"
        alert.informativeText = "Tell an agent to use it by this name, e.g. \"in tab Jira, create the ticket\"."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        input.stringValue = session.agentName
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let taken = workspaceManager.browserSessions.filter { $0 !== session }.map { $0.agentName.lowercased() }
        session.agentName = taken.contains(name.lowercased()) ? name + " 2" : name
    }

    private func iconButton(_ symbol: String, _ help: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).uiFont(size: 12)
                .foregroundColor(disabled ? VSDark.textDim.opacity(0.5) : VSDark.text)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Password and download bars

    private func passwordPromptBar(_ prompt: PasswordPrompt) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundColor(VSDark.blue)
            Text(prompt.isUpdate ? "Update the saved password for \(label(prompt))?" : "Save the password for \(label(prompt))?")
                .uiFont(size: 11).foregroundColor(VSDark.text).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(prompt.isUpdate ? "Update" : "Save") { session.savePasswordPrompt() }
            Button("Not now") { session.dismissPasswordPrompt() }
            Button("Never for this site") { session.dismissPasswordPrompt(neverForSite: true) }
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(VSDark.blue.opacity(0.12))
    }

    private func label(_ prompt: PasswordPrompt) -> String {
        prompt.username.isEmpty ? prompt.host : "\(prompt.username) on \(prompt.host)"
    }

    private func fillOfferBar(_ offer: PasswordFillOffer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundColor(VSDark.blue)
            Text("A saved login for \(offer.host) is available.").uiFont(size: 11).foregroundColor(VSDark.text)
            Spacer()
            if offer.usernames.count > 1 {
                Menu("Fill…") {
                    ForEach(offer.usernames, id: \.self) { name in
                        Button(name.isEmpty ? "Saved login" : name) { Task { await session.fillPassword(username: name) } }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            } else {
                Button("Fill") { Task { await session.fillPassword(username: offer.usernames.first) } }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(VSDark.blue.opacity(0.12))
    }

    private func noticeBar(_ text: String, symbol: String, color: Color, dismiss: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundColor(color)
            Text(text).uiFont(size: 11).foregroundColor(VSDark.text).lineLimit(2)
            Spacer()
            if dismiss { Button { session.pickNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(VSDark.bgActive)
    }

    private func downloadBanner(_ download: BrowserDownload) -> some View {
        HStack(spacing: 8) {
            switch download {
            case .running(let name):
                ProgressView().controlSize(.small)
                Text("Downloading \(name)…").uiFont(size: 11).foregroundColor(VSDark.text).lineLimit(1).truncationMode(.middle)
                Spacer()
            case .finished(let url):
                Image(systemName: "arrow.down.circle.fill").foregroundColor(VSDark.green)
                Text("Downloaded \(url.lastPathComponent)").uiFont(size: 11).foregroundColor(VSDark.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Open") { NSWorkspace.shared.open(url); session.download = nil }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(VSDark.orange)
                Text(message).uiFont(size: 11).foregroundColor(VSDark.text).lineLimit(2)
                Spacer()
            }
            if case .running = download {} else {
                Button { session.download = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(VSDark.bgActive)
    }

    // MARK: - Saved banner

    private func didSave(_ url: URL) {
        workspaceManager.refreshFileTree()
        saved = url
        savedHideTask?.cancel()
        savedHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { saved = nil }
        }
    }

    private func savedBanner(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(VSDark.green)
            Text("Saved \(relativePath(url))").uiFont(size: 11).foregroundColor(VSDark.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Open") {
                if url.pathExtension.lowercased() == "pdf" { NSWorkspace.shared.open(url) } else { workspaceManager.openFile(url) }
                saved = nil
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button { saved = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(VSDark.bgActive)
    }

    private func relativePath(_ url: URL) -> String {
        guard let root = workspaceManager.rootNode?.url, WebClip.isInside(url, root: root) else { return url.path }
        return String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    // MARK: - Placeholders

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(VSDark.bg)
    }

    @ViewBuilder
    private func previewContent(_ state: WebPreviewState) -> some View {
        switch state {
        case .searching:
            ProgressView().controlSize(.small)
            Text("Looking for the project's web app…").uiFont(size: 12).foregroundColor(VSDark.textDim)
        case .choose(let targets):
            Image(systemName: "macwindow.on.rectangle").uiFont(size: 26).foregroundColor(VSDark.textDim)
            Text("Which app should be previewed?").uiFont(size: 13, weight: .semibold).foregroundColor(VSDark.text)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(targets, id: \.folder) { target in
                    Button { session.startWebApp?(target) } label: {
                        HStack {
                            Text(target.label).uiFont(size: 12, weight: .medium)
                            Spacer(minLength: 16)
                            Text(target.command).uiFont(size: 11, design: .monospaced).foregroundColor(VSDark.textDim)
                        }
                        .frame(minWidth: 320)
                    }
                }
            }
        case .starting(let target, let started):
            ProgressView().controlSize(.small)
            Text(started ? "Starting \(target.label)…" : "Checking \(target.label)…")
                .uiFont(size: 13, weight: .semibold).foregroundColor(VSDark.text)
            Text(started
                 ? "`\(target.command)` runs in a terminal tab. The app opens here as soon as the server answers."
                 : "Looking for a running server on port \(target.ports.map(String.init).joined(separator: ", ")).")
                .uiFont(size: 11).foregroundColor(VSDark.textDim).multilineTextAlignment(.center)
            if target.isElectron {
                Text("An Electron app: only its web part runs here, Electron itself is not started.")
                    .uiFont(size: 11).foregroundColor(VSDark.textDim).multilineTextAlignment(.center)
            }
            if started { Button("Show Terminal") { session.showTerminal?() } }
        case .timedOut(let target):
            Image(systemName: "exclamationmark.triangle").uiFont(size: 24).foregroundColor(VSDark.orange)
            Text("\(target.label) did not answer yet").uiFont(size: 13, weight: .semibold).foregroundColor(VSDark.text)
            Text("Check the dev server's terminal for errors, or type its address above.")
                .uiFont(size: 11).foregroundColor(VSDark.textDim)
            HStack {
                Button("Show Terminal") { session.showTerminal?() }
                Button("Try Again") { session.startWebApp?(target) }
            }
        case .noApp:
            Image(systemName: "globe").uiFont(size: 26).foregroundColor(VSDark.textDim)
            Text("No web app found in this project").uiFont(size: 13, weight: .semibold).foregroundColor(VSDark.text)
            Text("No package.json dev script, Electron renderer, Django or Rails app, and nothing answers on the usual ports.\nType the address of your server above, e.g. localhost:3000.")
                .uiFont(size: 11).foregroundColor(VSDark.textDim).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private func errorContent(_ error: String) -> some View {
        Image(systemName: "wifi.exclamationmark").uiFont(size: 24).foregroundColor(VSDark.orange)
        Text(error).uiFont(size: 12).foregroundColor(VSDark.text).multilineTextAlignment(.center)
        HStack {
            Button("Retry") { session.reload() }
            if session.previewTerminalID != nil { Button("Show Terminal") { session.showTerminal?() } }
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        Image(systemName: "globe").uiFont(size: 26).foregroundColor(VSDark.textDim)
        Text("Type an address above").uiFont(size: 13, weight: .semibold).foregroundColor(VSDark.text)
        Text("localhost:5173 or any site. Selected text or the whole page can be saved as Markdown into the project.")
            .uiFont(size: 11).foregroundColor(VSDark.textDim).multilineTextAlignment(.center)
        if workspaceManager.rootNode != nil {
            Button("Preview Web App") { workspaceManager.previewWebApp() }
        }
    }
}

/// Hosts the session's web view, which outlives this view while the tab is open.
private struct BrowserWebViewRepresentable: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        let webView = session.webView
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// The tab bar's title of a browser tab, following the page title.
struct BrowserTabTitle: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        HStack(spacing: 4) {
            // The name agents and the user call the tab by.
            Text(session.agentName)
                .uiFont(size: 9, weight: .semibold, design: .monospaced)
                .padding(.horizontal, 3)
                .background(session.agentStopped ? VSDark.orange.opacity(0.25) : VSDark.bgActive)
                .cornerRadius(3)
            Text(session.displayTitle)
        }
    }
}

/// While an agent drives the tab (or the user stopped agents): who, and Stop / Allow.
struct BrowserAgentBar: View {
    @ObservedObject var session: BrowserSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if session.agentStopped {
                bar(icon: "hand.raised.fill", text: "Agents are stopped for tab \(session.agentName).", color: VSDark.orange,
                    button: "Allow") { session.agentStopped = false }
            } else if let last = session.agentLastUsed, context.date.timeIntervalSince(last) < 120 {
                bar(icon: "sparkles", text: "An agent is using this tab (\(session.agentName)).", color: VSDark.blue,
                    button: "Stop") { session.agentStopped = true }
            }
        }
    }

    private func bar(icon: String, text: String, color: Color, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).uiFont(size: 10).foregroundColor(color)
            Text(text).uiFont(size: 11).foregroundColor(VSDark.text)
            Spacer()
            Button(button, action: action).controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(color.opacity(0.12))
    }
}

/// "Save Page": a Markdown document of the selection or the page, or a PDF of the page; which folder
/// of the project, and the file name.
struct SavePageMarkdownSheet: View {
    @ObservedObject var session: BrowserSession
    @State var mode: PageCapture.Mode
    @State var format: PageFormat
    let root: URL?
    let onSaved: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selection: PageCapture?
    @State private var page: PageCapture?
    @State private var folders: [String] = []
    @State private var folder = WebClip.defaultFolder
    /// A folder chosen with "Other…" (absolute), used instead of `folder`.
    @State private var otherFolder: URL?
    @State private var fileName = ""
    @State private var nameEdited = false
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false

    private var ext: String { format == .pdf ? "pdf" : "md" }
    private var capture: PageCapture? { mode == .selection ? selection : page }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Page").uiFont(size: 14, weight: .semibold)
            Picker("Format", selection: $format) {
                Text("Markdown").tag(PageFormat.markdown)
                Text("PDF").tag(PageFormat.pdf)
            }
            .pickerStyle(.segmented)
            .onChange(of: format) { new in
                if new == .pdf { mode = .page }
                switchExtension()
            }
            Picker("Content", selection: $mode) {
                Text("Selected text").tag(PageCapture.Mode.selection)
                Text("Whole page").tag(PageCapture.Mode.page)
            }
            .pickerStyle(.segmented)
            .disabled(format == .pdf)
            .onChange(of: mode) { _ in updateName() }
            HStack {
                Text("Folder").frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(get: { otherFolder == nil ? folder : "\u{0}other" },
                                              set: { value in
                                                  if value == "\u{0}other" { chooseFolder() }
                                                  else { folder = value; otherFolder = nil }
                                              })) {
                    ForEach(folders, id: \.self) { Text($0).tag($0) }
                    if let otherFolder { Text(otherFolder.path).tag("\u{0}other") }
                    Divider()
                    Text("Other…").tag("\u{0}other")
                }
                .labelsHidden()
            }
            HStack {
                Text("File name").frame(width: 70, alignment: .leading)
                TextField(format == .pdf ? "name.pdf" : "name.md", text: Binding(get: { fileName }, set: { name in
                    // The field writes its value back when it gets focus; only a change is an edit.
                    guard name != fileName else { return }
                    fileName = name
                    nameEdited = true
                }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(loading)
            }
            Group {
                if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 160)
                } else if format == .pdf {
                    Text("A PDF of the whole page as it is shown now, in A4 pages.")
                        .uiFont(size: 11).foregroundColor(VSDark.textDim)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else if let capture, !capture.markdown.isEmpty {
                    ScrollView {
                        Text(preview(capture.markdown))
                            .uiFont(size: 11, design: .monospaced)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(height: 220)
                    .background(RoundedRectangle(cornerRadius: 5).fill(VSDark.bg))
                } else {
                    Text(mode == .selection ? "Nothing is selected on the page. Select text first, or save the whole page."
                                            : "The page has no readable content yet.")
                        .uiFont(size: 11).foregroundColor(VSDark.textDim)
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            if let error {
                Text(error).uiFont(size: 11).foregroundColor(VSDark.red)
            }
            HStack {
                if let capture, format == .markdown { Text("\(capture.markdown.count) characters").uiFont(size: 10).foregroundColor(VSDark.textDim) }
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || loading || WebClip.sanitizedName(fileName, ext: ext) == nil
                              || (format == .markdown && capture?.markdown.isEmpty != false))
            }
        }
        .padding(18)
        .frame(width: 560)
        .task { await load() }
    }

    private func preview(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix(60).joined(separator: "\n")
        return lines.count > 60 ? head + "\n…" : head
    }

    private func load() async {
        if let root {
            folders = await Task.detached { WebClip.suggestedFolders(root: root) }.value
        }
        do {
            selection = try await session.capture(.selection)
            page = try await session.capture(.page)
            if mode == .selection && selection?.hasSelection != true { mode = .page }
        } catch {
            self.error = error.localizedDescription
        }
        if root == nil, otherFolder == nil {
            otherFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        loading = false
        updateName()
    }

    private func updateName() {
        guard !nameEdited, let capture else { return }
        fileName = WebClip.fileName(title: WebClip.title(of: capture), url: capture.url, date: FeatureStore.today, ext: ext)
    }

    /// The format changed: a generated name follows it, a typed name only swaps `.md` and `.pdf`.
    private func switchExtension() {
        if !nameEdited { updateName(); return }
        let old = format == .pdf ? ".md" : ".pdf"
        if fileName.lowercased().hasSuffix(old) { fileName = String(fileName.dropLast(old.count)) + "." + ext }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = root == nil ? "Where to save the Markdown document" : "A folder of the project"
        panel.directoryURL = otherFolder ?? root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let root, !WebClip.isInside(url, root: root) {
            error = "Choose a folder inside the project (\(root.lastPathComponent))."
            return
        }
        error = nil
        otherFolder = url
    }

    private func save() {
        guard let name = WebClip.sanitizedName(fileName, ext: ext) else { return }
        let target: URL
        if let otherFolder { target = otherFolder }
        else if let root { target = root.appendingPathComponent(folder, isDirectory: true) }
        else { return }
        error = nil
        if format == .pdf {
            saving = true
            Task { @MainActor in
                defer { saving = false }
                do {
                    let data = try await session.pagePDF()
                    try write(data, to: target, name: name)
                } catch {
                    self.error = "Could not save: \(error.localizedDescription)"
                }
            }
            return
        }
        guard let capture else { return }
        let title = WebClip.title(of: capture)
        let text = WebClip.document(capture, mode: mode, title: title, date: FeatureStore.today)
        do {
            try write(Data(text.utf8), to: target, name: name)
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
    }

    private func write(_ data: Data, to target: URL, name: String) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let url = WebClip.freeURL(in: target, name: name) { FileManager.default.fileExists(atPath: $0.path) }
        try data.write(to: url, options: .atomic)
        onSaved(url)
        dismiss()
    }
}
