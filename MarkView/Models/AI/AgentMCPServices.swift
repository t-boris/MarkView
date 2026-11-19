import Combine
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Where an MCP service entry comes from for display and grouping.
enum MCPServiceSource: String, Hashable, Codable, Sendable {
    /// MarkView's built-in terminal/registration services (`markview`, `markview-browser`).
    case markviewBuiltin
    /// MarkView's separately registered control server (`markview-control`), shown only when configured.
    case markviewControl
    /// A third-party MCP server configured in the agent's own settings file.
    case agentConfig
    /// An agent built-in or plugin MCP server (e.g. Copilot's `github-mcp-server`).
    case agentBuiltin

    var badge: String {
        switch self {
        case .markviewBuiltin: return "MarkView"
        case .markviewControl: return "MarkView Control"
        case .agentConfig: return "Configured"
        case .agentBuiltin: return "Built-in"
        }
    }

    var sortRank: Int {
        switch self {
        case .markviewBuiltin: return 0
        case .markviewControl: return 1
        case .agentConfig: return 2
        case .agentBuiltin: return 3
        }
    }
}

/// One MCP service available to a specific assistant on this Mac.
struct AgentMCPService: Identifiable, Hashable, Sendable {
    let name: String
    let agentID: String
    let isEnabled: Bool
    let source: MCPServiceSource
    let configuredInAgent: Bool
    let detail: String
    let canToggle: Bool
    let note: String?

    var id: String { "\(agentID)::\(name)" }

    /// Short description for MarkView's own services.
    var summary: String? {
        switch name {
        case AgentMCPServer.markviewName:
            return "Project features, bugs, prototypes and lifecycle tools"
        case AgentMCPServer.markviewBrowserName:
            return "Drive MarkView's embedded browser tabs"
        case AgentMCPServer.markviewControlName:
            return "Remote window and UI control tools"
        default:
            return nil
        }
    }
}

/// Persisted per-agent MCP service selections on this Mac (`Setting.mcpServiceSelections`).
struct AgentMCPSelectionRecord: Codable, Equatable, Sendable {
    var selections: [String: Bool] = [:]
}

/// Dependency container so all MCP discovery, migration, and config writes are fully testable with fixtures.
struct AgentMCPEnvironment: Sendable {
    let settings: Settings
    let homeDirectory: URL
    let stash: MCPDisabledServerStash
    let resolveExecutable: @Sendable (CLITool) -> String?

    static var standard: AgentMCPEnvironment {
        AgentMCPEnvironment(
            settings: .standard,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            stash: MCPDisabledServerStash(),
            resolveExecutable: { CLIToolLocator.resolve($0) }
        )
    }

    init(
        settings: Settings = .standard,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        stash: MCPDisabledServerStash = MCPDisabledServerStash(),
        resolveExecutable: @escaping @Sendable (CLITool) -> String? = { CLIToolLocator.resolve($0) }
    ) {
        self.settings = settings
        self.homeDirectory = homeDirectory
        self.stash = stash
        self.resolveExecutable = resolveExecutable
    }
}

/// Core per-agent MCP service management:
/// - Migrates legacy agent-wide `browser.agentTools.<agent>` toggles (`DEC-004`).
/// - Discovers MarkView services, `markview-control` (when configured), and third-party/built-in MCP servers (`DEC-001`, `DEC-003`, `DEC-006`).
/// - Applies changes directly to each agent's own configuration on this Mac so disabled services cannot connect inside or outside MarkView (`DEC-002`, `DEC-003`).
/// - Leaves newly discovered services in their agent-configured state until changed (`Q-006`).
enum AgentMCPServices {
    /// Every supported assistant that supports MCP servers.
    static var supportedAgents: [CLITool] {
        CLITool.allCases.filter { $0.provider.mcp != nil || $0.provider.mcpConfig != nil }
    }

    /// Migrate the legacy agent-wide switch for all supported agents on this Mac (idempotent).
    static func migrateAllIfNeeded(env: AgentMCPEnvironment = .standard) {
        for tool in supportedAgents {
            migrateIfNeeded(for: tool, env: env)
        }
    }

    /// Migrate the legacy agent-wide switch for one agent (DEC-004):
    /// - When the existing agent-wide switch is off, initially disable `markview` and `markview-browser`,
    ///   including copies registered in the agent's own configuration, while leaving third-party services untouched.
    /// - When the existing agent-wide switch is on, preserve the existing state of every service.
    static func migrateIfNeeded(for tool: CLITool, env: AgentMCPEnvironment = .standard) {
        let migratedKey = Setting.mcpServiceMigrated(tool.rawValue)
        guard !env.settings.value(migratedKey) else { return }

        let legacyEnabled = env.settings.value(Setting.browserAgentTools(tool.rawValue))
        if !legacyEnabled {
            var record = loadSelections(for: tool, env: env)
            for serviceName in AgentMCPServer.launchServiceNames {
                if record.selections[serviceName] == nil {
                    record.selections[serviceName] = false
                }
                if record.selections[serviceName] == false {
                    do {
                        try tool.provider.mcpConfig?.setEnabled(
                            false,
                            serverName: serviceName,
                            home: env.homeDirectory,
                            stash: env.stash
                        )
                    } catch {
                        AppLog.browser.error("MCP migration could not update \(tool.displayName) config for \(serviceName): \(error.localizedDescription)")
                    }
                }
            }
            saveSelections(record, for: tool, env: env)
        }
        env.settings.set(true, for: migratedKey)
    }

    /// Saved explicit selections for `tool`.
    static func loadSelections(for tool: CLITool, env: AgentMCPEnvironment = .standard) -> AgentMCPSelectionRecord {
        let data = env.settings.value(Setting.mcpServiceSelections(tool.rawValue))
        guard !data.isEmpty else { return AgentMCPSelectionRecord() }
        return StoredJSON.decode(AgentMCPSelectionRecord.self, from: data, owner: "AgentMCPServices.\(tool.rawValue)")
            ?? AgentMCPSelectionRecord()
    }

    static func saveSelections(_ record: AgentMCPSelectionRecord, for tool: CLITool, env: AgentMCPEnvironment = .standard) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        env.settings.set(data, for: Setting.mcpServiceSelections(tool.rawValue))
    }

    /// Whether `serviceName` is enabled for `tool` (for launch arguments, Connect Agents registration, Cockpit, or relay).
    /// Runs one-time migration first and respects both saved selections and the agent's own configuration.
    static func isEnabled(_ serviceName: String, for tool: CLITool, env: AgentMCPEnvironment = .standard) -> Bool {
        migrateIfNeeded(for: tool, env: env)
        let canonical = tool.provider.mcpConfig?.canonicalName(for: serviceName) ?? serviceName
        let record = loadSelections(for: tool, env: env)
        if let explicit = record.selections[canonical] {
            if !explicit { return false }
            // Even if previously enabled in selections, check whether the agent's own config explicitly disabled it.
            if let configured = discoveredFromFiles(for: tool, env: env).first(where: { $0.name == canonical }),
               !configured.isEnabled {
                return false
            }
            return true
        }
        // No explicit selection yet: respect agent-configured state if present; MarkView launch services default to enabled.
        if let configured = discoveredFromFiles(for: tool, env: env).first(where: { $0.name == canonical }) {
            return configured.isEnabled
        }
        return AgentMCPServer.launchServiceNames.contains(canonical)
    }

    /// Filter a candidate list of MarkView launch servers to only those enabled for `tool`.
    static func enabledServers(from candidates: [AgentMCPServer], for tool: CLITool, env: AgentMCPEnvironment = .standard) -> [AgentMCPServer] {
        migrateIfNeeded(for: tool, env: env)
        return candidates.filter { isEnabled($0.name, for: tool, env: env) }
    }

    /// Synchronously discover all MCP services for `tool` from its configuration files (plus optional CLI discoveries).
    static func discoverServices(
        for tool: CLITool,
        cliDiscovered: [DiscoveredAgentMCPServer] = [],
        env: AgentMCPEnvironment = .standard
    ) -> [AgentMCPService] {
        migrateIfNeeded(for: tool, env: env)
        let record = loadSelections(for: tool, env: env)
        let fileDiscovered = discoveredFromFiles(for: tool, env: env)

        var mergedByName: [String: DiscoveredAgentMCPServer] = [:]
        // Start with CLI discoveries (includes built-in/plugin servers), then overlay file discoveries where toggleability is richer.
        for item in cliDiscovered {
            mergedByName[item.name] = item
        }
        for item in fileDiscovered {
            if let existing = mergedByName[item.name] {
                // File state is authoritative for configured entries; preserve built-in flag if it was only listed in settings.json.
                mergedByName[item.name] = DiscoveredAgentMCPServer(
                    name: item.name,
                    rawName: item.rawName,
                    isEnabled: item.isEnabled,
                    isBuiltin: existing.isBuiltin && item.isBuiltin,
                    detail: item.isBuiltin ? existing.detail : item.detail,
                    canToggle: item.canToggle || existing.canToggle,
                    note: item.note ?? existing.note
                )
            } else {
                mergedByName[item.name] = item
            }
        }

        var services: [AgentMCPService] = []
        var emitted: Set<String> = []

        // Always include MarkView's launch services (`markview`, `markview-browser`) for every supported agent.
        for name in AgentMCPServer.launchServiceNames {
            let discovered = mergedByName[name]
            let enabled: Bool
            if let discovered {
                if !discovered.isEnabled {
                    enabled = false
                } else {
                    enabled = record.selections[name] ?? true
                }
            } else {
                enabled = record.selections[name] ?? true
            }
            let detail = discovered?.detail ?? "MarkView terminal"
            services.append(AgentMCPService(
                name: name,
                agentID: tool.rawValue,
                isEnabled: enabled,
                source: .markviewBuiltin,
                configuredInAgent: discovered != nil,
                detail: detail,
                canToggle: true,
                note: discovered?.note
            ))
            emitted.insert(name)
        }

        // Include every other discovered service (`markview-control` if configured, third-party, built-in).
        for (name, discovered) in mergedByName where !emitted.contains(name) {
            let source: MCPServiceSource
            if name == AgentMCPServer.markviewControlName {
                source = .markviewControl
            } else if discovered.isBuiltin {
                source = .agentBuiltin
            } else {
                source = .agentConfig
            }
            services.append(AgentMCPService(
                name: name,
                agentID: tool.rawValue,
                isEnabled: discovered.isEnabled,
                source: source,
                configuredInAgent: true,
                detail: discovered.detail,
                canToggle: discovered.canToggle,
                note: discovered.note
            ))
            emitted.insert(name)
        }

        return services.sorted { lhs, rhs in
            if lhs.source.sortRank != rhs.source.sortRank {
                return lhs.source.sortRank < rhs.source.sortRank
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Discover all MCP services for `tool`, including async CLI discovery for built-in/plugin servers.
    static func discoverServicesIncludingCLI(
        for tool: CLITool,
        env: AgentMCPEnvironment = .standard
    ) async -> [AgentMCPService] {
        migrateIfNeeded(for: tool, env: env)
        var cliDiscovered: [DiscoveredAgentMCPServer] = []
        if let adapter = tool.provider.mcpConfig, let executable = env.resolveExecutable(tool) {
            cliDiscovered = await adapter.discoverFromCLI(executable: executable, home: env.homeDirectory)
        }
        return discoverServices(for: tool, cliDiscovered: cliDiscovered, env: env)
    }

    /// Enable or disable `serviceName` for `tool`, updating both the agent's own configuration on disk
    /// and MarkView's persisted per-agent selection. Throws if the agent's config file cannot be updated.
    static func setEnabled(
        _ enabled: Bool,
        service serviceName: String,
        for tool: CLITool,
        env: AgentMCPEnvironment = .standard
    ) throws {
        migrateIfNeeded(for: tool, env: env)
        let canonical = tool.provider.mcpConfig?.canonicalName(for: serviceName) ?? serviceName
        if let adapter = tool.provider.mcpConfig {
            try adapter.setEnabled(enabled, serverName: canonical, home: env.homeDirectory, stash: env.stash)
        }
        var record = loadSelections(for: tool, env: env)
        record.selections[canonical] = enabled
        saveSelections(record, for: tool, env: env)
    }

    private static func discoveredFromFiles(for tool: CLITool, env: AgentMCPEnvironment) -> [DiscoveredAgentMCPServer] {
        tool.provider.mcpConfig?.discoverFromFiles(home: env.homeDirectory, stash: env.stash) ?? []
    }
}

/// Observable store for UI views showing and toggling per-agent MCP services on this Mac.
@MainActor
final class AgentMCPServicesStore: ObservableObject {
    static let shared = AgentMCPServicesStore()

    @Published private(set) var servicesByAgent: [String: [AgentMCPService]] = [:]
    @Published private(set) var loadingAgents: Set<String> = []
    @Published private(set) var lastError: String?
    /// Agents whose MCP service selection changed while a session was running (cleared after restart).
    @Published private(set) var agentsNeedingRestart: Set<String> = []

    private let env: AgentMCPEnvironment
    private var cliCache: [String: [DiscoveredAgentMCPServer]] = [:]
    private let tasks = TaskBag()

    init(env: AgentMCPEnvironment = .standard) {
        self.env = env
        reloadFromFiles()
    }

    func services(for tool: CLITool) -> [AgentMCPService] {
        if let cached = servicesByAgent[tool.rawValue] {
            return cached
        }
        let discovered = AgentMCPServices.discoverServices(
            for: tool,
            cliDiscovered: cliCache[tool.rawValue] ?? [],
            env: env
        )
        servicesByAgent[tool.rawValue] = discovered
        return discovered
    }

    /// Fast synchronous reload from agent configuration files.
    func reloadFromFiles() {
        for tool in AgentMCPServices.supportedAgents {
            servicesByAgent[tool.rawValue] = AgentMCPServices.discoverServices(
                for: tool,
                cliDiscovered: cliCache[tool.rawValue] ?? [],
                env: env
            )
        }
    }

    /// Async refresh including CLI discovery (for built-in/plugin MCP servers).
    func refresh(for tool: CLITool) {
        let id = tool.rawValue
        let env = self.env
        loadingAgents.insert(id)
        tasks.store(Task { [weak self] in
            var cliItems: [DiscoveredAgentMCPServer] = []
            if let adapter = tool.provider.mcpConfig, let executable = env.resolveExecutable(tool) {
                cliItems = await adapter.discoverFromCLI(executable: executable, home: env.homeDirectory)
            }
            let services = await Task.detached(priority: .userInitiated) {
                AgentMCPServices.discoverServices(for: tool, cliDiscovered: cliItems, env: env)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.cliCache[id] = cliItems
            self.servicesByAgent[id] = services
            self.loadingAgents.remove(id)
        }, for: "mcp-refresh-\(id)")
    }

    func refreshAll() {
        for tool in AgentMCPServices.supportedAgents {
            refresh(for: tool)
        }
    }

    /// Toggle `serviceName` for `tool`. Returns nil on success or a user-facing error message on failure.
    @discardableResult
    func setEnabled(
        _ enabled: Bool,
        service serviceName: String,
        for tool: CLITool,
        sessionIsRunning: Bool
    ) -> String? {
        do {
            try AgentMCPServices.setEnabled(enabled, service: serviceName, for: tool, env: env)
            lastError = nil
            // Update CLI cache state if present so built-in servers immediately reflect the toggle.
            if var cached = cliCache[tool.rawValue],
               let idx = cached.firstIndex(where: { $0.name == serviceName }) {
                let old = cached[idx]
                cached[idx] = DiscoveredAgentMCPServer(
                    name: old.name,
                    rawName: old.rawName,
                    isEnabled: enabled,
                    isBuiltin: old.isBuiltin,
                    detail: old.detail,
                    canToggle: old.canToggle,
                    note: old.note
                )
                cliCache[tool.rawValue] = cached
            }
            servicesByAgent[tool.rawValue] = AgentMCPServices.discoverServices(
                for: tool,
                cliDiscovered: cliCache[tool.rawValue] ?? [],
                env: env
            )
            if sessionIsRunning {
                agentsNeedingRestart.insert(tool.rawValue)
            }
            return nil
        } catch {
            let message = error.localizedDescription
            lastError = message
            AppLog.browser.error("Failed to update MCP service \(serviceName) for \(tool.displayName): \(message)")
            reloadFromFiles()
            return message
        }
    }

    func clearRestartNotice(for tool: CLITool) {
        agentsNeedingRestart.remove(tool.rawValue)
    }

    func clearError() {
        lastError = nil
    }
}
