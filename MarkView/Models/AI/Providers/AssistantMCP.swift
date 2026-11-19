import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// One MCP server of this binary that an assistant can use: the browser tools or the project tools.
struct AgentMCPServer: Sendable {
    /// Canonical MarkView MCP server names shared across providers, launch, registration and settings.
    static let markviewName = "markview"
    static let markviewBrowserName = "markview-browser"
    static let markviewControlName = "markview-control"
    static let markviewBrowserTomlName = "markview_browser"
    /// Services MarkView supplies automatically at terminal launch and via Connect Agents.
    static let launchServiceNames: [String] = [markviewName, markviewBrowserName]

    /// Name in the assistant's settings (`markview-browser`, `markview`).
    let name: String
    /// The same server under a name that is valid as a TOML key (Codex keeps its servers in `config.toml`).
    let tomlName: String
    /// The argument that starts the server in the MarkView binary (`--mcp-browser`, `--mcp-project`).
    let flag: String
    /// "browser" or "project", for messages.
    let label: String
    /// The command and arguments that start the server for one window (per-session registration only).
    var command = ""
    var args: [String] = []
}

/// How MarkView's MCP servers are registered in an assistant's own settings. `AgentBrowserRegistration` interprets it.
enum AssistantMCPRegistration {
    /// The assistant's own `mcp` commands.
    case commands(CommandRegistration)
    /// One entry per server in a JSON settings file; everything else in the file is kept.
    case jsonFile(JSONFileRegistration)

    struct CommandRegistration {
        /// Arguments that remove a server (run before every add, so the entry points at this copy of MarkView).
        let remove: @Sendable (AgentMCPServer) -> [String]
        /// Arguments that add a server running `executable server.flag`.
        let add: @Sendable (AgentMCPServer, String) -> [String]
        /// Arguments that list the registered servers; when present a start only registers what the list lacks.
        let list: [String]?
        /// Where the registration lands, shown after Connect Agents.
        let location: String
        /// A failed add reports stdout and stderr (else stderr only).
        let reportsStdoutOnFailure: Bool
    }

    struct JSONFileRegistration {
        /// Path relative to the user's home directory (e.g. `.copilot/mcp-config.json`).
        let relativePath: String
        /// The entry for `server` running `executable`.
        let entry: @Sendable (_ executable: String, _ server: AgentMCPServer) -> [String: Any]
        /// An existing entry already runs `executable` and is enabled.
        let isCurrent: @Sendable (_ entry: [String: Any], _ executable: String) -> Bool
        /// Every start checks the file; false: only Connect Agents writes it.
        let checkedAtStart: Bool

        /// The settings file under the current user's home folder.
        var file: URL { file(in: FileManager.default.homeDirectoryForCurrentUser) }

        /// The settings file under `home` (for isolated fixture tests).
        func file(in home: URL) -> URL { home.appendingPathComponent(relativePath) }
    }
}

/// One MCP server discovered in an assistant's own configuration or CLI list.
struct DiscoveredAgentMCPServer: Hashable, Sendable {
    /// Canonical service name (e.g. `markview-browser` even when stored as `markview_browser` in Codex TOML).
    let name: String
    /// Name as written in the agent's own configuration.
    let rawName: String
    /// Enabled state in the agent's own configuration.
    let isEnabled: Bool
    /// True for agent built-in or plugin servers not defined as user entries in the agent's config file.
    let isBuiltin: Bool
    /// Human-readable config location or source label.
    let detail: String
    /// Whether MarkView can safely toggle this server in the agent's own configuration.
    let canToggle: Bool
    /// Optional note explaining a non-toggleable or special state.
    let note: String?

    init(
        name: String,
        rawName: String? = nil,
        isEnabled: Bool,
        isBuiltin: Bool = false,
        detail: String,
        canToggle: Bool = true,
        note: String? = nil
    ) {
        self.name = name
        self.rawName = rawName ?? name
        self.isEnabled = isEnabled
        self.isBuiltin = isBuiltin
        self.detail = detail
        self.canToggle = canToggle
        self.note = note
    }
}

/// Errors encountered when reading or updating an assistant's own MCP configuration file.
enum MCPConfigError: LocalizedError, Equatable, Sendable {
    case unreadableJSON(path: String)
    case unreadableFile(path: String, reason: String)
    case writeFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadableJSON(let path):
            return "\(path) is not a valid JSON object; left unchanged."
        case .unreadableFile(let path, let reason):
            return "Could not read \(path): \(reason)"
        case .writeFailed(let path, let reason):
            return "Could not update \(path): \(reason)"
        }
    }
}

/// Persists original server JSON entries removed from agents whose own configuration has no global `disabled` flag
/// (such as Claude Code's `~/.claude.json`), so re-enabling restores the exact configuration without losing headers,
/// environment variables, or arguments. Written with 0600 permissions via `AtomicFile`.
struct MCPDisabledServerStash: Sendable {
    let fileURL: URL

    init(fileURL: URL = MCPDisabledServerStash.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MarkView", isDirectory: true).appendingPathComponent("mcp-disabled-servers.json")
    }

    func stashedServers(for agentID: String) -> [String: [String: Any]] {
        guard let root = try? readRoot(),
              let agents = root["agents"] as? [String: Any],
              let map = agents[agentID] as? [String: [String: Any]] else {
            return [:]
        }
        return map
    }

    func entry(serverName: String, for agentID: String) -> [String: Any]? {
        stashedServers(for: agentID)[serverName]
    }

    func stash(serverName: String, definition: [String: Any], for agentID: String) throws {
        var root = try readRoot()
        var agents = root["agents"] as? [String: Any] ?? [:]
        var map = agents[agentID] as? [String: Any] ?? [:]
        map[serverName] = definition
        agents[agentID] = map
        root["schema"] = 1
        root["agents"] = agents
        try writeRoot(root)
    }

    func remove(serverName: String, for agentID: String) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        var root = try readRoot()
        guard var agents = root["agents"] as? [String: Any],
              var map = agents[agentID] as? [String: Any],
              map.removeValue(forKey: serverName) != nil else { return }
        if map.isEmpty {
            agents.removeValue(forKey: agentID)
        } else {
            agents[agentID] = map
        }
        root["schema"] = 1
        root["agents"] = agents
        try writeRoot(root)
    }

    private func readRoot() throws -> [String: Any] {
        try JSONMCPConfigHelper.readRoot(from: fileURL)
    }

    private func writeRoot(_ root: [String: Any]) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try AtomicFile.write(data, to: fileURL, permissions: 0o600)
        } catch let error as MCPConfigError {
            throw error
        } catch {
            throw MCPConfigError.writeFailed(path: fileURL.path, reason: error.localizedDescription)
        }
    }
}

/// How one assistant's own MCP configuration is discovered and updated on disk (and optionally via CLI).
/// Each supported assistant implements its own adapter inside `Models/AI/Providers/` (`AR-35`).
protocol AssistantMCPConfigAdapter: Sendable {
    /// Normalize an agent-specific config key to MarkView's canonical service name.
    func canonicalName(for rawName: String) -> String
    /// Discover MCP servers directly from the agent's configuration files under `home` (and `stash`).
    func discoverFromFiles(home: URL, stash: MCPDisabledServerStash) -> [DiscoveredAgentMCPServer]
    /// Optionally discover additional built-in or plugin MCP servers via the agent's CLI.
    func discoverFromCLI(executable: String, home: URL) async -> [DiscoveredAgentMCPServer]
    /// Apply an enabled/disabled selection for `serverName` to the agent's own configuration under `home`.
    func setEnabled(_ enabled: Bool, serverName: String, home: URL, stash: MCPDisabledServerStash) throws
}

extension AssistantMCPConfigAdapter {
    func canonicalName(for rawName: String) -> String { rawName }
    func discoverFromCLI(executable: String, home: URL) async -> [DiscoveredAgentMCPServer] { [] }
}

/// Shared JSON file helpers for agent MCP configurations (preserves unrelated keys, writes atomically).
enum JSONMCPConfigHelper {
    static func readRoot(from file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw MCPConfigError.unreadableFile(path: file.path, reason: error.localizedDescription)
        }
        let trimmed = data.filter { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        if trimmed.isEmpty { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MCPConfigError.unreadableJSON(path: file.path)
        }
        return object
    }

    static func writeRoot(_ root: [String: Any], to file: URL) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try AtomicFile.write(data, to: file)
        } catch {
            throw MCPConfigError.writeFailed(path: file.path, reason: error.localizedDescription)
        }
    }

    /// Discover servers from a JSON file whose `mcpServers` entries use `"disabled": true/false` (Cline, Antigravity).
    static func discoverDisabledFlagServers(from file: URL, detail: String) -> [DiscoveredAgentMCPServer] {
        guard let root = try? readRoot(from: file),
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted().compactMap { name in
            guard let entry = servers[name] as? [String: Any] else { return nil }
            let disabled = (entry["disabled"] as? Bool) == true
            return DiscoveredAgentMCPServer(name: name, isEnabled: !disabled, detail: detail)
        }
    }

    /// Set `"disabled": !enabled` on `mcpServers[serverName]` if present, keeping every other key and server intact.
    static func setDisabledFlag(_ disabled: Bool, serverName: String, in file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        var root = try readRoot(from: file)
        guard var servers = root["mcpServers"] as? [String: Any],
              var entry = servers[serverName] as? [String: Any] else { return }
        entry["disabled"] = disabled
        servers[serverName] = entry
        root["mcpServers"] = servers
        try writeRoot(root, to: file)
    }
}

/// Line-preserving TOML reader and updater for Codex's `~/.codex/config.toml` `[mcp_servers.<name>]` sections.
/// Preserves comments, formatting, subtables (such as `[mcp_servers.<name>.env]`), and every unrelated section.
enum CodexTOMLMCPHelper {
    struct ParsedServer: Equatable, Sendable {
        let rawName: String
        let isEnabled: Bool
    }

    /// Parse all `[mcp_servers.<name>]` tables in `text` (ignoring subtables like `[mcp_servers.<name>.env]`).
    static func parseServers(in text: String) -> [ParsedServer] {
        let lines = splitLines(text)
        var order: [String] = []
        var enabledByName: [String: Bool] = [:]
        var activeServer: String?

        for line in lines {
            if let header = parseTableHeader(line) {
                if header.count == 2, header[0] == "mcp_servers" {
                    let name = header[1]
                    if enabledByName[name] == nil {
                        order.append(name)
                        enabledByName[name] = true
                    }
                    activeServer = name
                } else {
                    activeServer = nil
                }
                continue
            }
            guard let server = activeServer else { continue }
            if let value = parseEnabledAssignment(line) {
                enabledByName[server] = value
            }
        }
        return order.map { ParsedServer(rawName: $0, isEnabled: enabledByName[$0] ?? true) }
    }

    /// Return `text` updated so every `[mcp_servers.<key>]` table whose key is in `targetKeys` has `enabled = <enabled>`.
    /// Does not add new tables if none match (Codex rejects an `[mcp_servers.<name>]` table without transport).
    static func updatingEnabled(_ enabled: Bool, forKeys targetKeys: Set<String>, in text: String) -> (updated: String, changed: Bool) {
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = splitLines(text)
        var sections: [(headerIndex: Int, endIndex: Int, enabledLineIndex: Int?)] = []

        var i = 0
        while i < lines.count {
            if let header = parseTableHeader(lines[i]), header.count == 2, header[0] == "mcp_servers", targetKeys.contains(header[1]) {
                let start = i
                var end = i + 1
                var enabledIdx: Int?
                while end < lines.count {
                    if parseTableHeader(lines[end]) != nil { break }
                    if parseEnabledAssignment(lines[end]) != nil { enabledIdx = end }
                    end += 1
                }
                sections.append((headerIndex: start, endIndex: end, enabledLineIndex: enabledIdx))
                i = end
            } else {
                i += 1
            }
        }

        guard !sections.isEmpty else { return (text, false) }
        var changed = false

        // Apply from bottom to top so inserted lines do not shift earlier indices.
        for section in sections.reversed() {
            if let idx = section.enabledLineIndex {
                let replacement = replacingEnabledValue(in: lines[idx], with: enabled)
                if replacement != lines[idx] {
                    lines[idx] = replacement
                    changed = true
                }
            } else if !enabled {
                // Insert `enabled = false` after the last non-blank line inside this section.
                var insertAt = section.headerIndex + 1
                for cursor in (section.headerIndex + 1)..<section.endIndex {
                    if !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                        insertAt = cursor + 1
                    }
                }
                lines.insert("enabled = false", at: insertAt)
                changed = true
            }
        }

        guard changed else { return (text, false) }
        var result = lines.joined(separator: "\n")
        if hadTrailingNewline || !result.hasSuffix("\n") {
            result += "\n"
        }
        return (result, true)
    }

    private static func splitLines(_ text: String) -> [String] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.hasSuffix("\n") {
            normalized.removeLast()
        }
        return normalized.isEmpty ? [] : normalized.components(separatedBy: "\n")
    }

    /// Parse a TOML `[a.b."c"]` table header (not `[[array]]`). Returns dotted key segments or nil.
    static func parseTableHeader(_ line: String) -> [String]? {
        let stripped = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard stripped.hasPrefix("["), !stripped.hasPrefix("[["), stripped.hasSuffix("]") else { return nil }
        let inner = String(stripped.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }
        return splitTOMLKeyPath(inner)
    }

    private static func parseEnabledAssignment(_ line: String) -> Bool? {
        let code = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard let eq = code.firstIndex(of: "=") else { return nil }
        let key = code[..<eq].trimmingCharacters(in: .whitespaces)
        guard key == "enabled" else { return nil }
        let value = code[code.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value == "true" { return true }
        if value == "false" { return false }
        return nil
    }

    private static func replacingEnabledValue(in line: String, with enabled: Bool) -> String {
        let leadingWhitespace = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let comment: String
        if let hashIndex = commentStartIndex(in: line) {
            comment = " " + String(line[hashIndex...]).trimmingCharacters(in: .whitespaces)
        } else {
            comment = ""
        }
        return "\(leadingWhitespace)enabled = \(enabled ? "true" : "false")\(comment)"
    }

    private static func stripComment(_ line: String) -> String {
        if let idx = commentStartIndex(in: line) {
            return String(line[..<idx])
        }
        return line
    }

    private static func commentStartIndex(in line: String) -> String.Index? {
        var inDouble = false
        var inSingle = false
        var escaped = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if escaped {
                escaped = false
            } else if inDouble {
                if c == "\\" { escaped = true }
                else if c == "\"" { inDouble = false }
            } else if inSingle {
                if c == "'" { inSingle = false }
            } else {
                if c == "\"" { inDouble = true }
                else if c == "'" { inSingle = true }
                else if c == "#" { return i }
            }
            i = line.index(after: i)
        }
        return nil
    }

    private static func splitTOMLKeyPath(_ path: String) -> [String]? {
        var segments: [String] = []
        var i = path.startIndex
        while i < path.endIndex {
            while i < path.endIndex && (path[i] == " " || path[i] == "\t") { i = path.index(after: i) }
            guard i < path.endIndex else { break }
            if path[i] == "\"" {
                i = path.index(after: i)
                var token = ""
                var escaped = false
                var closed = false
                while i < path.endIndex {
                    let c = path[i]
                    if escaped {
                        token.append(c)
                        escaped = false
                    } else if c == "\\" {
                        escaped = true
                    } else if c == "\"" {
                        closed = true
                        i = path.index(after: i)
                        break
                    } else {
                        token.append(c)
                    }
                    i = path.index(after: i)
                }
                guard closed else { return nil }
                segments.append(token)
            } else if path[i] == "'" {
                i = path.index(after: i)
                var token = ""
                var closed = false
                while i < path.endIndex {
                    let c = path[i]
                    if c == "'" {
                        closed = true
                        i = path.index(after: i)
                        break
                    }
                    token.append(c)
                    i = path.index(after: i)
                }
                guard closed else { return nil }
                segments.append(token)
            } else {
                var token = ""
                while i < path.endIndex && path[i] != "." && path[i] != " " && path[i] != "\t" {
                    token.append(path[i])
                    i = path.index(after: i)
                }
                guard !token.isEmpty else { return nil }
                segments.append(token)
            }
            while i < path.endIndex && (path[i] == " " || path[i] == "\t") { i = path.index(after: i) }
            if i < path.endIndex {
                guard path[i] == "." else { return nil }
                i = path.index(after: i)
            }
        }
        return segments.isEmpty ? nil : segments
    }
}
