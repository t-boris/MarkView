import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The browser's saved logins: look at them, delete them, bring them in from Chrome. Passwords
/// themselves are never shown here; they stay in the login Keychain until a page is filled.
struct BrowserPasswordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logins: [SavedLogin] = []
    @State private var never: [String] = []
    @State private var filter = ""
    @State private var message: String?

    private let store = BrowserPasswordStore.shared

    private var shown: [SavedLogin] {
        let text = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return text.isEmpty ? logins : logins.filter { $0.host.contains(text) || $0.username.lowercased().contains(text) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Passwords").uiFont(size: 14, weight: .semibold)
            Text("Stored in your login Keychain. A password is read only when you fill a login form of that exact site.")
                .uiFont(size: 11).foregroundColor(VSDark.textDim)
            TextField("Filter by site or user", text: $filter).textFieldStyle(.roundedBorder)
            Group {
                if shown.isEmpty {
                    Text(logins.isEmpty ? "Nothing saved yet. Sign in to a site here and MarkView offers to save the password."
                                        : "No match.")
                        .uiFont(size: 11).foregroundColor(VSDark.textDim)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List {
                        ForEach(shown) { login in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(login.host).uiFont(size: 12, weight: .medium)
                                    Text(login.username.isEmpty ? "(no user name)" : login.username)
                                        .uiFont(size: 11).foregroundColor(VSDark.textDim)
                                }
                                Spacer()
                                Button { copyPassword(login) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.plain).help("Copy the password (the clipboard is cleared after a minute)")
                                Button { remove(login) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).help("Delete this login")
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
            if !never.isEmpty {
                DisclosureGroup("Sites that never ask to save (\(never.count))") {
                    ForEach(never, id: \.self) { host in
                        HStack {
                            Text(host).uiFont(size: 11)
                            Spacer()
                            Button("Ask again") { PasswordRules.allowSaving(host: host); reload() }.controlSize(.small)
                        }
                    }
                }
                .uiFont(size: 11)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Import from Google Chrome").uiFont(size: 12, weight: .semibold)
                Text("Chrome keeps its passwords encrypted, so MarkView does not read them directly. In Chrome open Password Manager → Settings → Export passwords, then choose the file here.")
                    .uiFont(size: 11).foregroundColor(VSDark.textDim).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Chrome Password Settings") { openChrome() }
                        .disabled(Self.chromeURL == nil)
                    Button("Import Chrome CSV…") { importCSV() }
                }
            }
            if let message {
                Text(message).uiFont(size: 11).foregroundColor(VSDark.text).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear(perform: reload)
    }

    private func reload() {
        logins = store.all()
        never = PasswordRules.neverHosts().sorted()
    }

    private func remove(_ login: SavedLogin) {
        store.delete(host: login.host, username: login.username)
        reload()
    }

    private func copyPassword(_ login: SavedLogin) {
        guard let password = store.password(host: login.host, username: login.username) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(password, forType: .string)
        let count = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }

    // MARK: - Chrome

    private static var chromeURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") }

    private func openChrome() {
        guard let app = Self.chromeURL, let page = URL(string: "chrome://password-manager/settings") else { return }
        NSWorkspace.shared.open([page], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the CSV that Chrome exported"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8), let result = PasswordCSV.parse(text) else {
            message = "That file has no url, username and password columns. Export the passwords from Chrome as CSV."
            return
        }
        var added = 0, updated = 0
        for row in result.rows {
            let existing = store.password(host: row.host, username: row.username)
            if existing == row.password { continue }
            if store.save(host: row.host, username: row.username, password: row.password) {
                if existing == nil { added += 1 } else { updated += 1 }
            }
        }
        reload()
        var summary = "Imported \(added) new and \(updated) updated logins."
        if result.skipped > 0 { summary += " Skipped \(result.skipped) (not https, or without a password)." }
        message = summary
        offerToTrash(url)
    }

    /// The exported file holds every password as plain text.
    private func offerToTrash(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move the exported file to the Trash?"
        alert.informativeText = "\(url.lastPathComponent) contains all your passwords as plain text. The logins are in the Keychain now."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            message = (message ?? "") + " The exported file is in the Trash."
        } catch {
            message = (message ?? "") + " Could not move the file to the Trash: \(error.localizedDescription)"
        }
    }
}
