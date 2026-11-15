import Foundation

/// Reading an assistant's own session logs (JSON lines under its data directory), shared by the providers that have
/// such logs.
enum AssistantSessionLog {
    /// `.jsonl` files in `folders` changed since `since`, newest first.
    static func recentFiles(in folders: [URL], since: Date) -> [URL] {
        // Plain loops: one chained expression took Xcode 16 too long to type-check (CI failed).
        let fm = FileManager.default
        var dated: [(url: URL, date: Date)] = []
        for folder in folders {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let date = values?.contentModificationDate, date >= since else { continue }
                dated.append((url, date))
            }
        }
        return dated.sorted { $0.date > $1.date }.map(\.url)
    }

    /// The JSON objects of a log file, in file order.
    static func lines(of url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// The `timestamp` of a log line: ISO 8601, with or without fractional seconds.
    static func timestamp(_ object: [String: Any]) -> Date? {
        guard let text = object["timestamp"] as? String else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
