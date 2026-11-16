import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

print("=== Phase 5 AI Layer & AssistantProvider Tests (AR-26, AR-35) ===")

struct SampleDiagramPayload: Codable, Equatable {
    let title: String
    let nodeCount: Int
}

@MainActor
func runPhase5Tests() async {
    // 1. AR-35: AssistantProviderRegistry covers all CLITools with identical semantics
    check(AssistantProviderRegistry.all.count == CLITool.allCases.count, "AR-35: AssistantProviderRegistry covers all CLITool cases")
    for tool in CLITool.allCases {
        let p = AssistantProviderRegistry.provider(for: tool)
        check(p.tool == tool && p.id == tool.rawValue, "AR-35: Provider matches tool \(tool.rawValue)")
        check(tool.displayName == p.displayName && tool.binaryName == p.binaryName, "AR-35: CLITool.\(tool.rawValue) delegates displayName and binaryName to provider")
        check(tool.fullAccessArgs == p.fullAccessArgs && tool.continueArgs == p.continueArgs, "AR-35: CLITool.\(tool.rawValue) delegates fullAccessArgs and continueArgs")
    }
    check(CLITool.claude.modelArgs("opus") == ["--model", "opus"], "AR-35: Claude modelArgs uses --model")
    check(CLITool.codex.modelArgs("o3") == ["-m", "o3"], "AR-35: Codex modelArgs uses -m")
    check(CLITool.antigravity.binaryName == "agy", "AR-35: Antigravity binaryName is agy")
    check(CLITool.cline.usesACP && CLITool.copilot.usesACP && !CLITool.claude.usesACP, "AR-35: usesACP matches ACP providers")

    // The facts the old per-assistant switches held, now answered by the providers (behaviour preserved).
    check(AIAssistantPreferences.defaultXRayModel(for: .claude) == "sonnet" && AIAssistantPreferences.defaultXRayModel(for: .codex) == "gpt-5.6-luna"
          && CLITool.allCases.filter { $0 != .claude && $0 != .codex }.allSatisfy { AIAssistantPreferences.defaultXRayModel(for: $0).isEmpty },
          "AR-35: default X-Ray models")
    check(CLITool.claude.provider.loginState(stdout: #"{"loggedIn":true}"#, stderr: "") == true
          && CLITool.claude.provider.loginState(stdout: #"{"loggedIn":false}"#, stderr: "") == false
          && CLITool.claude.provider.loginState(stdout: "Logged in as someone", stderr: "") == true
          && CLITool.claude.provider.loginState(stdout: "", stderr: "") == nil,
          "AR-35: Claude login state reads the JSON flag, else the words")
    check(CLITool.codex.provider.loginState(stdout: "Logged in using ChatGPT", stderr: "") == true
          && CLITool.codex.provider.loginState(stdout: "", stderr: "Not logged in") == false
          && CLITool.codex.provider.loginState(stdout: "unknown", stderr: "") == nil
          && CLITool.cline.provider.loginState(stdout: "Logged in", stderr: "") == nil,
          "AR-35: Codex login state reads the words; ACP assistants have none")
    let folders = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
    check(CLITool.claude.additionalFolderArgs(folders) == ["--add-dir", "/a", "--add-dir", "/b"]
          && CLITool.allCases.filter { $0 != .claude }.allSatisfy { $0.additionalFolderArgs(folders).isEmpty },
          "AR-35: only Claude takes extra folders (--add-dir)")
    let cline = CLITool.cline.provider.acp, copilot = CLITool.copilot.provider.acp
    check(cline?.launchProfile(effort: nil).arguments == ["--acp"] && cline?.launchProfile(effort: nil).readOnlyMode == "plan"
          && cline?.launchProfile(effort: "high").arguments == ["--acp", "--thinking", "high"]
          && cline?.probe.minimumMajorVersion == 3 && cline?.probe.installCommand == "npm i -g cline@latest"
          && cline?.probe.silentExitMessage != nil && cline?.killedMessage?.contains("codesign") == true,
          "AR-35: Cline's ACP profile, probe and signature hint")
    check(copilot?.launchProfile(effort: "low").arguments == ["--acp", "--no-auto-update", "--no-ask-user", "--disable-builtin-mcps",
                                                              "--no-custom-instructions", "--reasoning-effort", "low",
                                                              "--available-tools", "view", "grep", "glob"]
          && copilot?.launchProfile(effort: nil).readOnlyMode == nil && copilot?.launchProfile(effort: nil).noticePrefix == "Info: Disabled tools:"
          && copilot?.probe.minimumMajorVersion == 1 && copilot?.probe.modelListImpliesSignedIn == true && copilot?.killedMessage == nil,
          "AR-35: Copilot's ACP profile and probe")
    check(CLITool.claude.provider.acp == nil && CLITool.codex.provider.acp == nil && CLITool.antigravity.provider.acp == nil,
          "AR-35: only Cline and Copilot are ACP assistants")
    check(CLITool.claude.authStatusArgs == ["auth", "status"] && CLITool.claude.loginCommand == "auth login"
          && CLITool.codex.authStatusArgs == ["login", "status"] && CLITool.codex.loginCommand == "login"
          && CLITool.cline.fullAccessArgs == ["--auto-approve", "true"] && CLITool.copilot.fullAccessArgs == ["--allow-all"]
          && CLITool.codex.continueArgs == ["resume", "--last"] && CLITool.cline.continueArgs.isEmpty
          && Setting.cliPath(CLITool.claude.rawValue).name == "settings.cli.claudePath",
          "AR-35: sign-in, full-access and continue arguments, and the override key, are unchanged")
    check(CLITool.allCases.map(\.rawValue) == ["claude", "codex", "cline", "copilot", "antigravity"]
          && CLITool.allCases.map(\.displayName) == ["Claude Code", "Codex", "Cline", "Copilot", "Antigravity"],
          "AR-35: the persisted raw values and their order are unchanged")

    // 2. AR-26: AIJSONSalvage extracts fenced and brace-wrapped JSON
    let fenced = """
    Here is your diagram:
    ```json
    {"title": "Auth Flow", "nodeCount": 4}
    ```
    Hope this helps!
    """
    let decodedFenced = try? AIJSONSalvage.decode(SampleDiagramPayload.self, from: fenced)
    check(decodedFenced == SampleDiagramPayload(title: "Auth Flow", nodeCount: 4), "AR-26: AIJSONSalvage decodes fenced ```json block")

    let proseWrapped = "Sure! The JSON object is {\"title\": \"Pipeline\", \"nodeCount\": 7} as requested."
    let decodedProse = try? AIJSONSalvage.decode(SampleDiagramPayload.self, from: proseWrapped)
    check(decodedProse == SampleDiagramPayload(title: "Pipeline", nodeCount: 7), "AR-26: AIJSONSalvage extracts outermost JSON braces from prose")

    let rawObjText = "Here is the annotation:\n```json\n{\"summary\":\"Intro\",\"parts\":[{\"id\":\"p1\",\"count\":2}],\"ok\":true}\n```"
    let rawObj = try? AIJSONSalvage.decode(AIRawJSONObject.self, from: rawObjText)
    let rawParts = rawObj?.dictionary["parts"] as? [[String: Any]]
    check(rawObj?.dictionary["summary"] as? String == "Intro" &&
          rawObj?.dictionary["ok"] as? Bool == true &&
          (rawParts?.first?["count"] as? Int) == 2,
          "AR-26: AIRawJSONObject decodes arbitrary JSON objects for BookAnnotator/X-Ray AIOperation calls")

    // 3. AR-26: AIOperation executes, validates, and repairs invalid output automatically
    var attempts = 0
    let op = AIOperation<String, SampleDiagramPayload>(
        name: "generate-diagram",
        maxRepairAttempts: 1,
        buildRequest: { topic in
            CLICompletion.Request(project: nil, prompt: "Generate diagram for \(topic)")
        },
        validate: { _, payload in
            if payload.nodeCount <= 0 {
                throw AIOperationError.validationFailed(operation: "generate-diagram", reason: "nodeCount must be positive")
            }
        },
        runner: { req, _, onActivity in
            attempts += 1
            onActivity?(.read("README.md"))
            if attempts == 1 {
                // First attempt returns invalid nodeCount = 0 -> triggers repair retry
                return try CLICompletion.Result(
                    text: #"{"title": "Draft", "nodeCount": 0}"#,
                    structured: nil,
                    inputTokens: 100,
                    outputTokens: 30,
                    costUSD: 0.001
                )
            }
            check(req.prompt.contains("Your previous response failed validation"), "AR-26: Repair retry includes validation failure context")
            return try CLICompletion.Result(
                text: #"{"title": "Repaired Architecture", "nodeCount": 5}"#,
                structured: nil,
                inputTokens: 120,
                outputTokens: 40,
                costUSD: 0.002
            )
        }
    )

    let outcome = try? await op.execute("MarkView")
    check(attempts == 2, "AR-26: AIOperation retries once when first response fails validation")
    check(outcome?.output == SampleDiagramPayload(title: "Repaired Architecture", nodeCount: 5), "AR-26: AIOperation returns repaired valid output")

    // 4. FU-17: allowTextSalvage == false rejects raw prose/fenced JSON when structured output is missing
    let strictOp = AIOperation<String, SampleDiagramPayload>(
        name: "strict-diagram",
        maxRepairAttempts: 0,
        allowTextSalvage: false,
        buildRequest: { topic in
            CLICompletion.Request(project: nil, prompt: "Generate strict JSON for \(topic)")
        },
        runner: { _, _, _ in
            try CLICompletion.Result(
                text: #"Here is your JSON: {"title": "Salvaged", "nodeCount": 2}"#,
                structured: nil,
                inputTokens: 10,
                outputTokens: 10,
                costUSD: 0.0001
            )
        }
    )
    var rejectedRawText = false
    do {
        _ = try await strictOp.execute("MarkView")
    } catch AIOperationError.decodingFailed {
        rejectedRawText = true
    } catch {}
    check(rejectedRawText, "FU-17: AIOperation with allowTextSalvage=false rejects raw text JSON when structured output is nil")

    await runPipelineTests()
}

// MARK: - AR-26: the pipeline every feature runs through

/// A run that is counted and answers from a script, in place of the assistant CLI.
final class ScriptedRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<CLICompletion.Result, Error>]
    private(set) var requests: [CLICompletion.Request] = []
    var deltas: [String] = []

    init(_ answers: [Result<CLICompletion.Result, Error>]) { self.answers = answers }

    var calls: Int { lock.withLock { requests.count } }

    func run(_ request: CLICompletion.Request, _ onDelta: (@Sendable (String) -> Void)?,
             _ onActivity: (@Sendable (CLICompletion.Activity) -> Void)?) async throws -> CLICompletion.Result {
        let next: Result<CLICompletion.Result, Error> = lock.withLock {
            requests.append(request)
            return answers.isEmpty ? .failure(CLICompletion.Failure.failed(.claude, "script ran out")) : answers.removeFirst()
        }
        onDelta?("part ")
        onActivity?(.thinking)
        return try next.get()
    }
}

func answer(_ text: String = "", structured: Any? = nil, cost: Double? = nil) -> Result<CLICompletion.Result, Error> {
    Result { try CLICompletion.Result(text: text, structured: structured, inputTokens: 10, outputTokens: 5, costUSD: cost) }
}

struct Rejected: LocalizedError {
    let problems: [String]
    var errorDescription: String? { problems.joined(separator: "; ") }
}

final class Seen<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func add(_ value: T) { lock.withLock { values.append(value) } }
    var all: [T] { lock.withLock { values } }
}

@MainActor
func runPipelineTests() async {
    let base = CLICompletion.Request(project: nil, prompt: "Describe it")

    // Plain text: the answer as written, the streaming callbacks of every attempt reach the caller, the label is the name.
    let textScript = ScriptedRunner([answer("  The text.  ", cost: 0.5)])
    let textOp = AIOperation<CLICompletion.Request, String>.text(name: "explain", runner: textScript.run)
    let deltas = Seen<String>(), activities = Seen<String>()
    let textRun = try? await textOp.execute(base, onDelta: { deltas.add($0) }, onActivity: { _ in activities.add("activity") })
    check(textRun?.output == "  The text.  " && textRun?.result.costUSD == 0.5, "AR-26: text mode returns the answer untouched with the run's usage")
    check(deltas.all == ["part "] && activities.all == ["activity"], "AR-26: streaming text and activity reach the caller")
    check(textScript.requests.first?.label == "explain", "AR-26: a request without a label is labelled with the operation's name")
    var labelled = base
    labelled.label = "qa-step"
    let keepScript = ScriptedRunner([answer("x")])
    _ = try? await AIOperation<CLICompletion.Request, String>.text(name: "explain", runner: keepScript.run).execute(labelled)
    check(keepScript.requests.first?.label == "qa-step", "AR-26: a label the feature set is kept")

    // A single run is not repaired: a rejected answer is thrown at once, the run is not repeated.
    let singleScript = ScriptedRunner([answer("no"), answer("yes")])
    let single = AIOperation<CLICompletion.Request, String>(
        name: "single",
        parse: { result in
            guard result.text == "yes" else { throw Rejected(problems: ["not yes"]) }
            return result.text
        }, runner: singleScript.run)
    var singleError: Error?
    do { _ = try await single.execute(base) } catch { singleError = error }
    check(singleScript.calls == 1 && (singleError as? Rejected)?.problems == ["not yes"], "AR-26: with no repair attempts a rejected answer is thrown after one run")

    // Structured answers: parse reads what the feature consumed; usage of every run is reported, also of the rejected one.
    let usage = Seen<Int>()
    let repairScript = ScriptedRunner([answer(structured: ["items": [String]()]), answer(structured: ["items": ["a", "b"]])])
    let repairing = AIOperation<CLICompletion.Request, [String]>(
        name: "list", maxRepairAttempts: 1,
        parse: { result in (result.structured as? [String: Any])?["items"] as? [String] ?? [] },
        validate: { items, _ in if items.isEmpty { throw Rejected(problems: ["the list is empty", "name at least one item"]) } },
        repair: { context in
            var next = context.original
            next.label = "\(context.original.label):repair\(context.attempt.number)"
            next.prompt = context.original.prompt + "\nProblems: " + ((context.error as? Rejected)?.problems.joined(separator: "; ") ?? "")
                + "\nPrevious: " + context.previousAnswer
            return next
        },
        onResult: { usage.add($0.inputTokens) },
        runner: repairScript.run)
    let repaired = try? await repairing.execute(base)
    check(repaired?.output == ["a", "b"] && repairScript.calls == 2, "AR-26: a rejected structured answer is asked again once and the repaired one is returned")
    check(repairScript.requests.last?.label == "list:repair1", "AR-26: the feature's repair request sets its own label")
    check(repairScript.requests.last?.prompt.contains("Problems: the list is empty; name at least one item") == true
          && repairScript.requests.last?.prompt.contains(#"{"items":[]}"#) == true,
          "AR-26: the repair request carries the problems and the previous structured answer as JSON")
    check(usage.all == [10, 10], "AR-26: usage is reported for every run, the rejected one included")

    // Bounded: attempts end, the last problem is thrown, the validator is told which attempt is the last.
    let boundedScript = ScriptedRunner([answer("1"), answer("2"), answer("3"), answer("4")])
    let attemptsSeen = Seen<AIAttempt>()
    let bounded = AIOperation<CLICompletion.Request, String>(
        name: "bounded", maxRepairAttempts: 2,
        parse: { $0.text },
        validate: { text, attempt in
            attemptsSeen.add(attempt)
            throw Rejected(problems: ["rejected \(text)"])
        }, runner: boundedScript.run)
    var boundedError: Error?
    do { _ = try await bounded.execute(base) } catch { boundedError = error }
    check(boundedScript.calls == 3, "AR-26: maxRepairAttempts 2 means three runs, no more")
    check((boundedError as? Rejected)?.problems == ["rejected 3"], "AR-26: the problem of the last attempt is the one thrown")
    check(attemptsSeen.all == [AIAttempt(number: 1, isLast: false), AIAttempt(number: 2, isLast: false), AIAttempt(number: 3, isLast: true)],
          "AR-26: the validator is told the attempt number and which one is the last")
    check(boundedScript.requests[2].prompt.components(separatedBy: "Previous response:").count == 2
          && boundedScript.requests[2].prompt.contains("rejected 2") && !boundedScript.requests[2].prompt.contains("rejected 1"),
          "AR-26: the default repair is built on the original prompt and the last answer, it does not stack")

    // A rejection that asking again cannot mend ends the operation at once.
    struct Final: AIUnrepairable, LocalizedError { var errorDescription: String? { "final" } }
    let finalScript = ScriptedRunner([answer("1"), answer("2")])
    let finalOp = AIOperation<CLICompletion.Request, String>(name: "final", maxRepairAttempts: 3, parse: { _ in throw Final() }, runner: finalScript.run)
    var finalError: Error?
    do { _ = try await finalOp.execute(base) } catch { finalError = error }
    check(finalScript.calls == 1 && finalError is Final, "AR-26: an unrepairable rejection is thrown at once, with attempts left")

    // Failures of the run itself are not repaired.
    let failScript = ScriptedRunner([.failure(CLICompletion.Failure.timedOut(.claude, 30)), answer("never")])
    let failing = AIOperation<CLICompletion.Request, String>(name: "failing", maxRepairAttempts: 3, parse: { $0.text }, runner: failScript.run)
    var failure: Error?
    do { _ = try await failing.execute(base) } catch { failure = error }
    check(failScript.calls == 1, "AR-26: a timed-out or failed run is not repeated")
    if case CLICompletion.Failure.timedOut? = failure { check(true, "AR-26: the run's own error reaches the caller unchanged") } else { check(false, "AR-26: the run's own error reaches the caller unchanged") }

    // Cancellation: before the first run nothing starts; during a run or its judging nothing is repaired.
    let idleScript = ScriptedRunner([answer("never")])
    let idle = AIOperation<CLICompletion.Request, String>.text(name: "idle", runner: idleScript.run)
    let beforeRun = Task { () -> Error? in
        try? await Task.sleep(nanoseconds: 20_000_000)
        do { _ = try await idle.execute(base); return nil } catch { return error }
    }
    beforeRun.cancel()
    let beforeError = await beforeRun.value
    check(beforeError is CancellationError && idleScript.calls == 0, "AR-26: a cancelled task starts no run")
    let cancelScript = ScriptedRunner([.failure(CancellationError()), answer("never")])
    let cancelling = AIOperation<CLICompletion.Request, String>(name: "cancelling", maxRepairAttempts: 2, parse: { $0.text }, runner: cancelScript.run)
    var cancelError: Error?
    do { _ = try await cancelling.execute(base) } catch { cancelError = error }
    check(cancelError is CancellationError && cancelScript.calls == 1, "AR-26: cancelling a run ends the operation without a repair")
    let judgeScript = ScriptedRunner([answer("a"), answer("b")])
    let judging = AIOperation<CLICompletion.Request, String>(
        name: "judging", maxRepairAttempts: 2, parse: { _ in throw CancellationError() }, runner: judgeScript.run)
    var judgeError: Error?
    do { _ = try await judging.execute(base) } catch { judgeError = error }
    check(judgeError is CancellationError && judgeScript.calls == 1, "AR-26: cancellation while judging an answer is not repaired")

    // The raw mode hands the whole run over.
    let rawScript = ScriptedRunner([answer("t", structured: ["k": 1], cost: 0.25)])
    let raw = try? await AIOperation<CLICompletion.Request, CLICompletion.Result>.run(name: "raw", runner: rawScript.run).execute(base)
    check(raw?.output.costUSD == 0.25 && (raw?.output.structured as? [String: Int])?["k"] == 1, "AR-26: raw mode returns the run with its structured answer and usage")
}

let semaphore = DispatchSemaphore(value: 0)
Task { @MainActor in
    await runPhase5Tests()
    semaphore.signal()
}
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
}

print("\nPhase 5 summary: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }

// The suite names the assistants by their stored identity; the app names none outside its providers.
extension CLITool {
    static var claude: CLITool { CLITool(rawValue: "claude")! }
    static var codex: CLITool { CLITool(rawValue: "codex")! }
    static var cline: CLITool { CLITool(rawValue: "cline")! }
    static var copilot: CLITool { CLITool(rawValue: "copilot")! }
    static var antigravity: CLITool { CLITool(rawValue: "antigravity")! }
}
