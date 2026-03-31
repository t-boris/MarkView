import Foundation
import SwiftUI

/// Represents a table of contents heading entry
struct HeadingItem: Identifiable, Codable {
    let id: String
    let level: Int
    let text: String

    var indent: CGFloat {
        CGFloat((level - 1) * 16)
    }
}

/// Represents an open tab with its associated file and state
struct OpenTab: Identifiable {
    let id = UUID()
    let url: URL
    var content: String
    var originalContent: String // snapshot from disk — used to detect real changes
    var isModified: Bool = false
    var headings: [HeadingItem] = []
    var activeHeadingId: String?
    var scrollPosition: CGFloat = 0

    // Semantic block extraction (DDE Stage 1)
    var blocks: [SemanticBlock] = []
    var activeBlockId: String?
    var blockCompilationState: [String: BlockCompilationState] = [:]

    /// The display name for the tab (file name)
    var displayName: String {
        url.lastPathComponent
    }

    /// Check if this tab is for a markdown file
    var isMarkdown: Bool {
        url.pathExtension.lowercased() == "md"
    }
}
