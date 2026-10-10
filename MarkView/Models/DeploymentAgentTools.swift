import Foundation

/// The Deployments tools of the "markview" MCP server (and `--project-call`): an assistant can see the
/// places a project runs and how each is doing, propose new ones, and run commands there. It never gets
/// around the person: a command that is not read-only waits for their yes in the app, and a blocked one
/// never runs. Declarations only; the app side is `DeploymentToolRunner`.
enum DeploymentAgentTools {
    private static func tool(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:],
                             required: [String] = []) -> BrowserAgentTools.Tool {
        BrowserAgentTools.Tool(name: name, description: description, properties: properties, required: required)
    }

    private static let environment: [String: Any] = ["type": "string", "description": "The environment id, from markview_deployments"]

    private static func objects(_ description: String, _ fields: [String: String]) -> [String: Any] {
        ["type": "array", "description": description,
         "items": ["type": "object", "properties": fields.mapValues { ["type": "string", "description": $0] }]]
    }

    static let tools: [BrowserAgentTools.Tool] = [
        tool("markview_deployments", "The places this project runs (servers over SSH, this Mac, cloud services) and what MarkView last saw of each: health, CPU load, memory, disks, containers, failed services and the result of every check."),
        tool("markview_deployments_propose", "Propose a place the project runs. It appears in the Deployments tab under \"Found in the project\" and the person decides whether to add it; nothing connects until they do. Give where you found it as evidence, and say in `notes` what you could not find out (host, user, how to log in). Never put a password, token or key into any field.",
             ["name": ["type": "string", "description": "e.g. Production"],
              "kind": ["type": "string", "enum": ["ssh", "local", "cloud"]],
              "host": ["type": "string", "description": "ssh: host name, address or a Host alias of ~/.ssh/config"], "user": ["type": "string"],
              "port": ["type": "integer"], "identity_file": ["type": "string", "description": "Path of the key file, not its content"],
              "provider": ["type": "string", "description": "cloud: vercel, fly, heroku, aws, gcloud, azure, kubernetes…"],
              "evidence": ["type": "array", "items": ["type": "string"], "description": "Files and lines that show it, e.g. `.github/workflows/deploy.yml`: ssh to $PROD_HOST"],
              "notes": ["type": "string"],
              "checks": objects("Things to check: systemd, docker, port, http, postgres, redis, mysql or command (read-only)",
                                ["title": "Label", "kind": "systemd|docker|port|http|postgres|redis|mysql|command", "target": "unit, container, host:port, URL or command", "expect": "http: status such as 200 or 2xx"]),
              "log_sources": objects("Read-only commands that print a log", ["title": "Label", "command": "e.g. journalctl -u app -n 200 --no-pager"]),
              "cloud_commands": objects("cloud: read-only CLI commands that show the state", ["title": "Label", "command": "e.g. fly status -a my-app"])],
             required: ["name", "kind"]),
        tool("markview_deployments_status", "Look at an environment now (CPU, memory, disks, containers, services, checks) and report. Read-only.",
             ["environment": environment]),
        tool("markview_deployments_run", "Run a command on an environment (over SSH, on this Mac, or with the cloud CLI). A read-only command (uptime, df, docker ps, journalctl, systemctl status, kubectl get, vercel ls…) runs at once. Anything else — a restart, an edit — is shown to the person with the host and waits for their yes; if they say no you get that answer and must not try another way to do the same. Commands that shut a machine down, wipe disks or pipe a download into a shell never run. Say what it is for in `purpose`.",
             ["environment": environment, "command": ["type": "string", "description": "One command; a pipe into grep, head, tail, wc or sort is read-only"],
              "purpose": ["type": "string", "description": "Why, in a sentence: the person reads it when asked to approve"]],
             required: ["environment", "command"]),
        tool("markview_deployments_logs", "Show a log of an environment: one of its log sources, or a read-only command such as journalctl, docker logs or tail.",
             ["environment": environment, "source": ["type": "string", "description": "A log source id from markview_deployments"],
              "lines": ["type": "integer", "description": "Keep the last N lines (default 200)"]],
             required: ["environment", "source"]),
    ]

    static let names: Set<String> = Set(tools.map(\.name))
}
