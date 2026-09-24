import Foundation

/// Moving and copying files into a folder, as the file tree's drag and drop does.
/// Never overwrites: a taken name becomes "name 2", "name 3"… A folder is never moved
/// or copied into itself.
enum FileTransfer {
    struct Result {
        /// Items actually moved (not copied): old URL → new URL.
        var moved: [(URL, URL)] = []
        var errors: [String] = []
    }

    static func perform(_ sources: [URL], into folder: URL, copy: Bool) -> Result {
        let fm = FileManager.default
        let target = folder.standardizedFileURL
        var result = Result()
        for raw in sources {
            let source = raw.standardizedFileURL
            let name = source.lastPathComponent
            if target.path == source.path || target.path.hasPrefix(source.path + "/") {
                result.errors.append("“\(name)” can't be \(copy ? "copied" : "moved") into itself.")
                continue
            }
            if !copy && source.deletingLastPathComponent().path == target.path { continue }   // already here
            let destination = freeName(for: name, in: target)
            do {
                if copy { try fm.copyItem(at: source, to: destination) } else { try fm.moveItem(at: source, to: destination) }
                if !copy { result.moved.append((source, destination)) }
            } catch {
                result.errors.append("Couldn't \(copy ? "copy" : "move") “\(name)”: \(error.localizedDescription)")
            }
        }
        return result
    }

    /// `name` in `folder`, or "name 2", "name 3"… when it is taken.
    static func freeName(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var number = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return candidate
    }
}
