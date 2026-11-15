import Foundation

/// Google Antigravity CLI (`agy`), the successor of Gemini CLI. Terminals use its interactive mode, one-shot
/// requests its print mode with stream-json (`CLICompletion`).
struct AntigravityProvider: AssistantProvider {
    let id = "antigravity"
    let displayName = "Antigravity"
    let binaryName = "agy"
    let authStatusArgs: [String] = []
    let loginCommand = ""
    let fullAccessArgs = ["--dangerously-skip-permissions"]
    let continueArgs = ["--continue"]

    func modelOptions() -> [AIModelOption] {
        // A few of `agy models`; any other id can be typed as a custom model name.
        [AIModelOption(id: "", name: "Default", detail: "Antigravity's configured model"),
         AIModelOption(id: "gemini-4-argon-medium", name: "Gemini 4 Argon (Medium)", detail: ""),
         AIModelOption(id: "gemini-3.8-flash-medium", name: "Gemini 3.8 Flash (Medium)", detail: ""),
         AIModelOption(id: "claude-opus-5-5-medium", name: "Claude Opus 5.5 (Medium)", detail: ""),
         AIModelOption(id: "claude-sonnet-5-5-medium", name: "Claude Sonnet 5.5 (Medium)", detail: "")]
    }
}
