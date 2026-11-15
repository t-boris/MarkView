import Foundation

// A made-up assistant: ONE provider and nothing else. assistant-provider-extension-tests.sh registers it by one line in the
// provider list and checks that the terminal profile, the one-shot run, the usage reader and the hand-off phrasing use it.

struct FakeProvider: AssistantProvider {
    let id = "fakeassist"
    let displayName = "Fake Assistant"
    let binaryName = "fakeassist"
    let authStatusArgs: [String] = []
    let loginCommand = ""
    let fullAccessArgs = ["--yolo"]
    let continueArgs = ["--resume-last"]
    let terminalIcon = "star"
    let fixesBugsAsGoal = true

    func modelOptions() -> [AIModelOption] { [AIModelOption(id: "", name: "Default", detail: "")] }
    func goalPrompt(_ objective: String, closing: String) -> String { "FAKE GOAL: \(objective)" }

    var usage: (any AssistantUsageSupport)? { FakeUsage() }
    var completion: (any AssistantCompletionSupport)? { self }
}

extension FakeProvider: AssistantCompletionSupport {
    func launch(_ request: CompletionLaunchRequest) throws -> CompletionLaunch {
        CompletionLaunch(arguments: ["--fake-run"] + modelArgs(request.model) + (request.effort.map { ["--effort", $0] } ?? []),
                         input: request.prompt, schemaFile: nil)
    }

    func makeParser() -> any CompletionStreamParser { FakeParser() }
}

/// One JSON line `{"answer": ..., "tokens": ...}` is the whole answer.
private final class FakeParser: CompletionStreamParser {
    func handle(_ json: [String: Any], output: inout CompletionOutput, sink: CompletionSink) {
        guard let answer = json["answer"] as? String else { return }
        output.text = answer
        output.outputTokens = json["tokens"] as? Int ?? 0
        sink.onDelta?(answer)
    }
}

struct FakeUsage: AssistantUsageSupport {
    let shortName = "Fake"
    let dataDirectoryName = ".fakeassist"
    var localLogs: (any UsageLogFormat)? { FakeLog() }

    func fetchOfficial(using transport: any UsageTransport) async -> UsageFetchResult { .signedOut }
}

/// `~/.fakeassist/logs/*.jsonl`, one `{"ts": ..., "tokens": ...}` line per call.
struct FakeLog: UsageLogFormat {
    var marker: Data { Data("tokens".utf8) }

    func roots(in dataDirectory: URL) -> [URL] { [dataDirectory.appendingPathComponent("logs", isDirectory: true)] }

    func read(line: Data, dates: ISO8601DateFormatter, lastTotal: inout Int) -> UsageLineReading {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let tokens = object["tokens"] as? Int, let date = UsageLogLine.date(object["ts"], dates) else { return .unrecognised }
        return .counted(key: nil, event: UsageEvent(date: date, tokens: tokens, costUSD: nil))
    }
}
