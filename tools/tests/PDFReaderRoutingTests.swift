import Foundation
import SwiftUI

// Not exercised here: audio transcription must never run while a PDF is read.
struct WhisperClient {
    init() { preconditionFailure("PDF reading must never invoke audio transcription") }
    func transcribe(fileURL: URL) async -> String? { nil }
}

/// The person is never asked anything while a PDF opens: any question is a failure of the check.
@MainActor
struct NeverAsked: UserPrompts {
    func ask(_ prompt: UserPrompt) -> Int? { preconditionFailure("A PDF tab asks nothing, but it asked: \(prompt.title)") }
}

/// A PDF opens in a tab of its own on the shipping `TabsController`: no text, no save, no watcher, one tab per file.
enum PDFReaderRoutingTests {
    @MainActor static func run() {
        let file = URL(fileURLWithPath: "/tmp/Read only.PDF")
        let tabs = TabsController(prompts: NeverAsked())
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
