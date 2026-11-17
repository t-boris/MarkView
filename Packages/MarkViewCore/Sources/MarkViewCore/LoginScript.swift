import Foundation

/// The sign-in scripts MarkView hands to Terminal.app (`claude login`, `gh auth login`, ...): a `.command` file, which macOS opens
/// in Terminal without the Apple Events permission that driving Terminal from the app would need. One folder, one naming rule, one write.
public enum LoginScript {
    /// `~/Library/Application Support/MarkView`, where the scripts live.
    public static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/MarkView", isDirectory: true)
    }

    /// Saves `body` as the executable `login-<name>.command` of `folder` (made when missing) and returns the file. The script is
    /// written whole and has its mode (rwxr-xr-x) before it takes the old script's place, so Terminal never runs a half-written
    /// script or one that is not executable yet.
    public static func write(named name: String, body: String, in folder: URL = LoginScript.folder) throws -> URL {
        let script = folder.appendingPathComponent("login-\(name).command")
        try AtomicFile.write(body, to: script, permissions: 0o755)
        return script
    }
}
