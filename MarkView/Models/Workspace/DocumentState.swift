import Foundation
import UniformTypeIdentifiers
import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Represents a table of contents heading entry
struct HeadingItem: Identifiable, Codable {
    let id: String
    let level: Int
    let text: String

    var indent: CGFloat {
        CGFloat((level - 1) * 16)
    }
}

/// Discriminator for the tab's underlying content source.
/// `.file` (default) preserves source-compat for all existing call sites that
/// read `tab.url` / `tab.content` — they continue to work unchanged.
/// `.insight` carries an in-memory Recursive Insight session (Task 4).
enum TabKind {
    case file
    case insight(InsightSession)
    /// X-Ray of the project (`scope` "") or of one of its folders (path relative to the
    /// project root); content lives in that scope's `ArchitectureStore`.
    case architecture(scope: String)
    /// A terminal opened in a folder; the session lives in `WorkspaceManager`.
    case terminal(UUID)
    /// An image file, shown by `ImageViewerView` (no text content).
    case image
    /// A read-only PDF; state belongs to the tab, not to the underlying text editor.
    case pdf(PDFReaderController)
    /// An archive (zip, tar, 7z…), shown by `ArchiveTabView`; its entries open as temporary copies.
    case archive
    /// A GitHub Actions run or an issue, shown by `GitHubRunView` / `GitHubIssueView`.
    case github(GitHubItem)
    /// A web page (a local development server or any site), shown by `BrowserTabView`.
    case browser(BrowserSession)
    /// A data file (`FileType.isData`): the editor page reads it itself and never writes it.
    case data
    /// The tab of a tool that keeps its state in the window (`ToolRegistry`); the view it shows is mapped in `ToolTabViews`.
    case tool(ToolID)
    /// Prototype Studio: a clickable prototype and its review conversation, shown by `PrototypeStudioView`.
    case prototype(PrototypeSession)
    /// UI Studio, a tool whose tab carries its own session: the project's real web interface with simulated dependencies,
    /// shown by `UIStudioView`.
    case uiStudio(StudioSession)
    /// The Copilot Cockpit, a tool whose tab carries its own session: plans and runs of this window, shown by `CockpitView`.
    case cockpit(CockpitSession)

    /// The tool this tab is the tab of (`ToolRegistry`); nil for a document or any other tab.
    var toolID: ToolID? {
        switch self {
        case .tool(let id): return id
        case .uiStudio: return .uiStudio
        case .cockpit: return .cockpit
        default: return nil
        }
    }

    /// What the registry knows of the tool this tab belongs to: its title, icon and shortcut.
    var toolDescriptor: ToolDescriptor? {
        toolID.flatMap { ToolRegistry.shared.descriptor(for: $0) }
    }
}

/// Represents an open tab with its associated file and state
struct OpenTab: Identifiable {
    let id = UUID()
    /// Where the tab's file is; changes when the file is moved in the file tree.
    var url: URL
    var content: String
    var originalContent: String // snapshot from disk — used to detect real changes
    var isModified: Bool = false
    var kind: TabKind = .file
    var headings: [HeadingItem] = []
    /// A text file shown with line-aligned Explain notes instead of its dedicated viewer.
    var notesView = false
    /// Bumped when a data tab's file changes on disk: its viewer reads it again (a log follows).
    var dataRevision = 0

    /// The display name for the tab (file name)
    var displayName: String {
        if case .terminal = kind { return "Terminal: " + url.deletingLastPathComponent().lastPathComponent }
        if let tool = kind.toolDescriptor { return tool.title }
        if case .github(let item) = kind { return item.title }
        // The page title lives on the main actor; the tab bar shows it with `BrowserTabTitle`.
        if case .browser = kind { return "Browser" }
        if case .prototype(let session) = kind { return "Prototype: " + session.slug }
        if case .architecture(let scope) = kind {
            if scope == XRayScope.pullRequest { return "PR X-Ray" }
            return scope.isEmpty ? "X-Ray" : "X-Ray: " + (scope as NSString).lastPathComponent
        }
        return url.lastPathComponent
    }

    /// True for tabs backed by a file on disk. Insight and Architecture tabs use a
    /// placeholder URL that must never be read, written or indexed.
    var isFileBacked: Bool {
        if case .file = kind { return true }
        return false
    }

    /// True for a tab that shows one file the person reads or edits (text, image, PDF, archive, data file); "Close Documents" closes
    /// these and keeps the project's tool tabs (Git, Workflow, X-Ray, QA, ...).
    var isDocument: Bool {
        switch kind {
        case .file, .image, .pdf, .archive, .data: return true
        default: return false
        }
    }

    /// The file type of this tab
    var fileType: FileType {
        FileType.from(url: url)
    }

    /// Check if this tab is for a markdown file
    var isMarkdown: Bool {
        fileType == .markdown
    }
}
