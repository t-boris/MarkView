import Foundation

/// How to get a cloud provider's command-line tool and sign in, for when a command says it is not there.
/// Foundation only, checked in `tools/tests/deployment-discovery-tests.sh`.
enum ProviderHints {
    struct Hint: Equatable {
        let tool: String
        /// What the person reads ("brew install neonctl   (or: npm i -g neonctl)").
        let install: String
        let login: String
        /// The one command MarkView runs, after the person approves it, to install the tool.
        var installCommand: String { install.components(separatedBy: "   (").first ?? install }
    }

    enum Problem: Equatable { case missing, signedOut }

    static let hints: [String: Hint] = [
        "neonctl": Hint(tool: "neonctl", install: "brew install neonctl   (or: npm i -g neonctl)", login: "neonctl auth"),
        "vercel": Hint(tool: "vercel", install: "npm i -g vercel", login: "vercel login"),
        "fly": Hint(tool: "fly", install: "brew install flyctl", login: "fly auth login"),
        "flyctl": Hint(tool: "flyctl", install: "brew install flyctl", login: "fly auth login"),
        "heroku": Hint(tool: "heroku", install: "brew tap heroku/brew && brew install heroku", login: "heroku login"),
        "aws": Hint(tool: "aws", install: "brew install awscli", login: "aws configure   (or: aws sso login)"),
        "gcloud": Hint(tool: "gcloud", install: "brew install --cask google-cloud-sdk", login: "gcloud auth login"),
        "az": Hint(tool: "az", install: "brew install azure-cli", login: "az login"),
        "doctl": Hint(tool: "doctl", install: "brew install doctl", login: "doctl auth init"),
        "kubectl": Hint(tool: "kubectl", install: "brew install kubectl", login: "(your cluster's kubeconfig)"),
        "supabase": Hint(tool: "supabase", install: "brew install supabase/tap/supabase", login: "supabase login"),
        "pscale": Hint(tool: "pscale", install: "brew install planetscale/tap/pscale", login: "pscale auth login"),
        "turso": Hint(tool: "turso", install: "brew install tursodatabase/tap/turso", login: "turso auth login"),
        "docker": Hint(tool: "docker", install: "install Docker Desktop", login: "(none)")
    ]

    /// The tool a command starts with (`sudo` and options skipped).
    static func tool(of command: String) -> String {
        let words = command.split(separator: " ").map(String.init)
        let first = words.first(where: { $0 != "sudo" && !$0.hasPrefix("-") && !$0.contains("=") }) ?? ""
        return (first as NSString).lastPathComponent
    }

    /// What is wrong with a provider's tool, from what a command printed.
    static func problem(command: String, stderr: String, status: Int32) -> (problem: Problem, hint: Hint)? {
        let tool = tool(of: command)
        guard let hint = hints[tool] else { return nil }
        let text = stderr.lowercased()
        if status == 127 || text.contains("command not found") || text.contains("no such file or directory") && text.contains(tool) { return (.missing, hint) }
        if text.contains("not logged in") || text.contains("not authenticated") || text.contains("unauthorized") || text.contains("no credentials") || text.contains("please log in") || text.contains("login required") || text.contains("401") { return (.signedOut, hint) }
        return nil
    }

    /// A line that says what to do, when `stderr` of a command says the tool is missing or not signed in.
    static func advice(command: String, stderr: String, status: Int32) -> String? {
        guard let found = problem(command: command, stderr: stderr, status: status) else { return nil }
        switch found.problem {
        case .missing: return "\(found.hint.tool) is not installed on this Mac. Install it: \(found.hint.install). Then sign in: \(found.hint.login)."
        case .signedOut: return "\(found.hint.tool) is not signed in. Sign in with: \(found.hint.login)."
        }
    }
}
