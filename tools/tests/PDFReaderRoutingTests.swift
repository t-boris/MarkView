import Foundation
import SwiftUI

// Not exercised here: audio transcription must never run while a PDF is read.
struct WhisperClient {
    init() { preconditionFailure("PDF reading must never invoke audio transcription") }
    func transcribe(fileURL: URL) async -> String? { nil }
}

/// A PDF opens in a tab of its own on the shipping `TabsController`: no text, no save, no watcher, one tab per file.
enum PDFReaderRoutingTests {
    @MainActor static func run() {
        let file = URL(fileURLWithPath: "/tmp/Read only.PDF")
        let tabs = TabsController(dialogs: TabDialogs(
            askToSave: { _, _ in preconditionFailure("A PDF tab never asks about unsaved changes") },
            confirmSave: { _, _ in preconditionFailure("A PDF tab never asks about unsaved changes") },
            reportFailedSave: { _ in preconditionFailure("A PDF tab never saves") },
            offerDefaultApp: { _, _ in preconditionFailure("A PDF is not read as text") }))
        tabs.openDocument(file)
        precondition(FileType.from(url: file) == .pdf && !FileType.hasTextSource(file))
        precondition(tabs.openTabs.count == 1 && tabs.activeTabIndex == 0)
        precondition(!tabs.openTabs[0].isFileBacked && tabs.openTabs[0].content.isEmpty)
        guard case .pdf = tabs.openTabs[0].kind else { preconditionFailure("Not a PDF reader tab") }
        let originalID = tabs.openTabs[0].id
        tabs.saveActiveFile()
        precondition(!FileManager.default.fileExists(atPath: file.path) && tabs.lastSaveError == nil, "saving a PDF tab writes nothing")
        tabs.openDocument(URL(fileURLWithPath: "/tmp/Another.pdf"))
        precondition(tabs.openTabs.count == 2 && tabs.activeTabIndex == 1)
        tabs.openDocument(file)
        precondition(tabs.openTabs.count == 2 && tabs.activeTabIndex == 0)
        precondition(tabs.openTabs[0].id == originalID)
        tabs.shutdown()
        print("PDF workspace routing: dedicated tabs, duplicate reuse, no text/save path passed")
    }
}
