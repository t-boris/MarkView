import Foundation

/// Creates an isolated directory for a test, which the caller removes after its assertions.
public enum TemporaryDirectory {
    public static func make(prefix: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
