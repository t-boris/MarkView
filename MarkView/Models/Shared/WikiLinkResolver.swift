import Foundation

/// Which file a wiki-link (`[[Note]]`) names when several files carry that name, the way
/// Obsidian decides: a file in the linking note's own folder first, then the one with the
/// shortest path, then alphabetical so the answer is stable. Shared by the editor's wiki-link
/// click (`WorkspaceManager.openWikiLink`) and the Book X-Ray's cross-references.
enum WikiLinkResolver {
    /// `candidates` are paths (relative or absolute, all in the same form); `folder` is the
    /// linking note's folder in that same form, without a trailing slash.
    static func choose(candidates: [String], from folder: String?) -> String? {
        candidates.min { a, b in
            let aHere = parent(of: a) == folder
            let bHere = parent(of: b) == folder
            if aHere != bHere { return aHere }
            let aDepth = a.split(separator: "/").count
            let bDepth = b.split(separator: "/").count
            if aDepth != bDepth { return aDepth < bDepth }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
