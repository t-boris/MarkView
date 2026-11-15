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

    /// Rename a file or folder in place. Refuses an invalid name or one already taken; a change
    /// of letter case alone goes through a temporary name (the volume may ignore case).
    static func rename(_ source: URL, to name: String) -> Result {
        let fm = FileManager.default
        let source = source.standardizedFileURL
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var result = Result()
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), trimmed != ".", trimmed != ".." else {
            result.errors.append("“\(trimmed)” is not a valid name.")
            return result
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent(trimmed)
        guard destination.path != source.path else { return result }
        let caseOnly = destination.path.lowercased() == source.path.lowercased()
        if !caseOnly, fm.fileExists(atPath: destination.path) {
            result.errors.append("“\(trimmed)” already exists in this folder.")
            return result
        }
        do {
            if caseOnly {
                let temporary = source.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
                try fm.moveItem(at: source, to: temporary)
                try fm.moveItem(at: temporary, to: destination)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
            result.moved.append((source, destination))
        } catch {
            result.errors.append("Couldn't rename “\(source.lastPathComponent)”: \(error.localizedDescription)")
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
