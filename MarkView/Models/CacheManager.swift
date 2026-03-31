import Foundation

/// Manages cached AI provider responses in .dde/cache/provider_responses/
class CacheManager {
    private let cacheDir: URL

    init(workspacePath: URL) {
        self.cacheDir = workspacePath
            .appendingPathComponent(".dde")
            .appendingPathComponent("cache")
            .appendingPathComponent("provider_responses")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Load cached response for a given input hash
    func loadCachedResponse(inputHash: String) -> Data? {
        let file = cacheDir.appendingPathComponent("\(inputHash).json")
        return try? Data(contentsOf: file)
    }

    /// Save response data to cache
    func saveCachedResponse(inputHash: String, data: Data) {
        let file = cacheDir.appendingPathComponent("\(inputHash).json")
        try? data.write(to: file)
    }

    /// Check if a cached response exists
    func hasCachedResponse(inputHash: String) -> Bool {
        let file = cacheDir.appendingPathComponent("\(inputHash).json")
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Evict old cache entries (keep last N)
    func evict(keepLast count: Int = 1000) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        let sorted = files.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate > bDate
        }

        if sorted.count > count {
            for file in sorted[count...] {
                try? fm.removeItem(at: file)
            }
        }
    }
}
