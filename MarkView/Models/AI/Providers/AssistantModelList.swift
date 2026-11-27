import Foundation
import MarkViewCore

/// How an assistant's CLI lists the models of the signed-in account, with no prompt and no tokens spent. Present on the providers
/// whose account decides the models (`AssistantProvider.modelListing`): their pickers show the last list (`AssistantModelCache`).
protocol AssistantModelListing: Sendable {
    func listModels(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption]
}

/// ACP assistants (Cline, Copilot) list the account's models when a session opens (`ACPAssistant.listModels`).
struct ACPModelListing: AssistantModelListing {
    func listModels(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption] {
        try await ACPAssistant.listModels(tool, toolPath: toolPath)
    }
}

/// The models an assistant's account offers, as its CLI listed them last (`AssistantModelListing`). Settings refreshes the list when
/// it checks the assistant, and the model menus when none is kept yet.
enum AssistantModelCache {
    static func cached(_ id: String) -> [AIModelOption] {
        guard let data = Settings.standard.stored(Setting.cliModelList(id)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return rows.compactMap { row in
            guard let modelID = row["id"], !modelID.isEmpty else { return nil }
            return AIModelOption(id: modelID, name: row["name"] ?? modelID, detail: row["detail"] ?? "")
        }
    }

    /// Asks `tool`'s CLI at `toolPath` for the account's models and keeps them; nil when the assistant does not list its models.
    static func refresh(_ tool: CLITool, toolPath: String) async throws -> [AIModelOption]? {
        guard let listing = tool.provider.modelListing else { return nil }
        let models = try await listing.listModels(tool, toolPath: toolPath)
        store(models, for: tool.rawValue)
        return models
    }

    private static func store(_ models: [AIModelOption], for id: String) {
        guard !models.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: models.map { ["id": $0.id, "name": $0.name, "detail": $0.detail] })
        else { return }
        Settings.standard.set(data, for: Setting.cliModelList(id))
    }
}
