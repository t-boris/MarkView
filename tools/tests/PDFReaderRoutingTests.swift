import Foundation
import SwiftUI

// Dependencies not exercised by the extracted, shipping workspace routing and tab store.
struct InsightSession {}
struct SemanticBlock {}
struct BlockCompilationState {}
struct BrowserSession {}
struct PrototypeSession { let slug: String }
struct StudioSession {}
enum Archive { static func isArchive(_ url: URL) -> Bool { false } }
struct WhisperClient {
    init() { preconditionFailure("PDF reading must never invoke audio transcription") }
    func transcribe(fileURL: URL) async -> String? { nil }
}

@MainActor
final class PDFReaderRoutingHarness {
    enum Area { case files }
    struct Layout { var workspaceArea = Area.files }
    struct Feature { let slug: String }
    struct Located { let feature: Feature }
    struct Features { func locate(_ url: URL) -> Located? { nil } }
    var layout = Layout()
    let features = Features()
    let tabsStore = WorkspaceTabsStore()
    var rootOpenedAsFolder = true
    var openFileDates: [URL: Date] = [:]
    var recent: [URL] = []
    var openTabs: [OpenTab] { tabsStore.openTabs }
    var activeTabIndex: Int { tabsStore.activeTabIndex }
    func isFileInCurrentWorkspace(_ url: URL) -> Bool { true }
    func initSingleFileWorkspace(fileURL: URL) { preconditionFailure("PDF must not initialize a text workspace") }
    func showFeatureContext(_ slug: String) {}
    func addRecentFile(_ url: URL) { recent.append(url) }
    func startWatchingOpenFiles() { preconditionFailure("PDF must not start a text/data watch") }
    func openTextFile(_ url: URL) async { preconditionFailure("PDF must not be loaded as text") }
    func saveFile(at index: Int) { preconditionFailure("PDF must not enter text saving") }
}

enum PDFReaderRoutingTests {
    @MainActor static func run() {
        let file = URL(fileURLWithPath: "/tmp/Read only.PDF")
        let harness = PDFReaderRoutingHarness()
        harness.openFile(file)
        precondition(FileType.from(url: file) == .pdf && !FileType.hasTextSource(file))
        precondition(harness.openTabs.count == 1 && harness.activeTabIndex == 0)
        precondition(!harness.openTabs[0].isFileBacked && harness.openTabs[0].content.isEmpty)
        guard case .pdf = harness.openTabs[0].kind else { preconditionFailure("Not a PDF reader tab") }
        let originalID = harness.openTabs[0].id
        harness.saveActiveFile()
        harness.openFile(URL(fileURLWithPath: "/tmp/Another.pdf"))
        precondition(harness.openTabs.count == 2 && harness.activeTabIndex == 1)
        harness.openFile(file)
        precondition(harness.openTabs.count == 2 && harness.activeTabIndex == 0)
        precondition(harness.openTabs[0].id == originalID && harness.recent.count == 2)
        print("PDF workspace routing: dedicated tabs, duplicate reuse, no text/AI/indexing/save path passed")
    }
}
