import Foundation
#if MARKVIEW_HOSTED_TEST_HOST
import os
#endif

/// Lookups over `AssistantProviders.list`.
enum AssistantProviderRegistry {
#if MARKVIEW_HOSTED_TEST_HOST
    private static let testProviders = OSAllocatedUnfairLock(initialState: [any AssistantProvider]())
    static func setTestProviders(_ providers: [any AssistantProvider]) { testProviders.withLock { $0 = providers } }
    static var all: [any AssistantProvider] { AssistantProviders.list + testProviders.withLock { $0 } }
    private static var byID: [String: any AssistantProvider] {
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
#else
    static let all: [any AssistantProvider] = AssistantProviders.list

    private static let byID: [String: any AssistantProvider] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
#endif

    static func provider(for tool: CLITool) -> any AssistantProvider {
        guard let provider = byID[tool.rawValue] else { preconditionFailure("No assistant provider is registered for “\(tool.rawValue)”") }
        return provider
    }

    /// The assistant used when nothing is chosen: the first one in the list.
    static var defaultTool: CLITool { all[0].tool }

    static func provider(id: String) -> (any AssistantProvider)? { byID[id] }
}
