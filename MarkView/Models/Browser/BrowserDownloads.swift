import Foundation

/// What a tab's download banner shows.
enum BrowserDownload: Equatable {
    case running(String)
    case finished(URL)
    case failed(String)
}

enum BrowserDownloads {
    /// `name`, then `name 2`, `name 3`… before the extension, until the file is free. The name is the
    /// server's suggestion, so only its last path component is used.
    static func freeURL(in folder: URL, suggestedName: String, exists: (URL) -> Bool) -> URL {
        let name = (suggestedName as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "download" : name)
        var n = 2
        while exists(target) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return target
    }
}
