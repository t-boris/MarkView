import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

// ssh config
let config = """
Host prod
    HostName 203.0.113.10
    User deploy
    Port 2222
    IdentityFile ~/.ssh/prod_ed25519
Host staging stage
  HostName staging.example.net
  User ubuntu
Host *
  ServerAliveInterval 30
Host unrelated
  HostName 198.51.100.7
"""
let hosts = DeploymentDiscovery.parseSSHConfig(config)
check(hosts.map(\.alias) == ["prod", "staging", "stage", "unrelated"], "ssh config hosts, wildcards left out: \(hosts.map(\.alias))")
check(hosts[0].hostName == "203.0.113.10" && hosts[0].user == "deploy" && hosts[0].port == 2222 && hosts[0].identityFile == "~/.ssh/prod_ed25519", "ssh config fields")
check(hosts[1].hostName == "staging.example.net" && hosts[2].user == "ubuntu", "one block, several aliases")

// ssh mentions in docs
let docs = """
Deploy with `ssh deploy@203.0.113.10 'cd /srv/app && git pull'`.
Then `scp build.tar.gz deploy@staging.example.net:/srv/` and rsync -av out/ deploy@staging.example.net:/srv/app.
Clone with git@github.com:me/app.git (ssh git@github.com).
Use ssh user@host as a template, and ssh keys are in 1Password. Connect via ssh into the box.
"""
let targets = DeploymentDiscovery.sshTargets(in: docs)
check(targets.map(\.host).contains("203.0.113.10") && targets.map(\.host).contains("staging.example.net"), "real hosts are found: \(targets.map(\.host))")
let prose = DeploymentDiscovery.sshTargets(in: "Then ssh git@github to test. Run `ssh apt-get install x`. After 109 steps ssh 109 is a number. Real: ssh deploy@10.0.0.5 and ssh root@db-1")
check(prose.map(\.host) == ["10.0.0.5", "db-1"], "prose words and bare numbers are not machines: \(prose.map(\.host))")
check(!targets.map(\.host).contains("github.com") && !targets.map(\.host).contains("host") && !targets.map(\.host).contains("keys") && !targets.map(\.host).contains("into"), "code hosts, placeholders and prose are not: \(targets.map(\.host))")
check(targets.first { $0.host == "203.0.113.10" }?.user == "deploy", "the user is read")

// compose
let composeText = """
version: "3"
services:
  web:
    image: nginx
  db:
    image: postgres:16
    volumes:
      - data:/var/lib/postgresql/data
volumes:
  data:
"""
check(DeploymentDiscovery.composeServices(composeText) == ["web", "db"], "compose services: \(DeploymentDiscovery.composeServices(composeText))")

// a project
let root = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
func write(_ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}
try write(".github/workflows/deploy.yml", """
name: Deploy
on: push
jobs:
  prod:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.PROD_HOST }}
          username: deploy
  stage:
    environment: staging
    steps:
      - run: rsync -av . ${{ secrets.STAGING_HOST }}:/srv
""")
try write("fly.toml", "app = \"my-api\"\n[http_service]\n")
try write("vercel.json", "{}")
try write("docker-compose.yml", composeText)
try write("README.md", docs)
try write("node_modules/x/README.md", "ssh deploy@evil.example.org")
try write("src/main.swift", "print(1)")

let found = DeploymentDiscovery.scan(root: root, sshConfig: config)
let byId = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
check(byId["production"]?.kind == .ssh && byId["production"]?.missing.joined().contains("PROD_HOST") == true, "workflow: production, host is a secret: \(found.map(\.id))")
check(byId["staging"]?.kind == .ssh, "workflow: staging")
check(byId["fly"]?.provider == "fly" && byId["fly"]?.cloudCommands.first?.command == "fly status -a my-api", "fly.toml: app and commands")
check(byId["fly"]?.cloudCommands.allSatisfy { CommandPolicy.classify($0.command).isReadOnly } == true, "every suggested fly command is read-only")
check(byId["vercel"]?.provider == "vercel" && byId["vercel"]?.cloudCommands.allSatisfy { CommandPolicy.classify($0.command).isReadOnly } == true, "vercel.json: read-only commands")
let server = found.first { $0.host == "203.0.113.10" }
check(server?.user == "deploy" && server?.port == 2222 && server?.identityFile == "~/.ssh/prod_ed25519", "the docs' host picks up its ssh config entry")
for f in found { print("   found", f.id, f.kind, f.host, f.confidence, f.checks.map(\.id)) }
check(server?.checks.contains { $0.kind == .docker && $0.target == "web" } == true || found.contains { $0.id == "docker-host" && $0.checks.contains { $0.target == "web" } }, "compose services become container checks (on the only server, or on their own entry)")
check(found.first { $0.host == "staging.example.net" } != nil, "a second host from the docs")
check(!found.contains { $0.host.contains("evil") }, "node_modules is not read")
check(!found.contains { $0.host == "198.51.100.7" }, "an unrelated ssh config host is left out")
check(found.sorted { $0.confidence > $1.confidence } == found, "sorted by confidence")
let env = byId["fly"]!.makeEnvironment(existing: ["fly-io-my-api"])
check(env.id == "fly-io-my-api-2" && env.kind == .cloud && env.problems.isEmpty, "a suggestion becomes an environment with a free id")
check(DeploymentEnvironment(id: "a", name: "a", kind: .ssh, host: "-oProxyCommand=evil").problems.contains { $0.contains("characters") }, "an option-like host is refused")
check(DeploymentEnvironment(id: "a", name: "a", kind: .ssh, host: "web-1.example.com", user: "deploy").problems.isEmpty, "a normal ssh environment is fine")
check(DeploymentEnvironment(id: "a", name: "a", kind: .ssh, host: "::1").problems.isEmpty && DeploymentEnvironment.isSafeToken("fe80::1%en0"), "ipv6 fits")

let file = DeploymentsFile(environments: [env])
check(DeploymentsFile.decode((try? file.encoded()) ?? Data()) == file, "the file round-trips as JSON")


// A project that keeps its database in a managed service (as docs write it down) and its servers at a hosting vendor.
let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("discovery2-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root2) }
func write2(_ path: String, _ text: String) throws {
    let url = root2.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}
try write2("docs/deployment/environments.md", """
# Environments

| | local | dev | production |
|---|---|---|---|
| Business DB | local postgres | **Neon** branch `dev` | **Neon** branch `production` |

> Neon provisioned: project `flat-dawn-39185109`, region aws-eu-central-1. Host (pooled): `ep-billowing-paper-as15eck5-pooler.c-4.eu-central-1.aws.neon.tech`.
| production | `production` | `br-frosty-queen-aswnplte` | `ep-billowing-paper-as15eck5-pooler.c-4.eu-central-1.aws.neon.tech` |
| dev | `dev` | `br-mute-sun-asvtz0qs` | `ep-bitter-bird-as7ypdhk-pooler.c-4.eu-central-1.aws.neon.tech` |
Variant A: dev and production each run on a single Contabo box with docker-compose.app.yml.
The full connection string goes only in infrastructure/.env, never commit it.
""")
try write2("package.json", "{\"dependencies\": {\"@neondatabase/serverless\": \"^0.9\", \"next\": \"15\"}}")
try write2(".env", "DATABASE_URL=postgres://neondb_owner:SuperSecretPassw0rd@ep-secret-host-123456.us-east-2.aws.neon.tech/db")
let managed = DeploymentDiscovery.scan(root: root2)
let neon = managed.first { $0.id == "neon" }
check(neon?.kind == .cloud && neon?.provider == "neon", "a Neon database is found: \(managed.map(\.id))")
check(neon?.checks.map(\.target).sorted() == ["ep-billowing-paper-as15eck5-pooler.c-4.eu-central-1.aws.neon.tech:5432", "ep-bitter-bird-as7ypdhk-pooler.c-4.eu-central-1.aws.neon.tech:5432"], "its two endpoints become reachability checks: \(neon?.checks.map(\.target) ?? [])")
check(neon?.checks.contains { $0.title.contains("(production)") } == true && neon?.checks.contains { $0.title.contains("(dev)") } == true, "labelled production and dev from the docs' lines")
check(neon?.cloudCommands.contains { $0.command == "neonctl branches list --project-id flat-dawn-39185109" } == true, "the project id gives neonctl commands: \(neon?.cloudCommands.map(\.command) ?? [])")
check(neon?.cloudCommands.allSatisfy { CommandPolicy.classify($0.command).isReadOnly } == true, "every Neon command is read-only")
check(neon?.missing.joined().contains("never reads it") == true, "it says the connection URL is never read")
check(!managed.flatMap { $0.evidence + $0.missing + $0.checks.map(\.target) }.joined().contains("SuperSecret") && !managed.contains { $0.evidence.joined().contains("ep-secret-host") }, ".env is never read")
let servers = managed.filter { $0.kind == .ssh }
check(servers.map(\.name).contains("Dev (Contabo)") && servers.map(\.name).contains("Production (Contabo)") && servers.allSatisfy { $0.host.isEmpty && !$0.missing.isEmpty }, "the hosting vendor and environments from the docs become servers still missing a host: \(servers.map(\.name))")
let onlyPackage = DeploymentDiscovery.scan(root: { let r = FileManager.default.temporaryDirectory.appendingPathComponent("discovery3-\(UUID().uuidString)"); try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true); try? "{\"dependencies\":{\"@supabase/supabase-js\":\"2\"}}".write(to: r.appendingPathComponent("package.json"), atomically: true, encoding: .utf8); return r }())
check(onlyPackage.first?.provider == "supabase" && onlyPackage.first?.name.contains("library found") == true && onlyPackage.first?.checks.isEmpty == true && onlyPackage.first?.cloudCommands.first?.command == "supabase projects list", "a dependency alone suggests the service, without inventing a host")

// Hints for a missing CLI.
check(ProviderHints.tool(of: "sudo -n neonctl projects list") == "neonctl", "the tool of a command")
check(ProviderHints.advice(command: "neonctl projects list", stderr: "sh: neonctl: command not found", status: 127)?.contains("brew install neonctl") == true, "a missing CLI says how to install it")
check(ProviderHints.advice(command: "vercel ls", stderr: "Error: No existing credentials found. Please log in", status: 1)?.contains("vercel login") == true, "a signed-out CLI says how to sign in")
check(ProviderHints.hints["neonctl"]?.installCommand == "brew install neonctl" && ProviderHints.hints["vercel"]?.installCommand == "npm i -g vercel", "the install command is the one the hint names")
check(ProviderHints.hints.values.allSatisfy { $0.tool == "docker" || !CommandPolicy.classify($0.installCommand).isReadOnly }, "an install always asks first")
check(ProviderHints.problem(command: "fly status", stderr: "sh: fly: command not found", status: 127)?.problem == .missing && ProviderHints.problem(command: "vercel ls", stderr: "Please log in", status: 1)?.problem == .signedOut, "missing or signed out")
check(ProviderHints.advice(command: "uptime", stderr: "command not found", status: 127) == nil && ProviderHints.advice(command: "fly status", stderr: "app not found", status: 1) == nil, "other failures get no advice")

print(failures == 0 ? "All deployment discovery checks passed." : "\(failures) deployment discovery check(s) failed.")
exit(failures == 0 ? 0 : 1)
