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

    static let webRules = """
        Use web search when the repository alone cannot answer well. Search queries may contain only \
        generic concepts, public product or library names and the wording of the user's question. Never \
        put code, file contents, secrets, credentials, internal hostnames, internal project or module \
        names or other identifiers from the repository into a query. Every query you send is listed in \
        the report.
        """

    static var languageLine: String {
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

    /// Evidence-backed deep prompt for Continue / deepen on an existing research document (REQ-008, I-6).
    static func deepFollowUp(document: String, question: String, scope: [String], web: Bool) -> String {
        """
        The current research document (including the user's edits):

        <document>
        \(document)
        </document>

        Follow-up question to investigate deeply (answer only this; do not repeat settled material from the document):

        \(question)

        Deep research protocol:
        1. Identify the distinct angles needed to answer this follow-up thoroughly (for example: current implementation/evidence, interactions or edge cases, trade-offs/alternatives, and gaps or risks) and investigate each with your permitted tools.
        2. Read primary files in full or around the exact lines you cite; never guess symbol names, file paths, or line numbers.
        3. ALWAYS cite the FULL workspace-relative path from the Analysis scope with exact line numbers (e.g. `MarkView/Models/AI/CLICompletion.swift:42` — NEVER a bare filename like `CLICompletion.swift:42`). Keep each `[Project fact]` atomic and grounded in the current working-tree file lines you cite (do not cite `git diff`/`HEAD` history or repo-wide absence as `[Project fact]` — use `[AI inference]` or `[Open assumption]` for those).\(web ? " Cite exact opened URLs for every `[External fact]`." : " Web search is disabled/unavailable — do not write `[External fact]`.")
        4. Explicitly distinguish `[Project fact]`, `[External fact]`, `[AI inference]`, and `[Open assumption]`. Add at least one `[Open assumption]` when any relevant premise, runtime behavior, or external source remains unverified or unavailable.
        5. Tie every recommendation directly to verified findings.

        \(scopeText(scope))
        """
    }

    /// Evidence-backed deep retry prompt for an incomplete section (REQ-008, I-6): preserves usable
    /// evidence from the partial output and explicitly targets the recorded failure/gaps.
    static func deepRetry(document: String, question: String, partial: String, context: ResearchDocument.IncompleteContext,
                          scope: [String], web: Bool) -> String {
        let reasonsText = context.reasons.isEmpty
            ? "The prior attempt stopped early."
            : context.reasons.map { "- \($0)" }.joined(separator: "\n")
        let preservedText = context.preservedFindings.isEmpty
            ? "(none recorded)"
            : context.preservedFindings.prefix(12).map { "- \($0)" }.joined(separator: "\n")
        let missingText = context.missingParts.isEmpty
            ? "Incomplete coverage or unverified claims in the partial section."
            : context.missingParts.joined(separator: ", ")
        return """
            The current research document (including the user's edits):

            <document>
            \(document)
            </document>

            This section is incomplete and is being retried with an evidence-backed deep pass:

            <incomplete>
            \(partial)
            </incomplete>

            Why the earlier run was incomplete:
            \(reasonsText)

            Usable findings already collected (preserve what holds after re-checking, do not discard valid evidence):
            \(preservedText)

            Missing or unfinished parts to close:
            \(missingText)

            Question to answer completely:

            \(question)

            Deep retry protocol:
            1. Close every gap left by the incomplete attempt using only tools permitted and available in this run.
            2. Re-verify cited repository paths, exact line numbers, and symbols directly in files before asserting `[Project fact]`. ALWAYS cite the FULL workspace-relative path from the Analysis scope (e.g. `MarkView/Models/AI/Providers/CodexProvider.swift:251`, NEVER a bare filename like `CodexProvider.swift:251`). Keep each `[Project fact]` atomic and grounded in the current working-tree file lines you cite (label git history or repo-wide absence claims as `[AI inference]` or `[Open assumption]`).
            3. \(web ? "Use web search only for generic external facts and cite exact opened URLs for `[External fact]`." : "Web search is not available for this run; do not emit `[External fact]`, and record any web-dependent gap explicitly as `[Open assumption]`.")
            4. Keep `[Project fact]`, `[External fact]`, `[AI inference]`, and `[Open assumption]` clearly separated, and explicitly list any source/verification gaps that remain unavailable.

            \(scopeText(scope))
            """
    }

    /// Evidence-backed deep prompt for Revise With Comment on an existing research document (REQ-008, I-6).
    static func deepComment(document: String, section: String, passage: String, comment: String, scope: [String], web: Bool) -> String {
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

        Evidence-backed revision protocol:
        1. Independently investigate what the comment raises using your permitted tools (read the actual repository files\(web ? " and search the web if external facts are needed" : "; web search is disabled/unavailable for this run")). Do not take either the existing passage or the comment on faith — verify against primary sources.
        2. Revise ONLY what the comment concerns, keeping all accurate untouched parts of the section intact.
        3. For every new or modified `[Project fact]`, ALWAYS cite the FULL workspace-relative path and exact line range from the Analysis scope (e.g. `MarkView/Models/AI/Providers/CodexProvider.swift:251-252`, NEVER a bare filename) and keep each bullet atomic to the current working-tree lines cited (label git history or repo-wide absence claims as `[AI inference]` or `[Open assumption]`).\(web ? " Cite an opened URL for `[External fact]`." : " Do not add new `[External fact]` claims without web access.")
        4. Keep `[Project fact]`, `[External fact]`, `[AI inference]`, and `[Open assumption]` clearly separated. If the comment asks about something unavailable or unverified, explicitly add an `[Open assumption]` noting the gap.
        5. Do NOT use the Summary / Findings / Recommendations template unless this section already uses it: return ONLY the complete revised section starting with its exact heading line, as plain Markdown without a code fence, and nothing else.

        \(scopeText(scope))
        """
    }

    // MARK: - Claim-Level Verification Prompts & Schemas (REQ-008)

    static let claimVerificationSystem = """
        You are a strict research fact-checker. You receive draft findings alongside VERBATIM excerpts read directly \
        from cited repository files (and web-fetch metadata). You have no tools — judge ONLY from the provided excerpts. \
        Mark a claim "supported" when the provided excerpts directly substantiate its core factual assertion (not merely \
        because the file exists). Mark it "unsupported" with a concrete one-sentence reason if an excerpt contradicts the \
        claim, lacks the claimed symbol/behavior in the cited range, or fails to substantiate the main assertion. If the \
        core factual assertion IS clearly substantiated in the provided excerpts and only a minor secondary clause was \
        truncated or unshown, mark it "supported" and note the unchecked secondary point in `gaps`. Never invent facts \
        not in the excerpts.
        """

    static var documentVerificationSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["verdicts", "gaps", "refined_summary", "refined_recommendations"],
            "properties": [
                "verdicts": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "status", "reason"],
                        "properties": [
                            "id": ["type": "string"],
                            "status": ["type": "string", "enum": ["supported", "unsupported"]],
                            "reason": ["type": "string"],
                        ],
                    ],
                ],
                "gaps": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Zero to three concrete [Open assumption] gap notes for unverified premises or unavailable sources.",
                ],
                "refined_summary": [
                    "type": "string",
                    "description": "Tight, accurate summary consistent with only the verified findings (empty string to keep draft summary as-is).",
                ],
                "refined_recommendations": [
                    "type": "string",
                    "description": "Concrete recommendations grounded in verified findings (empty string to keep draft recommendations as-is).",
                ],
            ],
        ]
    }

    static func documentVerificationPrompt(
        question: String,
        draft: ResearchDocument.Answer,
        checks: [ResearchClaimVerifier.ClaimCheck],
        limitationNote: String?
    ) -> String {
        let claimsBlock = checks.filter { $0.deterministicFailure == nil }.map { check in
            """
            CLAIM \(check.id) [\(check.label.rawValue)]: \(check.claimText)
            SOURCES: \(check.sources.joined(separator: ", "))
            VERBATIM EXCERPTS:
            \(check.excerpts.isEmpty ? "(no excerpt available)" : check.excerpts)
            """
        }.joined(separator: "\n\n---\n\n")
        return """
            Question:
            \(question)

            Draft Summary:
            \(draft.summary)

            Draft Recommendations:
            \(draft.recommendations)
            \(limitationNote.map { "\nSource/Tool Limitation Note: \($0)\n" } ?? "")
            Check every claim below strictly against its VERBATIM EXCERPTS. Return one verdict per CLAIM id.
            If any claim is marked "unsupported", also refine `refined_summary` and `refined_recommendations` so they do not rely on the unsupported claim (otherwise return "" for unchanged fields). Add up to 3 concise gap strings in `gaps` if important premises or sources remain unverified.

            \(claimsBlock)
            """
    }

    static var commentVerificationSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["verdicts", "gaps"],
            "properties": [
                "verdicts": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "status", "reason"],
                        "properties": [
                            "id": ["type": "string"],
                            "status": ["type": "string", "enum": ["supported", "unsupported"]],
                            "reason": ["type": "string"],
                        ],
                    ],
                ],
                "gaps": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Zero to two concise unverified-gap notes if the comment touches unavailable sources.",
                ],
            ],
        ]
    }

    static func commentVerificationPrompt(
        comment: String,
        originalSection: String,
        revisedSection: String,
        checks: [ResearchClaimVerifier.ClaimCheck],
        limitationNote: String?
    ) -> String {
        let claimsBlock = checks.filter { $0.deterministicFailure == nil }.map { check in
            """
            CLAIM \(check.id) [\(check.label.rawValue)]: \(check.claimText)
            SOURCES: \(check.sources.joined(separator: ", "))
            VERBATIM EXCERPTS:
            \(check.excerpts.isEmpty ? "(no excerpt available)" : check.excerpts)
            """
        }.joined(separator: "\n\n---\n\n")
        return """
            User Comment:
            \(comment)

            Original Section:
            \(String(originalSection.prefix(3000)))

            Revised Section:
            \(String(revisedSection.prefix(4000)))
            \(limitationNote.map { "\nSource/Tool Limitation Note: \($0)\n" } ?? "")
            Check every CLAIM below strictly against its VERBATIM EXCERPTS. Return one verdict per CLAIM id.
            Add a short gap string in `gaps` only if the comment asks about something that remained unverified or unavailable.

            \(claimsBlock)
            """
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
    static func scopeText(_ scope: [String]) -> String {
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
