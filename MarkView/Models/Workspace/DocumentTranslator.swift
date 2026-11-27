import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Translates a whole document into another language and opens the result in a new tab (`AR-14` step 1). It owns what a translation
/// is made of: the engine chosen once for the document, the structure-aware split (`MarkdownDocumentChunker`), the check that each
/// translated section kept its skeleton, the progress banner written into the tab, and the progress line of the file tree. The
/// window's tabs are reached through `TabsController`, the open project through `ProjectProviding`, and every job runs as a task of
/// the window's `TaskBag`, so closing the window or the folder stops it.
@MainActor
final class DocumentTranslator: ObservableObject {
    /// Which backend performs the translation. Chosen once per document so the whole file is translated by a single engine (mixing
    /// engines mid-document produces visibly inconsistent terminology).
    private struct Engine {
        let tool: CLITool
        let model: String?

        var label: String { AIAssistantPreferences.summary(tool: tool, model: model ?? "") }
    }

    /// One translation in progress: the document split into sections, and the tab that fills in as they come back.
    private struct Job {
        let tabID: UUID
        let targetLang: String
        let engine: Engine
        let prefix: String
        let chunks: [MarkdownDocumentChunker.Chunk]
        let translatableCount: Int

        /// Live progress banner, written into the tab itself. The file tree's line only renders in the sidebar, which may be
        /// collapsed: this one is visible in the document the person is actually watching.
        func banner(_ completed: Int) -> String {
            let pct = translatableCount > 0 ? completed * 100 / translatableCount : 100
            let filled = translatableCount > 0 ? completed * 20 / translatableCount : 20
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 20 - filled)
            return "> 🌐 **Translating to \(targetLang)** — `\(bar)` \(pct)% "
                + "(\(completed)/\(translatableCount) sections, \(engine.label))\n\n"
        }
    }

    /// The line the file tree shows while a translation runs ("Translating 3/8 (Claude · opus)..."); nil when none does.
    var progress: String? { lines.values.sorted().first }
    @Published private var lines: [UUID: String] = [:]

    private let tabs: TabsController
    private let project: any ProjectProviding
    private let tasks: TaskBag
    private let runner: AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner
    private let toolAvailable: (CLITool) -> Bool

    /// `runner` asks the assistant; the app's own is the default, a check supplies another.
    init(tabs: TabsController, project: any ProjectProviding, tasks: TaskBag,
         toolAvailable: @escaping (CLITool) -> Bool = { CLIToolLocator.resolve($0) != nil },
         runner: @escaping AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner = AIAssistantRunner.run) {
        self.tabs = tabs
        self.project = project
        self.tasks = tasks
        self.runner = runner
        self.toolAvailable = toolAvailable
    }

    /// Translate the whole document to `targetLang` and open the result in a new tab. The source file is never modified; the new
    /// tab is left unsaved so the person decides where (and whether) it lands on disk.
    ///
    /// Returns a message to show the person when the translation could not start or was stopped, or nil on success. The caller
    /// surfaces it in the editor popup: the progress line alone is easy to miss when the file tree is collapsed.
    @discardableResult
    func translate(markdown: String, targetLang: String) async -> String? {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Nothing to translate — the document is empty."
        }

        // The assistant chosen in DDE Settings / the toolbar; fixed for the whole document. A missing CLI is reported up front
        // rather than as a document full of untranslated sections.
        let aiProject = project.aiProject
        let tool = AIAssistantPreferences.backend(project: aiProject)
        let engine = Engine(tool: tool, model: AIAssistantPreferences.model(for: tool, project: aiProject))
        guard toolAvailable(tool) else {
            AppLog.workspace.error("Translation aborted: \(tool.binaryName) not found")
            return "\(tool.displayName) was not found. Set its path in DDE Settings → AI CLI Tools."
        }

        let sourceTab = tabs.activeTab
        let sourceName = sourceTab?.url.deletingPathExtension().lastPathComponent ?? "document"
        let newURL = sourceTab?.url.deletingLastPathComponent()
            .appendingPathComponent("\(sourceName)_\(targetLang.lowercased()).md") ?? URL(fileURLWithPath: "/tmp/translated.md")

        // Split at structural boundaries — never inside a table, list or code block.
        let (prefix, chunks) = MarkdownDocumentChunker.splitForTranslation(markdown, maxChars: 4000)
        let translatableCount = chunks.filter { $0.isTranslatable }.count

        // The new tab opens at once with the banner at 0%.
        let translatedTab = OpenTab(url: newURL, content: "", originalContent: "")
        let job = Job(tabID: translatedTab.id, targetLang: targetLang, engine: engine, prefix: prefix, chunks: chunks,
                      translatableCount: translatableCount)
        var opened = translatedTab
        opened.content = job.banner(0)
        tabs.appendTab(opened)

        let key = "translate-\(job.tabID.uuidString)"
        let running = Task { await self.run(job) }
        tasks.store(running, for: key)
        let outcome = await running.value
        tasks.cancel(key: key)
        return outcome
    }

    /// Translates the sections into the job's tab, `CLICompletion.sideBySide` at a time: no section's prompt depends on another's
    /// answer. After each section the tab shows the whole document, the sections finished so far translated and the others still in
    /// the original language. Returns the message for a translation that was stopped.
    private func run(_ job: Job) async -> String? {
        // The translatable sections in document order; a section's number is its place among them, as the banner counts them.
        // Front matter and fenced code go through verbatim: never sent to the model, so code can't come back "helpfully" rewritten.
        let translatable = job.chunks.indices.filter { job.chunks[$0].isTranslatable }
        var translated: [Int: String] = [:]
        var failedChunks: [Int] = []
        var lastError: String?
        var finished = 0
        func document() -> String {
            job.prefix + job.chunks.indices.map { (translated[$0] ?? job.chunks[$0].text) + job.chunks[$0].separator }.joined()
        }
        func showProgress() {
            lines[job.tabID] = "Translating \(finished)/\(job.translatableCount) (\(job.engine.label))..."
        }
        showProgress()
        write(job.banner(0) + document(), to: job.tabID)
        // A run never throws: a failed or stopped section keeps its source text, so the others go on.
        _ = try? await SideBySide.map(translatable, limit: CLICompletion.sideBySide, work: { [weak self] index in
            await self?.translateSection(job.chunks[index].text, job: job) ?? Outcome(text: nil, error: nil)
        }, done: { position, outcome in
            finished += 1
            let index = translatable[position]
            if !Task.isCancelled, let text = outcome.text {
                translated[index] = text
            } else {
                // Keep the source text rather than emit corrupted markdown.
                failedChunks.append(position + 1)
                if let error = outcome.error { lastError = error }
            }
            showProgress()
            write(job.banner(finished) + document(), to: job.tabID)
        })
        // A stopped translation keeps the sections it has not reached in the original language.
        let stopped = Task.isCancelled
        if stopped { failedChunks = translatable.indices.filter { translated[translatable[$0]] == nil }.map { $0 + 1 } }

        var result = document()
        if !failedChunks.isEmpty {
            // Silent fallbacks previously made a partly-translated document look finished. Say so, in the document itself.
            let list = failedChunks.sorted().map(String.init).joined(separator: ", ")
            let reason = stopped ? "(the translation was stopped)"
                : lastError.map { "(\($0))" } ?? "(the model's output did not preserve their structure)"
            result = "> ⚠️ Translation incomplete — section(s) \(list) kept in the original language "
                + "\(reason).\n\n" + result
            AppLog.workspace.error("Translation: \(failedChunks.count) chunk(s) left untranslated")
        }
        write(result, to: job.tabID)
        lines[job.tabID] = nil
        AppLog.workspace.notice("Translation complete: \(job.chunks.count) chunks, engine \(job.engine.label)")
        return stopped ? "The translation was stopped before it finished." : nil
    }

    /// What became of one section: its translation, or nil to keep the source, with the error of the last call that failed.
    private struct Outcome: Sendable {
        var text: String?
        var error: String?
    }

    /// One section: a translation whose Markdown skeleton must match the source's, asked again once, strictly, when it does not.
    private func translateSection(_ text: String, job: Job) async -> Outcome {
        var lastError: String?
        let expected = MarkdownDocumentChunker.skeleton(of: text)
        var translated = await translateChunk(text, job: job, strict: false, error: &lastError)
        // Structural check, then one stricter retry. This is what keeps tables intact when a small local model reflows them.
        if let candidate = translated, MarkdownDocumentChunker.skeleton(of: candidate) != expected, !Task.isCancelled {
            AppLog.workspace.notice("Translation section: structure mismatch, retrying strictly")
            translated = await translateChunk(text, job: job, strict: true, error: &lastError)
        }
        guard let candidate = translated, MarkdownDocumentChunker.skeleton(of: candidate) == expected else {
            return Outcome(text: nil, error: lastError)
        }
        return Outcome(text: candidate, error: lastError)
    }

    /// Re-resolve the tab by id on every write: the awaits take real time and the person may open or close tabs meanwhile, which would
    /// make a captured index point at somebody else's document.
    private func write(_ content: String, to tabID: UUID) {
        guard let index = tabs.openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.updateTab(at: index) { tab in
            tab.content = content
            tab.isModified = true
        }
    }

    /// Translate a single chunk. Returns nil when the call fails; the caller decides whether to retry or fall back to the source text.
    private func translateChunk(_ text: String, job: Job, strict: Bool, error lastError: inout String?) async -> String? {
        var systemPrompt = """
            You are a professional translator. Translate the following markdown text to \(job.targetLang).
            Rules:
            - Translate ONLY the text content. Keep ALL markdown formatting intact (headings, lists, code blocks, links, tables).
            - Do NOT translate code inside code blocks (```...```). Keep code exactly as-is.
            - Do NOT translate URLs, file paths, or technical identifiers.
            - Keep proper nouns, product names, and acronyms as-is.
            - Preserve the exact markdown structure — same number of headings, lists, paragraphs.
            - For tables: keep the same number of rows and columns, and keep the |---| separator row unchanged.
            - Do NOT wrap your answer in a code fence.
            - Return ONLY the translated markdown, no explanations.
            """
        if strict {
            systemPrompt += """

                IMPORTANT: your previous attempt changed the structure. Copy the layout line by line —
                same line count, same table rows, same list markers, same heading levels — and replace
                only the natural-language words.
                """
        }

        var request = CLICompletion.Request(project: project.aiProject, prompt: text, systemPrompt: systemPrompt)
        request.tool = job.engine.tool
        request.model = job.engine.model
        request.timeout = 240
        do {
            let result = try await AIOperation<CLICompletion.Request, CLICompletion.Result>
                .run(name: "translate-chunk", runner: runner).execute(request).result
            result.record(in: project.database)
            return MarkdownDocumentChunker.normalizeTranslation(result.text)
        } catch is CancellationError {
            return nil
        } catch {
            lastError = error.localizedDescription
            AppLog.workspace.error("Translation chunk error: \(error.localizedDescription)")
            return nil
        }
    }
}
