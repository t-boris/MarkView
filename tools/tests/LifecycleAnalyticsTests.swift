import Foundation

// Test main for LifecycleAnalytics.swift, run by tools/tests/lifecycle-tests.sh.

var failures = 0
var checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL line \(line): \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

let base = Date(timeIntervalSince1970: 1_790_000_000)
let minute: TimeInterval = 60, hour: TimeInterval = 3600, day: TimeInterval = 86_400

func event(_ stage: LifecycleStage, _ offset: TimeInterval, feature: String = "f", model: String? = nil) -> LifecycleEvent {
    LifecycleEvent(id: UUID(), project: "/p", feature: feature, stage: stage, timestamp: base.addingTimeInterval(offset),
                   actor: "tester", source: stage.isAutomatic ? .automatic : .manual, model: model, note: nil)
}

// Stages and steps
expect(LifecycleStage.allCases.count, 9, "nine canonical stages")
expect(LifecycleStage.manual, [.implementationStarted, .implementationFinished, .reviewDone, .ciPassed, .mergedToMain, .verified],
       "six manual stages")
expect(LifecycleStep.all.count, 8, "eight adjacent steps")
expect(LifecycleStep.all.first, LifecycleStep(start: .ideaCreated, end: .questionsResolved), "first step")
expect(LifecycleStep.all.filter(\.isAIStep), [LifecycleStep(start: .implementationStarted, end: .implementationFinished)], "one AI step")

// Simple pair
let simple = [event(.ideaCreated, 0), event(.questionsResolved, 2 * hour)]
expect(LifecycleAnalytics.duration(from: .ideaCreated, to: .questionsResolved, in: simple), .valid(2 * hour), "adjacent pair")

// Missing start or end: no duration
expect(LifecycleAnalytics.duration(from: .specReady, to: .implementationStarted, in: simple), .missing, "missing both")
expect(LifecycleAnalytics.duration(from: .questionsResolved, to: .specReady, in: simple), .missing, "missing end")

// Skipped stages are not bridged: idea → spec ready without questions resolved
let skipped = [event(.ideaCreated, 0), event(.specReady, hour)]
let skippedSteps = LifecycleAnalytics.steps(skipped)
expect(skippedSteps[0].duration, .missing, "idea → questions resolved missing")
expect(skippedSteps[1].duration, .missing, "questions resolved → spec ready missing (no bridge)")

// Repeats: earliest start, latest end
let repeated = [event(.implementationStarted, 0), event(.implementationStarted, 5 * hour),
                event(.implementationFinished, 3 * hour), event(.implementationFinished, 9 * hour)]
expect(LifecycleAnalytics.duration(from: .implementationStarted, to: .implementationFinished, in: repeated), .valid(9 * hour),
       "earliest start to latest end")

// End before start: inconsistent
let backwards = [event(.reviewDone, 4 * hour), event(.ciPassed, hour)]
expect(LifecycleAnalytics.duration(from: .reviewDone, to: .ciPassed, in: backwards), .inconsistent, "negative is inconsistent")
expect(LifecycleAnalytics.duration(from: .reviewDone, to: .ciPassed, in: backwards).seconds, nil, "inconsistent has no seconds")

// Same instant: zero, valid
let same = [event(.ciPassed, hour), event(.mergedToMain, hour)]
expect(LifecycleAnalytics.duration(from: .ciPassed, to: .mergedToMain, in: same), .valid(0), "zero duration is valid")

// Total idea → verified
let full = [event(.ideaCreated, 0), event(.ideaCreated, day), event(.verified, 2 * day), event(.verified, 3 * day)]
expect(LifecycleAnalytics.total(full), .valid(3 * day), "total earliest idea to latest verified")
expect(LifecycleAnalytics.total([event(.verified, day)]), .missing, "no total without idea created")

// Model of the step: the earliest start event's
let models = [event(.implementationStarted, hour, model: "B"), event(.implementationStarted, 0, model: "A")]
expect(LifecycleAnalytics.model(of: LifecycleStep.all[3], in: models), "A", "model from the start event used")

// Statistic
expect(LifecycleAnalytics.statistic([]), nil, "no values")
expect(LifecycleAnalytics.statistic([3, 1, 2]), .init(median: 2, mean: 2, count: 3), "odd median")
expect(LifecycleAnalytics.statistic([1, 2, 3, 10]), .init(median: 2.5, mean: 4, count: 4), "even median")

// Summary: valid durations only, per model on the AI step
let features: [String: [LifecycleEvent]] = [
    "a": [event(.implementationStarted, 0, feature: "a", model: "Opus"), event(.implementationFinished, hour, feature: "a")],
    "b": [event(.implementationStarted, 0, feature: "b", model: "opus-x"), event(.implementationFinished, 3 * hour, feature: "b")],
    "c": [event(.implementationStarted, 0, feature: "c", model: "Opus"), event(.implementationFinished, 5 * hour, feature: "c")],
    // inconsistent: left out
    "d": [event(.implementationStarted, 2 * hour, feature: "d", model: "Opus"), event(.implementationFinished, hour, feature: "d")],
    // no model recorded
    "e": [event(.implementationStarted, 0, feature: "e"), event(.implementationFinished, 2 * hour, feature: "e")],
    // total only
    "f": [event(.ideaCreated, 0, feature: "f"), event(.verified, day, feature: "f")],
]
let summary = LifecycleAnalytics.summary(features)
expect(summary.rows.count, 8, "one row per step")
let ai = summary.rows[3]
expect(ai.step.isAIStep, true, "fourth row is the AI step")
expect(ai.statistic, .init(median: 2.5 * hour, mean: 11 * hour / 4, count: 4), "AI step over valid durations (1h, 3h, 5h, 2h)")
expect(ai.byModel.map(\.model), ["Opus", "opus-x", LifecycleAnalytics.unknownModel], "models sorted by name")
expect(ai.byModel.first { $0.model == "Opus" }?.statistic, .init(median: 3 * hour, mean: 3 * hour, count: 2), "per model")
expect(summary.rows[0].statistic, nil, "step without data")
expect(summary.rows[0].byModel.isEmpty, true, "no model breakdown on other steps")
expect(summary.total, .init(median: day, mean: day, count: 1), "total statistic")

// Format: days/hours/minutes, rounded to the minute, leading zero units left out
expect(LifecycleAnalytics.format(0), "0m", "zero")
expect(LifecycleAnalytics.format(29), "0m", "rounds down under half a minute")
expect(LifecycleAnalytics.format(30), "1m", "rounds half a minute up")
expect(LifecycleAnalytics.format(45 * minute), "45m", "minutes")
expect(LifecycleAnalytics.format(hour), "1h 0m", "an hour")
expect(LifecycleAnalytics.format(2 * day + 3 * hour + 15 * minute), "2d 3h 15m", "days hours minutes")
expect(LifecycleAnalytics.format(day + 59 * minute + 50), "1d 1h 0m", "rounding carries into hours")
expect(LifecycleAnalytics.format(-5), "0m", "negative clamps")

// Codable round trip: unknown stages do not decode
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let original = event(.ciPassed, 0, model: "M")
let data = try! encoder.encode(original)
expect(try? decoder.decode(LifecycleEvent.self, from: data), original, "round trip")
let bogus = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "ci_passed", with: "deployed")
expect((try? decoder.decode(LifecycleEvent.self, from: Data(bogus.utf8))) == nil, true, "unknown stage rejected")

print(failures == 0 ? "OK — \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
