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
    var stages: [AIOperationStage] = []
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
        runner: { req, onActivity in
            attempts += 1
            onActivity?(.read("README.md"))
            if attempts == 1 {
                // First attempt returns invalid nodeCount = 0 -> triggers repair retry
                return CLICompletion.Result(
                    text: #"{"title": "Draft", "nodeCount": 0}"#,
                    structured: nil,
                    inputTokens: 100,
                    outputTokens: 30,
                    costUSD: 0.001
                )
            }
            check(req.prompt.contains("Your previous response failed validation"), "AR-26: Repair retry includes validation failure context")
            return CLICompletion.Result(
                text: #"{"title": "Repaired Architecture", "nodeCount": 5}"#,
                structured: nil,
                inputTokens: 120,
                outputTokens: 40,
                costUSD: 0.002
            )
        }
    )

    let outcome = try? await op.execute("MarkView") { stage in
        stages.append(stage)
    }
    check(attempts == 2, "AR-26: AIOperation retries once when first response fails validation")
    check(outcome?.output == SampleDiagramPayload(title: "Repaired Architecture", nodeCount: 5), "AR-26: AIOperation returns repaired valid output")
    check(stages.contains(.preparing) && stages.contains(.validating) && stages.contains(.repairing(attempt: 1)) && stages.contains(.completed), "AR-26: AIOperation reports lifecycle stages including .repairing(attempt: 1)")
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
