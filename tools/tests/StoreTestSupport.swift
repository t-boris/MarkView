import Foundation

/// Helpers for the checks of every store that keeps its data through `SchemaVersionedStore` (AR-36, AR-39). A check writes the
/// file the way the previous version of the app wrote it (a "legacy fixture"), drives the real store, and then looks at the file.
enum StoreFixture {
    /// A new empty folder in the temporary area; the caller removes it.
    static func folder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `text` to `url`, creating the folder; this is how a legacy, damaged or newer file is put in place.
    static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    static func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    /// The envelope of a store file: its `schema` and the payload under `data`. Nil when the file is a bare payload or not JSON.
    static func envelope(_ url: URL) -> (schema: Int, data: Any)? {
        guard let raw = bytes(url), let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let schema = object["schema"] as? Int, let data = object["data"] else { return nil }
        return (schema, data)
    }

    /// The dated copies a store makes of a file it could not read before replacing it, newest name last.
    static func backups(of url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasPrefix(url.lastPathComponent + ".corrupt-") }.sorted()
            .map { url.deletingLastPathComponent().appendingPathComponent($0) }
    }

    /// A file written by a newer MarkView: schema 99 around a payload this version cannot know.
    static func newerFile(payload: String = "{}") -> String {
        #"{"schema":99,"updatedAt":"2030-01-01T00:00:00Z","data":\#(payload)}"#
    }
}
