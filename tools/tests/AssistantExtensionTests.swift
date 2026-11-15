import Foundation

// AR-35: adding an assistant is one provider file and one line in the provider list. FakeAssistantProvider.swift is such a
// provider and FakeAssistantProviderList.swift is the list with that one extra line; nothing else here knows "fakeassist".
// The checks run the app's own paths: the stored raw values, the terminal profile, the usage reader, the hand-off prompts and
// CLICompletion.run, which starts this very binary as the fake assistant's CLI.

@main enum AssistantExtensionTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print((condition ? "ok   " : "FAIL ") + message)
        if !condition { failures += 1 }
    }

    /// The assistant CLI: the one-shot run of the fake assistant asks for this binary with `--fake-run`.
    static func serveFake() {
        let prompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let arguments = CommandLine.arguments.drop(while: { $0 != "--fake-run" }).dropFirst().joined(separator: " ")
        let line = ["answer": "echo:\(prompt)|\(arguments)", "tokens": 7] as [String: Any]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self))
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--fake-run") { serveFake(); return }
        let fake = CLITool(rawValue: "fakeassist")

        // The stored raw values of the built-in assistants decode as before, whatever else is registered.
        let stored: [(raw: String, name: String, binary: String, overrideKey: String, icon: String)] = [
            ("claude", "Claude Code", "claude", "settings.cli.claudePath", "sparkle"),
            ("codex", "Codex", "codex", "settings.cli.codexPath", "chevron.left.forwardslash.chevron.right"),
            ("cline", "Cline", "cline", "settings.cli.clinePath", "circle.hexagongrid"),
            ("copilot", "Copilot", "copilot", "settings.cli.copilotPath", "airplane"),
            ("antigravity", "Antigravity", "agy", "settings.cli.antigravityPath", "wand.and.stars"),
        ]
        for row in stored {
            let tool = CLITool(rawValue: row.raw)
            check(tool?.displayName == row.name && tool?.binaryName == row.binary && tool.map { Setting.cliPath($0.rawValue).name } == row.overrideKey,
                  "stored value \(row.raw) still names \(row.name) (\(row.binary), \(row.overrideKey))")
            check((try? JSONDecoder().decode(CLITool.self, from: Data("\"\(row.raw)\"".utf8))) == tool,
                  "\(row.raw) decodes from JSON")
            check(TerminalProfile(rawValue: row.raw) == tool.map(TerminalProfile.assistant) && TerminalProfile(rawValue: row.raw)?.rawValue == row.raw
                  && TerminalProfile(rawValue: row.raw)?.icon == row.icon, "terminal profile \(row.raw) keeps its raw value and icon")
        }
        check(TerminalProfile(rawValue: "shell") == .shell && TerminalProfile.shell.rawValue == "shell" && TerminalProfile.shell.icon == "terminal"
              && TerminalProfile.shell.title == "Shell", "the shell profile keeps its raw value")
        check(CLITool(rawValue: "gemini") == nil && TerminalProfile(rawValue: "gemini") == nil
              && (try? JSONDecoder().decode(CLITool.self, from: Data("\"gemini\"".utf8))) == nil, "an unknown stored value stays unknown")
        check(TerminalProfile.allCases.map(\.rawValue) == ["claude", "codex", "cline", "copilot", "antigravity", "fakeassist", "shell"],
              "the profiles follow the provider list, then the shell")
        check(AssistantProviderRegistry.defaultTool.rawValue == "claude", "the first provider is the default assistant")

        // The one registered line is the whole integration.
        guard let fake else { check(false, "the fake assistant is registered"); finish(); return }
        check(CLITool.allCases.last == fake && CLITool.allCases.count == 6, "the fake assistant is the sixth, after the built-in five")
        check(fake.displayName == "Fake Assistant" && fake.binaryName == "fakeassist" && Setting.cliPath(fake.rawValue).name == "settings.cli.fakeassistPath",
              "identity, binary and settings key come from the provider")
        check(fake.fullAccessArgs == ["--yolo"] && fake.continueArgs == ["--resume-last"] && fake.modelArgs("m") == ["--model", "m"]
              && fake.modelArgs(nil).isEmpty, "launch arguments come from the provider")

        // Terminal profile.
        let profile = TerminalProfile(rawValue: "fakeassist")
        check(profile == .assistant(fake) && profile?.tool == fake && profile?.title == "Fake Assistant" && profile?.icon == "star"
              && profile?.rawValue == "fakeassist", "the terminal profile of the fake assistant uses its provider")

        // Hand-off phrasing.
        check(HandoffPrompt.goal("tests pass", tool: fake) == "FAKE GOAL: tests pass", "a goal is phrased by the provider")
        check(HandoffPrompt.feature("docs/features/x", tool: fake).hasPrefix("FAKE GOAL: Implement what docs/features/x specifies."),
              "a feature hand-off is phrased by the provider")
        check(HandoffPrompt.bug("docs/bugs/BUG-1.md", tool: fake).hasPrefix("FAKE GOAL: fix the bug described in docs/bugs/BUG-1.md"),
              "a bug hand-off is a goal for a provider that fixes bugs as goals")
        check(HandoffPrompt.bug("docs/bugs/BUG-1.md", tool: CLITool(rawValue: "codex")).hasPrefix("Fix the bug described in"),
              "a provider that does not fix bugs as goals gets the plain request")

        // Usage lookup.
        check(CLITool.usageTracked.contains(fake) && fake.hasLocalLogs && fake.shortName == "Fake"
              && Setting.usageHidden(fake.rawValue).name == "settings.usage.fakeassist.hidden" && Setting.usageLimit(fake.rawValue).name == "settings.usage.fakeassist.limit",
              "the fake assistant is tracked, with the usage keys of every assistant")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("mv-fake-assistant-" + UUID().uuidString)
        let logs = home.appendingPathComponent(".fakeassist/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let stamp = UsageLogLine.timestampFormatter().string(from: now)
        try (["{\"ts\":\"\(stamp)\",\"tokens\":40}", "{\"ts\":\"\(stamp)\",\"tokens\":2}", "not a usage line"].joined(separator: "\n") + "\n")
            .write(to: logs.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let reader = UsageLogReader(agent: fake, home: home)
        let events = (try? reader?.events(since: now.addingTimeInterval(-60))) ?? []
        check(events.count == 2 && events.map(\.tokens).reduce(0, +) == 42, "the usage reader counts the fake assistant's own log format")
        check(UsageLogReader(agent: CLITool(rawValue: "antigravity")!, home: home) == nil, "an assistant without readable logs has no reader")

        // One-shot run: the provider builds the command line and reads the answer.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-fake-run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var request = CLICompletion.Request(project: root, prompt: "hello fake")
        request.tool = fake
        request.model = "model-x"
        request.effort = "low"
        let result = try await CLICompletion.run(request)
        check(result.text == "echo:hello fake|--model model-x --effort low" && result.outputTokens == 7,
              "CLICompletion starts the fake CLI with the provider's arguments and reads its answer with the provider's parser")

        finish()
    }

    static func finish() {
        if failures > 0 { print("assistant extension checks FAILED: \(failures)"); exit(1) }
        print("assistant extension checks passed")
    }
}
