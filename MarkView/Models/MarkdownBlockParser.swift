import Foundation

/// Swift-side markdown block parser — mirrors JS extractBlocks() logic.
/// Used for background analysis of all files in workspace (not just the currently viewed one).
struct MarkdownBlockParser {

    /// Parse markdown content into semantic blocks
    static func extractBlocks(from markdown: String, documentId: String) -> [SemanticBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [SemanticBlock] = []
        var headingStack: [String] = []
        var currentContent = ""
        var currentType: BlockType = .paragraph
        var currentLineStart = 1
        var position = 0
        var inCodeBlock = false
        var codeLanguage: String?

        func flush() {
            let trimmed = currentContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let pathKey = headingStack.joined(separator: "/") + ":\(position)"
            let id = fnv1a(pathKey)
            let plainText = trimmed
                .replacingOccurrences(of: #"[#*_`~\[\]()>!|]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            blocks.append(SemanticBlock(
                id: id,
                documentId: documentId,
                type: currentType,
                level: currentType == .section ? headingStack.count : nil,
                content: trimmed,
                plainText: plainText,
                contentHash: fnv1a(trimmed),
                headingPath: headingStack,
                parentBlockId: nil,
                lineStart: currentLineStart,
                lineEnd: currentLineStart + trimmed.components(separatedBy: "\n").count - 1,
                position: position,
                language: codeLanguage,
                anchor: nil
            ))
            position += 1
            currentContent = ""
            codeLanguage = nil
        }

        for (i, line) in lines.enumerated() {
            let lineNum = i + 1

            // Code block fences
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !inCodeBlock {
                    flush()
                    inCodeBlock = true
                    codeLanguage = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if codeLanguage?.isEmpty == true { codeLanguage = nil }
                    currentType = .codeBlock
                    currentLineStart = lineNum
                    currentContent = line + "\n"
                    continue
                } else {
                    currentContent += line
                    inCodeBlock = false
                    flush()
                    currentType = .paragraph
                    continue
                }
            }

            if inCodeBlock {
                currentContent += line + "\n"
                continue
            }

            // Headings
            if let match = line.range(of: #"^(#{1,6})\s+(.+)"#, options: .regularExpression) {
                flush()
                let hashes = line.prefix(while: { $0 == "#" })
                let level = hashes.count
                let text = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)

                while headingStack.count >= level { headingStack.removeLast() }
                headingStack.append(text)

                currentType = .section
                currentLineStart = lineNum
                currentContent = line
                flush()
                currentType = .paragraph
                continue
            }

            // Empty line — flush
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !currentContent.isEmpty {
                    currentContent += "\n"
                }
                flush()
                continue
            }

            // Table
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") && line.trimmingCharacters(in: .whitespaces).hasSuffix("|") {
                if currentType != .table {
                    flush()
                    currentType = .table
                    currentLineStart = lineNum
                }
                currentContent += line + "\n"
                continue
            }

            // Quote
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                if currentType != .quote {
                    flush()
                    currentType = .quote
                    currentLineStart = lineNum
                }
                currentContent += line + "\n"
                continue
            }

            // List
            if line.range(of: #"^\s*[-*+]\s"#, options: .regularExpression) != nil ||
               line.range(of: #"^\s*\d+\.\s"#, options: .regularExpression) != nil {
                if currentType != .list {
                    flush()
                    currentType = .list
                    currentLineStart = lineNum
                }
                currentContent += line + "\n"
                continue
            }

            // Paragraph
            if currentContent.isEmpty {
                currentLineStart = lineNum
            }
            currentContent += line + "\n"
        }

        flush()
        return blocks
    }

    /// FNV-1a hash matching the JS implementation
    private static func fnv1a(_ str: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in str.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return String(hash, radix: 16)
    }
}

// Add the `init` that SemanticBlock needs for Swift-side creation
extension SemanticBlock {
    init(id: String, documentId: String, type: BlockType, level: Int?, content: String,
         plainText: String, contentHash: String, headingPath: [String], parentBlockId: String?,
         lineStart: Int, lineEnd: Int, position: Int, language: String?, anchor: String?) {
        self.id = id
        self.documentId = documentId
        self.type = type
        self.level = level
        self.content = content
        self.plainText = plainText
        self.contentHash = contentHash
        self.headingPath = headingPath
        self.parentBlockId = parentBlockId
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.position = position
        self.language = language
        self.anchor = anchor
    }
}
