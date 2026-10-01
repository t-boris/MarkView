// Checks the Book X-Ray skeleton (MarkView/Models/BookBuilder.swift): headings of every text
// format, slugs, nested sections with line ranges, link extraction and resolution down to the
// section, reading order, and the nodes/edges of a small book.
import Foundation

// The app's node and edge types, as far as the builder uses them.
struct ArchNode {
    var id: String
    var parent: String?
    var kind: String
    var name: String
    var path: String?
    var language: String?
    var loc: Int
    var files: Int
    var summary: String?
    var signature: String?
    var summarySignature: String?
    var line: Int?
    var endLine: Int?
    var anchor: String?

    init(id: String, parent: String?, kind: String, name: String, path: String? = nil, language: String? = nil,
         loc: Int = 0, files: Int = 0, summary: String? = nil) {
        self.id = id; self.parent = parent; self.kind = kind; self.name = name; self.path = path
        self.language = language; self.loc = loc; self.files = files; self.summary = summary
    }
}

struct ArchView {
    var id: String
    var nodes: [ArchNode]
    var edges: [ArchEdge]
}

struct ArchEdge {
    var source: String
    var target: String
    var kind: String
    var weight: Int = 1
    var label: String?
}

extension String {
    var editorLines: [Substring] {
        replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
    }
}

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "ok  " : "FAIL") \(name)")
    if !condition { failures += 1 }
}
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want { print("ok   \(name)") } else { failures += 1; print("FAIL \(name): got \(got) want \(want)") }
}

// MARK: Text documents

check("markdown is a text document", BookBuilder.isTextDocument("docs/a.md"))
check("txt/rst/adoc/org are text documents", ["notes.txt", "a/b.rst", "guide.adoc", "todo.org"].allSatisfy(BookBuilder.isTextDocument))
check("CMakeLists.txt is not", !BookBuilder.isTextDocument("CMakeLists.txt"))
check("requirements.txt is not", !BookBuilder.isTextDocument("requirements-dev.txt"))
check("swift is not", !BookBuilder.isTextDocument("App.swift"))

// MARK: Headings

let markdown = """
---
title: front matter
---
# Guide

Intro text.

## Setup

```sh
# not a heading
echo "## nor this"
```

### Install

Setext title
------------

## Setup

#hashtag line
####### seven hashes
"""
let heads = BookBuilder.headings(of: markdown, format: .markdown)
check("markdown headings", heads.map { "\($0.level):\($0.title)@\($0.line)" },
      ["1:Guide@4", "2:Setup@8", "3:Install@15", "2:Setext title@17", "2:Setup@20"])

let adoc = "= Title\n\n== First\n\n----\n== not a heading\n----\n\n=== Deep\n"
check("asciidoc headings", BookBuilder.headings(of: adoc, format: .asciidoc).map { "\($0.level):\($0.title)" },
      ["1:Title", "2:First", "3:Deep"])

let rst = "=====\nTitle\n=====\n\nPart\n----\n\nSub\n~~~\n\nPart two\n--------\n"
check("rst headings by adornment", BookBuilder.headings(of: rst, format: .rst).map { "\($0.level):\($0.title)@\($0.line)" },
      ["1:Title@2", "2:Part@5", "3:Sub@8", "2:Part two@11"])

let org = "* One\n#+BEGIN_SRC\n* not\n#+END_SRC\n** Two\n*** Three\n*nope\n"
check("org headings", BookBuilder.headings(of: org, format: .org).map { "\($0.level):\($0.title)" }, ["1:One", "2:Two", "3:Three"])
check("plain text has no headings", BookBuilder.headings(of: "a\nb", format: .plain).isEmpty)

// MARK: Slugs

check("github slug", BookBuilder.slug("API: Auth & Tokens"), "api-auth--tokens")
check("cyrillic slug", BookBuilder.slug("Сборка и релиз"), "сборка-и-релиз")
check("markup stripped", BookBuilder.slug("3.2 `ArchitectureScanner` and *links* [x](y.md) ##"), "32-architecturescanner-and-links-x")
check("underscore kept", BookBuilder.slug("snake_case_name"), "snake_case_name")
check("unique slugs", BookBuilder.uniqueSlugs(["setup", "intro", "setup", "setup"]), ["setup", "intro", "setup-1", "setup-2"])

// MARK: Chapters

let doc = """
# Architecture map

Overview paragraph.

## 1. Purpose

Text [see scanner](#3-scanner) and [[other]].

### 1.1 Goals

Goal text.

## 3. Scanner

Scanner text, see [concurrency](../guides/concurrency.md#main-actor) and [missing](nowhere.md).

### 3.1 Files

Files [ref][sc] and ![image](pic.png) and `[code](x.md)`.

[sc]: ./scanner.md#files
"""
let chapter = BookBuilder.chapter(path: "docs/arch.md", text: doc)
check("title from the only H1", chapter.title, "Architecture map")
check("sections exclude the title", chapter.sections.map(\.title), ["1. Purpose", "1.1 Goals", "3. Scanner", "3.1 Files"])
check("section ids by slug", chapter.sections.map(\.id),
      ["d:docs/arch.md#1-purpose", "d:docs/arch.md#11-goals", "d:docs/arch.md#3-scanner", "d:docs/arch.md#31-files"])
check("nesting by level", chapter.sections.map(\.parent),
      ["d:docs/arch.md", "d:docs/arch.md#1-purpose", "d:docs/arch.md", "d:docs/arch.md#3-scanner"])
check("ranges: parent spans children, last ends at EOF", chapter.sections.map { "\($0.start)-\($0.end)" }, ["5-12", "9-12", "13-21", "17-21"])
check("title slug leads to the chapter", chapter.anchors["architecture-map"], "d:docs/arch.md")
check("innermost section by line", chapter.section(containing: 10)?.id, "d:docs/arch.md#11-goals")
check("chapter-level line has no section", chapter.section(containing: 3) == nil)
check("signature is 24 hex", chapter.signature.count == 24 && chapter.signature.allSatisfy(\.isHexDigit))

check("links found with lines", chapter.links.map { "\($0.line):\($0.target)#\($0.fragment ?? "")\($0.wiki ? "w" : "")" },
      ["7:other#w", "7:#3-scanner", "15:../guides/concurrency.md#main-actor", "15:nowhere.md#", "19:./scanner.md#files"])

let twoH1 = BookBuilder.chapter(path: "notes.md", text: "# A\n\ntext\n\n# B\n\nmore\n")
check("two H1s: file name title, both are sections", twoH1.title == "notes" && twoH1.sections.map(\.title) == ["A", "B"])
let headless = BookBuilder.chapter(path: "plain.txt", text: "just\nsome\ntext")
check("headless chapter", !headless.hasHeadings && headless.sections.isEmpty && headless.lines == 3)

// Cap: 400 H3 headings under 2 H2s keep the H2s and drop the H3s; links to dropped ones go up.
var big = "# T\n"
for i in 0..<2 { big += "## Part \(i)\n"; for j in 0..<200 { big += "### Item \(i)-\(j)\n" } }
let capped = BookBuilder.chapter(path: "big.md", text: big)
check("section cap drops deepest level", capped.sections.map(\.title), ["Part 0", "Part 1"])
check("dropped heading leads to kept ancestor", capped.anchors["item-1-7"], "d:big.md#part-1")

// MARK: Resolution

let concurrency = BookBuilder.chapter(path: "guides/concurrency.md", text: "# Concurrency\n\n## Main actor\n\ntext\n\n## Queues\n\nmore\n")
let other = BookBuilder.chapter(path: "docs/other.md", text: "# Other\n\nbody\n")
let otherDeep = BookBuilder.chapter(path: "deep/x/other.md", text: "# Other deep\n\nbody\n")
let scanner = BookBuilder.chapter(path: "docs/scanner.md", text: "# Scanner\n\n## Files\n\nf\n\n## Files\n\ng\n")
let readme = BookBuilder.chapter(path: "README.md", text: "# The Book\n\nStart [here](docs/arch.md) and [there](docs/arch.md#L10).\n")
let chapters = [chapter, concurrency, other, otherDeep, scanner, readme]
let index = BookBuilder.Index(chapters)
func resolve(_ link: BookBuilder.Link, from: BookBuilder.Chapter = chapter) -> String? { BookBuilder.resolve(link, from: from, index: index) }

check("same-document fragment", resolve(.init(line: 7, target: "", fragment: "3-scanner", wiki: false)), "d:docs/arch.md#3-scanner")
check("relative path with fragment", resolve(.init(line: 15, target: "../guides/concurrency.md", fragment: "main-actor", wiki: false)), "d:guides/concurrency.md#main-actor")
check("fragment by heading text", resolve(.init(line: 15, target: "../guides/concurrency.md", fragment: "Main Actor", wiki: false)), "d:guides/concurrency.md#main-actor")
check("unknown fragment → chapter", resolve(.init(line: 15, target: "../guides/concurrency.md", fragment: "nope", wiki: false)), "d:guides/concurrency.md")
check("missing document → nil", resolve(.init(line: 15, target: "nowhere.md", fragment: nil, wiki: false)) == nil)
check("./ prefix and duplicate slug", resolve(.init(line: 19, target: "./scanner.md", fragment: "files-1", wiki: false)), "d:docs/scanner.md#files-1")
check("wiki link by name prefers the same folder", resolve(.init(line: 7, target: "other", fragment: nil, wiki: true)), "d:docs/other.md")
check("wiki link by name elsewhere: shortest path", resolve(.init(line: 1, target: "other", fragment: nil, wiki: true), from: readme), "d:docs/other.md")
check("wiki link with heading", resolve(.init(line: 7, target: "concurrency", fragment: "Queues", wiki: true)), "d:guides/concurrency.md#queues")
check("wiki path from the root", resolve(.init(line: 7, target: "guides/concurrency", fragment: nil, wiki: true)), "d:guides/concurrency.md")
check("extension added", resolve(.init(line: 7, target: "scanner", fragment: nil, wiki: false)), "d:docs/scanner.md")
check("#L line fragment → containing section", resolve(.init(line: 3, target: "docs/arch.md", fragment: "L10", wiki: false), from: readme), "d:docs/arch.md#11-goals")
check("percent-decoded path", resolve(.init(line: 1, target: "docs/arch.md", fragment: nil, wiki: false), from: readme), "d:docs/arch.md")

// MARK: Order

let paths = ["zeta.md", "docs/10-api.md", "README.md", "docs/2-setup.md", "docs/01-intro.md", "docs/README.md", "docs/sub/a.md", "docs/b.md"]
check("book order", paths.sorted(by: BookBuilder.bookOrder),
      ["README.md", "zeta.md", "docs/README.md", "docs/01-intro.md", "docs/2-setup.md", "docs/10-api.md", "docs/b.md", "docs/sub/a.md"])

// MARK: Build

let book = BookBuilder.build(chapters: chapters, rootName: "folder")
check("book title from the root README", book.nodes.first?.name, "The Book")
check("parts and chapters in order", book.nodes.filter { $0.kind == "dir" || $0.kind == "doc" }.map(\.id),
      ["d:README.md", "d:deep/", "d:deep/x/", "d:deep/x/other.md", "d:docs/", "d:docs/arch.md", "d:docs/other.md", "d:docs/scanner.md",
       "d:guides/", "d:guides/concurrency.md"])
let archNode = book.nodes.first { $0.id == "d:docs/arch.md" }!
check("chapter node", archNode.kind == "doc" && archNode.name == "Architecture map" && archNode.language == "markdown" && archNode.files == 1 && archNode.signature != nil)
let goals = book.nodes.first { $0.id == "d:docs/arch.md#11-goals" }!
check("section node carries lines and anchor", goals.line == 9 && goals.endLine == 12 && goals.anchor == "1.1 Goals" && goals.loc == 4)
let docsPart = book.nodes.first { $0.id == "d:docs/" }!
check("part counts chapters and lines", docsPart.files == 3 && docsPart.loc == chapter.lines + other.lines + scanner.lines)
let edgeKeys = book.edges.map { "\($0.source) → \($0.target) ×\($0.weight)" }
check("edges from the containing section to the section",
      edgeKeys.contains("d:docs/arch.md#1-purpose → d:docs/arch.md#3-scanner ×1")
      && edgeKeys.contains("d:docs/arch.md#1-purpose → d:docs/other.md ×1")
      && edgeKeys.contains("d:docs/arch.md#3-scanner → d:guides/concurrency.md#main-actor ×1")
      && edgeKeys.contains("d:docs/arch.md#31-files → d:docs/scanner.md#files ×1"))
check("README links from the chapter, weight aggregates by target", edgeKeys.contains("d:README.md → d:docs/arch.md ×1")
      && edgeKeys.contains("d:README.md → d:docs/arch.md#11-goals ×1"))
check("no edge to a missing document or image", !edgeKeys.contains { $0.contains("nowhere") || $0.contains("pic.png") })
check("no edge from code spans", !edgeKeys.contains { $0.contains("x.md") })

let selfLink = BookBuilder.chapter(path: "s.md", text: "# S\n\n## A\n\n[up](#s) [self](#a)\n\n### B\n\n[parent](#a)\n")
let selfBook = BookBuilder.build(chapters: [selfLink], rootName: "x")
check("self, ancestor and descendant links dropped", selfBook.edges.isEmpty)

// MARK: Annotator

let bookView = ArchView(id: "docs", nodes: book.nodes, edges: book.edges)
let annotated = BookAnnotator.Book(view: bookView, language: "English")
check("book title and chapters", annotated.title == "The Book" && annotated.chapters.count == 6)
let archChapter = annotated.chapters.first { $0.path == "docs/arch.md" }!
check("chapter sections with depth", archChapter.sections.map { "\($0.depth)" }, ["0", "1", "0", "1"])
check("chapter not current before annotation", !archChapter.isCurrent)
check("README is front matter", annotated.chapters.first { $0.path == "README.md" }!.isFrontMatter)

// Windows: a 6000-line chapter with three 2000-line top-level sections.
var longChapter = archChapter
longChapter.lines = 6000
longChapter.sections = [
    BookAnnotator.Section(id: "s1", parent: "c", title: "One", line: 1, end: 2000, depth: 0),
    BookAnnotator.Section(id: "s1a", parent: "s1", title: "One a", line: 100, end: 2000, depth: 1),
    BookAnnotator.Section(id: "s2", parent: "c", title: "Two", line: 2001, end: 4000, depth: 0),
    BookAnnotator.Section(id: "s3", parent: "c", title: "Three", line: 4001, end: 6000, depth: 0),
]
let windows = BookAnnotator.windows(for: longChapter)
check("windows split at top-level sections", windows.map { "\($0.start)-\($0.end):\($0.sectionIds.joined(separator: ","))" },
      ["1-2000:s1,s1a", "2001-4000:s2", "4001-6000:s3"])
check("short chapter: one window", BookAnnotator.windows(for: archChapter).count == 1)
check("long chapter is large", longChapter.isLarge && !archChapter.isLarge)

let job = BookAnnotator.Job(chapter: archChapter, window: BookAnnotator.windows(for: archChapter)[0])
let built = BookAnnotator.request(job: job, book: annotated, lines: doc.editorLines.map(String.init))
check("prompt lists sections with ids and lines", built.prompt.contains("- d:docs/arch.md#1-purpose | 1. Purpose | 5–12")
      && built.prompt.contains("  - d:docs/arch.md#11-goals | 1.1 Goals | 9–12"))
check("prompt has the index with same-part sections", built.prompt.contains("- d:docs/scanner.md | Scanner") && built.prompt.contains("- d:docs/scanner.md#files | Files"))
check("prompt numbers the text", built.prompt.contains("1| # Architecture map"))
check("system prompt asks for facts, no items for a small chapter", built.system.contains("CHAPTER SUMMARY") && !built.system.contains("ITEMS:"))
check("schema has sections", (built.schema["required"] as? [String]) == ["sections"])

check("empty answer unusable", !BookAnnotator.isUsable([:], job: job))
check("answer without chapter summary unusable", !BookAnnotator.isUsable(["sections": [["id": "d:docs/arch.md#1-purpose", "summary": "x"]]], job: job))
let answer: [String: Any] = [
    "chapter": ["summary": "Maps the X-Ray: scanner, store, views.", "importance": "high"],
    "sections": [
        ["id": "d:docs/arch.md#1-purpose", "summary": "States the goals of the map.", "importance": "critical",
         "refs": [["target": "d:docs/scanner.md#files", "why": "scanner lists files"],
                  ["target": "d:docs/arch.md#1-purpose", "why": "self"],
                  ["target": "d:docs/arch.md#11-goals", "why": "child"],
                  ["target": "d:nowhere.md", "why": "unknown"]]],
        ["id": "d:docs/arch.md#3-scanner", "summary": "Lists what the scanner reads.", "importance": "normal", "refs": [],
         "items": [["name": "Files", "type": "Input", "line": 14], ["name": "Links", "type": "Input", "line": 15],
                   ["name": "Tokens", "type": "Input", "line": 15], ["name": "Edges", "type": "Output", "line": 99],
                   ["name": "Refs", "type": "Output", "line": 1]]],
        ["id": "d:unknown#x", "summary": "ignored", "importance": "low", "refs": []],
    ],
]
check("answer usable", BookAnnotator.isUsable(answer, job: job))
let applied = BookAnnotator.apply(answer, job: job, to: bookView, lines: doc.editorLines.map(String.init))
let byId = Dictionary(applied.view.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
check("chapter summary and signature", byId["d:docs/arch.md"]?.summary == "Maps the X-Ray: scanner, store, views." && byId["d:docs/arch.md"]?.summarySignature == archChapter.expectedSignature)
check("section summaries", byId["d:docs/arch.md#1-purpose"]?.summary == "States the goals of the map." && byId["d:docs/arch.md#3-scanner"]?.summary != nil)
check("importance keys", applied.importance == ["p:docs/arch.md": "high", "d:docs/arch.md#1-purpose": "critical", "d:docs/arch.md#3-scanner": "normal"])
let related = applied.view.edges.filter { $0.kind == "related" }
check("one related edge survives (self, child, unknown dropped)", related.map { "\($0.source)→\($0.target):\($0.label ?? "")" }, ["d:docs/arch.md#1-purpose→d:docs/scanner.md#files:scanner lists files"])
check("explicit links kept", applied.view.edges.filter { $0.kind == "links" }.count == book.edges.count)
let items = applied.view.nodes.filter { $0.id.hasPrefix("d:docs/arch.md#3-scanner/") }
check("five items under the section, no group level (groups under 4 items)", items.count == 5 && items.allSatisfy { $0.kind == "entity" && $0.parent == "d:docs/arch.md#3-scanner" })
check("item lines clamped into the section", items.allSatisfy { ($0.line ?? 0) >= 13 && ($0.line ?? 0) <= 21 })

// Re-applying replaces the earlier items and related edges instead of adding to them.
let reapplied = BookAnnotator.apply(answer, job: job, to: applied.view, lines: doc.editorLines.map(String.init))
check("re-apply replaces items and refs", reapplied.view.nodes.filter { $0.id.hasPrefix("d:docs/arch.md#3-scanner/") }.count == 5
      && reapplied.view.edges.filter { $0.kind == "related" }.count == 1)

// A document without headings: the AI proposes the sections.
let plainBook = BookBuilder.build(chapters: [BookBuilder.chapter(path: "notes.txt", text: Array(repeating: "line", count: 60).joined(separator: "\n"))], rootName: "n")
let plainView = ArchView(id: "docs", nodes: plainBook.nodes, edges: plainBook.edges)
let plainChapter = BookAnnotator.Book(view: plainView, language: "English").chapters[0]
let plainJob = BookAnnotator.Job(chapter: plainChapter, window: BookAnnotator.windows(for: plainChapter)[0])
check("headless prompt says so", BookAnnotator.request(job: plainJob, book: BookAnnotator.Book(view: plainView, language: "English"), lines: Array(repeating: "line", count: 60)).system.contains("no headings"))
let plainAnswer: [String: Any] = [
    "chapter": ["summary": "Notes.", "importance": "normal"],
    "sections": [["id": "", "title": "Second part", "line": 31, "summary": "B", "importance": "normal", "refs": []],
                 ["id": "", "title": "First part", "line": 1, "summary": "A", "importance": "high", "refs": []]],
]
check("headless answer usable", BookAnnotator.isUsable(plainAnswer, job: plainJob))
let plainApplied = BookAnnotator.apply(plainAnswer, job: plainJob, to: plainView, lines: Array(repeating: "line", count: 60))
let plainSections = plainApplied.view.nodes.filter { $0.kind == "section" }
check("AI sections with ranges", plainSections.map { "\($0.id):\($0.line ?? 0)-\($0.endLine ?? 0)" }, ["d:notes.txt#first-part:1-30", "d:notes.txt#second-part:31-60"])
check("AI section summaries and importance", plainSections.first?.summary == "A" && plainApplied.importance["d:notes.txt#first-part"] == "high")

// Parts.
check("no parts call without chapter summaries", BookAnnotator.partsRequests(view: bookView, language: "English").isEmpty)
let partsRequests = BookAnnotator.partsRequests(view: applied.view, language: "English")
check("one parts call listing parts with chapters", partsRequests.count == 1 && partsRequests[0].prompt.contains("- d:docs/ (3 chapters")
      && partsRequests[0].prompt.contains("\"Architecture map\" — Maps the X-Ray: scanner, store, views"))
let withParts = BookAnnotator.applyParts(["book": ["summary": "All about X-Ray."], "parts": [["id": "d:docs/", "summary": "Design notes."]]], to: applied.view)
check("part and book summaries applied", withParts.nodes.first { $0.id == "d:docs/" }?.summary == "Design notes." && withParts.nodes.first { $0.kind == "root" }?.summary == "All about X-Ray.")

print(failures == 0 ? "All Book X-Ray checks passed" : "\(failures) Book X-Ray check(s) failed")
exit(failures == 0 ? 0 : 1)
