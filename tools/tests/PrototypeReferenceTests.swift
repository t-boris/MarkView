import Foundation

// Checks the prototype reference agents are handed (MarkView/Models/PrototypeReference.swift): the reference
// string, every accepted form of a reference text (URI, bare slug, project-relative and absolute paths, with the
// site or a version folder) and what is rejected. Compiled by tools/tests/prototype-reference-tests.sh.

var failures = 0
func check(_ condition: Bool, _ message: String, _ detail: String = "", line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line)) \(detail)") }
}

// MARK: String

check(PrototypeReference.scheme == "markview" && PrototypeReference.host == "prototype", "scheme and host")
check(PrototypeReference.string(slug: "order-tracking") == "markview://prototype/order-tracking", "the reference string")
check(PrototypeReference.parse(PrototypeReference.string(slug: "shop-2")) == "shop-2", "a reference string parses back to its slug")

// MARK: Accepted forms

let forms: [(String, String)] = [
    ("markview://prototype/shop", "URI"),
    ("markview://prototype/shop/", "URI with trailing slash"),
    ("MARKVIEW://Prototype/shop", "URI scheme and host are case-insensitive"),
    ("  markview://prototype/shop\n", "surrounding whitespace is trimmed"),
    ("shop", "bare slug"),
    (".dde/prototypes/shop", "project-relative path"),
    (".dde/prototypes/shop/", "project-relative path with trailing slash"),
    ("./.dde/prototypes/shop", "project-relative path with a leading dot"),
    (".dde/prototypes/shop/site", "the site folder"),
    (".dde/prototypes/shop/site/", "the site folder with trailing slash"),
    (".dde/prototypes/shop/versions/v3", "a version folder"),
    ("/Users/boris/github.com/App/.dde/prototypes/shop", "absolute path"),
    ("/Users/boris/github.com/App/.dde/prototypes/shop/site", "absolute path to the site"),
    ("/Users/boris/github.com/App/.dde/prototypes/shop/versions/v12/", "absolute path to a version"),
    ("markview://prototype/shop/versions/v2", "URI with a version folder"),
]
for (text, name) in forms {
    check(PrototypeReference.parse(text) == "shop", "parses \(name): \(text.debugDescription)", "\(String(describing: PrototypeReference.parse(text)))")
}
check(PrototypeReference.parse("order_tracking-2") == "order_tracking-2", "a slug may hold dashes and underscores")
check(PrototypeReference.parse("заказы") == "заказы", "a slug may hold non-ASCII letters, as PrototypeFiles.slug makes them")

// MARK: Version: read, reported, never required

check(PrototypeReference.components(".dde/prototypes/shop/versions/v3") == .init(slug: "shop", version: 3), "the version folder is reported")
check(PrototypeReference.components("/x/.dde/prototypes/shop/versions/v12/") == .init(slug: "shop", version: 12), "a multi-digit version is read")
check(PrototypeReference.components("markview://prototype/shop")?.version == nil, "a plain reference carries no version")
check(PrototypeReference.components(".dde/prototypes/shop/site")?.version == nil, "the site is the latest version")

// MARK: Rejected

let rejected: [(String, String)] = [
    ("", "empty"),
    ("   ", "blank"),
    ("markview://prototype/", "URI without a slug"),
    ("markview://prototype", "URI without a path"),
    ("markview://feature/shop", "another host"),
    ("https://prototype/shop", "another scheme"),
    ("markview:prototype/shop", "not a URI"),
    ("markview://prototype/shop/site/index.html", "a file inside the site"),
    ("markview://prototype/shop/prototype.json", "the manifest"),
    ("markview://prototype/shop/versions", "versions without a number"),
    ("markview://prototype/shop/versions/3", "a version without v"),
    ("markview://prototype/shop/versions/v0", "version zero"),
    ("markview://prototype/shop/versions/vX", "a non-numeric version"),
    ("markview://prototype/shop/versions/v1/index.html", "a file inside a version"),
    ("markview://prototype/../shop", "dot-dot in the URI"),
    ("markview://prototype/shop/..", "dot-dot after the slug"),
    (".dde/prototypes/../shop", "dot-dot in a relative path"),
    ("/x/../.dde/prototypes/shop", "dot-dot before the storage folder"),
    ("/x/.dde/prototypes/shop/../other", "dot-dot after the slug in an absolute path"),
    ("..", "dot-dot alone"),
    ("../shop", "a parent path"),
    ("a/b", "a path that is not the storage layout"),
    ("docs/.dde/prototypes/shop", "a relative path that does not start with the storage folder"),
    (".dde/prototypes", "the storage folder alone"),
    (".dde/prototypes/", "the storage folder alone with a slash"),
    ("/x/.dde/prototypes", "an absolute storage folder without a slug"),
    (".dde/prototypes/.hidden", "a hidden name"),
    (".dde/prototypes/shop/other", "another folder under the prototype"),
    (".dde/prototypes/shop/site/x", "a file under the site"),
    ("shop v3", "a slug with a space"),
    ("shop?x=1", "a slug with a query"),
    ("shop#top", "a slug with a fragment"),
    ("a\\b", "a backslash"),
    (".dde/other/shop", "another folder under .dde"),
]
for (text, name) in rejected {
    check(PrototypeReference.parse(text) == nil, "rejects \(name): \(text.debugDescription)", "\(String(describing: PrototypeReference.parse(text)))")
}

print(failures == 0 ? "All prototype reference checks passed." : "\(failures) prototype reference check(s) failed.")
exit(failures == 0 ? 0 : 1)
