import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let now = CloudServices.date("2026-10-12T12:00:00Z")!

// MARK: scope and queries
let commands = [CloudCommand(id: "a", title: "", command: "firebase hosting:sites:list --project demo-dev"), CloudCommand(id: "b", title: "", command: "fly status -a my-api")]
let scope = CloudServices.scope(of: commands)
check(scope.project == "demo-dev" && scope.app == "my-api", "the project and the app are read from the commands")
check(CloudServices.scope(of: [CloudCommand(id: "x", title: "", command: "firebase x --project a;rm")]).project == nil, "a project name with shell characters is refused")
check(CloudServices.queries(provider: "firebase", scope: scope).map(\.id) == ["hosting", "functions"], "firebase: hosting and functions")
check(CloudServices.queries(provider: "firebase", scope: CloudScope()).isEmpty, "firebase without a project asks nothing")
check(CloudServices.queries(provider: "fly", scope: scope).map(\.command) == ["fly status -a my-api --json", "fly machines list -a my-api --json"], "fly: app and machines")
check(CloudServices.queries(provider: "vercel", scope: CloudScope()).map(\.id) == ["deployments"], "vercel: deployments")
check(CloudServices.queries(provider: "aws", scope: scope).isEmpty, "other providers: none yet")
let all = CloudServices.queries(provider: "firebase", scope: scope) + CloudServices.queries(provider: "fly", scope: scope) + CloudServices.queries(provider: "vercel", scope: scope)
check(all.allSatisfy { CommandPolicy.classify($0.command).isReadOnly }, "every query is read-only: \(all.filter { !CommandPolicy.classify($0.command).isReadOnly }.map(\.command))")

// MARK: firebase
let functionsJSON = """
Warning: something printed before the JSON
{"status":"success","result":[
 {"id":"zeta","region":"us-central1","runtime":"nodejs22","availableMemoryMb":256,"callableTrigger":{},"environmentVariables":{"STRIPE_KEY":"sk_live_SECRET"},"uri":"https://zeta-x.a.run.app"},
 {"id":"alpha","region":"europe-west1","runtime":"nodejs22","availableMemoryMb":512,"httpsTrigger":{},"uri":"https://alpha-x.a.run.app"},
 {"id":"nightly","region":"us-central1","runtime":"nodejs22","scheduleTrigger":{"schedule":"every 24 hours"}},
 {"id":"bad name; rm -rf","region":"us-central1","callableTrigger":{}}
]}
"""
let functionsQuery = CloudQuery(id: "functions", group: "Functions", command: "")
let functions = CloudServices.parse(functionsQuery, provider: "firebase", scope: CloudScope(project: "demo-dev", app: nil), output: functionsJSON, now: now)
check(functions.map(\.name) == ["alpha", "bad name; rm -rf", "nightly", "zeta"], "functions are listed by name: \(functions.map(\.name))")
let alpha = functions.first { $0.name == "alpha" }!, zeta = functions.first { $0.name == "zeta" }!
check(alpha.details == ["https", "nodejs22", "europe-west1", "512 MB"], "details: trigger, runtime, region, memory")
check(alpha.openURL == "https://alpha-x.a.run.app" && zeta.openURL == nil, "an https function can be opened, a callable one cannot")
check(alpha.logCommand == "firebase functions:log --project demo-dev --only alpha --lines 100" && CommandPolicy.classify(alpha.logCommand!).isReadOnly, "the log command is the function's own and read-only")
check(functions.first { $0.name.hasPrefix("bad") }?.logCommand == nil, "a function name with shell characters gets no command")
check(functions.first { $0.name == "nightly" }?.details.first == "scheduled", "a scheduled trigger")
let dump = functions.map { "\($0)" }.joined()
check(!dump.contains("SECRET") && !dump.contains("STRIPE"), "environment variables are never read")
check(zeta.consoleURL == "https://console.firebase.google.com/project/demo-dev/functions", "console page of the functions")

let channelsJSON = """
{"status":"success","result":{"channels":[
 {"name":"projects/demo-dev/sites/demo-dev/channels/live","url":"https://demo-dev.web.app","updateTime":"2026-10-09T12:00:00.123Z"},
 {"name":"projects/demo-dev/sites/demo-dev/channels/pr-7","url":"https://demo-dev--pr-7-abc.web.app","updateTime":"2026-10-12T11:00:00Z","expireTime":"2026-10-14T12:00:00Z"}
]}}
"""
let channels = CloudServices.parse(CloudQuery(id: "hosting", group: "Hosting", command: ""), provider: "firebase", scope: CloudScope(project: "demo-dev", app: nil), output: channelsJSON, now: now)
check(channels.count == 2 && channels[0].name == "demo-dev · live" && channels[0].probe && channels[0].openURL == "https://demo-dev.web.app", "hosting: a channel per row, to open and to probe")
check(channels[0].details == ["updated 3 d ago", "never expires"], "hosting: age and expiry: \(channels[0].details)")
check(channels[1].details == ["updated 1 h ago", "expires in 2 d"], "hosting: a preview channel expires: \(channels[1].details)")
check(channels[0].consoleURL == "https://console.firebase.google.com/project/demo-dev/hosting/sites/demo-dev", "hosting: console page")

// MARK: fly
let appJSON = #"{"Name":"my-api","Status":"suspended","Hostname":"my-api.fly.dev","Version":7,"Secrets":[{"Name":"DATABASE_URL"}]}"#
let flyApp = CloudServices.parse(CloudQuery(id: "app", group: "App", command: ""), provider: "fly", scope: CloudScope(project: nil, app: "my-api"), output: appJSON, now: now)
check(flyApp.count == 1 && flyApp[0].state == "suspended" && flyApp[0].level == .warn && flyApp[0].openURL == "https://my-api.fly.dev" && !flyApp[0].probe, "fly app: state, address, never probed (a call would wake it)")
check(flyApp[0].logCommand == "fly logs -a my-api --no-tail" && CommandPolicy.classify(flyApp[0].logCommand!).isReadOnly && !"\(flyApp)".contains("DATABASE_URL"), "fly app: read-only log command, secrets untouched")
let machinesJSON = #"""
[{"id":"148e1","name":"a-machine","state":"started","region":"fra","updated_at":"2026-10-12T11:30:00Z","image_ref":{"repository":"my-org/my-api","tag":"deployment-1"},"config":{"env":{"TOKEN":"SECRETVALUE"}},"checks":[{"name":"http","status":"passing"}]},
 {"id":"287f2","name":"b-machine","state":"started","region":"ams","checks":[{"name":"http","status":"critical"}]},
 {"id":"391a3","name":"c-machine","state":"stopped","region":"fra"}]
"""#
let machines = CloudServices.parse(CloudQuery(id: "machines", group: "Machines", command: ""), provider: "fly", scope: CloudScope(project: nil, app: "my-api"), output: machinesJSON, now: now)
check(machines.map(\.name) == ["b-machine", "a-machine", "c-machine"], "fly machines: problems first: \(machines.map(\.name))")
check(machines[0].level == .bad && machines[1].level == .ok && machines[2].level == .unknown, "fly machines: a critical check is bad, started is ok, stopped is quiet")
check(machines[1].details == ["fra", "my-api", "updated 30 min ago"], "fly machines: details: \(machines[1].details)")
check(machines[1].logCommand == "fly logs -a my-api --machine 148e1 --no-tail" && CommandPolicy.classify(machines[1].logCommand!).isReadOnly, "fly machines: the machine's own log")
check(!"\(machines)".contains("SECRETVALUE"), "fly machines: environment is never read")

// MARK: vercel
let vercelJSON = #"""
{"contextName":"team","deployments":[
 {"name":"web","url":"web-abc123.vercel.app","state":"READY","target":"production","createdAt":1791806400000},
 {"name":"web","url":"web-def456.vercel.app","state":"ERROR","createdAt":1791802800000},
 {"name":"web","url":"web-ghi789.vercel.app","state":"BUILDING","target":null,"createdAt":1791806100000}],"pagination":{}}
"""#
let deployments = CloudServices.parse(CloudQuery(id: "deployments", group: "Deployments", command: ""), provider: "vercel", scope: CloudScope(), output: vercelJSON, now: now)
check(deployments.map(\.state) == ["ready", "error", "building"], "vercel: states: \(deployments.map { $0.state ?? "-" })")
check(deployments.map(\.level) == [.ok, .bad, .warn], "vercel: ready is ok, error bad, building warn")
check(deployments[0].details.first == "production" && deployments[1].details.first == "preview", "vercel: production or preview")
check(deployments[0].openURL == "https://web-abc123.vercel.app" && deployments[0].logCommand == "vercel inspect web-abc123.vercel.app --logs" && CommandPolicy.classify(deployments[0].logCommand!).isReadOnly, "vercel: open and a read-only build log")

// MARK: totals, probe, junk
let totals = CloudServices.totals(machines + deployments)
check(totals.map(\.group) == ["Machines", "Deployments"] && totals[0].bad == 1 && totals[0].ok == 1 && totals[0].count == 3 && totals[1].warn == 1, "totals per group: \(totals)")
check(CloudServices.probeResult(code: 200, seconds: 0.4).level == .ok && CloudServices.probeResult(code: 200, seconds: 5).level == .warn, "probe: 200 is ok, slow is a warning")
check(CloudServices.probeResult(code: 404, seconds: 0.2).level == .warn && CloudServices.probeResult(code: 503, seconds: 0.2).level == .bad && CloudServices.probeResult(code: nil, seconds: 8).state == "unreachable", "probe: 404 warns, 5xx and no answer are bad")
check(CloudServices.parse(functionsQuery, provider: "firebase", scope: CloudScope(project: "p", app: nil), output: "Error: Failed to authenticate", now: now).isEmpty, "output that is not JSON gives nothing")
check(CloudServices.parse(functionsQuery, provider: "firebase", scope: CloudScope(project: "p", app: nil), output: "{\"status\":\"success\",\"result\":{}}", now: now).isEmpty, "an unexpected shape gives nothing")

print(failures == 0 ? "All cloud services checks passed." : "\(failures) cloud services check(s) failed.")
exit(failures == 0 ? 0 : 1)
