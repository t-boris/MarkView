import Foundation

/// Routes actions to the appropriate AI provider based on task type
@MainActor
class ProviderRouter: ObservableObject {
    @Published var anthropicConfigured = false
    @Published var openaiConfigured = false
    @Published var localConfigured = false

    let anthropicClient: AIProviderClient
    let embeddingClient: EmbeddingClient

    init(anthropicClient: AIProviderClient, embeddingClient: EmbeddingClient) {
        self.anthropicClient = anthropicClient
        self.embeddingClient = embeddingClient
        updateStatus()
    }

    func updateStatus() {
        anthropicConfigured = anthropicClient.hasAPIKey
        openaiConfigured = embeddingClient.hasAPIKey
    }

    /// Which model to use for each action type
    enum ActionType {
        case describe        // Fast, cheap
        case summarize       // Fast, cheap
        case diagram         // Complex, needs quality
        case research        // Medium complexity
        case implement       // Complex, needs precision
        case generateTests   // Medium complexity
        case adr             // Medium complexity
        case deepResearch    // Complex, multiple calls
        case embedding       // Specialized

        var recommendedModel: String {
            switch self {
            case .describe, .summarize: return "claude-sonnet-4-6"
            case .diagram, .implement: return "claude-opus-4-6"
            case .research, .adr, .generateTests: return "claude-sonnet-4-6"
            case .deepResearch: return "claude-sonnet-4-6" // Multiple calls, keep cost down
            case .embedding: return "text-embedding-3-small"
            }
        }

        var provider: Provider {
            switch self {
            case .embedding: return .openai
            default: return .anthropic
            }
        }

        var estimatedCostPerCall: String {
            switch self {
            case .describe, .summarize: return "~$0.01"
            case .diagram: return "~$0.10"
            case .research, .adr, .generateTests: return "~$0.03"
            case .implement: return "~$0.15"
            case .deepResearch: return "~$0.20"
            case .embedding: return "~$0.001"
            }
        }
    }

    enum Provider: String {
        case anthropic = "Anthropic"
        case openai = "OpenAI"
        case local = "Local"
    }

    /// Check if a specific action can be performed
    func canPerform(_ action: ActionType) -> Bool {
        switch action.provider {
        case .anthropic: return anthropicConfigured
        case .openai: return openaiConfigured
        case .local: return localConfigured
        }
    }

    /// Get status message for an action
    func statusMessage(for action: ActionType) -> String? {
        if canPerform(action) { return nil }
        switch action.provider {
        case .anthropic: return "Configure Anthropic API key in DDE Settings"
        case .openai: return "Configure OpenAI API key in DDE Settings"
        case .local: return "Local model not configured"
        }
    }
}
