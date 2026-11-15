import Foundation
import Darwin

/// Resolve terminal text at the native boundary. File IO and process inspection run off-main.
enum TerminalLink: Equatable {
    case web(URL)
    case file(URL, line: Int?)

    static func resolve(_ text: String, directory: URL) -> TerminalLink? {
        guard !text.isEmpty, text.utf8.count <= 8192,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let scheme = URLComponents(string: text)?.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
            return .web(url)
        }

        var path = text
        var line: Int?
        if scheme == "file" {
            guard let url = URL(string: text), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            path = url.path
            if let fragment = url.fragment, fragment.hasPrefix("L") {
                line = Int(fragment.dropFirst())
            }
        } else if text.contains("://") {
            return nil
        }

        func fileURL(_ path: String) -> URL {
            let expanded = (path as NSString).expandingTildeInPath
            return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                    : directory.appendingPathComponent(expanded)).standardizedFileURL
        }
        func exists(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        // Prefer an actual filename containing a colon over interpreting it as a line suffix.
        let literal = fileURL(path)
        if exists(literal) { return .file(literal, line: line.flatMap { $0 > 0 ? $0 : nil }) }
        if let suffix = path.range(of: #":[1-9]\d*(?::[1-9]\d*)?$"#, options: .regularExpression) {
            line = Int(path[suffix].dropFirst().split(separator: ":")[0])
            path = String(path[..<suffix.lowerBound])
        } else if let fragment = path.range(of: #"#L[1-9]\d*$"#, options: .regularExpression) {
            line = Int(path[fragment].dropFirst(2))
            path = String(path[..<fragment.lowerBound])
        }
        let url = fileURL(path)
        return exists(url) ? .file(url, line: line) : nil
    }

    /// The foreground TUI's cwd, then the shell's cwd (after `cd`), then the launch folder.
    static func workingDirectory(foregroundPID: pid_t, shellPID: pid_t, fallback: URL) -> URL {
        for pid in [foregroundPID, shellPID] where pid > 0 {
            var info = proc_vnodepathinfo()
            let count = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
            guard count == MemoryLayout.size(ofValue: info) else { continue }
            let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return fallback
    }
}
