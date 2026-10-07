import Foundation
// Stand-in for CLICompletion that runs the real `claude` CLI (see prototype-live-run.sh): same read-only
// tools and JSON schema as the app, so the prompts and schemas can be checked against a real assistant.
enum CLITool { case claude }
enum CLICompletion {
    struct Request {
        let project: URL?
        var prompt: String
        var systemPrompt: String? = nil
        var jsonSchema: [String: Any]? = nil
        var readableFolder: URL? = nil
        var timeout: TimeInterval = 180
        var effort: String? = nil
        var label = ""
    }
    struct Result { let text: String; let structured: Any?; let inputTokens: Int; let outputTokens: Int }
    enum Activity { case read(String), search(String), run(String), thinking, writing(Int), answerDelta(String), webSearch(String), webFetch(String) }
    enum Failure: LocalizedError {
        case invalidOutput(CLITool, String)
        case timedOut(CLITool, TimeInterval)
        var errorDescription: String? { if case .invalidOutput(_, let d) = self { return d } else { return nil } }
    }
    static func run(_ r: Request, onDelta: (@Sendable (String) -> Void)? = nil, onActivity: (@Sendable (Activity) -> Void)? = nil) async throws -> Result {
        var args = ["-p", "--safe-mode", "--no-session-persistence", "--output-format", "json", "--tools", "Read,Grep,Glob"]
        if let effort = r.effort { args += ["--effort", effort] }
        if let system = r.systemPrompt { args += ["--system-prompt", system] }
        if let schema = r.jsonSchema {
            args += ["--json-schema", String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_BIN"] ?? "/Users/boris/.local/bin/claude")
        process.arguments = args
        process.currentDirectoryURL = r.readableFolder
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = nil; env["FORCE_COLOR"] = nil; env["CLAUDECODE"] = nil
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(r.prompt.utf8)); try input.fileHandleForWriting.close()
        onActivity?(.thinking)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLICompletion.Failure.invalidOutput(.claude, "not JSON: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        return Result(text: json["result"] as? String ?? "", structured: json["structured_output"],
                      inputTokens: usage["input_tokens"] as? Int ?? 0, outputTokens: usage["output_tokens"] as? Int ?? 0)
    }
}
