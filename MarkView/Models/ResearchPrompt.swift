import Foundation

/// Prompts of New Research (I-4): the fact/inference labels of DEC-008 and REQ-004, the web
/// search guardrails of DEC-011, and the parts of the retired Deep Research tool that still help
/// (research points, current status, known issues, alternatives; DEC-010).
enum ResearchPrompt {
    /// How many scope paths are listed in full; larger repositories get a per-folder summary.
    static let listedFiles = 1500

    /// `titled`: a new research, whose answer starts with `## Title` (the document's title and,
    /// unless the user chose a path, its file name). Follow-ups and comments have none.
    static func system(web: Bool, titled: Bool = false) -> String {
        """
        You are a research analyst working inside a software repository, which may hold code, \
        documentation or both. You answer open analytical and strategic questions with a grounded \
        report. Explore the repository with your file search and read tools; never assume what a \
        file says without reading it.

        Every finding starts with exactly one of these labels:
        - [Project fact]: something you read in a repository file. Cite its workspace-relative path \
        inline, with a line when useful, e.g. `src/app/main.swift:42`.
        - [External fact]: something from a web page or search result you actually opened. Cite its \
        URL inline.
        - [AI inference]: your own conclusion or general knowledge without a source you opened. \
        Knowledge from training is an inference, never an external fact.
        - [Open assumption]: a premise that is not verified and matters for the answer.

        \(web ? webRules : "Web search is not available for this research. Rely on the repository; label general knowledge as [AI inference].")

        When the question concerns technologies, APIs, dependencies or claims in the project, identify \
        them as research points and, for each, cover what matters: how the project uses it, its current \
        status, known issues or limits, alternatives, and a recommendation (keep, replace, update or \
        investigate).

        \(languageLine)
        Answer in Markdown with exactly these headings and nothing before the first one:
        \(titled ? titleHeading : "")## Summary
        (a direct answer in a few sentences)
        ## Findings
        (a bulleted list; every item starts with one label)
        ## Recommendations
        (concrete next steps)
        Do not write the question or a Sources section: the app adds them from what you read.
        Never modify files.
        """
    }

    private static let webRules = """
        Use web search when the repository alone cannot answer well. Search queries may contain only \
        generic concepts, public product or library names and the wording of the user's question. Never \
        put code, file contents, secrets, credentials, internal hostnames, internal project or module \
        names or other identifiers from the repository into a query. Every query you send is listed in \
        the report.
        """

    private static var languageLine: String {
        let language = ActionOutputLanguage.current
        return language == ActionOutputLanguage.documentLanguage
            ? "Write the report in the language of the question."
            : "Write the report in \(language); keep code, identifiers, paths, URLs and the labels exactly as given."
    }

    // MARK: - Per job

    static func research(question: String, targets: [String], attachments: [String], scope: [String], web: Bool) -> String {
        var prompt = "Research question:\n\n\(question)\n\n"
        if !targets.isEmpty {
            prompt += "Target documents (the primary focus; read them in full first, never modify them):\n"
                + targets.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !attachments.isEmpty {
            prompt += "Attachments provided by the user (read them):\n" + attachments.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        return prompt + scopeText(scope)
    }

    /// The first heading of a new research's answer.
    private static let titleHeading = """
        ## Title
        (one line, at most 10 words: a report title naming the subject and the outcome — never a copy or a \
        fragment of the question)

        """

    static func followUp(document: String, question: String, retrying partial: String?, scope: [String], web: Bool) -> String {
        var prompt = "The current research document (including the user's edits):\n\n<document>\n\(document)\n</document>\n\n"
        if let partial {
            prompt += """
                This section of it is incomplete; its work stopped early:

                <incomplete>
                \(partial)
                </incomplete>

                Answer its question again, completely, using the partial output as a starting point:

                \(question)


                """
        } else {
            prompt += "Follow-up question to answer (only this; do not repeat what the document already says):\n\n\(question)\n\n"
        }
        return prompt + scopeText(scope)
    }

    static func comment(document: String, section: String, passage: String, comment: String, scope: [String], web: Bool) -> String {
        """
        The research document:

        <document>
        \(document)
        </document>

        The user selected this passage:

        <passage>
        \(passage)
        </passage>

        in this section:

        <section>
        \(section)
        </section>

        and commented:

        <comment>
        \(comment)
        </comment>

        Reflect on the comment and revise the section accordingly: investigate again where needed, \
        correct or extend what the comment concerns, and keep everything else in the section as it is. \
        Keep the labels and citation rules for every finding. This time do not use the Summary / \
        Findings / Recommendations answer format: return only the complete revised section, starting \
        with its heading line exactly as it is, as plain Markdown without a code fence, and nothing else.

        \(scopeText(scope))
        """
    }

    /// The revised section from the answer: code fences and text before the heading removed; the
    /// original heading line is kept when the answer dropped it.
    static func revisedSection(_ answer: String, original: String) -> String {
        var lines = answer.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        let heading = original.components(separatedBy: "\n").first ?? ""
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading.trimmingCharacters(in: .whitespaces) }) {
            lines.removeFirst(start)
        } else if !lines.isEmpty, !heading.isEmpty {
            lines.insert(contentsOf: [heading, ""], at: 0)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The analysis scope as the agent should see it (DEC-016).
    private static func scopeText(_ scope: [String]) -> String {
        guard !scope.isEmpty else {
            return "Analysis scope: the repository has no eligible files. There are no project facts; say so in the Summary and answer from external sources and inference."
        }
        var text = "Analysis scope: \(scope.count) files (git-listed text files honouring .gitignore; binary, generated and vendor files and files over 1 MB are excluded). Only read and cite files in this scope."
        if scope.count <= listedFiles {
            return text + "\n\n" + scope.joined(separator: "\n")
        }
        var folders: [String: Int] = [:]
        for path in scope {
            let parts = path.split(separator: "/")
            let folder = parts.count > 2 ? parts.prefix(2).joined(separator: "/") : (parts.count == 2 ? String(parts[0]) : ".")
            folders[folder, default: 0] += 1
        }
        text += " The list is too long to show; files per folder (explore with search):\n\n"
        text += folders.sorted { $0.key < $1.key }.map { "\($0.key)/ — \($0.value) files" }.joined(separator: "\n")
        return text
    }
}
