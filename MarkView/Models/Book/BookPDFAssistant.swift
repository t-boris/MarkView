import Foundation

/// Shared by the app and opt-in live checks. Translation and condensation are separate passes:
/// translation covers tables; condensation treats their complete rendered content as immutable.
@MainActor
enum BookPDFAssistant {
    static func rewriteChapter(renderer: BookPDFRenderer, id: String, html: String,
                               language: String, reduction: Int, project: URL?, tool: CLITool? = nil,
                               usage: (CLICompletion.Result) -> Void = { _ in },
                               progress: (String, Double) -> Void = { _, _ in }) async throws {
        if language != "document" {
            let translated = try await rewrite(html, language: language, reduction: 0, project: project, tool: tool, usage: usage) { message, fraction in
                progress(message, reduction > 0 ? fraction * 0.5 : fraction)
            }
            try await renderer.setChapter(id, html: translated)
        }
        if reduction > 0 {
            let passages = try await renderer.prosePassages(id)
            for (index, passage) in passages.enumerated() {
                let shortened = try await rewrite(passage.html, language: "document", reduction: reduction,
                    project: project, tool: tool, usage: usage) { _, fraction in
                        let part = (Double(index) + fraction) / Double(max(1, passages.count))
                        progress("Shortening paragraph \(index + 1) of \(passages.count)…", language == "document" ? part : 0.5 + part * 0.5)
                    }
                try await renderer.setPassage(chapter: id, id: passage.id, html: shortened)
            }
        }
    }

    static func rewrite(_ html: String, language: String, reduction: Int, project: URL?, tool: CLITool? = nil,
                        usage: (CLICompletion.Result) -> Void = { _ in },
                        progress: (String, Double) -> Void = { _, _ in }) async throws -> String {
        var passes: [(String, Int)] = []
        if language != "document" { passes.append((language, 0)) }
        if reduction > 0 { passes.append(("document", reduction)) }
        var html = html
        for (phase, pass) in passes.enumerated() {
            let input = html
            let preparation = Task.detached { BookPDFTransform.prepare(input, preserveTables: pass.1 > 0) }
            let protected = await withTaskCancellationHandler { await preparation.value } onCancel: { preparation.cancel() }
            var answers: [String] = []
            for (index, chunk) in protected.chunks.enumerated() {
                try Task.checkCancellation()
                let fraction = (Double(phase) + Double(index) / Double(protected.chunks.count)) / Double(passes.count)
                progress("\(pass.1 > 0 ? "Shortening" : "Translating") passage \(index + 1) of \(protected.chunks.count)…", fraction)
                let words = chunk.wordCount
                if words == 0 { answers.append(chunk.text); continue }
                let target = max(1, Int((Double(words) * Double(100 - pass.1) / 100).rounded()))
                let minimum = max(1, Int(Double(words) * max(0.03, Double(100 - pass.1) / 100 - 0.10)))
                let maximum = max(target + 4, Int(Double(words) * min(1, Double(100 - pass.1) / 100 + 0.10)))
                var correction = ""
                var accepted: String?
                var currentInput = chunk.text
                var writingTarget = target
                let attempts = pass.1 > 0 ? 3 : 2
                for attempt in 0..<attempts {
                    let currentWords = BookPDFTransform.wordCount(currentInput)
                    let effectiveReduction = pass.1 > 0 ? max(1, 100 - writingTarget * 100 / max(1, currentWords)) : 0
                    var system = BookPDFTransform.system(language: pass.0, reduction: effectiveReduction)
                    let proseRule = pass.1 > 0 ? "Shorten body prose decisively." : "Translate body prose completely, without shortening or omissions."
                    system += "\nThe token legend describes the original structure. Text inside P, LI and BLOCKQUOTE is body prose. \(proseRule) H1-H6 text is a heading; keep its meaning. Protected islands contain no editable text.\n" + protected.structure(for: chunk)
                    if pass.1 > 0 { system += "\nThere are \(currentWords) editable words in this version, excluding structural tokens. Write about \(writingTarget) editable words. HARD MAXIMUM: \(min(maximum, writingTarget + 3)) editable words; minimum \(minimum). Opaque tokens do NOT count as words. Count the editable words before returning your answer. If above the maximum, shorten again before responding. Use concise declarative sentences; preserve topics and critical facts, not every sentence or secondary detail.\n" }
                    system += correction
                    var request = CLICompletion.Request(project: project, prompt: currentInput, systemPrompt: system,
                        jsonSchema: BookPDFTransform.schema, timeout: 240, toolOverride: tool)
                    request.effort = pass.1 > 0 ? "medium" : "low"; request.label = "pdf-book:\(phase):\(index):\(attempt)"
                    let result = try await CLICompletion.run(request); usage(result)
                    guard let answer = (result.structured as? [String: Any])?["text"] as? String else { throw BookPDFError.invalid("The assistant did not return the requested passage.") }
                    do {
                        try BookPDFTransform.validate(answer, for: chunk)
                        let actual = BookPDFTransform.wordCount(answer)
                        if pass.1 > 0, words > 25, !(minimum...maximum).contains(actual) {
                            correction = "\nThe previous attempt produced \(actual) editable words. Continue editing to meet \(minimum)-\(maximum) words, targeting \(target). Preserve ALL tokens in order."
                            currentInput = actual > maximum ? answer : chunk.text
                            if actual > maximum { writingTarget = max(minimum, Int(Double(writingTarget) * Double(target) / Double(actual))) }
                            if attempt == attempts - 1 { throw BookPDFError.invalid("The assistant returned \(actual) words for a target of about \(target) (source: \(words)). Try again or choose a smaller reduction. No PDF was saved.") }
                            continue
                        }
                        accepted = answer; break
                    } catch {
                        if attempt == attempts - 1 { throw error }
                        currentInput = chunk.text
                        correction = "\nThe previous attempt changed protected structure. Copy every opaque token exactly once in its original order; do not output HTML or Markdown fences."
                    }
                }
                guard let accepted else { throw BookPDFError.invalid("The requested passage could not be completed.") }
                answers.append(accepted)
            }
            let completed = answers
            let restoring = Task.detached { try protected.restore(completed) }
            html = try await withTaskCancellationHandler { try await restoring.value } onCancel: { restoring.cancel() }
        }
        return html
    }
}
