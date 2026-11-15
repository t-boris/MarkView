import Foundation

/// Where the images the reviewer sends to the assistant in Prototype Studio (pasted, chosen, or a screenshot of a
/// pointed-at element) are stored: next to the prototype, where the assistant can open them. Normalising them to PNG and
/// the limits of a request are shared with UI Studio in `ImageAttachments`.
enum PrototypeImages {
    /// Writes `data` as a new file in `<prototype>/attachments/`.
    static func save(_ data: Data, in prototypeFolder: URL) throws -> URL {
        try ImageAttachments.save(data, into: prototypeFolder.appendingPathComponent("attachments", isDirectory: true))
    }
}
