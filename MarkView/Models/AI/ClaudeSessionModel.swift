import Foundation

/// The model a running Claude Code session uses now, read from the session's own log (the lines
/// `AgentActivityLog.tail` returns). The agent's title and the remembered model follow it: the user
/// may switch with `/model` inside the session, which MarkView's settings never hear about
/// (BUG-048). Pure and Foundation-only: `tools/tests/claude-session-model-tests.sh` checks it.
enum ClaudeSessionModel {
    /// A model the log says the session used, and when.
    struct Reading: Equatable {
        /// What `--model` accepts: a family alias ("sonnet") when the name belongs to a known family,
        /// else the model id as logged.
        let model: String
        let date: Date
    }

    /// Families `--model` takes as aliases, which always mean the family's newest model.
    static let families = ["fable", "opus", "sonnet", "haiku"]

    /// "claude-sonnet-5-5" and "Sonnet 5.5" are both "sonnet"; nil when no family is named.
    static func family(of name: String) -> String? {
        let lower = name.lowercased()
        return families.first { lower.contains($0) }
    }

    /// The newest model in `lines` (oldest first) that applied at or after `since`: the reply of the
    /// session itself, or the confirmation of a `/model` command, which comes before the next reply.
    /// Replies of subagents (`isSidechain`) and placeholder replies (`<synthetic>`) are not the
    /// session's model.
    static func reading(lines: [Data], since: Date? = nil) -> Reading? {
        for data in lines.reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let date = timestamp(object) else { continue }
            if let since, date < since { continue }
            switch object["type"] as? String {
            case "assistant":
                guard object["isSidechain"] as? Bool != true,
                      let model = (object["message"] as? [String: Any])?["model"] as? String,
                      !model.isEmpty, !model.hasPrefix("<") else { continue }
                return Reading(model: family(of: model) ?? model, date: date)
            case "user":
                guard let switched = switchedModel(in: object) else { continue }
                return Reading(model: switched, date: date)
            default:
                continue
            }
        }
        return nil
    }

    /// The family a `/model` confirmation names ("Set model to `Sonnet 5.5` and saved as your default
    /// for new sessions"). Only a known family is trusted: the next reply names anything else by id.
    private static func switchedModel(in object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        } else {
            return nil
        }
        let marker = "<local-command-stdout>Set model to "
        guard let range = text.range(of: marker) else { return nil }
        return family(of: String(text[range.upperBound...].prefix(60)))
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    private static func timestamp(_ object: [String: Any]) -> Date? {
        guard let text = object["timestamp"] as? String else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    /// `title` with its model part ("Claude Code · fable") replaced by `model`; a title without one
    /// gets it appended. Tab titles stay unique because the part before " · " is kept.
    static func title(_ title: String, model: String) -> String {
        guard let range = title.range(of: " · ", options: .backwards) else { return title + " · " + model }
        return String(title[..<range.lowerBound]) + " · " + model
    }
}
