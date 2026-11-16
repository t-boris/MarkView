import Foundation

// The Insight page template and the saved node tree, over real values: no window, session or assistant.
//   InsightHTMLTemplate: model-controlled text is escaped, section text is kept as written, equal input gives equal bytes.
//   InsightTreeSnapshot: what is saved comes back as the same tree (also from an older root-only snapshot).

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

func skeleton(title: String, topics: [(label: String, hint: String)] = []) -> InsightSkeleton {
    InsightSkeleton(title: title, suggestedTheme: nil, sections: [
        InsightSection(id: "s1", type: .prose, title: "Overview <b>", scopeHint: nil, metadata: [:],
                       deepDiveTopics: topics.enumerated().map {
                           InsightDeepDiveTopic(id: "t\($0.offset)", label: $0.element.label, hint: $0.element.hint, scopeHint: [])
                       })
    ])
}

func node(_ title: String, parent: InsightNode?, buffer: String, scope: NodeScope = .folderRoot) -> InsightNode {
    let node = InsightNode(parentId: parent?.id, level: parent == nil ? 0 : 1, title: title, scope: scope)
    node.skeleton = skeleton(title: title)
    node.sectionStates = ["s1": SectionState(buffer: buffer, status: buffer.isEmpty ? .pending : .ready)]
    return node
}

print("=== Insight page template ===")
let hostile = skeleton(title: "<script>alert(1)</script> & \"co\"", topics: [(label: "A'b <i>", hint: "\"hint\" <x>")])
let states = ["s1": SectionState(buffer: "<p class=\"keep\">body & <b>text</b></p>", status: .ready)]
let crumbs: [(nodeId: String, title: String)] = [("ROOT-ID", "Root <1>"), ("CHILD-ID", "Child")]
let page = InsightHTMLTemplate.html(skeleton: hostile, sectionStates: states, breadcrumbs: crumbs, libRefMode: .exportRelative)
check(!page.contains("<script>alert(1)</script>") && page.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;co&quot;"),
      "the title is escaped in the page title and nowhere appears as markup")
check(page.contains("<h2>Overview &lt;b&gt;</h2>"), "a section title is escaped")
check(page.contains("<div class=\"section-body\"><p class=\"keep\">body & <b>text</b></p></div>"), "the section text streamed by the assistant is kept as written")
check(page.contains("data-topic-index=\"0\" title=\"&quot;hint&quot; &lt;x&gt;\">🤿 A&#39;b &lt;i&gt;</button>"),
      "a deep-dive button carries its escaped label and hint")
check(page.contains("<a class=\"crumb\" href=\"#ROOT-ID\">Root &lt;1&gt;</a>") && page.contains("<span class=\"crumb crumb-active\">Child</span>"),
      "breadcrumbs link every ancestor and mark the last one active, escaped")
check(page == InsightHTMLTemplate.html(skeleton: hostile, sectionStates: states, breadcrumbs: crumbs, libRefMode: .exportRelative),
      "equal input gives byte-identical output")
let blobPage = InsightHTMLTemplate.html(skeleton: hostile, sectionStates: states, breadcrumbs: crumbs,
    libRefMode: .runtimeBlobs(libBlobURLs: ["b.js": "blob:x/2", "a.css": "blob:x/1\"y"]))
let cssAt = blobPage.range(of: "<link rel=\"stylesheet\" href=\"blob:x/1&quot;y\">"), jsAt = blobPage.range(of: "<script src=\"blob:x/2\"></script>")
check(cssAt != nil && jsAt != nil && cssAt!.lowerBound < jsAt!.lowerBound, "runtime blobs are referenced in name order, a stylesheet as a link, the URL escaped")
check(InsightHTMLTemplate.escape("&<>\"'") == "&amp;&lt;&gt;&quot;&#39;", "the escape covers text and attribute contexts")

print("\n=== Insight tree snapshot ===")
let root = node("Root", parent: nil, buffer: "<p>root</p>")
let child = node("Auth", parent: root, buffer: "<p>auth</p>", scope: .topic(label: "Auth", hint: "h", files: [URL(fileURLWithPath: "/tmp/a.md")]))
root.children = [child.id]
let empty = node("Unfinished", parent: root, buffer: "")
let snapshot = InsightTreeSnapshot(rootId: root.id, folderPath: "/tmp/notes", nodes: [root, child, empty])
check(Set(snapshot.nodes?.map(\.nodeId) ?? []) == [root.id, child.id], "a node whose skeleton has no content yet is not saved")
guard let data = try? snapshot.encoded(), let decoded = InsightTreeSnapshot.decode(data) else {
    check(false, "the snapshot encodes and decodes")
    exit(1)
}
let restored = decoded.restoredNodes(rootTitle: "ignored") ?? []
let byId = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
check(restored.count == 2 && decoded.rootId == root.id && decoded.folderPath == "/tmp/notes", "the saved tree comes back with its root and folder")
check(byId[root.id]?.children == [child.id] && byId[child.id]?.parentId == root.id && byId[child.id]?.level == 1, "parent, children and level survive")
check(byId[child.id]?.sectionStates["s1"]?.buffer == "<p>auth</p>" && byId[child.id]?.sectionStates["s1"]?.status == .ready && byId[child.id]?.status == .ready,
      "section text comes back ready, and so does the node")
if case .topic(let label, let hint, let files)? = byId[child.id]?.scope {
    check(label == "Auth" && hint == "h" && files == [URL(fileURLWithPath: "/tmp/a.md")], "a deep dive keeps its topic, hint and files")
} else {
    check(false, "a deep dive keeps its topic scope")
}

let legacy = """
{"rootId":"\(root.id.uuidString)","folderPath":"/tmp/notes","createdAt":"2026-01-01T00:00:00Z",
 "skeleton":\(String(decoding: try! JSONEncoder().encode(skeleton(title: "Old")), as: UTF8.self)),"sectionBuffers":{"s1":"<p>old</p>"}}
"""
let old = InsightTreeSnapshot.decode(Data(legacy.utf8))?.restoredNodes(rootTitle: "notes") ?? []
check(old.count == 1 && old[0].id == root.id && old[0].title == "notes" && old[0].sectionStates["s1"]?.buffer == "<p>old</p>",
      "an older root-only snapshot becomes one root node titled by the folder")
let bare = #"{"rootId":"\#(root.id.uuidString)","folderPath":"/x","createdAt":"2026-01-01T00:00:00Z","nodes":[]}"#
check(InsightTreeSnapshot.decode(Data(bare.utf8))?.restoredNodes(rootTitle: "x") == nil, "a snapshot with neither a tree nor a root restores nothing")
check(InsightTreeSnapshot.decode(Data("not json".utf8)) == nil, "unreadable data is no snapshot")

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
