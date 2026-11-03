import Foundation

// Standalone check of the rule that decides which pictures next to a document the editor page may be given (BUG-061).
// Run with tools/tests/document-files-tests.sh.

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
}

@main
struct DocumentFilesTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("document-files-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        for folder in [project.appendingPathComponent("docs/images"), project.appendingPathComponent("sub"), outside] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: base) }
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        for path in ["docs/images/shot.png", "docs/images/file tree.PNG", "docs/images/logo.svg", "docs/notes.md", "sub/up.jpg"] {
            try bytes.write(to: project.appendingPathComponent(path))
        }
        try bytes.write(to: outside.appendingPathComponent("secret.png"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("docs/escape.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("docs/linked"), withDestinationURL: outside)

        func request(_ path: String) -> URL {
            var components = URLComponents()
            components.scheme = DocumentFiles.scheme
            components.host = ""
            components.path = path
            return components.url!
        }
        func resolve(_ path: String, roots: [URL]? = nil) -> DocumentFiles.Resolution {
            DocumentFiles.resolve(request(path), roots: roots ?? [project])
        }
        let real = project.resolvingSymlinksInPath().standardizedFileURL

        // A picture inside the project is served with its content type.
        if case .file(let url, let type) = resolve(project.path + "/docs/images/shot.png") {
            check("a picture inside the project is served", url.path == real.appendingPathComponent("docs/images/shot.png").path, url.path)
            check("png gets image/png", type == "image/png", type)
        } else { check("a picture inside the project is served", false) }

        if case .file(_, let type) = resolve(project.path + "/docs/images/logo.svg") {
            check("svg is declared as svg so an img can draw it", type == "image/svg+xml", type)
        } else { check("svg is served", false) }

        if case .file(let url, let type) = resolve(project.path + "/docs/images/file tree.PNG") {
            check("a name with a space and a capital extension is served", url.lastPathComponent == "file tree.PNG" && type == "image/png", url.path)
        } else { check("a name with a space and a capital extension is served", false) }

        // The address the page builds for a path with a space is percent-encoded; the request decodes it back.
        let encoded = URL(string: "markview-doc://" + project.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "/docs/images/file%20tree.PNG")!
        if case .file(let url, _) = DocumentFiles.resolve(encoded, roots: [project]) {
            check("a percent-encoded request is decoded", url.lastPathComponent == "file tree.PNG", url.path)
        } else { check("a percent-encoded request is decoded", false) }

        // Only pictures.
        check("a Markdown file is refused", resolve(project.path + "/docs/notes.md") == .forbidden)
        check("a path without a file type is refused", resolve(project.path + "/docs/images") == .forbidden)

        // Only inside the folders the person works in.
        check("a picture outside every root is refused", resolve(outside.path + "/secret.png") == .forbidden)
        check("a .. that leaves the root is refused", resolve(project.path + "/docs/../../outside/secret.png") == .forbidden)
        check("a symbolic link to a picture outside is refused", resolve(project.path + "/docs/escape.png") == .forbidden)
        check("a symbolic link to a folder outside is refused", resolve(project.path + "/docs/linked/secret.png") == .forbidden)
        check("a sibling folder with the root's name as a prefix is refused",
              resolve(base.path + "/project-other/x.png") == .forbidden)

        // .. that stays inside is fine.
        if case .file(let url, _) = resolve(project.path + "/sub/../docs/images/shot.png") {
            check("a .. that stays inside the root is served", url.lastPathComponent == "shot.png")
        } else { check("a .. that stays inside the root is served", false) }

        // Several roots: the folder of a document outside the project.
        check("a picture next to a document outside the project is served with that folder as a root",
              resolve(outside.path + "/secret.png", roots: [project, outside]) != .forbidden)

        // Requests that are not for this scheme or not absolute.
        check("another scheme is refused", DocumentFiles.resolve(URL(string: "https://example.com/a.png")!, roots: [project]) == .forbidden)
        check("no roots, nothing is served", resolve(project.path + "/docs/images/shot.png", roots: []) == .forbidden)

        // The roots: the project and the folder of each open document, without repeats.
        let docs = [project.appendingPathComponent("README.md"), project.appendingPathComponent("docs/notes.md"), outside.appendingPathComponent("a.md")]
        let roots = DocumentFiles.roots(project: project, documents: docs)
        check("roots are the project and the folders of the documents", roots.map(\.path) == [project.path, project.appendingPathComponent("docs").path, outside.path], roots.map(\.path).joined(separator: ", "))
        check("roots without a project are the folders of the documents",
              DocumentFiles.roots(project: nil, documents: [outside.appendingPathComponent("a.md")]).map(\.path) == [outside.path])

        print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
