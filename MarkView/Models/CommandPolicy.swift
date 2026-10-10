import Foundation

/// How risky a shell command is, decided before anything runs on a server or in a cloud CLI
/// (Deployments). Foundation only; checked in `tools/tests/command-policy-tests.sh`.
///
/// - `readOnly`: on the short list of commands that only look (uptime, df, docker ps, journalctl…).
///   These run without asking.
/// - `needsConfirmation`: anything else. It is shown to the person, with the host, and runs only after
///   they approve that very command.
/// - `blocked`: never runs, approved or not (shutdown, rm -rf /, mkfs, a download piped into a shell).
enum CommandRisk: Equatable {
    case readOnly
    case needsConfirmation(String)
    case blocked(String)

    var isReadOnly: Bool { if case .readOnly = self { return true } else { return false } }
    var isBlocked: Bool { if case .blocked = self { return true } else { return false } }
}

enum CommandPolicy {
    static func classify(_ raw: String) -> CommandRisk {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .blocked("The command is empty.") }
        if let reason = blockedReason(command) { return .blocked(reason) }
        if command.contains("\n") || command.contains("\0") { return .needsConfirmation("A multi-line command is not on the read-only list.") }
        switch segments(of: command) {
        case .failure(let reason): return .needsConfirmation(reason.description)
        case .success(let parts):
            for part in parts {
                if case .needsConfirmation(let why) = classifySegment(part) { return .needsConfirmation(why) }
            }
            return .readOnly
        }
    }

    // MARK: Never

    private static let blockedPatterns: [(String, String)] = [
        (#"\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rR][a-zA-Z]*\s+(-[a-zA-Z]+\s+)*(/|/\*|~|~/|\$HOME|\*)(\s|$)"#, "Deleting everything under / or the home folder."),
        (#"\bmkfs(\.\w+)?\b"#, "Formatting a disk."),
        (#"\bdd\b[^|;]*\bof=/dev/"#, "Writing straight to a device."),
        (#">\s*/dev/(sd|nvme|vd|disk)"#, "Writing straight to a device."),
        (#":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "A fork bomb."),
        (#"(^|[;&|]\s*|\s)(shutdown|reboot|halt|poweroff)(\s|$)"#, "Shutting the machine down."),
        (#"\binit\s+[06]\b"#, "Shutting the machine down."),
        (#"\bsystemctl\s+(poweroff|reboot|halt|kexec)\b"#, "Shutting the machine down."),
        (#"\bchmod\s+(-[a-zA-Z]+\s+)*[0-7]*777\s+/(\s|$)"#, "Opening up the whole file system."),
        (#"\bchown\s+(-[a-zA-Z]+\s+)*\S+\s+/(\s|$)"#, "Changing the owner of the whole file system."),
        (#"\b(curl|wget)\b[^|;]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#, "Running a download as a script."),
        (#"\bdrop\s+(database|table)\b"#, "Dropping a database or table."),
        (#"\btruncate\s+table\b"#, "Emptying a table.")
    ]

    static func blockedReason(_ command: String) -> String? {
        for (pattern, reason) in blockedPatterns {
            if command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return reason + " MarkView never runs this." }
        }
        return nil
    }

    // MARK: Splitting

    /// Words of one command of a pipeline.
    private struct Segment { var words: [String] }

    /// Split on `|` outside quotes; any other way of chaining or redirecting makes it a command to confirm.
    private static func segments(of command: String) -> Result<[Segment], ChainError> {
        var segments: [Segment] = []
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        let chars = Array(command)
        var i = 0
        func endWord() { if inWord { words.append(current); current = ""; inWord = false } }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"", i + 1 < chars.count { i += 1; current.append(chars[i]) } else { current.append(c) }
                if q == "\"" && (c == "$" && i + 1 < chars.count && chars[i + 1] == "(" || c == "`") { return .failure(ChainError("Command substitution is not on the read-only list.")) }
                i += 1; continue
            }
            switch c {
            case "'", "\"": quote = c; inWord = true
            case "\\": if i + 1 < chars.count { i += 1; current.append(chars[i]); inWord = true }
            case " ", "\t": endWord()
            case "|":
                if i + 1 < chars.count, chars[i + 1] == "|" { return .failure(ChainError("Chained commands are not on the read-only list.")) }
                endWord(); segments.append(Segment(words: words)); words = []
            case ";", "&", "`", "<", "(", ")", "{", "}":
                // "2>&1" is the one use of & that only merges output.
                if c == "&", i > 0, chars[i - 1] == ">" { current.append(c); inWord = true }
                else { return .failure(ChainError("Chaining, background jobs or redirects are not on the read-only list.")) }
            case ">":
                // "2>/dev/null" and "2>&1" only drop or merge output.
                let rest = String(chars[i...])
                if rest.hasPrefix(">/dev/null") || rest.hasPrefix(">&1") { current.append(c); inWord = true }
                else { return .failure(ChainError("Writing to a file is not on the read-only list.")) }
            case "$":
                if i + 1 < chars.count, chars[i + 1] == "(" { return .failure(ChainError("Command substitution is not on the read-only list.")) }
                current.append(c); inWord = true
            default: current.append(c); inWord = true
            }
            i += 1
        }
        if quote != nil { return .failure(ChainError("An unclosed quote.")) }
        endWord(); segments.append(Segment(words: words))
        return .success(segments.filter { !$0.words.isEmpty })
    }

    private struct ChainError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: One command

    /// Commands that only look, whatever their arguments.
    private static let looking: Set<String> = [
        "uptime", "hostname", "whoami", "id", "date", "uname", "df", "du", "free", "vmstat", "iostat", "mpstat", "ps", "pgrep",
        "ls", "cat", "head", "wc", "sort", "uniq", "grep", "egrep", "fgrep", "cut", "tr", "nl", "stat", "file", "lsof", "ss", "netstat",
        "nproc", "lscpu", "lsblk", "lsmod", "lspci", "lsusb", "w", "who", "last", "lastlog", "uptime", "arch", "sw_vers", "sysctl",
        "vm_stat", "getconf", "readlink", "realpath", "basename", "dirname", "which", "type", "echo", "printf", "true", "pwd",
        "nslookup", "dig", "host", "getent", "free", "dmidecode", "ulimit", "tac", "rev", "column", "less", "more", "md5sum", "sha256sum", "shasum"
    ]

    private static func classifySegment(_ segment: Segment) -> CommandRisk {
        var words = segment.words
        // Environment assignments (FOO=bar cmd) are a way to change behaviour: ask.
        if let first = words.first, first.contains("="), !first.hasPrefix("-") { return .needsConfirmation("An environment assignment is not on the read-only list.") }
        // `sudo -n <command>`: the same command, with rights.
        if words.first == "sudo" {
            words.removeFirst()
            while let f = words.first, f.hasPrefix("-") { if f == "-n" || f == "--non-interactive" { words.removeFirst() } else { return .needsConfirmation("sudo with options is not on the read-only list.") } }
            if words.isEmpty { return .needsConfirmation("sudo alone.") }
        }
        guard let name = words.first.map({ ($0 as NSString).lastPathComponent }) else { return .needsConfirmation("An empty command.") }
        let args = Array(words.dropFirst())
        let positional = args.filter { !$0.hasPrefix("-") }
        let flags = args.filter { $0.hasPrefix("-") }
        func ask(_ why: String) -> CommandRisk { .needsConfirmation("\(name): \(why)") }
        func hasFlag(_ names: [String]) -> Bool { flags.contains { f in names.contains { f == $0 || f.hasPrefix($0 + "=") } } }

        if looking.contains(name) {
            if name == "sysctl", flags.contains("-w") || args.contains(where: { $0.contains("=") }) { return ask("setting a kernel value") }
            if name == "less" || name == "more" { return ask("a pager waits for input") }
            return .readOnly
        }
        switch name {
        case "tail":
            return hasFlag(["-f", "-F", "--follow"]) ? ask("following a file never ends") : .readOnly
        case "top":
            return flags.contains(where: { $0.contains("b") }) && flags.contains(where: { $0.contains("n") }) ? .readOnly : ask("top is interactive; use top -bn1")
        case "find":
            return args.contains(where: { ["-exec", "-execdir", "-delete", "-ok", "-fprint", "-fprintf", "-fls"].contains($0) }) ? ask("it can change files") : .readOnly
        case "ifconfig":
            return positional.isEmpty ? .readOnly : ask("it can change interfaces")
        case "ip":
            let verbs = ["addr", "address", "a", "route", "r", "link", "l", "neigh", "-s", "-br", "-4", "-6"]
            return !args.contains(where: { ["add", "del", "delete", "set", "flush", "replace", "change"].contains($0) }) && (positional.first.map { verbs.contains($0) } ?? false) ? .readOnly : ask("it can change the network")
        case "mount":
            return positional.isEmpty && !hasFlag(["-a"]) ? .readOnly : ask("mounting changes the system")
        case "dmesg":
            return hasFlag(["-c", "-C", "--clear", "-w", "--follow"]) ? ask("it clears or follows the log") : .readOnly
        case "ping":
            return hasFlag(["-c"]) ? .readOnly : ask("ping without -c never ends")
        case "crontab":
            return flags == ["-l"] ? .readOnly : ask("it can change the schedule")
        case "journalctl":
            if hasFlag(["-f", "--follow", "--vacuum-size", "--vacuum-time", "--vacuum-files", "--rotate", "--flush", "--sync", "--relinquish-var", "--setup-keys"]) { return ask("it follows or changes the journal") }
            return .readOnly
        case "systemctl":
            let ok: Set<String> = ["status", "is-active", "is-enabled", "is-failed", "list-units", "list-unit-files", "list-timers", "list-sockets", "list-dependencies", "show", "cat", "--failed"]
            guard let verb = (positional.first ?? flags.first(where: { $0 == "--failed" })) else { return ask("no subcommand") }
            return ok.contains(verb) ? .readOnly : ask("systemctl \(verb) changes a service")
        case "service":
            return positional.count >= 2 && positional[1] == "status" ? .readOnly : ask("it can change a service")
        case "docker", "podman":
            return containerRisk(name, positional: positional, flags: flags)
        case "docker-compose":
            return composeRisk(name, positional: positional, flags: flags)
        case "kubectl":
            let ok: Set<String> = ["get", "describe", "logs", "top", "version", "cluster-info", "api-resources", "explain", "events"]
            guard let verb = positional.first else { return ask("no subcommand") }
            if verb == "config" { return ["get-contexts", "current-context", "view"].contains(positional.dropFirst().first ?? "") ? .readOnly : ask("it can change the kubeconfig") }
            if verb == "logs", hasFlag(["-f", "--follow"]) { return ask("following logs never ends") }
            if verb == "get", args.contains(where: { $0.hasPrefix("secret") }) { return ask("secrets") }
            return ok.contains(verb) ? .readOnly : ask("kubectl \(verb) changes the cluster")
        case "curl":
            let bad = ["-X", "--request", "-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "-F", "--form", "-T", "--upload-file", "-o", "--output", "-O", "--remote-name", "-K", "--config", "-u", "--user"]
            for f in flags where bad.contains(where: { f == $0 || f.hasPrefix($0 + "=") }) {
                if (f == "-X" || f == "--request"), let i = args.firstIndex(of: f), i + 1 < args.count, args[i + 1].uppercased() == "GET" { continue }
                return ask("it can send data or write a file")
            }
            return .readOnly
        case "log":
            return positional.first == "show" ? .readOnly : ask("log stream never ends; use log show --last 15m")
        case "pg_isready": return .readOnly
        case "redis-cli":
            let verb = positional.first?.lowercased() ?? ""
            return ["ping", "info", "dbsize", "--latency", "time"].contains(verb) ? .readOnly : ask("it can change data")
        case "mysqladmin":
            return positional.contains(where: { ["ping", "status", "version", "processlist", "extended-status", "variables"].contains($0) }) && !positional.contains(where: { ["shutdown", "kill", "drop", "create", "flush-hosts", "flush-logs", "flush-privileges", "reload", "refresh", "password"].contains($0) }) ? .readOnly : ask("it can change the server")
        case "git":
            let ok: Set<String> = ["status", "log", "diff", "show", "branch", "rev-parse", "describe", "remote", "tag", "ls-files", "blame", "shortlog", "rev-list"]
            guard let verb = positional.first, ok.contains(verb) else { return ask("it can change the repository") }
            if verb == "branch" || verb == "tag" || verb == "remote", args.contains(where: { ["-d", "-D", "-m", "-M", "-f", "add", "remove", "rm", "set-url", "rename", "prune"].contains($0) }) { return ask("it can change the repository") }
            return .readOnly
        case "pm2":
            let verb = positional.first ?? ""
            if ["list", "ls", "status", "jlist", "prettylist", "describe", "show", "ping", "report"].contains(verb) { return .readOnly }
            if verb == "logs", hasFlag(["--nostream"]) { return .readOnly }
            return ask("it can restart or follow processes")
        case "supervisorctl":
            return positional.first == "status" ? .readOnly : ask("it can change processes")
        case "nginx", "apachectl", "httpd":
            return hasFlag(["-t", "-T", "-v", "-V", "configtest"]) || positional.first == "configtest" ? .readOnly : ask("it can reload or stop the server")
        case "openssl":
            return positional.first == "x509" && hasFlag(["-noout"]) ? .readOnly : ask("it is not a certificate check")
        case "sed":
            return ask("sed can write files")
        case "awk", "gawk":
            return ask("awk can run commands")
        case "vercel":
            let ok: Set<String> = ["ls", "list", "inspect", "logs", "whoami", "projects", "domains", "teams", "status"]
            guard let verb = positional.first else { return ask("no subcommand") }
            if verb == "logs", hasFlag(["-f", "--follow"]) { return ask("following logs never ends") }
            if ["projects", "domains", "teams"].contains(verb), positional.dropFirst().first.map({ !["ls", "list"].contains($0) }) ?? false { return ask("it can change the account") }
            return ok.contains(verb) ? .readOnly : ask("vercel \(verb) deploys or changes the project")
        case "fly", "flyctl":
            let ok: Set<String> = ["status", "logs", "apps", "releases", "regions", "version", "doctor", "checks", "scale", "ips", "machine", "machines", "info", "services"]
            guard let verb = positional.first, ok.contains(verb) else { return ask("fly \(positional.first ?? "") can deploy or change the app") }
            if verb == "logs", !hasFlag(["--no-tail"]) { return ask("fly logs follows; use --no-tail") }
            if ["scale", "machine", "machines", "apps", "ips", "services"].contains(verb), let sub = positional.dropFirst().first, !["show", "list", "ls", "status"].contains(sub) { return ask("it changes the app") }
            if verb == "scale", positional.count == 1 { return ask("scale") }
            return .readOnly
        case "heroku":
            let ok: Set<String> = ["ps", "releases", "apps", "status", "logs", "whoami", "info"]
            guard let verb = positional.first, ok.contains(verb) else { return ask("heroku \(positional.first ?? "") can change the app") }
            if verb == "logs", hasFlag(["-t", "--tail"]) { return ask("following logs never ends") }
            if verb == "ps", let sub = positional.dropFirst().first, ["restart", "stop", "scale", "kill", "resize"].contains(sub) { return ask("it restarts or scales dynos") }
            return .readOnly
        case "neonctl", "neon":
            // neonctl <noun> <verb>: listing and getting only; connection strings carry the password.
            let noun = positional.first ?? "", verb = positional.dropFirst().first ?? ""
            if noun == "me" { return .readOnly }
            if noun == "connection-string" { return ask("a connection string holds the password") }
            return ["list", "get"].contains(verb) && !["auth", "set-context"].contains(noun) ? .readOnly : ask("neonctl \(noun) \(verb) can change the project")
        case "supabase":
            return positional.prefix(2) == ["projects", "list"] ? .readOnly : ask("supabase \(positional.joined(separator: " ")) can change the project")
        case "pscale":
            let verb = positional.dropFirst().first ?? ""
            return ["list", "show"].contains(verb) && !["password", "service-token", "auth"].contains(positional.first ?? "") ? .readOnly : ask("pscale \(positional.joined(separator: " ")) can change the database")
        case "turso":
            let verb = positional.dropFirst().first ?? ""
            return positional.first == "db" && ["list", "show"].contains(verb) ? .readOnly : ask("turso \(positional.joined(separator: " ")) can change the database")
        case "aws":
            return awsRisk(positional: positional, flags: flags, args: args)
        case "gcloud":
            let tail = positional.last ?? ""
            if hasFlag(["--follow"]) { return ask("following logs never ends") }
            if positional.contains(where: { ["secrets", "kms", "auth"].contains($0) }) && !positional.contains("list") { return ask("secrets or credentials") }
            return ["list", "describe", "read", "get-iam-policy", "get-value", "tail"].contains(tail) && tail != "tail" ? .readOnly : ask("gcloud \(tail) can change resources")
        case "az":
            let tail = positional.last ?? ""
            return ["list", "show", "list-all", "show-all"].contains(tail) ? .readOnly : ask("az \(tail) can change resources")
        case "doctl":
            let tail = positional.last ?? ""
            return ["list", "get", "ls"].contains(tail) ? .readOnly : ask("doctl \(tail) can change resources")
        default:
            return ask("not on the read-only list")
        }
    }

    private static func containerRisk(_ name: String, positional: [String], flags: [String]) -> CommandRisk {
        func ask(_ why: String) -> CommandRisk { .needsConfirmation("\(name): \(why)") }
        guard let verb = positional.first else { return ask("no subcommand") }
        if verb == "compose" { return composeRisk(name, positional: Array(positional.dropFirst()), flags: flags) }
        let ok: Set<String> = ["ps", "images", "logs", "inspect", "top", "version", "info", "stats", "port", "history", "diff", "events", "network", "volume", "container", "image", "system"]
        guard ok.contains(verb) else { return ask("\(verb) changes a container") }
        if verb == "logs", flags.contains(where: { $0 == "-f" || $0 == "--follow" }) { return ask("following logs never ends") }
        if verb == "stats", !flags.contains("--no-stream") { return ask("docker stats never ends; use --no-stream") }
        if verb == "events" { return ask("docker events never ends") }
        if ["network", "volume", "container", "image", "system"].contains(verb) {
            let sub = positional.dropFirst().first ?? ""
            return ["ls", "list", "inspect", "ps", "df", "info", "logs", "top", "stats", "history"].contains(sub) && !(sub == "stats" && !flags.contains("--no-stream")) ? .readOnly : ask("\(verb) \(sub) changes things")
        }
        return .readOnly
    }

    private static func composeRisk(_ name: String, positional: [String], flags: [String]) -> CommandRisk {
        func ask(_ why: String) -> CommandRisk { .needsConfirmation("\(name) compose: \(why)") }
        guard let verb = positional.first(where: { !$0.hasPrefix("-") }) else { return ask("no subcommand") }
        if ["ps", "ls", "config", "images", "top", "version", "port"].contains(verb) { return .readOnly }
        if verb == "logs" { return flags.contains(where: { $0 == "-f" || $0 == "--follow" }) ? ask("following logs never ends") : .readOnly }
        return ask("\(verb) changes services")
    }

    private static func awsRisk(positional: [String], flags: [String], args: [String]) -> CommandRisk {
        func ask(_ why: String) -> CommandRisk { .needsConfirmation("aws: \(why)") }
        guard positional.count >= 2 else { return ask("no subcommand") }
        let service = positional[0], operation = positional[1]
        if args.contains("--with-decryption") || operation == "get-secret-value" || operation.hasPrefix("get-parameter") && args.contains("--with-decryption") { return ask("secrets") }
        if service == "logs", operation == "tail", args.contains("--follow") { return ask("following logs never ends") }
        if service == "sts", operation == "get-caller-identity" { return .readOnly }
        if service == "logs", ["tail", "filter-log-events", "describe-log-groups", "describe-log-streams", "get-log-events"].contains(operation) { return .readOnly }
        if service == "s3" { return operation == "ls" ? .readOnly : ask("s3 \(operation) changes buckets") }
        let verbs = ["describe-", "list-", "get-"]
        return verbs.contains(where: { operation.hasPrefix($0) }) ? .readOnly : ask("\(operation) changes resources")
    }
}
