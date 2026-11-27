import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Shared by the app and opt-in live checks. Translation and condensation are separate passes:
/// translation covers tables; condensation treats their complete rendered content as immutable.
@MainActor
enum BookPDFAssistant {
    /// Translates and shortens one chapter in `renderer`. The passages of a pass, and the paragraphs that are shortened, do not depend
    /// on each other: they run `CLICompletion.sideBySide` at a time and come back in their order. A run that fails stops the chapter.
    static func rewriteChapter(renderer: BookPDFRenderer, id: String, html: String,
                               language: String, reduction: Int, project: URL?, tool: CLITool? = nil,
                               usage: @escaping (CLICompletion.Result) -> Void = { _ in },
                               progress: (String, Double) -> Void = { _, _ in }) async throws {
        if language != "document" {
            let translated = try await rewrite(html, language: language, reduction: 0, project: project, tool: tool, usage: usage) { message, fraction in
                progress(message, reduction > 0 ? fraction * 0.5 : fraction)
            }
            try await renderer.setChapter(id, html: translated)
        }
        if reduction > 0 {
            let passages = try await renderer.prosePassages(id)
            var finished = 0
            // A paragraph is short: its own passages run one at a time, so the side-by-side runs are the paragraphs.
            let shortened = try await SideBySide.map(passages.map(\.html), limit: CLICompletion.sideBySide, work: { @MainActor passage in
                try await rewrite(passage, language: "document", reduction: reduction, project: project, tool: tool, concurrency: 1,
                                  usage: usage)
            }, done: { _, _ in
                finished += 1
                let part = Double(finished) / Double(max(1, passages.count))
                progress("Shortening paragraph \(finished) of \(passages.count)…", language == "document" ? part : 0.5 + part * 0.5)
            })
            for (passage, html) in zip(passages, shortened) {
                try await renderer.setPassage(chapter: id, id: passage.id, html: html)
            }
        }
    }

    /// `html` translated into `language` and/or shortened by `reduction` percent, one pass after the other. The passages of a pass
    /// run `concurrency` at a time; a passage that fails its checks after its attempts stops the rewrite.
    static func rewrite(_ html: String, language: String, reduction: Int, project: URL?, tool: CLITool? = nil,
                        concurrency: Int = CLICompletion.sideBySide,
                        usage: @escaping (CLICompletion.Result) -> Void = { _ in },
                        progress: (String, Double) -> Void = { _, _ in }) async throws -> String {
        var passes: [(String, Int)] = []
        if language != "document" { passes.append((language, 0)) }
        if reduction > 0 { passes.append(("document", reduction)) }
        var html = html
        for (phase, pass) in passes.enumerated() {
            let input = html
            let preparation = Task.detached { BookPDFTransform.prepare(input, preserveTables: pass.1 > 0) }
            let protected = await withTaskCancellationHandler { await preparation.value } onCancel: { preparation.cancel() }
            let count = protected.chunks.count
            var finished = 0
            progress("\(pass.1 > 0 ? "Shortening" : "Translating") \(count) passage\(count == 1 ? "" : "s")…", Double(phase) / Double(passes.count))
            let answers = try await SideBySide.map(Array(protected.chunks.indices), limit: concurrency, work: { @MainActor index in
                try await passage(protected.chunks[index], index: index, of: protected, phase: phase, language: pass.0, reduction: pass.1,
                                  project: project, tool: tool, usage: usage)
            }, done: { _, _ in
                finished += 1
                let fraction = (Double(phase) + Double(finished) / Double(max(1, count))) / Double(passes.count)
                progress("\(pass.1 > 0 ? "Shortening" : "Translating") passage \(finished) of \(count)…", fraction)
            })
            let restoring = Task.detached { try protected.restore(answers) }
            html = try await withTaskCancellationHandler { try await restoring.value } onCancel: { restoring.cancel() }
        }
        return html
    }

    /// One passage of a pass: asked again with what was wrong when the answer breaks its structure or misses its length, up to two
    /// runs in all for a translation and three for shortening.
    private static func passage(_ chunk: BookPDFTransform.Chunk, index: Int, of protected: BookPDFTransform.Prepared, phase: Int,
                                language: String, reduction: Int, project: URL?, tool: CLITool?,
                                usage: @escaping (CLICompletion.Result) -> Void) async throws -> String {
        let words = chunk.wordCount
        if words == 0 { return chunk.text }
        let target = max(1, Int((Double(words) * Double(100 - reduction) / 100).rounded()))
        let minimum = max(1, Int(Double(words) * max(0.03, Double(100 - reduction) / 100 - 0.10)))
        let maximum = max(target + 4, Int(Double(words) * min(1, Double(100 - reduction) / 100 + 0.10)))
        var correction = ""
        var currentInput = chunk.text
        var writingTarget = target
        let attempts = reduction > 0 ? 3 : 2
        func request(attempt: Int) -> CLICompletion.Request {
            let currentWords = BookPDFTransform.wordCount(currentInput)
            let effectiveReduction = reduction > 0 ? max(1, 100 - writingTarget * 100 / max(1, currentWords)) : 0
            var system = BookPDFTransform.system(language: language, reduction: effectiveReduction)
            let proseRule = reduction > 0 ? "Shorten body prose decisively." : "Translate body prose completely, without shortening or omissions."
            system += "\nThe token legend describes the original structure. Text inside P, LI and BLOCKQUOTE is body prose. \(proseRule) H1-H6 text is a heading; keep its meaning. Protected islands contain no editable text.\n" + protected.structure(for: chunk)
            if reduction > 0 { system += "\nThere are \(currentWords) editable words in this version, excluding structural tokens. Write about \(writingTarget) editable words. HARD MAXIMUM: \(min(maximum, writingTarget + 3)) editable words; minimum \(minimum). Opaque tokens do NOT count as words. Count the editable words before returning your answer. If above the maximum, shorten again before responding. Use concise declarative sentences; preserve topics and critical facts, not every sentence or secondary detail.\n" }
            system += correction
            var request = CLICompletion.Request(project: project, prompt: currentInput, systemPrompt: system,
                jsonSchema: BookPDFTransform.schema, timeout: 240, toolOverride: tool)
            request.effort = reduction > 0 ? "medium" : "low"; request.label = "pdf-book:\(phase):\(index):\(attempt)"
            return request
        }
        // A passage that fails its checks is asked for again with what was wrong, up to `attempts` runs in all.
        let writing = AIOperation<Void, String>(
            name: "pdf-book",
            maxRepairAttempts: attempts - 1,
            buildRequest: { _ in request(attempt: 0) },
            parse: { _, result, _ in
                guard let answer = (result.structured as? [String: Any])?["text"] as? String else { throw NoPassage() }
                return answer
            },
            validate: { _, answer, _ in
                do {
                    try BookPDFTransform.validate(answer, for: chunk)
                } catch {
                    currentInput = chunk.text
                    correction = "\nThe previous attempt changed protected structure. Copy every opaque token exactly once in its original order; do not output HTML or Markdown fences."
                    throw error
                }
                let actual = BookPDFTransform.wordCount(answer)
                guard reduction > 0, words > 25, !(minimum...maximum).contains(actual) else { return }
                correction = "\nThe previous attempt produced \(actual) editable words. Continue editing to meet \(minimum)-\(maximum) words, targeting \(target). Preserve ALL tokens in order."
                currentInput = actual > maximum ? answer : chunk.text
                if actual > maximum { writingTarget = max(minimum, Int(Double(writingTarget) * Double(target) / Double(actual))) }
                throw BookPDFError.invalid("The assistant returned \(actual) words for a target of about \(target) (source: \(words)). Try again or choose a smaller reduction. No PDF was saved.")
            },
            repair: { context in request(attempt: context.attempt.number) },
            onResult: { result in usage(result) })
        do {
            return try await writing.execute(()).output
        } catch is NoPassage {
            throw BookPDFError.invalid("The assistant did not return the requested passage.")
        }
    }
}

/// The assistant's answer had no passage in it; asking again does not change that.
private struct NoPassage: Error, AIUnrepairable {}
