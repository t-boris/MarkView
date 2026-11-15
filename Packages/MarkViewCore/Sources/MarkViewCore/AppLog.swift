import os

/// The app's log (AR-24): one `os.Logger` per area under the `com.markview.app` subsystem, so a message reaches the unified
/// system log with a level and a category instead of the unstructured `NSLog` stream.
///
///     AppLog.workspace.error("Could not save the recent files: \(error.localizedDescription)")
///
/// Privacy: the system keeps an interpolated string private (`<private>` unless the person turned private data on), and the
/// static text and numbers readable. Leave that default alone. A path, a name the person typed, an error from a child process
/// and every other dynamic string is private; mark a value `privacy: .public` only for a constant of the app itself. Never log
/// the contents of a file or a document, a token or key, a prompt, or a request header, at any privacy level.
///
/// Levels: `error` for a failure the person or a developer must hear about, `notice` for an event worth keeping in the log, `debug`
/// for diagnostics that are only wanted while developing.
public enum AppLog {
    public static let subsystem = "com.markview.app"

    /// The application object and the Apple Event handoff.
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let appDelegate = Logger(subsystem: subsystem, category: "app-delegate")
    /// Files handed over by the Finder Quick Action.
    public static let finder = Logger(subsystem: subsystem, category: "finder")
    public static let fileTree = Logger(subsystem: subsystem, category: "file-tree")
    /// The workspace: folders, tabs, files, translation, recent files.
    public static let workspace = Logger(subsystem: subsystem, category: "workspace")
    /// The window session saved at quit and restored at launch.
    public static let windowSession = Logger(subsystem: subsystem, category: "window-session")
    /// Versioned stores (`SchemaVersionedStore`): a damaged or newer file.
    public static let store = Logger(subsystem: subsystem, category: "store")
    /// The Swift to JavaScript bridge and the editor page.
    public static let bridge = Logger(subsystem: subsystem, category: "bridge")
    /// Recursive Insight sessions and the GraphRAG skeleton.
    public static let insight = Logger(subsystem: subsystem, category: "insight")
    /// The structural and semantic indexes.
    public static let index = Logger(subsystem: subsystem, category: "index")
    /// Dictation: the Whisper client and the speech recognizer.
    public static let dictation = Logger(subsystem: subsystem, category: "dictation")
    /// The agent browser, its control socket and the terminal bridge.
    public static let browser = Logger(subsystem: subsystem, category: "browser")
}
