import Foundation

// Test main for AgentUsage.swift and AgentUsageLogs.swift, run by tools/tests/agent-usage-tests.sh.

var failures = 0
var checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL line \(line): \(name)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

let hour: TimeInterval = 3600, day: TimeInterval = 86_400
let now = Date(timeIntervalSince1970: 1_790_000_000)
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!

func date(_ string: String) -> Date { OfficialUsageParser.isoDate(string)! }

func window(_ id: String, _ percent: Double, resets: TimeInterval?, duration: TimeInterval? = 5 * hour) -> QuotaWindow {
    QuotaWindow(id: id, label: id, title: id, percentUsed: percent, resetsAt: resets.map { now.addingTimeInterval($0) },
                duration: duration, source: .official)
}

// Levels (DEC-008): normal < 80, warning 80..<95, critical >= 95
expect(UsageLevel(percent: 0), .normal, "0% normal")
expect(UsageLevel(percent: 79.99), .normal, "79.99% normal")
expect(UsageLevel(percent: 80), .warning, "80% warning")
expect(UsageLevel(percent: 94.99), .warning, "94.99% warning")
expect(UsageLevel(percent: 95), .critical, "95% critical")
expect(UsageLevel(percent: 100), .critical, "100% critical")
expect(UsageLevel(percent: 130), .critical, "over limit critical")

// Headline window (DEC-009): highest percent; tie → later reset
let session = window("session", 40, resets: 2 * hour)
let weekly = window("weekly", 70, resets: 3 * day, duration: 7 * day)
expect(QuotaWindow.headline(of: [session, weekly])?.id, "weekly", "highest percent wins")
let tieShort = window("short", 50, resets: hour)
let tieLong = window("long", 50, resets: 5 * day)
expect(QuotaWindow.headline(of: [tieLong, tieShort])?.id, "long", "tie: later reset wins")
expect(QuotaWindow.headline(of: [tieShort, tieLong])?.id, "long", "tie: order does not matter")
expect(QuotaWindow.headline(of: [window("noReset", 50, resets: nil), tieShort])?.id, "short", "tie: a known reset beats none")
expect(QuotaWindow.headline(of: [])?.id, nil, "no windows")

// Remaining and pace
expect(session.remainingPercent, 60, "remaining percent")
expect(window("over", 120, resets: hour).remainingPercent, 0, "remaining never negative")
// 5h window resetting in 2h: 60% elapsed
expect(session.elapsedFraction(now: now).map { ($0 * 100).rounded() }, 60, "elapsed share")
expect(session.pace(now: now), .under, "40% used at 60% elapsed: under pace")
expect(window("w", 62, resets: 2 * hour).pace(now: now), .on, "within 5 points: on pace")
expect(window("w", 90, resets: 2 * hour).pace(now: now), .ahead, "ahead of pace")
expect(window("w", 90, resets: nil).pace(now: now), nil, "no pace without reset")

// Fallback windows (DEC-014)
let hourly = FallbackLimit(value: 1000, unit: .tokens, anchor: date("2026-09-01T10:00:00Z"), period: .hours(5))
let w1 = hourly.window(containing: date("2026-09-01T16:30:00Z"), calendar: utc)
expect(w1.start, date("2026-09-01T15:00:00Z"), "5h window start")
expect(w1.end, date("2026-09-01T20:00:00Z"), "5h window end")
let atBoundary = hourly.window(containing: date("2026-09-01T20:00:00Z"), calendar: utc)
expect(atBoundary.start, date("2026-09-01T20:00:00Z"), "boundary belongs to the next window")
let beforeAnchor = hourly.window(containing: date("2026-09-01T08:00:00Z"), calendar: utc)
expect(beforeAnchor.start, date("2026-09-01T05:00:00Z"), "anchor in the future: earlier window")
expect(beforeAnchor.end, date("2026-09-01T10:00:00Z"), "anchor in the future: ends at the anchor")

let weeklyLimit = FallbackLimit(value: 10, unit: .usd, anchor: date("2026-09-07T00:00:00Z"), period: .days(7))
let w2 = weeklyLimit.window(containing: date("2026-09-26T12:00:00Z"), calendar: utc)
expect(w2.start, date("2026-09-21T00:00:00Z"), "weekly window start")
expect(w2.end, date("2026-09-28T00:00:00Z"), "weekly window end")

let monthly = FallbackLimit(value: 100, unit: .tokens, anchor: date("2026-01-31T09:00:00Z"), period: .months(1))
let feb = monthly.window(containing: date("2026-03-01T00:00:00Z"), calendar: utc)
expect(feb.start, date("2026-02-28T09:00:00Z"), "Jan 31 + 1 month clamps to Feb 28")
expect(feb.end, date("2026-03-31T09:00:00Z"), "clamping does not accumulate: Mar 31")
let apr = monthly.window(containing: date("2026-04-15T00:00:00Z"), calendar: utc)
expect(apr.start, date("2026-03-31T09:00:00Z"), "Mar 31 window")
expect(apr.end, date("2026-04-30T09:00:00Z"), "Apr 30 clamp")

let estimate = hourly.quotaWindow(consumed: 850, now: date("2026-09-01T16:30:00Z"), calendar: utc)
expect(estimate.percentUsed, 85, "estimated percent")
expect(estimate.source, .estimated, "estimated source")
expect(estimate.remainingAmount, 150, "remaining in the limit's unit")
expect(estimate.resetsAt, date("2026-09-01T20:00:00Z"), "estimated reset")
expect(estimate.label, "5h", "estimated label")
expect(FallbackLimit(value: 0, unit: .tokens, anchor: now, period: .hours(5)).isValid, false, "zero limit invalid")
expect(FallbackLimit(value: 5, unit: .tokens, anchor: now, period: .days(0)).isValid, false, "zero period invalid")

// Limit round-trips through UserDefaults JSON
let encoded = try! JSONEncoder().encode(monthly)
expect(try! JSONDecoder().decode(FallbackLimit.self, from: encoded), monthly, "limit Codable round trip")

// State precedence (DEC-012)
let today = UsageAmount(tokens: 1234, costUSD: nil)
expect(AgentUsageState.resolve(official: [session], limit: hourly, limitUsage: today, today: today, localError: nil, now: now),
       .official([session]), "official first")
if case .userLimit(let w) = AgentUsageState.resolve(official: [], limit: hourly, limitUsage: UsageAmount(tokens: 500, costUSD: nil),
                                                     today: today, localError: nil, now: now) {
    expect(w.percentUsed, 50, "user limit second")
} else { expect("other", "userLimit", "user limit second") }
expect(AgentUsageState.resolve(official: nil, limit: nil, limitUsage: today, today: today, localError: nil, now: now),
       .noLimit(today: today), "no limit third")
expect(AgentUsageState.resolve(official: nil, limit: weeklyLimit, limitUsage: today, today: today, localError: nil, now: now),
       .noLimit(today: today), "USD limit without logged cost: no limit state")
expect(AgentUsageState.resolve(official: nil, limit: hourly, limitUsage: nil, today: nil, localError: "broken", now: now),
       .unavailable(reason: "broken"), "unreadable logs: unavailable, never zero")
expect(AgentUsageState.unavailable(reason: "x").headline, nil, "unavailable has no headline")

// Claude official response (shape seen 2026-09-26)
let claudeJSON = """
{"five_hour":{"utilization":19.0,"resets_at":"2026-09-26T22:59:59.760104+00:00"},
 "seven_day":{"utilization":13.0,"resets_at":"2026-10-02T18:59:59.760125+00:00"},
 "limits":[{"kind":"session","group":"session","percent":19,"severity":"normal","resets_at":"2026-09-26T22:59:59.760104+00:00","scope":null,"is_active":true},
           {"kind":"weekly_all","group":"weekly","percent":13,"resets_at":"2026-10-02T18:59:59.760125+00:00","scope":null},
           {"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":"2026-10-02T19:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
"""
let claude = OfficialUsageParser.claude(Data(claudeJSON.utf8)) ?? []
expect(claude.map(\.label), ["5h", "week", "Fable wk"], "claude limits labels")
expect(claude.map(\.percentUsed), [19, 13, 0], "claude limits percents")
expect(claude.first?.resetsAt.map { Int($0.timeIntervalSince1970) }, Int(date("2026-09-26T22:59:59Z").timeIntervalSince1970),
       "six-digit fractional seconds parse")
expect(QuotaWindow.headline(of: claude)?.id, "session", "claude headline")
expect(claude.map(\.modelScope), [nil, nil, "Fable"], "claude scoped window keeps its model")
let legacy = OfficialUsageParser.claude(Data("""
{"five_hour":{"utilization":42.5,"resets_at":"2026-09-26T22:59:59Z"},"seven_day":null,"seven_day_opus":{"utilization":5,"resets_at":null}}
""".utf8)) ?? []
expect(legacy.map(\.id), ["five_hour", "seven_day_opus"], "claude legacy keys")
expect(legacy.map(\.modelScope), [nil, "Opus"], "claude legacy scoped window")
expect(OfficialUsageParser.claude(Data(#"{"error":{"type":"authentication_error"}}"#.utf8)) == nil, true, "claude error body unrecognised")

// Codex official response (shape seen 2026-09-26)
let codexJSON = """
{"plan_type":"prolite","rate_limit":{"allowed":true,"limit_reached":false,
 "primary_window":{"used_percent":1,"limit_window_seconds":604800,"reset_after_seconds":592301,"reset_at":1791050407},
 "secondary_window":{"used_percent":55.5,"limit_window_seconds":18000,"reset_after_seconds":600}}}
"""
let codex = OfficialUsageParser.codex(Data(codexJSON.utf8), now: now) ?? []
expect(codex.map(\.label), ["week", "5h"], "codex labels")
expect(codex.first?.resetsAt, Date(timeIntervalSince1970: 1_791_050_407), "codex reset_at")
expect(codex.last?.resetsAt, now.addingTimeInterval(600), "codex reset_after_seconds fallback")
expect(QuotaWindow.headline(of: codex)?.id, "secondary_window", "codex headline")
expect(OfficialUsageParser.codex(Data(#"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#.utf8), now: now) == nil,
       true, "codex without windows unrecognised")

// Antigravity (DEC-020): `agy --output-format json -p "/usage"`, shape seen 2026-11-14 (descriptions shortened)
func antigravityJSON(_ groups: String) -> String {
    #"{"conversation_id":"","status":"SUCCESS","response":"x","duration_seconds":0,"num_turns":0,"usage":{"total_tokens":0},"command":{"name":"usage","data":{"description":"d","groups":[\#(groups)]}}}"#
}
let antigravityGroups = """
{"name":"Gemini Models","description":"Models within this group: Gemini 4 Hydrogen, Gemini 3.8 Flash","buckets":[
  {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-22T03:19:24Z"},
  {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-11-15T08:19:24Z"}]},
{"name":"Claude and GPT models","description":"Models within this group: Claude Opus 5.5","buckets":[
  {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-11-22T03:19:24Z"},
  {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-11-15T08:19:24Z"}]},
{"name":"Gemini 4 Argon","description":"Argon quota is separate.","buckets":[
  {"id":"gemini-argon-wtu-weekly","name":"Gemini 4 Argon Weekly Limit","description":"You have used some.","window":"weekly","remaining_fraction":0.9298666715621948,"reset_time":"2026-11-22T03:10:56Z"}]}
"""
let antigravityData = Data(antigravityJSON(antigravityGroups).utf8)
let antigravity = OfficialUsageParser.antigravity(antigravityData) ?? []
expect(antigravity.map(\.id), ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h", "gemini-argon-wtu-weekly"], "antigravity bucket ids")
expect(antigravity.map(\.label), ["Gemini wk", "Gemini 5h", "Claude and GPT wk", "Claude and GPT 5h", "Gemini 4 Argon wk"],
       "antigravity labels carry the group, without the word models")
expect(antigravity.map(\.title).last, "Gemini 4 Argon · Weekly", "antigravity title")
expect(antigravity.map(\.title).first, "Gemini Models · Weekly", "antigravity title keeps the full group name")
expect(antigravity.map { ($0.percentUsed * 10).rounded() / 10 }, [0, 0, 0, 0, 7.0], "antigravity percent used is 1 - remaining fraction")
expect(antigravity.map { $0.duration ?? -1 }, [7 * day, 5 * hour, 7 * day, 5 * hour, 7 * day], "antigravity window lengths")
expect(antigravity.map { $0.resetsAt == nil }, [true, true, true, true, false], "a bucket nobody used has no reset time (agy reports now + window)")
expect(antigravity.last?.resetsAt, date("2026-11-22T03:10:56Z"), "a used bucket keeps its reset time")
expect(antigravity.map { $0.modelScope ?? "" }, ["Gemini Models", "Gemini Models", "Claude and GPT models", "Claude and GPT models", "Gemini 4 Argon"],
       "antigravity group is the scope")
expect(antigravity.allSatisfy { $0.source == .official }, true, "antigravity is official data")
expect(QuotaWindow.headline(of: antigravity)?.id, "gemini-argon-wtu-weekly", "antigravity headline is the most used window")
expect(antigravity.last?.pace(now: date("2026-11-19T03:10:56Z")), .under, "7% used with 4 of 7 days gone: under pace")
expect(antigravity.last?.pace(now: date("2026-11-15T03:10:56Z")), .ahead, "7% used before the window has started to run: ahead")
expect(antigravity.first?.pace(now: now), nil, "an unused bucket has no pace")

let exhausted = OfficialUsageParser.antigravity(Data(antigravityJSON(#"""
{"name":"Gemini Models","buckets":[{"id":"a","window":"5h","remaining_fraction":0,"reset_time":"2026-11-15T08:19:24Z"},
 {"id":"b","window":"weekly","remaining_fraction":-0.2,"reset_time":"2026-11-22T03:19:24Z"},
 {"id":"c","window":"weekly","remaining_fraction":1.3,"reset_time":"2026-11-22T03:19:24Z"},
 {"id":"d","window":"daily","remaining_fraction":0.5,"reset_time":"2026-11-15T03:19:24Z"},
 {"id":"e","window":"5h","reset_time":"2026-11-15T03:19:24Z"}]}
"""#).utf8)) ?? []
expect(exhausted.map(\.id), ["a", "b", "c", "d"], "a bucket without a fraction is skipped")
expect(exhausted.map(\.percentUsed), [100, 100, 0, 50], "fractions are clamped to 0...100% used")
expect(exhausted.first?.level, .critical, "an exhausted bucket is critical")
expect(exhausted.first?.resetsAt, date("2026-11-15T08:19:24Z"), "an exhausted bucket keeps its reset time")
expect(exhausted.last?.label, "Gemini daily", "unknown window kind keeps its name")
expect(exhausted.last?.duration, nil, "unknown window kind has no length")
let unnamed = OfficialUsageParser.antigravity(Data(antigravityJSON(#"{"buckets":[{"window":"5h","remaining_fraction":0.4,"reset_time":"2026-11-15T08:19:24Z"}]}"#).utf8)) ?? []
expect(unnamed.map(\.id), ["0_0_5h"], "bucket without an id gets a stable one")
expect(unnamed.map(\.label), ["Group 1 5h"], "group without a name")
expect(OfficialUsageParser.antigravity(Data("{}".utf8)) == nil, true, "antigravity: empty object unrecognised")
expect(OfficialUsageParser.antigravity(Data(antigravityJSON("").utf8)) == nil, true, "antigravity: no groups unrecognised")
expect(OfficialUsageParser.antigravity(Data(antigravityJSON(#"{"name":"G","buckets":[]}"#).utf8)) == nil, true, "antigravity: no buckets unrecognised")
expect(OfficialUsageParser.antigravity(Data("Authentication required".utf8)) == nil, true, "antigravity: text unrecognised")

// What one `agy` run means (exit -1: could not start, -2: stopped at our timeout)
let signInPrompt = "Authentication required. Please visit the URL to log in:\n  https://accounts.google.com/o/oauth2/auth?client_id=x\n\nWaiting for authentication (timeout 60s)..."
expect(OfficialUsageParser.antigravityRun(exitCode: 0, stdout: String(data: antigravityData, encoding: .utf8)!, stderr: ""),
       .windows(antigravity), "a good answer gives the windows")
expect(OfficialUsageParser.antigravityRun(exitCode: -2, stdout: signInPrompt, stderr: ""), .signedOut, "sign-in prompt cut at our timeout is signed out")
expect(OfficialUsageParser.antigravityRun(exitCode: 1, stdout: "", stderr: "Error: authentication failed or timed out"), .signedOut, "authentication failed is signed out")
expect(OfficialUsageParser.antigravityRun(exitCode: -2, stdout: "", stderr: ""), .failed("agy did not answer in time"), "timeout without output")
expect(OfficialUsageParser.antigravityRun(exitCode: -1, stdout: "", stderr: "no such file"), .failed("could not start the agy command"), "could not start")
expect(OfficialUsageParser.antigravityRun(exitCode: 0, stdout: "{\"status\":\"SUCCESS\"}", stderr: ""), .failed("response not recognised"), "unknown json")
expect(OfficialUsageParser.antigravityRun(exitCode: 2, stdout: "boom", stderr: ""), .failed("response not recognised"), "other failure")

// The agents and what differs between them
expect(UsageAgent.allCases.map(\.rawValue), ["claude", "codex", "antigravity"], "agents in bar order")
expect(UsageAgent.allCases.map(\.hasLocalLogs), [true, true, false], "only Claude and Codex have local logs")
expect(UsageAgent.antigravity.displayName, "Antigravity", "antigravity name")
expect(UsageAgent.antigravity.dataDirectoryName, ".gemini/antigravity-cli", "antigravity data directory")
expect(UsageAgent.antigravity.hiddenKey, "settings.usage.antigravity.hidden", "antigravity hide key")
expect(UsageAgent.allCases.map(\.pollInterval), [300, 300, 600], "Antigravity is read every 10 minutes")
expect(UsageAgent.allCases.map(\.signedOutInterval), [300, 300, 1800], "Antigravity waits 30 minutes while signed out")
expect(AgentUsageState.resolve(official: antigravity, limit: nil, limitUsage: nil, today: nil, localError: nil, now: now).headline?.id,
       "gemini-argon-wtu-weekly", "antigravity official state")

// Formatting
expect(UsageFormat.tokens(950), "950", "tokens plain")
expect(UsageFormat.tokens(12_345), "12.3K", "tokens K")
expect(UsageFormat.tokens(1_234_567), "1.2M", "tokens M")
expect(UsageFormat.tokens(345_000_000), "345M", "tokens large M")
expect(UsageFormat.countdown(30), "<1m", "countdown seconds")
expect(UsageFormat.countdown(45 * 60), "45m", "countdown minutes")
expect(UsageFormat.countdown(92 * 60), "1h32m", "countdown hours")
expect(UsageFormat.countdown(2 * hour), "2h", "countdown whole hours")
expect(UsageFormat.countdown(6 * day + 4 * hour + 59), "6d 4h", "countdown days")
expect(UsageFormat.ago(10), "just now", "ago now")
expect(UsageFormat.ago(3 * 60), "3 min ago", "ago minutes")

// Local log lines
let dates = UsageLogLine.timestampFormatter()
let claudeLine = Data("""
{"type":"assistant","timestamp":"2026-09-26T08:00:04.131Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-sonnet-5","usage":{"input_tokens":2,"cache_creation_input_tokens":27007,"cache_read_input_tokens":11694,"output_tokens":322}}}
""".utf8)
let parsedClaude = UsageLogLine.claude(claudeLine, dates: dates)
expect(parsedClaude?.key, "msg_1:req_1", "claude dedupe key")
expect(parsedClaude?.event.tokens, 2 + 27007 + 11694 + 322, "claude tokens include cache")
expect(parsedClaude?.event.costUSD, nil, "claude no cost recorded")
let costLine = Data(#"{"type":"assistant","timestamp":"2026-09-26T08:00:04Z","costUSD":0.5,"message":{"id":"m","usage":{"input_tokens":1}}}"#.utf8)
expect(UsageLogLine.claude(costLine, dates: dates)?.event.costUSD, 0.5, "timestamp without fraction; cost recorded")
let userLine = Data(#"{"type":"user","timestamp":"2026-09-26T08:00:04.131Z","message":{"usage":{}}}"#.utf8)
expect(UsageLogLine.claude(userLine, dates: dates) == nil, true, "user lines ignored")
let codexLine = Data("""
{"timestamp":"2026-09-25T15:21:09.530Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":21101,"cached_input_tokens":12416,"output_tokens":368,"total_tokens":21469}},"rate_limits":{}}}
""".utf8)
expect(UsageLogLine.codex(codexLine, dates: dates)?.total, 21469, "codex cumulative total")
let codexNull = Data(#"{"timestamp":"2026-09-25T15:21:09.530Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#.utf8)
expect(UsageLogLine.codex(codexNull, dates: dates)?.total, -1, "codex null info recognised, no tokens")

// Reader over a temporary home: dedupe, deltas, incremental reads, unrecognised format
let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-usage-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: home) }
let claudeDir = home.appendingPathComponent(".claude/projects/p")
let codexDir = home.appendingPathComponent(".codex/sessions/2026/09/26")
try! FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

func claudeRecord(_ id: String, _ tokens: Int, _ time: String) -> String {
    #"{"type":"assistant","timestamp":"\#(time)","requestId":"r\#(id)","message":{"id":"m\#(id)","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"#
}
let session1 = claudeDir.appendingPathComponent("a.jsonl")
try! ([claudeRecord("1", 100, "2026-09-26T08:00:00.000Z"), claudeRecord("1", 100, "2026-09-26T08:00:00.500Z"),
       #"{"type":"user","message":{"content":"hi"}}"#, claudeRecord("2", 50, "2026-09-25T08:00:00.000Z")]
    .joined(separator: "\n") + "\n").write(to: session1, atomically: true, encoding: .utf8)
// The same call again in a sub-agent file is counted once.
try! (claudeRecord("1", 100, "2026-09-26T08:00:00.000Z") + "\n" + claudeRecord("3", 7, "2026-09-26T09:00:00.000Z") + "\n")
    .write(to: claudeDir.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)

let claudeReader = UsageLogReader(agent: .claude, home: home)
let since = date("2026-09-26T00:00:00Z")
let events = try! claudeReader.events(since: .distantPast)
expect(events.usage(from: since).tokens, 107, "claude: duplicates counted once, window filter")
expect(events.usage(from: .distantPast).tokens, 157, "claude: all calls")

// Append a line and a partial line: only the complete one counts; the rest on the next scan.
let handle = try! FileHandle(forWritingTo: session1)
handle.seekToEndOfFile()
handle.write(Data((claudeRecord("4", 1000, "2026-09-26T10:00:00.000Z") + "\n" + #"{"type":"assist"#).utf8))
try! handle.close()
expect(try! claudeReader.events(since: .distantPast).usage(from: since).tokens, 1107, "claude: incremental append")
let handle2 = try! FileHandle(forWritingTo: session1)
handle2.seekToEndOfFile()
handle2.write(Data((#"ant","timestamp":"2026-09-26T11:00:00.000Z","requestId":"r5","message":{"id":"m5","usage":{"input_tokens":3}}}"# + "\n").utf8))
try! handle2.close()
expect(try! claudeReader.events(since: .distantPast).usage(from: since).tokens, 1110, "claude: partial line completed later")

func codexRecord(_ total: Int?, _ time: String) -> String {
    let info = total.map { #"{"total_token_usage":{"total_tokens":\#($0)}}"# } ?? "null"
    return #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":\#(info)}}"#
}
try! ([codexRecord(nil, "2026-09-26T08:00:00.000Z"), codexRecord(1000, "2026-09-26T08:01:00.000Z"),
       codexRecord(1000, "2026-09-26T08:01:01.000Z"), codexRecord(1500, "2026-09-26T08:02:00.000Z"),
       codexRecord(200, "2026-09-26T09:00:00.000Z")].joined(separator: "\n") + "\n")
    .write(to: codexDir.appendingPathComponent("rollout-1.jsonl"), atomically: true, encoding: .utf8)
let codexEvents = try! UsageLogReader(agent: .codex, home: home).events(since: .distantPast)
expect(codexEvents.usage(from: since).tokens, 1700, "codex: deltas, repeats ignored, counter restart")
expect(codexEvents.recordsCost, false, "codex records no cost")

// A changed format is an error, never zero.
let broken = home.appendingPathComponent("broken")
try! FileManager.default.createDirectory(at: broken.appendingPathComponent(".claude/projects/p"), withIntermediateDirectories: true)
try! (#"{"type":"assistant","usage":{"tokens":5}}"# + "\n")
    .write(to: broken.appendingPathComponent(".claude/projects/p/x.jsonl"), atomically: true, encoding: .utf8)
do {
    _ = try UsageLogReader(agent: .claude, home: broken).events(since: .distantPast)
    expect("no error", "unrecognised", "changed format")
} catch let error as UsageLogError {
    expect(error, .unrecognised("Claude Code log format not recognised"), "changed format")
} catch { expect("\(error)", "unrecognised", "changed format") }
do {
    _ = try UsageLogReader(agent: .codex, home: broken).events(since: .distantPast)
    expect("no error", "unreadable", "missing logs")
} catch let error as UsageLogError {
    expect(error, .unreadable("No local logs in ~/.codex"), "missing logs")
} catch { expect("\(error)", "unreadable", "missing logs") }

print(failures == 0 ? "OK: \(checks) checks passed" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
