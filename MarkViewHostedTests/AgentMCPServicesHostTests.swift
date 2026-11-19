import Foundation
import XCTest
@testable import MarkView
import MarkViewCore

final class AgentMCPServicesHostTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let stashURL: URL
        let suiteName: String
        let defaults: UserDefaults
        let env: AgentMCPEnvironment

        init(resolveExecutable: @escaping @Sendable (CLITool) -> String? = { _ in nil }) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mv-mcp-tests-" + UUID().uuidString, isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            stashURL = root.appendingPathComponent("stash/mcp-disabled-servers.json")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            suiteName = "com.markview.mcp-tests." + UUID().uuidString
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            env = AgentMCPEnvironment(
                settings: Settings(defaults),
                homeDirectory: home,
                stash: MCPDisabledServerStash(fileURL: stashURL),
                resolveExecutable: resolveExecutable
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        func write(_ relativePath: String, content: String) throws {
            let url = home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }

        func writeJSON(_ relativePath: String, object: [String: Any]) throws {
            let url = home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
        }

        func readJSON(_ relativePath: String) throws -> [String: Any] {
            let url = home.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: url)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func readText(_ relativePath: String) throws -> String {
            try String(contentsOf: home.appendingPathComponent(relativePath), encoding: .utf8)
        }
    }

    private func tool(_ id: String) throws -> CLITool {
        try XCTUnwrap(CLITool(rawValue: id))
    }

    // MARK: - I-1 & I-2: Discovery and applying selections across all 5 supported agents

    func testDiscoverAndToggleAllSupportedAgentsWithFixtures() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        // 1. Claude Code (~/.claude.json + stash)
        let claude = try tool("claude")
        try fixture.writeJSON(".claude.json", object: [
            "theme": "dark",
            "oauthAccount": ["email": "user@example.com"],
            "mcpServers": [
                "Neon": ["type": "http", "url": "https://mcp.neon.tech", "headers": ["Authorization": "Bearer secret"]],
                "markview-browser": ["type": "stdio", "command": "/Applications/MarkView.app/Contents/MacOS/MarkView", "args": ["--mcp-browser"]],
                "markview-control": ["type": "stdio", "command": "/Applications/MarkView.app/Contents/MacOS/MarkView", "args": ["--mcp-control"]],
            ],
        ])

        let claudeInitial = AgentMCPServices.discoverServices(for: claude, env: fixture.env)
        XCTAssertEqual(Set(claudeInitial.map(\.name)), ["markview", "markview-browser", "markview-control", "Neon"])
        XCTAssertTrue(claudeInitial.allSatisfy(\.isEnabled))

        // Disable third-party Neon and markview-control independently
        try AgentMCPServices.setEnabled(false, service: "Neon", for: claude, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "markview-control", for: claude, env: fixture.env)

        let claudeJSONAfterDisable = try fixture.readJSON(".claude.json")
        XCTAssertEqual(claudeJSONAfterDisable["theme"] as? String, "dark")
        let claudeServersAfterDisable = try XCTUnwrap(claudeJSONAfterDisable["mcpServers"] as? [String: Any])
        XCTAssertNil(claudeServersAfterDisable["Neon"], "Disabled server must be removed from ~/.claude.json so external launches cannot connect")
        XCTAssertNil(claudeServersAfterDisable["markview-control"])
        XCTAssertNotNil(claudeServersAfterDisable["markview-browser"], "Unrelated servers must stay untouched")

        let claudeAfterDisable = AgentMCPServices.discoverServices(for: claude, env: fixture.env)
        XCTAssertEqual(claudeAfterDisable.first(where: { $0.name == "Neon" })?.isEnabled, false)
        XCTAssertEqual(claudeAfterDisable.first(where: { $0.name == "markview-control" })?.isEnabled, false)
        XCTAssertEqual(claudeAfterDisable.first(where: { $0.name == "markview-browser" })?.isEnabled, true)

        // Re-enable Neon: exact config (headers, url, type) must be restored without altering unrelated settings
        try AgentMCPServices.setEnabled(true, service: "Neon", for: claude, env: fixture.env)
        let claudeJSONAfterEnable = try fixture.readJSON(".claude.json")
        XCTAssertEqual(claudeJSONAfterEnable["theme"] as? String, "dark")
        let claudeServersAfterEnable = try XCTUnwrap(claudeJSONAfterEnable["mcpServers"] as? [String: Any])
        let restoredNeon = try XCTUnwrap(claudeServersAfterEnable["Neon"] as? [String: Any])
        XCTAssertEqual(restoredNeon["url"] as? String, "https://mcp.neon.tech")
        XCTAssertEqual((restoredNeon["headers"] as? [String: String])?["Authorization"], "Bearer secret")
        XCTAssertNil(claudeServersAfterEnable["markview-control"], "Other disabled server must stay disabled")

        // 2. Codex (~/.codex/config.toml)
        let codex = try tool("codex")
        let codexToml = """
        # Top comment
        model = "gpt-5.4"

        [projects."/Users/dev/app"]
        trust_level = "trusted"

        [mcp_servers.markview_browser]
        command = "/Applications/MarkView.app/Contents/MacOS/MarkView"
        args = ["--mcp-browser"]

        [mcp_servers.markview-control]
        command = "/Applications/MarkView.app/Contents/MacOS/MarkView"
        args = ["--mcp-control"]

        [mcp_servers.node_repl]
        command = "/usr/local/bin/node_repl"

        [mcp_servers.node_repl.env]
        FOO = "bar"

        [mcp_servers.openaiDeveloperDocs]
        url = "https://developers.openai.com/mcp"
        enabled = true # keep comment
        """
        try fixture.write(".codex/config.toml", content: codexToml)

        let codexInitial = AgentMCPServices.discoverServices(for: codex, env: fixture.env)
        XCTAssertEqual(Set(codexInitial.map(\.name)), ["markview", "markview-browser", "markview-control", "node_repl", "openaiDeveloperDocs"])
        XCTAssertTrue(codexInitial.allSatisfy(\.isEnabled))

        try AgentMCPServices.setEnabled(false, service: "markview-browser", for: codex, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "markview-control", for: codex, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "node_repl", for: codex, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "openaiDeveloperDocs", for: codex, env: fixture.env)

        let codexTextAfterDisable = try fixture.readText(".codex/config.toml")
        XCTAssertTrue(codexTextAfterDisable.contains("# Top comment"))
        XCTAssertTrue(codexTextAfterDisable.contains("[projects.\"/Users/dev/app\"]"))
        XCTAssertTrue(codexTextAfterDisable.contains("[mcp_servers.node_repl.env]\nFOO = \"bar\""))
        XCTAssertTrue(codexTextAfterDisable.contains("enabled = false # keep comment"))

        let codexAfterDisable = AgentMCPServices.discoverServices(for: codex, env: fixture.env)
        XCTAssertEqual(codexAfterDisable.first(where: { $0.name == "markview-browser" })?.isEnabled, false)
        XCTAssertEqual(codexAfterDisable.first(where: { $0.name == "markview-control" })?.isEnabled, false)
        XCTAssertEqual(codexAfterDisable.first(where: { $0.name == "node_repl" })?.isEnabled, false)
        XCTAssertEqual(codexAfterDisable.first(where: { $0.name == "openaiDeveloperDocs" })?.isEnabled, false)
        XCTAssertEqual(codexAfterDisable.first(where: { $0.name == "markview" })?.isEnabled, true)

        try AgentMCPServices.setEnabled(true, service: "node_repl", for: codex, env: fixture.env)
        let codexAfterReenable = AgentMCPServices.discoverServices(for: codex, env: fixture.env)
        XCTAssertEqual(codexAfterReenable.first(where: { $0.name == "node_repl" })?.isEnabled, true)
        XCTAssertEqual(codexAfterReenable.first(where: { $0.name == "markview-browser" })?.isEnabled, false)

        // 3. Cline (~/.cline/data/settings/cline_mcp_settings.json)
        let cline = try tool("cline")
        try fixture.writeJSON(".cline/data/settings/cline_mcp_settings.json", object: [
            "otherKey": 42,
            "mcpServers": [
                "cloud-run": ["transport": ["type": "stdio", "command": "npx"], "disabled": false, "timeout": 60],
                "markview": ["transport": ["type": "stdio", "command": "/MV", "args": ["--mcp-project"]], "disabled": false],
                "markview-browser": ["transport": ["type": "stdio", "command": "/MV", "args": ["--mcp-browser"]], "disabled": false],
                "markview-control": ["transport": ["type": "stdio", "command": "/MV", "args": ["--mcp-control"]], "disabled": false],
            ],
        ])

        try AgentMCPServices.setEnabled(false, service: "cloud-run", for: cline, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "markview-control", for: cline, env: fixture.env)
        let clineJSON = try fixture.readJSON(".cline/data/settings/cline_mcp_settings.json")
        XCTAssertEqual(clineJSON["otherKey"] as? Int, 42)
        let clineServers = try XCTUnwrap(clineJSON["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(clineServers["cloud-run"]?["disabled"] as? Bool, true)
        XCTAssertEqual(clineServers["cloud-run"]?["timeout"] as? Int, 60)
        XCTAssertEqual(clineServers["markview-control"]?["disabled"] as? Bool, true)
        XCTAssertEqual(clineServers["markview"]?["disabled"] as? Bool, false)

        try AgentMCPServices.setEnabled(true, service: "cloud-run", for: cline, env: fixture.env)
        let clineRestored = try XCTUnwrap((try fixture.readJSON(".cline/data/settings/cline_mcp_settings.json"))["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(clineRestored["cloud-run"]?["disabled"] as? Bool, false)
        XCTAssertEqual(clineRestored["cloud-run"]?["timeout"] as? Int, 60)

        // 4. Copilot (~/.copilot/mcp-config.json + ~/.copilot/settings.json)
        let copilot = try tool("copilot")
        try fixture.writeJSON(".copilot/mcp-config.json", object: [
            "mcpServers": [
                "markview-browser": ["type": "local", "command": "/MV", "args": ["--mcp-browser"], "tools": ["*"]],
                "markview-control": ["type": "local", "command": "/MV", "args": ["--mcp-control"], "tools": ["*"]],
                "third-party": ["type": "http", "url": "https://example.invalid/mcp"],
            ],
        ])
        try fixture.writeJSON(".copilot/settings.json", object: [
            "model": "gpt-5",
            "theme": "auto",
        ])

        try AgentMCPServices.setEnabled(false, service: "third-party", for: copilot, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "markview-control", for: copilot, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "github-mcp-server", for: copilot, env: fixture.env)

        let copilotSettings = try fixture.readJSON(".copilot/settings.json")
        XCTAssertEqual(copilotSettings["model"] as? String, "gpt-5")
        XCTAssertEqual(copilotSettings["theme"] as? String, "auto")
        let disabledList = Set(copilotSettings["disabledMcpServers"] as? [String] ?? [])
        XCTAssertEqual(disabledList, ["third-party", "markview-control", "github-mcp-server"])

        try AgentMCPServices.setEnabled(true, service: "third-party", for: copilot, env: fixture.env)
        let copilotAfterEnable = try fixture.readJSON(".copilot/settings.json")
        XCTAssertEqual(Set(copilotAfterEnable["disabledMcpServers"] as? [String] ?? []), ["markview-control", "github-mcp-server"])

        // 5. Antigravity (~/.gemini/config/mcp_config.json)
        let agy = try tool("antigravity")
        try fixture.writeJSON(".gemini/config/mcp_config.json", object: [
            "mcpServers": [
                "markview": ["command": "/MV", "args": ["--mcp-project"], "disabled": false],
                "markview-browser": ["command": "/MV", "args": ["--mcp-browser"], "disabled": false],
                "markview-control": ["command": "/MV", "args": ["--mcp-control"], "disabled": false],
                "tolaria": ["command": "node", "args": ["server.js"], "disabled": false],
            ],
        ])

        try AgentMCPServices.setEnabled(false, service: "tolaria", for: agy, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "markview-control", for: agy, env: fixture.env)
        let agyServers = try XCTUnwrap((try fixture.readJSON(".gemini/config/mcp_config.json"))["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(agyServers["tolaria"]?["disabled"] as? Bool, true)
        XCTAssertEqual(agyServers["markview-control"]?["disabled"] as? Bool, true)
        XCTAssertEqual(agyServers["markview"]?["disabled"] as? Bool, false)

        try AgentMCPServices.setEnabled(true, service: "tolaria", for: agy, env: fixture.env)
        let agyRestored = try XCTUnwrap((try fixture.readJSON(".gemini/config/mcp_config.json"))["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(agyRestored["tolaria"]?["disabled"] as? Bool, false)
    }

    // MARK: - Q-004, Q-006, DEC-006: Per-agent isolation & newly discovered services

    func testPerAgentIsolationAndNewlyDiscoveredServicePreservation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let copilot = try tool("copilot")
        let claude = try tool("claude")

        // markview-control must NOT appear when not configured for an agent
        let copilotBefore = AgentMCPServices.discoverServices(for: copilot, env: fixture.env)
        XCTAssertNil(copilotBefore.first(where: { $0.name == "markview-control" }))

        // Disable markview-browser only for Copilot
        try AgentMCPServices.setEnabled(false, service: "markview-browser", for: copilot, env: fixture.env)
        XCTAssertFalse(AgentMCPServices.isEnabled("markview-browser", for: copilot, env: fixture.env))
        XCTAssertTrue(AgentMCPServices.isEnabled("markview", for: copilot, env: fixture.env))
        XCTAssertTrue(AgentMCPServices.isEnabled("markview-browser", for: claude, env: fixture.env),
                      "Disabling a service for one agent must not affect other agents")

        // Newly discovered services added AFTER initial configuration keep their agent-configured state (Q-006)
        try fixture.writeJSON(".copilot/mcp-config.json", object: [
            "mcpServers": [
                "newly-added-enabled": ["type": "local", "command": "/bin/echo"],
                "newly-added-disabled": ["type": "local", "command": "/bin/echo"],
                "markview-control": ["type": "local", "command": "/MV", "args": ["--mcp-control"]],
            ],
        ])
        var copilotSettings = try fixture.readJSON(".copilot/settings.json")
        var disabled = copilotSettings["disabledMcpServers"] as? [String] ?? []
        disabled.append("newly-added-disabled")
        copilotSettings["disabledMcpServers"] = disabled
        try fixture.writeJSON(".copilot/settings.json", object: copilotSettings)

        let copilotAfter = AgentMCPServices.discoverServices(for: copilot, env: fixture.env)
        XCTAssertEqual(copilotAfter.first(where: { $0.name == "newly-added-enabled" })?.isEnabled, true)
        XCTAssertEqual(copilotAfter.first(where: { $0.name == "newly-added-disabled" })?.isEnabled, false)
        XCTAssertEqual(copilotAfter.first(where: { $0.name == "markview-control" })?.isEnabled, true)
        XCTAssertEqual(copilotAfter.first(where: { $0.name == "markview-browser" })?.isEnabled, false)
    }

    // MARK: - I-3 & DEC-004: Legacy agent-wide switch migration

    func testLegacyMigrationWhenSwitchIsOffAndWhenSwitchIsOn() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let copilot = try tool("copilot")
        let claude = try tool("claude")
        let codex = try tool("codex")
        let cline = try tool("cline")
        let agy = try tool("antigravity")

        // Prepare pre-existing registered MarkView copies + third-party servers for all 5 agents
        try fixture.writeJSON(".copilot/mcp-config.json", object: [
            "mcpServers": [
                "markview": ["type": "local", "command": "/MV", "args": ["--mcp-project"]],
                "markview-browser": ["type": "local", "command": "/MV", "args": ["--mcp-browser"]],
                "corp-mcp": ["type": "http", "url": "https://corp.invalid/mcp"],
            ],
        ])
        try fixture.writeJSON(".claude.json", object: [
            "mcpServers": [
                "markview": ["type": "stdio", "command": "/MV", "args": ["--mcp-project"]],
                "markview-browser": ["type": "stdio", "command": "/MV", "args": ["--mcp-browser"]],
                "third-party": ["type": "stdio", "command": "npx"],
            ],
        ])
        try fixture.write(".codex/config.toml", content: """
        [mcp_servers.markview]
        command = "/MV"
        args = ["--mcp-project"]

        [mcp_servers.markview_browser]
        command = "/MV"
        args = ["--mcp-browser"]

        [mcp_servers.third_party]
        command = "npx"
        """)
        try fixture.writeJSON(".cline/data/settings/cline_mcp_settings.json", object: [
            "mcpServers": [
                "markview": ["transport": ["type": "stdio", "command": "/MV"], "disabled": false],
                "markview-browser": ["transport": ["type": "stdio", "command": "/MV"], "disabled": true],
                "third-party": ["transport": ["type": "stdio", "command": "npx"], "disabled": false],
            ],
        ])
        try fixture.writeJSON(".gemini/config/mcp_config.json", object: [
            "mcpServers": [
                "markview": ["command": "/MV", "args": ["--mcp-project"], "disabled": false],
                "markview-browser": ["command": "/MV", "args": ["--mcp-browser"], "disabled": false],
                "third-party": ["command": "npx", "disabled": false],
            ],
        ])

        // Legacy switches: Copilot, Claude, Codex, Antigravity OFF; Cline ON (with markview-browser already disabled in its config)
        fixture.env.settings.set(false, for: copilot.agentToolsKey)
        fixture.env.settings.set(false, for: claude.agentToolsKey)
        fixture.env.settings.set(false, for: codex.agentToolsKey)
        fixture.env.settings.set(false, for: agy.agentToolsKey)
        fixture.env.settings.set(true, for: cline.agentToolsKey)

        AgentMCPServices.migrateAllIfNeeded(env: fixture.env)

        // Agents whose switch was OFF must have markview and markview-browser disabled in selections AND own configs; third-party untouched
        for offAgent in [copilot, claude, codex, agy] {
            XCTAssertFalse(AgentMCPServices.isEnabled("markview", for: offAgent, env: fixture.env), "\(offAgent.rawValue) markview")
            XCTAssertFalse(AgentMCPServices.isEnabled("markview-browser", for: offAgent, env: fixture.env), "\(offAgent.rawValue) markview-browser")
        }

        // Verify agent configs on disk (external launch behavior)
        let copilotDisabled = Set((try fixture.readJSON(".copilot/settings.json"))["disabledMcpServers"] as? [String] ?? [])
        XCTAssertEqual(copilotDisabled, ["markview", "markview-browser"])
        XCTAssertTrue(AgentMCPServices.discoverServices(for: copilot, env: fixture.env).first(where: { $0.name == "corp-mcp" })?.isEnabled == true)

        let claudeServers = try XCTUnwrap((try fixture.readJSON(".claude.json"))["mcpServers"] as? [String: Any])
        XCTAssertNil(claudeServers["markview"])
        XCTAssertNil(claudeServers["markview-browser"])
        XCTAssertNotNil(claudeServers["third-party"])

        let codexParsed = Dictionary(uniqueKeysWithValues: CodexTOMLMCPHelper.parseServers(in: try fixture.readText(".codex/config.toml")).map { ($0.rawName, $0.isEnabled) })
        XCTAssertEqual(codexParsed["markview"], false)
        XCTAssertEqual(codexParsed["markview_browser"], false)
        XCTAssertEqual(codexParsed["third_party"], true)

        let agyServers = try XCTUnwrap((try fixture.readJSON(".gemini/config/mcp_config.json"))["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(agyServers["markview"]?["disabled"] as? Bool, true)
        XCTAssertEqual(agyServers["markview-browser"]?["disabled"] as? Bool, true)
        XCTAssertEqual(agyServers["third-party"]?["disabled"] as? Bool, false)

        // Cline's switch was ON: existing states preserved (markview enabled, markview-browser stays disabled, third-party enabled)
        XCTAssertTrue(AgentMCPServices.isEnabled("markview", for: cline, env: fixture.env))
        XCTAssertFalse(AgentMCPServices.isEnabled("markview-browser", for: cline, env: fixture.env))
        let clineServers = try XCTUnwrap((try fixture.readJSON(".cline/data/settings/cline_mcp_settings.json"))["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(clineServers["markview"]?["disabled"] as? Bool, false)
        XCTAssertEqual(clineServers["markview-browser"]?["disabled"] as? Bool, true)
        XCTAssertEqual(clineServers["third-party"]?["disabled"] as? Bool, false)
    }

    // MARK: - I-4 & DEC-005: Connect Agents registration honors selections and reports skipped services

    func testRegistrationHonorsSelectionsAndReportsSkippedServices() async throws {
        let fixture = try Fixture(resolveExecutable: { "/fake/bin/\($0.binaryName)" })
        defer { fixture.cleanup() }

        let copilot = try tool("copilot")
        let claude = try tool("claude")
        let codex = try tool("codex")
        let cline = try tool("cline")

        try AgentMCPServices.setEnabled(false, service: "markview-browser", for: copilot, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "markview-browser", for: claude, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "markview", for: codex, env: fixture.env)
        try AgentMCPServices.setEnabled(false, service: "markview", for: cline, env: fixture.env)

        actor Recorder {
            var commands: [(String, [String])] = []
            func record(_ exe: String, _ args: [String]) { commands.append((exe, args)) }
        }
        let recorder = Recorder()

        let outcomes = await AgentBrowserRegistration.registerAll(
            executable: "/Applications/MarkView.app/Contents/MacOS/MarkView",
            env: fixture.env,
            runCommand: { exe, args in
                await recorder.record(exe, args)
                return CLIToolLocator.RunResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let ranCommands = await recorder.commands

        // Skipped services must be reported explicitly
        XCTAssertTrue(outcomes.contains { $0.agent == "Copilot (browser tools)" && $0.status == .skipped && $0.detail.contains("markview-browser") })
        XCTAssertTrue(outcomes.contains { $0.agent == "Copilot (project tools)" && $0.status == .registered })
        XCTAssertTrue(outcomes.contains { $0.agent == "Claude Code (browser tools)" && $0.status == .skipped })
        XCTAssertTrue(outcomes.contains { $0.agent == "Claude Code (project tools)" && $0.status == .registered })
        XCTAssertTrue(outcomes.contains { $0.agent == "Codex (project tools)" && $0.status == .skipped })
        XCTAssertTrue(outcomes.contains { $0.agent == "Codex (browser tools)" && $0.status == .registered })
        XCTAssertTrue(outcomes.contains { $0.agent == "Cline (project tools)" && $0.status == .skipped })
        XCTAssertTrue(outcomes.contains { $0.agent == "Cline (browser tools)" && $0.status == .registered })

        // CLI registration must never have been invoked for disabled servers
        XCTAssertFalse(ranCommands.contains { $0.0.hasSuffix("/claude") && $0.1.contains("markview-browser") })
        XCTAssertTrue(ranCommands.contains { $0.0.hasSuffix("/claude") && $0.1.contains("add") && $0.1.contains("markview") })
        XCTAssertFalse(ranCommands.contains { $0.0.hasSuffix("/codex") && $0.1.contains("markview") })
        XCTAssertTrue(ranCommands.contains { $0.0.hasSuffix("/codex") && $0.1.contains("add") && $0.1.contains("markview_browser") })

        // JSON registration must have written only the enabled MarkView service
        let copilotMCP = try XCTUnwrap((try fixture.readJSON(".copilot/mcp-config.json"))["mcpServers"] as? [String: Any])
        XCTAssertNotNil(copilotMCP["markview"])
        XCTAssertNil(copilotMCP["markview-browser"], "Skipped service must not be written into ~/.copilot/mcp-config.json")

        let clineMCP = try XCTUnwrap((try fixture.readJSON(".cline/data/settings/cline_mcp_settings.json"))["mcpServers"] as? [String: Any])
        XCTAssertNil(clineMCP["markview"], "Skipped service must not be written into cline_mcp_settings.json")
        XCTAssertNotNil(clineMCP["markview-browser"])

        // Saved selections must still be preserved after registration, and skipped services stay excluded at launch
        XCTAssertFalse(AgentMCPServices.isEnabled("markview-browser", for: copilot, env: fixture.env))
        XCTAssertTrue(AgentMCPServices.isEnabled("markview", for: copilot, env: fixture.env))
        XCTAssertFalse(AgentMCPServices.isEnabled("markview", for: codex, env: fixture.env))
        XCTAssertTrue(AgentMCPServices.isEnabled("markview-browser", for: codex, env: fixture.env))

        let summary = AgentBrowserRegistration.formatSummary(outcomes)
        XCTAssertTrue(summary.detail.contains("⊘"))
        XCTAssertTrue(summary.detail.contains("Skipped services remain disabled"))
    }

    // MARK: - Launch filtering, policy block parsing, and unreadable config handling

    func testLaunchFilteringPolicyBlockAndCorruptConfigHandling() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let copilot = try tool("copilot")
        try AgentMCPServices.setEnabled(false, service: "markview-browser", for: copilot, env: fixture.env)

        let candidates = [
            AgentMCPServer(name: "markview-browser", tomlName: "markview_browser", flag: "--mcp-browser", label: "browser", command: "/MV", args: ["--mcp-browser"]),
            AgentMCPServer(name: "markview", tomlName: "markview", flag: "--mcp-project", label: "project", command: "/MV", args: ["--mcp-project"]),
        ]
        let enabled = AgentMCPServices.enabledServers(from: candidates, for: copilot, env: fixture.env)
        XCTAssertEqual(enabled.map(\.name), ["markview"])

        let launchArgs = try XCTUnwrap(copilot.provider.mcpLaunchArguments(for: enabled, quote: { $0 }))
        let joined = launchArgs.joined(separator: " ")
        XCTAssertTrue(joined.contains("\"markview\""))
        XCTAssertFalse(joined.contains("markview-browser"))

        // Policy block parsing recognizes specific blocked MarkView servers without matching unrelated servers
        XCTAssertEqual(BrowserAgentTools.blockedPolicyServer(in: "MCP server was blocked by policy: \"markview-browser\""), "markview-browser")
        XCTAssertEqual(BrowserAgentTools.blockedPolicyServer(in: "1 MCP server was blocked by policy: 'markview' (Not found in registry)"), "markview")
        XCTAssertEqual(BrowserAgentTools.blockedPolicyServer(in: "MCP server was blocked by policy: 'markview-control'"), "markview-control")
        XCTAssertNil(BrowserAgentTools.blockedPolicyServer(in: "MCP server was blocked by policy: \"github\""))
        XCTAssertNil(BrowserAgentTools.blockedPolicyServer(in: "markview-browser ready"))

        // Unreadable JSON config fails safely without overwriting or drifting saved selection
        let corruptRaw = "{not valid json"
        try fixture.write(".copilot/settings.json", content: corruptRaw)
        XCTAssertThrowsError(try AgentMCPServices.setEnabled(false, service: "markview", for: copilot, env: fixture.env)) { error in
            XCTAssertTrue(error is MCPConfigError)
        }
        XCTAssertEqual(try fixture.readText(".copilot/settings.json"), corruptRaw, "Corrupt config file must remain untouched")
        XCTAssertTrue(AgentMCPServices.isEnabled("markview", for: copilot, env: fixture.env), "Failed update must not silently save selection")
    }

    // MARK: - Real CLI verification in isolated homes (when codex / copilot CLIs are present)

    func testRealCLIExternalLaunchVerificationWhenInstalled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let codex = try tool("codex")
        if let codexPath = CLIToolLocator.resolve(codex) {
            try fixture.write(".codex/config.toml", content: """
            [mcp_servers.alpha]
            command = "/bin/echo"
            args = ["alpha"]

            [mcp_servers.markview-control]
            command = "/bin/echo"
            args = ["control"]
            """)
            try AgentMCPServices.setEnabled(false, service: "alpha", for: codex, env: fixture.env)
            try AgentMCPServices.setEnabled(false, service: "markview-control", for: codex, env: fixture.env)
            let afterDisable = await codex.provider.mcpConfig?.discoverFromCLI(executable: codexPath, home: fixture.home) ?? []
            XCTAssertEqual(afterDisable.first(where: { $0.name == "alpha" })?.isEnabled, false)
            XCTAssertEqual(afterDisable.first(where: { $0.name == "markview-control" })?.isEnabled, false)

            try AgentMCPServices.setEnabled(true, service: "alpha", for: codex, env: fixture.env)
            let afterEnable = await codex.provider.mcpConfig?.discoverFromCLI(executable: codexPath, home: fixture.home) ?? []
            XCTAssertEqual(afterEnable.first(where: { $0.name == "alpha" })?.isEnabled, true)
            XCTAssertEqual(afterEnable.first(where: { $0.name == "markview-control" })?.isEnabled, false)
        }

        let copilot = try tool("copilot")
        if let copilotPath = CLIToolLocator.resolve(copilot) {
            try fixture.writeJSON(".copilot/mcp-config.json", object: [
                "mcpServers": [
                    "alpha": ["type": "local", "command": "/bin/echo", "args": ["hi"], "tools": ["*"]],
                    "markview-control": ["type": "local", "command": "/bin/echo", "args": ["ctl"], "tools": ["*"]],
                ],
            ])
            try AgentMCPServices.setEnabled(false, service: "alpha", for: copilot, env: fixture.env)
            try AgentMCPServices.setEnabled(false, service: "markview-control", for: copilot, env: fixture.env)
            try AgentMCPServices.setEnabled(false, service: "github-mcp-server", for: copilot, env: fixture.env)
            let afterDisable = await copilot.provider.mcpConfig?.discoverFromCLI(executable: copilotPath, home: fixture.home) ?? []
            XCTAssertEqual(afterDisable.first(where: { $0.name == "alpha" })?.isEnabled, false)
            XCTAssertEqual(afterDisable.first(where: { $0.name == "markview-control" })?.isEnabled, false)
            XCTAssertEqual(afterDisable.first(where: { $0.name == "github-mcp-server" })?.isEnabled, false)

            try AgentMCPServices.setEnabled(true, service: "alpha", for: copilot, env: fixture.env)
            let afterEnable = await copilot.provider.mcpConfig?.discoverFromCLI(executable: copilotPath, home: fixture.home) ?? []
            XCTAssertEqual(afterEnable.first(where: { $0.name == "alpha" })?.isEnabled, true)
            XCTAssertEqual(afterEnable.first(where: { $0.name == "markview-control" })?.isEnabled, false)
        }
    }
}
