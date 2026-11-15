import Foundation
import NaturalLanguage

// End-to-End QA (feature end-to-end-qa, REQ-009): the language a scenario is written in, named for the assistant. "The language of the step
// title" alone is followed unreliably: the assistant's own settings and the page text pull it elsewhere, so narration and review findings came
// back in languages other than the scenario's. The name is worked out from the scenario's own texts and stated outright to the assistant.

enum QALanguage {
    /// Least confidence of the recogniser for a language to be named; below it the prompts keep the general wording.
    static let minimumConfidence = 0.6

    /// The English name of the language the scenario is written in ("English", "Russian"), or nil when no language stands out.
    static func name(of scenario: QAScenario) -> String? {
        var parts = [scenario.title, scenario.goal]
        for node in scenario.nodes { parts += [node.title, node.detail] }
        return name(ofText: parts.filter { !$0.isEmpty }.joined(separator: ". "))
    }

    static func name(ofText text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= minimumConfidence else { return nil }
        return Locale(identifier: "en_US").localizedString(forLanguageCode: best.key.rawValue)
    }
}
