import SwiftUI

/// Popup showing semantic intelligence for a selected block:
/// extracted entities, claims, diagnostics, and available AI actions
struct BlockIntelligenceView: View {
    let block: SemanticBlock
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: iconForType(block.type))
                    .foregroundColor(.accentColor)
                Text(block.type.rawValue.capitalized)
                    .font(.headline)
                Spacer()
                Text("L\(block.lineStart)-\(block.lineEnd)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Content preview
            Text(block.plainText.prefix(200))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(4)

            // Heading path
            if !block.headingPath.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "location")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(block.headingPath.joined(separator: " > "))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Actions
            Text("Actions")
                .font(.subheadline.bold())

            HStack(spacing: 8) {
                ActionButton(title: "Extract", icon: "wand.and.stars", color: .blue) {
                    submitJob(.extractBlockSemantics)
                }
                ActionButton(title: "Rewrite", icon: "pencil.line", color: .green) {
                    submitJob(.rewriteForClarity)
                }
                ActionButton(title: "Translate", icon: "globe", color: .orange) {
                    submitJob(.translateBlock)
                }
            }

            if block.type == .section {
                HStack(spacing: 8) {
                    ActionButton(title: "Generate", icon: "doc.badge.plus", color: .purple) {
                        submitJob(.generateSectionDraft)
                    }
                    ActionButton(title: "Review", icon: "checkmark.shield", color: .mint) {
                        submitJob(.reviewCompiledSection)
                    }
                }
            }

            // Compilation status
            if let compiler = workspaceManager.incrementalCompiler {
                if compiler.compilationQueue.contains(block.id) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("In compilation queue...")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 8)
    }

    private func submitJob(_ type: AIJobType) {
        guard let compiler = workspaceManager.incrementalCompiler else { return }
        let docId = workspaceManager.openTabs[safe: workspaceManager.activeTabIndex]?.url.lastPathComponent ?? ""
        compiler.orchestrator.submitExtraction(
            block: block,
            documentId: docId,
            file: docId
        )
    }

    private func iconForType(_ type: BlockType) -> String {
        switch type {
        case .section: return "number"
        case .paragraph: return "text.alignleft"
        case .list, .listItem: return "list.bullet"
        case .table, .tableRow: return "tablecells"
        case .codeBlock: return "chevron.left.forwardslash.chevron.right"
        case .quote: return "text.quote"
        default: return "doc"
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Safe Array Access

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
