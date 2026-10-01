import AppKit
import Foundation

/// Web addresses that programs in MarkView's terminals open (Claude Code, Codex, `vite --open`,
/// `gh browse`, Python's webbrowser, …) go to the browser tab of the terminal's window instead
/// of the default browser.
///
/// The terminal's environment carries `BROWSER` and, first on `PATH`, an `open` wrapper; both
/// drop a request file into a spool folder of this app process, which MarkView watches. Login
/// zsh rebuilds `PATH` (path_helper), so zsh starts with MarkView's `ZDOTDIR`, which sources the
/// user's own startup files and then puts the wrapper first again.
@MainActor
enum TerminalBrowserBridge {
    /// Setting: open terminal web links in MarkView (default on).
    static let enabledKey = "browser.openTerminalLinksInApp"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static var sessions: [UUID: WeakTerminal] = [:]
    private static var watcher: DispatchSourceFileSystemObject?
    private static var installed: Support?

    private struct WeakTerminal { weak var session: TerminalSession? }

    struct Support {
        var bin: URL
        var zsh: URL
        var spool: URL
    }

    // MARK: - Terminal environment

    /// Variables for a terminal that routes web addresses to `session`'s window; empty when the
    /// setting is off or the support files could not be written.
    static func environment(for session: TerminalSession, shell: String,
                            inherited: [String: String]) -> [String: String] {
        guard isEnabled, let support = install() else { return [:] }
        sessions = sessions.filter { $0.value.session != nil }
        sessions[session.id] = WeakTerminal(session: session)
        var environment = [
            "MARKVIEW_TERMINAL_ID": session.id.uuidString,
            "MARKVIEW_BROWSER_SPOOL": support.spool.path,
            "MARKVIEW_BIN": support.bin.path,
            "BROWSER": support.bin.appendingPathComponent("markview-browser").path,
            "PATH": support.bin.path + ":" + (inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"),
        ]
        if (shell as NSString).lastPathComponent == "zsh" {
            if let own = inherited["ZDOTDIR"], !own.isEmpty { environment["MARKVIEW_USER_ZDOTDIR"] = own }
            environment["ZDOTDIR"] = support.zsh.path
        }
        return environment
    }

    // MARK: - Support files

    /// Writes the wrapper scripts and zsh startup files once per launch and starts watching the spool.
    @discardableResult
    static func install() -> Support? {
        if let installed { return installed }
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "MarkView", isDirectory: true)
            .appendingPathComponent("TerminalBrowser", isDirectory: true) else { return nil }
        let support = Support(bin: base.appendingPathComponent("bin", isDirectory: true),
                              zsh: base.appendingPathComponent("zsh", isDirectory: true),
                              spool: base.appendingPathComponent("spool-\(ProcessInfo.processInfo.processIdentifier)",
                                                                 isDirectory: true))
        do {
            for folder in [base, support.bin, support.zsh, support.spool] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            removeStaleSpools(in: base)
            try write(Scripts.browser, to: support.bin.appendingPathComponent("markview-browser"), executable: true)
            try write(Scripts.open, to: support.bin.appendingPathComponent("open"), executable: true)
            for (name, text) in Scripts.zshFiles {
                try write(text, to: support.zsh.appendingPathComponent(name), executable: false)
            }
        } catch {
            NSLog("[MarkView] terminal browser bridge unavailable: \(error.localizedDescription)")
            return nil
        }
        watch(support.spool)
        installed = support
        return support
    }

    private static func write(_ text: String, to url: URL, executable: Bool) throws {
        if (try? String(contentsOf: url, encoding: .utf8)) != text {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
    }

    /// Spool folders of MarkView processes that are gone.
    private static func removeStaleSpools(in base: URL) {
        let mine = "spool-\(ProcessInfo.processInfo.processIdentifier)"
        for url in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            guard name.hasPrefix("spool-"), name != mine, let pid = Int32(name.dropFirst(6)) else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Requests

    private static func watch(_ spool: URL) {
        let fd = open(spool.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { drain(spool) } }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        drain(spool)
    }

    /// Reads and removes the finished request files (`<terminal id>\n<url>\n`).
    private static func drain(_ spool: URL) {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: spool, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "url" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? fm.removeItem(at: file)
            guard let request = parse(text) else { continue }
            route(request.url, from: request.terminal)
        }
    }

    /// The terminal id and the web address of a request; nil for anything else.
    nonisolated static func parse(_ text: String) -> (terminal: UUID?, url: URL)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard lines.count >= 2, lines[1].count <= 8_192, let url = URL(string: lines[1]),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return (UUID(uuidString: lines[0]), url)
    }

    private static func route(_ url: URL, from terminal: UUID?) {
        if let terminal, let session = sessions[terminal]?.session, let open = session.openInAppBrowser {
            open(url)
        } else if let session = sessions.values.compactMap(\.session).first(where: { $0.openInAppBrowser != nil }) {
            // A terminal that has closed meanwhile: any window of this app.
            session.openInAppBrowser?(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Scripts

    enum Scripts {
        /// `BROWSER=markview-browser URL…` (one or more addresses).
        static let browser = """
        #!/bin/sh
        # MarkView: web addresses opened from a MarkView terminal go to MarkView's browser tab.
        [ -n "$MARKVIEW_BROWSER_SPOOL" ] && [ -d "$MARKVIEW_BROWSER_SPOOL" ] || exec /usr/bin/open "$@"
        status=0
        for url in "$@"; do
          case "$url" in
            http://*|https://*)
              tmp="$MARKVIEW_BROWSER_SPOOL/.$$-$(date +%s)-$RANDOM.tmp"
              printf '%s\\n%s\\n' "$MARKVIEW_TERMINAL_ID" "$url" > "$tmp" && mv "$tmp" "${tmp%.tmp}.url" || status=1
              ;;
            *) /usr/bin/open "$url" || status=1 ;;
          esac
        done
        exit $status
        """

        /// `open URL` without options goes to MarkView; anything else is macOS `open` as usual.
        static let open = """
        #!/bin/sh
        # MarkView: `open https://…` from a MarkView terminal shows the page in MarkView's browser tab.
        # Every other use (files, apps, options) is passed to /usr/bin/open unchanged.
        [ $# -gt 0 ] || exec /usr/bin/open
        for arg in "$@"; do
          case "$arg" in
            http://*|https://*) ;;
            *) exec /usr/bin/open "$@" ;;
          esac
        done
        exec "$(dirname "$0")/markview-browser" "$@"
        """

        /// zsh reads these from MarkView's `ZDOTDIR`; each sources the user's file of the same
        /// name, and the wrapper folder goes first on `PATH` after the user's own changes.
        static let zshFiles: [(String, String)] = [
            (".zshenv", """
            # MarkView terminal: run the user's startup files, then keep MarkView's browser wrapper first on PATH.
            MARKVIEW_ZDOTDIR="$ZDOTDIR"
            ZDOTDIR="${MARKVIEW_USER_ZDOTDIR:-$HOME}"
            [ -f "$ZDOTDIR/.zshenv" ] && . "$ZDOTDIR/.zshenv"
            MARKVIEW_USER_ZDOTDIR="$ZDOTDIR"
            ZDOTDIR="$MARKVIEW_ZDOTDIR"
            """),
            (".zprofile", """
            ZDOTDIR="$MARKVIEW_USER_ZDOTDIR"
            [ -f "$ZDOTDIR/.zprofile" ] && . "$ZDOTDIR/.zprofile"
            MARKVIEW_USER_ZDOTDIR="$ZDOTDIR"
            ZDOTDIR="$MARKVIEW_ZDOTDIR"
            [ -n "$MARKVIEW_BIN" ] && path=("$MARKVIEW_BIN" ${path:#$MARKVIEW_BIN})
            """),
            (".zshrc", """
            ZDOTDIR="$MARKVIEW_USER_ZDOTDIR"
            [ -f "$ZDOTDIR/.zshrc" ] && . "$ZDOTDIR/.zshrc"
            MARKVIEW_USER_ZDOTDIR="$ZDOTDIR"
            ZDOTDIR="$MARKVIEW_ZDOTDIR"
            [ -n "$MARKVIEW_BIN" ] && path=("$MARKVIEW_BIN" ${path:#$MARKVIEW_BIN})
            """),
            (".zlogin", """
            ZDOTDIR="$MARKVIEW_USER_ZDOTDIR"
            [ -f "$ZDOTDIR/.zlogin" ] && . "$ZDOTDIR/.zlogin"
            [ -n "$MARKVIEW_BIN" ] && path=("$MARKVIEW_BIN" ${path:#$MARKVIEW_BIN})
            # Shells started from here use the user's own startup files.
            if [ "$ZDOTDIR" = "$HOME" ]; then unset ZDOTDIR; fi
            unset MARKVIEW_ZDOTDIR MARKVIEW_USER_ZDOTDIR
            """),
        ]
    }
}
