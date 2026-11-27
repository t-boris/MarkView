import Foundation

// One-shot, non-interactive runs of an assistant (`CLICompletion`): how the provider builds the command line of a run and how
// it reads the CLI's output stream. Foundation only, so the suites that compile the providers need no app state.

/// What the assistant is doing during a run, for progress displays.
enum CompletionActivity: Sendable {
    /// Reading a file (absolute or working-directory-relative path).
    case read(String)
    /// Searching files for a pattern.
    case search(String)
    /// Running a shell command (Codex reads files this way).
    case run(String)
    /// A web search query sent (Claude WebSearch, Codex --search).
    case webSearch(String)
    /// A web page fetched (Claude WebFetch).
    case webFetch(String)
    /// Reasoning before the next action.
    case thinking
    /// Characters of the answer produced so far.
    case writing(Int)
    /// The next piece of the answer as it is written (structured answers included).
    case answerDelta(String)
}

/// What a stream parser collects from the CLI's output.
struct CompletionOutput {
    var text = ""
    var structured: Any?
    var inputTokens = 0
    var outputTokens = 0
    var costUSD: Double?
    var errorMessage: String?
    var refused: [(tool: String, input: String)] = []
}

/// Where a parser reports progress while the CLI is running.
struct CompletionSink {
    let onDelta: (@Sendable (String) -> Void)?
    let onActivity: (@Sendable (CompletionActivity) -> Void)?
    /// The id of the session the CLI keeps on disk for this run (Codex's `thread.started`), so it can be deleted when the run ends.
    var onSession: (@Sendable (String) -> Void)? = nil
}

/// Reads one CLI run, line by line. One parser per run: it keeps the state of the stream (the tool being streamed, the
/// characters written so far).
protocol CompletionStreamParser: AnyObject {
    /// One JSON line of the CLI's output.
    func handle(_ json: [String: Any], output: inout CompletionOutput, sink: CompletionSink)
    /// A non-fatal complaint of the CLI that explains an empty answer (Codex "error" events).
    var warning: String? { get }
}

extension CompletionStreamParser {
    var warning: String? { nil }
}

/// What a run needs to know to build its command line.
struct CompletionLaunchRequest {
    var prompt: String
    var systemPrompt: String?
    /// JSON Schema the answer must match.
    var jsonSchema: [String: Any]?
    /// Folder the CLI may read with its own tools; nil = no file access at all.
    var readableFolder: URL?
    var extraReadableFolders: [URL]
    /// The folders linked to the project of `readableFolder` (read only when the CLI uses them).
    var linkedFolders: () -> [URL]
    var allowWeb: Bool
    var images: [URL]
    var effort: String?
    var model: String?
    /// The CLI's working directory.
    var workDir: URL
    /// An empty folder for files that live for one run.
    var scratchDirectory: () -> URL
    /// The run may start subagents while it reads `readableFolder` (`CLICompletion.Request.subagents`). Claude and Codex follow it;
    /// Antigravity's `-p` has no switch for its own.
    var subagents = true
}

/// A built command line.
struct CompletionLaunch {
    var arguments: [String]
    /// What the CLI reads on its standard input (the prompt).
    var input: String
    /// A file the run created and the caller removes when the run ends.
    var schemaFile: URL?
    /// The CLI keeps a session on disk for this run (its subagents load it): the run reports its id (`CompletionSink.onSession`)
    /// and deletes it with `AssistantCompletionSupport.deleteSessionArguments` when it ends, however it ends.
    var keepsSession = false
}

/// How one assistant runs once: the command line and the reading of its output stream.
protocol AssistantCompletionSupport: Sendable {
    func launch(_ request: CompletionLaunchRequest) throws -> CompletionLaunch
    func makeParser() -> any CompletionStreamParser
    /// The arguments, after the executable, of the command that deletes session `id` of a run that kept one; nil when the
    /// assistant keeps none.
    func deleteSessionArguments(_ id: String) -> [String]?
    /// Session `id` is still stored (a run stopped before the CLI wrote it keeps nothing to delete).
    func storesSession(_ id: String) -> Bool
}

extension AssistantCompletionSupport {
    func deleteSessionArguments(_ id: String) -> [String]? { nil }
    func storesSession(_ id: String) -> Bool { false }
}

enum CompletionJSON {
    /// `object` as JSON text with sorted keys.
    static func string(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
