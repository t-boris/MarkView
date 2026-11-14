import Foundation

/// "Close Documents" on the shipping `OpenTab` and `WorkspaceTabsStore`: which tabs are documents, and what stays open and active.
enum TabClosingStoreTests {
    @MainActor static func run() {
        func tab(_ name: String, _ kind: TabKind) -> OpenTab {
            OpenTab(url: URL(fileURLWithPath: "/tmp/\(name)"), content: "", originalContent: "", kind: kind)
        }
        let pdfHarness = PDFReaderRoutingHarness()
        pdfHarness.openFile(URL(fileURLWithPath: "/tmp/doc.pdf"))
        let documents = [tab("a.md", .file), tab("b.png", .image), pdfHarness.openTabs[0], tab("c.zip", .archive), tab("d.csv", .data)]
        let tools = [tab("t", .terminal(UUID())), tab("x", .architecture(scope: "")), tab("pr", .architecture(scope: TabKind.pullRequestScope)),
                     tab("i", .insight(InsightSession())), tab("dep", .deployments), tab("dis", .discussions), tab("wf", .workflow), tab("g", .git),
                     tab("rev", .changeReview), tab("gh", .github(.run(id: 1, repo: "o/r", title: "Run"))), tab("br", .browser(BrowserSession())),
                     tab("p", .prototype(PrototypeSession(slug: "p"))), tab("ui", .uiStudio(StudioSession())), tab("ck", .cockpit(CockpitSession())),
                     tab("qa", .qa)]
        precondition(documents.allSatisfy(\.isDocument), "file, image, PDF, archive and data tabs are documents")
        precondition(tools.allSatisfy { !$0.isDocument }, "every tool tab stays when documents close")

        func store(_ list: [OpenTab], active: Int) -> WorkspaceTabsStore {
            let store = WorkspaceTabsStore()
            list.forEach { store.appendTab($0, activate: false) }
            store.activeTabIndex = active
            return store
        }
        let doc1 = documents[0], git = tools[7], doc2 = documents[1], doc3 = documents[3], workflow = tools[6], doc4 = documents[4]
        let mixed = [doc1, git, doc2, doc3, workflow, doc4]

        var s = store(mixed, active: 1)
        s.keepTabs { !$0.isDocument }
        precondition(s.openTabs.map(\.id) == [git.id, workflow.id], "only the tool tabs stay, in their order")
        precondition(s.activeTabIndex == 0, "an active tool tab stays active")

        s = store(mixed, active: 4)
        s.keepTabs { !$0.isDocument }
        precondition(s.activeTabIndex == 1 && s.openTabs[1].id == workflow.id, "the second tool tab stays active at its new index")

        s = store(mixed, active: 3)
        s.keepTabs { !$0.isDocument }
        precondition(s.activeTabIndex == 0 && s.openTabs[0].id == git.id, "a closed active document hands over to the nearest tool tab on its left")

        s = store(mixed, active: 0)
        s.keepTabs { !$0.isDocument }
        precondition(s.activeTabIndex == 0 && s.openTabs[0].id == git.id, "with no tool tab on its left the first one on its right takes over")

        s = store(documents, active: 2)
        s.keepTabs { !$0.isDocument }
        precondition(s.openTabs.isEmpty && s.activeTabIndex == -1, "with only documents open every tab closes and the Welcome tab is active")

        s = store(tools, active: 3)
        let before = s.openTabs.map(\.id)
        s.keepTabs { !$0.isDocument }
        precondition(s.openTabs.map(\.id) == before && s.activeTabIndex == 3, "with no document open nothing changes")

        s = store(mixed, active: -1)
        s.keepTabs { !$0.isDocument }
        precondition(s.activeTabIndex == -1 && s.openTabs.count == 2, "the Welcome tab stays active")
        print("Close Documents: every tab kind classified, tool tabs kept in order, active tab handed over correctly")
    }
}
