import Foundation

/// THE list of the assistants MarkView supports, in the order menus and pickers show them. Adding an assistant is one provider
/// file in this folder and one line here; nothing else in the app names an assistant (AR-35).
enum AssistantProviders {
    static let list: [any AssistantProvider] = [
        ClaudeProvider(),
        CodexProvider(),
        ClineProvider(),
        CopilotProvider(),
        AntigravityProvider(),
    ]
}
