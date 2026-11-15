import Foundation

/// Lookups over `AssistantProviders.list`.
enum AssistantProviderRegistry {
    static let all: [any AssistantProvider] = AssistantProviders.list

    private static let byID: [String: any AssistantProvider] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    static func provider(for tool: CLITool) -> any AssistantProvider {
        guard let provider = byID[tool.rawValue] else { preconditionFailure("No assistant provider is registered for “\(tool.rawValue)”") }
        return provider
    }

    static func provider(id: String) -> (any AssistantProvider)? { byID[id] }
}
