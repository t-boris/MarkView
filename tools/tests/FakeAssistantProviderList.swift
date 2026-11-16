// Replaces MarkView/Models/AI/Providers/AssistantProviderList.swift in assistant-provider-extension-tests.sh: the same list
// with one more line, for an assistant that no other code of the app has ever heard of.
enum AssistantProviders {
    static let list: [any AssistantProvider] = [
        ClaudeProvider(),
        CodexProvider(),
        ClineProvider(),
        CopilotProvider(),
        AntigravityProvider(),
        FakeProvider(),
    ]
}
