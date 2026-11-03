import Foundation

/// The durable, project-local reference to a saved prototype: `markview://prototype/<slug>`. A person
/// copies it from Prototype Studio and hands it to an AI agent that has the same project open; the agent
/// resolves it with `markview_get_prototype`, which accepts the reference in every form `parse` reads.
///
/// The reference names the prototype only, never a version (DEC-002): resolving it always yields the
/// latest saved version, so it stays valid across accepted edits and reopenings as long as the prototype
/// exists. A version folder in a path form (`…/versions/v3`) is read and ignored for that reason; the
/// caller may mention it.
///
/// The prototype lives in `<project>/.dde/prototypes/<slug>/`, and `.dde/` is local to the machine that
/// built the prototype: it is not part of the repository. The reference therefore resolves only in a
/// checkout that holds that folder — it is a pointer for agents working on this machine's project, not
/// a link that can be published or opened elsewhere.
///
/// Pure Foundation, so `tools/tests/prototype-reference-tests.sh` compiles it on its own.
enum PrototypeReference {

    static let scheme = "markview"
    static let host = "prototype"
    /// The prototype storage, relative to the project root.
    static let storageFolder = ".dde/prototypes"

    /// What a reference text named: the prototype, and a version when the text carried one.
    struct Parsed: Equatable {
        var slug: String
        /// A `versions/vN` folder in a path form; informational only, the reference means the latest version.
        var version: Int? = nil
    }

    /// `markview://prototype/<slug>`.
    static func string(slug: String) -> String {
        "\(scheme)://\(host)/\(slug)"
    }

    /// The slug a reference text names, or nil when the text is not a prototype reference.
    /// Accepted: the URI form `markview://prototype/<slug>`, a bare slug, the project-relative path
    /// `.dde/prototypes/<slug>` and an absolute path ending in that layout. A path may end in `/`, `/site`
    /// or `/versions/vN`. Anything else is rejected: other schemes or hosts, `..`, empty text, paths that
    /// name something other than the prototype folder, its site or one of its versions.
    static func parse(_ text: String) -> String? {
        components(text)?.slug
    }

    /// `parse` with the version a path form carried, so a caller can say that it was ignored.
    static func components(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: "://") {
            guard trimmed[..<range.lowerBound].lowercased() == scheme else { return nil }
            let rest = String(trimmed[range.upperBound...])
            var parts = pathComponents(rest)
            guard let first = parts.first, first.lowercased() == host else { return nil }
            parts.removeFirst()
            return prototypeComponents(parts)
        }
        if isSlug(trimmed) { return Parsed(slug: trimmed) }
        var parts = pathComponents(trimmed)
        if trimmed.hasPrefix("/") {
            // An absolute path: the storage folder may sit anywhere in it, once.
            guard let index = storageIndex(in: parts) else { return nil }
            parts.removeFirst(index + 2)
        } else {
            if parts.first == "." { parts.removeFirst() }
            guard storageIndex(in: parts) == 0 else { return nil }
            parts.removeFirst(2)
        }
        return prototypeComponents(parts)
    }

    /// A prototype slug as `PrototypeFiles.slug(for:)` makes it: letters, digits, dashes (underscores allowed).
    static func isSlug(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // MARK: - Pieces

    /// The non-empty components of a path (a trailing or doubled `/` adds none).
    private static func pathComponents(_ text: String) -> [String] {
        text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Where `.dde/prototypes` starts in the components, when the path is free of `..`.
    private static func storageIndex(in parts: [String]) -> Int? {
        guard !parts.contains("..") else { return nil }
        let storage = storageFolder.split(separator: "/").map(String.init)
        guard parts.count >= storage.count else { return nil }
        for index in 0...(parts.count - storage.count) where Array(parts[index..<index + storage.count]) == storage {
            return index
        }
        return nil
    }

    /// `[slug]`, `[slug, "site"]` or `[slug, "versions", "vN"]` after the storage folder.
    private static func prototypeComponents(_ parts: [String]) -> Parsed? {
        guard let slug = parts.first, isSlug(slug) else { return nil }
        let rest = Array(parts.dropFirst())
        switch rest.count {
        case 0:
            return Parsed(slug: slug)
        case 1 where rest[0] == "site":
            return Parsed(slug: slug)
        case 2 where rest[0] == "versions":
            guard rest[1].hasPrefix("v"), let version = Int(rest[1].dropFirst()), version >= 1 else { return nil }
            return Parsed(slug: slug, version: version)
        default:
            return nil
        }
    }
}
