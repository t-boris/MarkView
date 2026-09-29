import CryptoKit
import Darwin
import Foundation

/// Native file selection is the security boundary for discovery. The assistant receives
/// excerpts, not a readable folder, so every backend sees the same bounded inputs.
enum ProjectOperationDiscovery {
    struct InputFile {
        var location: String
        var text: String
        var external: Bool
        var url: URL
    }

    struct Inputs {
        var files: [InputFile]
        var grantedFolders: [String]
        var rejectedReferences: [String]
        var signature: String

        func prompt(limit: Int = 180_000) -> String {
            var remaining = limit
            var chunks: [String] = []
            for file in files {
                let header = "\n[FILE \(file.location)]\n"
                if remaining < header.utf8.count + 100 { break }
                let excerpt = String(file.text.prefix(min(remaining - header.utf8.count, 12_000)))
                chunks.append(header + excerpt)
                remaining -= header.utf8.count + excerpt.utf8.count
            }
            return chunks.joined(separator: "\n")
        }
    }

    private static let deniedNames: Set<String> = [
        ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".netrc", ".npmrc", ".env",
    ]
    private static let deniedExtensions: Set<String> = ["pem", "key"]
    private static let ignoredFolders: Set<String> = [
        ".git", ".dde", "node_modules", "vendor", ".build", "build", "dist", "DerivedData", ".next",
    ]

    static func scan(root: URL) -> Inputs {
        let root = canonical(root)
        var files: [InputFile] = []
        var granted: [String] = []
        var rejected: [String] = []
        var externalBytes = 0
        var externalFiles = 0

        func read(_ url: URL, external: Bool, folder: URL? = nil) {
            let resolved = canonical(url)
            guard !isDenied(resolved) else { return }
            if external {
                guard let folder, isInside(resolved, folder) else { return }
                guard externalFiles < 200 && externalBytes < 2_000_000 else { return }
            } else {
                guard isInside(resolved, root) else { return }
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 128_000 else { return }
            guard let data = try? Data(contentsOf: resolved), !data.contains(0),
                  let text = String(data: data, encoding: .utf8) else { return }
            if external {
                guard externalBytes + data.count <= 2_000_000 else { return }
                externalFiles += 1
                externalBytes += data.count
            }
            let location = external ? resolved.path : String(resolved.path.dropFirst(root.path.count + 1))
            files.append(InputFile(location: location, text: text, external: external, url: resolved))
        }

        for url in walk(root, maxFiles: 10_000) {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if isProjectInput(relative) { read(url, external: false) }
        }

        func resolveReferences(_ source: [InputFile], depth: Int) {
            for file in source {
                for reference in references(in: file.text) {
                    let candidate: URL
                    if reference.hasPrefix("~/") {
                        candidate = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(String(reference.dropFirst(2)))
                    } else if reference.hasPrefix("/") {
                        candidate = URL(fileURLWithPath: reference)
                    } else {
                        candidate = file.url.deletingLastPathComponent().appendingPathComponent(reference)
                    }
                    let resolved = canonical(candidate)
                    if isInside(resolved, root) { continue }
                    let label = file.location + " → " + reference
                    if isDenied(resolved) || isBroadRoot(resolved) {
                        rejected.append(label + " (restricted location)")
                        continue
                    }
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory) else {
                        rejected.append(label + " (not found)")
                        continue
                    }
                    let folder = directory.boolValue ? resolved : resolved.deletingLastPathComponent()
                    if isDenied(folder) || isBroadRoot(folder) {
                        rejected.append(label + " (restricted folder)")
                        continue
                    }
                    if granted.contains(folder.path) { continue }
                    if granted.count >= 5 {
                        rejected.append(label + " (five-folder limit)")
                        continue
                    }
                    granted.append(folder.path)
                    let before = files.count
                    for externalURL in walk(folder, maxFiles: 500) where isExternalInput(externalURL) {
                        if externalFiles >= 200 || externalBytes >= 2_000_000 { break }
                        read(externalURL, external: true, folder: folder)
                    }
                    if depth == 0 { resolveReferences(Array(files.dropFirst(before)), depth: 1) }
                }
            }
        }
        resolveReferences(files, depth: 0)
        let signatureSource = files.filter { !$0.external }
            .map { $0.location + ":" + String(SHA256.hash(data: Data($0.text.utf8)).map { String(format: "%02x", $0) }.joined()) }
            .sorted().joined(separator: "\n")
        let signature = SHA256.hash(data: Data(signatureSource.utf8)).map { String(format: "%02x", $0) }.joined()
        return Inputs(files: files, grantedFolders: granted, rejectedReferences: rejected, signature: signature)
    }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        url.path == folder.path || url.path.hasPrefix(folder.path + "/")
    }

    static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &resolved) != nil { return URL(fileURLWithPath: String(cString: resolved)) }
        return url.standardizedFileURL
    }

    private static func isBroadRoot(_ url: URL) -> Bool {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return path == "/" || path == home || path == "/Users" || path == "/Volumes" || path == "/tmp"
    }

    private static func isDenied(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.path
        if path.hasPrefix(home + "/Library/") { return true }
        if path == home + "/.config/gcloud" || path.hasPrefix(home + "/.config/gcloud/") { return true }
        for component in url.pathComponents {
            let name = component.lowercased()
            if deniedNames.contains(name) || name.hasPrefix(".env.") || name.hasPrefix("id_rsa")
                || name.hasPrefix("id_ed25519") || deniedExtensions.contains((name as NSString).pathExtension)
                || name.contains("keychain") { return true }
        }
        return false
    }

    private static func walk(_ folder: URL, maxFiles: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDenied(url) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if isDirectory {
                if ignoredFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            result.append(url)
            if result.count >= maxFiles { break }
        }
        return result
    }

    private static func isProjectInput(_ path: String) -> Bool {
        if ArchitectureScanner.isDeploymentHint(path) { return true }
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "package.json" || name == "justfile" || name == "taskfile.yml" || name == "taskfile.yaml"
            || name == "fastfile" || name.hasPrefix("readme") { return true }
        if path.lowercased().hasPrefix("docs/") && ["runbook", "deploy", "install", "operations"].contains(where: name.contains) { return true }
        if name.hasSuffix(".sh") {
            let components = path.split(separator: "/")
            return components.count == 1 || ["scripts", "bin", "deploy"].contains(String(components.first ?? ""))
        }
        return false
    }

    private static func isExternalInput(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        return ["md", "sh", "json", "yaml", "yml", "toml", "txt"].contains(ext)
            || ["makefile", "justfile", "dockerfile", "procfile", "fastfile"].contains(name)
    }

    private static func references(in text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_])(?:\.\./|~/|/(?:Users|Volumes|opt|srv|private|tmp)/)[A-Za-z0-9_./+~-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { range in
                var value = String(text[range])
                while let last = value.last, ".,;:)'\"".contains(last) { value.removeLast() }
                return value
            }
        }
    }
}
