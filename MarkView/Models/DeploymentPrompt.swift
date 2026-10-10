import Foundation

/// The prompt that sends the assistant to find where the project runs (Deployments → Ask AI).
enum DeploymentPrompt {
    /// The prompt of the in-app answer: MarkView has already looked and read the logs; the model reads only that.
    static func answer(environment name: String, id: String, question: String, report: String, evidence: [(title: String, text: String)]) -> String {
        var text = """
        You are a careful site-reliability engineer. A person asks a question about one environment of their project ("\(name)", id \(id)) in MarkView's Deployments. MarkView has looked at it and read some logs; that evidence is below. Use ONLY the evidence. If it is not enough, say what is missing and give the exact read-only command to run next. Do not guess and do not invent numbers.

        Question: \(question)

        State MarkView saw:
        \(report)
        """
        var budget = 24_000
        for item in evidence where budget > 0 {
            let body = item.text.count > 6000 ? "…" + String(item.text.suffix(6000)) : item.text
            budget -= body.count
            text += "\n\n--- \(item.title) ---\n\(body)"
        }
        if evidence.isEmpty { text += "\n\n(No log could be read.)" }
        text += """


        Answer in the language of the question, in under 250 words, in this shape:
        **Verdict:** Healthy / Needs attention / Problem / Can't tell, in one line.
        **What I see:** a few bullets with the numbers and the log lines that matter.
        **What I would do:** concrete next steps; mark each command "(read-only)" or "(changes something: MarkView will ask you first)". Say nothing about changes before saying what the evidence shows.
        """
        return text
    }

    /// A question about one environment, with what MarkView last saw and, when given, a log the person is reading.
    static func ask(environment name: String, id: String, question: String, report: String, logTitle: String? = nil, log: String? = nil) -> String {
        var text = """
        Look into the environment "\(name)" (id \(id)) in this project's Deployments and answer my question.

        My question: \(question)

        What MarkView last saw:
        \(report)
        """
        if let log, !log.isEmpty {
            let excerpt = log.count > 8000 ? "…" + String(log.suffix(8000)) : log
            text += "\n\nThe log I am reading (\(logTitle ?? "log")):\n```\n\(excerpt)\n```"
        }
        text += """


        How: use the MarkView tools: markview_deployments_status to look now, markview_deployments_logs and markview_deployments_run to read more (read-only commands run at once; anything that changes something is shown to me in the app and runs only if I approve it). If this environment is a cloud service and you have tools for it (an MCP server such as Neon's, or its CLI), use them to read its state too. Answer plainly: what is wrong or fine, the evidence (numbers, log lines), and what you would do next. Do not change anything without asking me first, and never ask me for a password.
        """
        return text
    }

    static func analyze(project: String, existing: [String], hasMCP: Bool) -> String {
        let known = existing.isEmpty ? "No environment is set up yet." : "Already set up: \(existing.joined(separator: ", ")). Do not propose these again."
        let how = hasMCP
            ? "Use the MarkView tools: markview_guide with topic \"deployments\" first, then markview_deployments, then markview_deployments_propose for each place you find."
            : "Use the MarkView command: `MarkView --project-call markview_guide '{\"topic\":\"deployments\"}'`, then `markview_deployments_propose` for each place you find (the Skill \"markview\" describes the command)."
        return """
        Find where the project \(project) runs, and how to reach each place, so MarkView can show its state (CPU, memory, disks, services, containers, databases, logs).

        \(known)

        1. Read how it is deployed: the CI (.github/workflows), platform files (vercel.json, fly.toml, Procfile, app.json, serverless.yml, docker-compose, Dockerfile, k8s/, helm/, terraform), deploy scripts and Makefile, README and docs. If `gh` is installed and the repository is on GitHub, also look at its environments and recent deployments (`gh api repos/{owner}/{repo}/environments`, `gh run list`). Read ~/.ssh/config for Host entries that match.
        2. For each place (production, staging, dev, a database server, a cloud service) work out: what it is (a server over SSH, a cloud service and which, this Mac), the host and user if they are written down, what runs there (services, containers, databases, ports, health URLs such as /health), and where its logs are (journalctl unit, docker logs, a file path).
        3. \(how) Give evidence (file and line) for each proposal, and say in `notes` what you could not find out.
        4. Ask me for what is missing: the host name behind a secret, the user, which key to use, which environments exist that are not in the code. Ask one short question at a time.

        Rules: do not read, print or write secret values (names of secrets are fine); never ask me for a password in chat, MarkView connects with my SSH agent or key file; do not connect anywhere or run anything yourself yet. When I have added the environments in the Deployments tab, you may look with markview_deployments_status and read logs; anything that changes something on a server is shown to me for approval first.
        """
    }
}
