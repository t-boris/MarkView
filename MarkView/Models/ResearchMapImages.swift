import Foundation

/// Pictures that a research map node carries beside its icon (REQ-017, DEC-018).
///
/// The page sends a picture it was given (chosen, dropped or pasted) as Base64. This module checks it, works out the
/// kind of picture from its first bytes (never from the name the page gives), and writes it into `images/` next to the
/// map file under a safe, unique name. It touches nothing else; the node is changed by `ResearchMap.update`.
/// Foundation only, so `tools/tests/research-map-images-tests.sh` can compile it on its own.
enum ResearchMapImages {
    /// The folder, next to the map file, that receives the pictures.
    static let folder = "images"
    /// The largest picture accepted, in bytes (the page checks the same limit before it sends).
    static let sizeLimit = 6_000_000

    struct Failure: Error, Equatable {
        let message: String
    }

    /// The file extension for the kinds of picture the card can show, or nil for anything else.
    static func fileExtension(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        if bytes.count >= 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "png" }
        if bytes.count >= 3, Array(bytes[0..<3]) == [0xFF, 0xD8, 0xFF] { return "jpg" }
        if bytes.count >= 6, let head = String(bytes: bytes[0..<6], encoding: .ascii), head == "GIF87a" || head == "GIF89a" { return "gif" }
        if bytes.count >= 12, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF", String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return "webp" }
        return nil
    }

    /// A file name base that is safe on every file system: the last path component without its extension, letters,
    /// digits, dot, dash and underscore only, at most 48 characters; "image" when nothing is left.
    static func safeBase(_ name: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let stem = (last as NSString).deletingPathExtension
        var out = ""
        for scalar in stem.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" { out.unicodeScalars.append(scalar) }
            else if !out.hasSuffix("-") { out += "-" }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        if out.count > 48 { out = String(out.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-_.")) }
        return out.isEmpty ? "image" : out
    }

    /// Decodes and checks a Base64 picture. Fails with a one-line reason the page shows.
    static func decode(base64 encoded: String) -> Result<Data, Failure> {
        // A Base64 text is 4/3 of its bytes: refuse an oversized one before it is decoded.
        guard encoded.utf8.count <= sizeLimit / 3 * 4 + 8 else { return .failure(Failure(message: "The picture is larger than 6 MB.")) }
        guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
            return .failure(Failure(message: "The picture could not be read."))
        }
        guard data.count <= sizeLimit else { return .failure(Failure(message: "The picture is larger than 6 MB.")) }
        guard fileExtension(of: data) != nil else { return .failure(Failure(message: "Use a PNG, JPEG, GIF or WebP picture.")) }
        return .success(data)
    }

    /// Writes the picture into `images/` beside the map file and returns its path relative to the map file
    /// (`images/<name>.<ext>`). The same bytes under the same name are reused; a different picture with the same name
    /// gets `-2`, `-3` … Blocking file work: call it off the main thread.
    static func store(base64 encoded: String, suggestedName: String, besideMap map: URL) -> Result<String, Failure> {
        let data: Data
        switch decode(base64: encoded) {
        case .success(let decoded): data = decoded
        case .failure(let failure): return .failure(failure)
        }
        guard let ext = fileExtension(of: data) else { return .failure(Failure(message: "Use a PNG, JPEG, GIF or WebP picture.")) }
        let directory = map.deletingLastPathComponent().appendingPathComponent(folder, isDirectory: true)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = safeBase(suggestedName)
            var attempt = 1
            while attempt < 1000 {
                let name = (attempt == 1 ? base : "\(base)-\(attempt)") + "." + ext
                let target = directory.appendingPathComponent(name)
                if manager.fileExists(atPath: target.path) {
                    if let existing = try? Data(contentsOf: target), existing == data { return .success("\(folder)/\(name)") }
                    attempt += 1
                    continue
                }
                try data.write(to: target, options: .withoutOverwriting)
                return .success("\(folder)/\(name)")
            }
            return .failure(Failure(message: "There are too many pictures with that name."))
        } catch {
            return .failure(Failure(message: "The picture could not be saved next to the map."))
        }
    }
}
