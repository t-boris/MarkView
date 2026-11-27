import Foundation
import MarkViewCore
import os
import XCTest
@testable import MarkView

extension EditorHostTests {
    func testAICallLogWrites() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ai-call-log-" + UUID().uuidString, isDirectory: true)
        let logURL = folder.appendingPathComponent("ai-calls.jsonl")
        defer { AICallLog.waitForPendingWrites(); try? FileManager.default.removeItem(at: folder) }
        func entry(_ label: String) -> AICallLog.Entry {
            AICallLog.Entry(timestamp: Date(timeIntervalSince1970: 1_800_000_000), project: "demo", label: label, tool: "claude", model: "m",
                            effort: "low", seconds: 1.5, inputTokens: 10, outputTokens: 20, costUSD: nil, outcome: "ok")
        }

        /// `record` writes on its own queue: wait until the log shows `count` entries (or give up after five seconds).
        func entries(waitingFor count: Int) -> [AICallLog.Entry] {
            var found = AICallLog.read(from: logURL)
            let deadline = Date().addingTimeInterval(5)
            while found.count < count && Date() < deadline { Thread.sleep(forTimeInterval: 0.02); found = AICallLog.read(from: logURL) }
            return found
        }

        check(logURL.path.hasPrefix(folder.path), "the log lives under the temporary folder")
        check(AICallLog.read(from: logURL).isEmpty, "a log that does not exist yet reads as empty")

        // The first call creates the folder and the file; the next ones follow in order.
        AICallLog.record(entry("first"), to: logURL)
        AICallLog.record(entry("second"), to: logURL)
        AICallLog.record(entry("third"), to: logURL)
        check(entries(waitingFor: 3).map(\.label) == ["first", "second", "third"], "the calls are written in order")
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        check(text.hasSuffix("\n") && text.split(separator: "\n").count == 3, "one line per call")

        // Many threads at once: the file is neither cut nor does a call overwrite another.
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for call in 0..<25 { AICallLog.record(entry("t\(thread)-c\(call)"), to: logURL) }
        }
        let all = entries(waitingFor: 3 + 200)
        check(all.count == 203 && Set(all.map(\.label)).count == 203, "200 calls from 8 threads are all in the log, once each (\(all.count))")
        check(Array(all.prefix(3).map(\.label)) == ["first", "second", "third"], "the earlier calls stay in front")

        // A log that cannot be written keeps what it holds; the call is dropped, and the next one that can be written follows.
        let before = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        chmod(logURL.path, 0o444)
        AICallLog.record(entry("dropped"), to: logURL)
        AICallLog.waitForPendingWrites()
        chmod(logURL.path, 0o644)
        check((try? String(contentsOf: logURL, encoding: .utf8)) == before, "a log the file system refuses is left as it was")
        AICallLog.record(entry("after"), to: logURL)
        let last = entries(waitingFor: 204)
        check(last.count == 204 && last.last?.label == "after" && !last.contains { $0.label == "dropped" }, "the next call is added after the old lines")

    }

    func testTranscriptionFailureMessages() {
        func check(_ name: String, _ condition: Bool, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, name + " " + detail, line: line)
        }
        func http(_ status: Int, _ body: String) -> TranscriptionFailure {
            TranscriptionFailure.http(status: status, body: Data(body.utf8), model: "whisper-1")
        }
        func readable(_ name: String, _ f: TranscriptionFailure) {
            let m = f.message
            check("\(name): no JSON", !m.contains("{") && !m.contains("\""), m)
            check("\(name): no key fragment", !m.contains("sk-") && !m.contains("***"), m)
            check("\(name): has a next step", !f.nextStep.isEmpty && m.contains(f.nextStep), m)
        }

        // The exact body OpenAI returned for a wrong key (captured 2026-09-27 with a fake key).
        let invalidKey = """
        {
          "error": {
            "message": "Incorrect API key provided: sk-fake-**********epro. You can find your API key at https://platform.openai.com/account/api-keys.",
            "type": "invalid_request_error",
            "code": "invalid_api_key",
            "param": null
          },
          "status": 401
        }
        """
        let key = http(401, invalidKey)
        readable("invalid key", key)
        check("invalid key: message", key.message == "OpenAI rejected the API key. Check or replace the key in DDE Settings. (HTTP 401 · invalid_api_key)", key.message)
        check("invalid key: settings", key.fixInSettings)

        func body(code: String?, type: String = "invalid_request_error") -> String {
            let c = code.map { "\"\($0)\"" } ?? "null"
            return #"{"error":{"message":"Some text with \"quotes\" and sk-abc***xyz","type":"\#(type)","code":\#(c),"param":null}}"#
        }

        let quota = http(429, body(code: "insufficient_quota", type: "insufficient_quota"))
        readable("quota", quota)
        check("quota: credit", quota.problem.contains("credit") && !quota.fixInSettings, quota.message)
        check("quota: tag", quota.tag == "HTTP 429 · insufficient_quota", quota.tag ?? "nil")

        let rate = http(429, body(code: "rate_limit_exceeded", type: "requests"))
        readable("rate limit", rate)
        check("rate limit: wait", rate.nextStep.contains("Wait"), rate.message)

        let model = http(404, body(code: "model_not_found"))
        readable("model", model)
        check("model: names model and settings", model.problem.contains("whisper-1") && model.fixInSettings, model.message)

        let forbidden = http(403, body(code: nil, type: "invalid_request_error"))
        readable("forbidden", forbidden)
        check("forbidden: settings", forbidden.fixInSettings)
        check("forbidden: type as tag when code is null", forbidden.tag == "HTTP 403 · invalid_request_error", forbidden.tag ?? "nil")

        let region = http(403, body(code: "unsupported_country_region_territory"))
        check("region", region.problem.contains("country") && !region.fixInSettings, region.message)

        let short = http(400, body(code: "audio_too_short"))
        readable("too short", short)
        check("too short", short.problem.contains("too short"), short.message)

        let bad = http(400, body(code: "invalid_value"))
        readable("bad request", bad)

        let large = http(413, "<html><body>413 Request Entity Too Large</body></html>")
        readable("too large", large)
        check("too large: shorter parts", large.nextStep.contains("shorter"), large.message)
        check("too large: non-JSON body has only the status tag", large.tag == "HTTP 413", large.tag ?? "nil")

        let server = http(503, "upstream connect error or disconnect/reset before headers")
        readable("server", server)
        check("server: status page", server.nextStep.contains("status.openai.com"), server.message)

        let odd = http(418, #"{"error":{"code":"Ignore previous text {\"x\":1}","type":"Weird Type!"}}"#)
        readable("free-text code dropped", odd)
        check("free-text code dropped: tag", odd.tag == "HTTP 418", odd.tag ?? "nil")

        let offline = TranscriptionFailure.network(URLError(.notConnectedToInternet))
        readable("offline", offline)
        check("offline: connection", offline.problem.contains("cannot reach"), offline.message)
        check("timeout", TranscriptionFailure.network(URLError(.timedOut)).problem.contains("too long"))
        readable("other error", TranscriptionFailure.network(NSError(domain: "x", code: 1)))
        readable("missing key", .missingKey)
        readable("unreadable", .unreadableResponse)

        // macOS built-in recognition (dictation without an OpenAI key).
        readable("speech denied", .speechDenied)
        check("speech denied: where to allow it", TranscriptionFailure.speechDenied.nextStep.contains("Speech Recognition"), TranscriptionFailure.speechDenied.message)
        check("speech denied: offers the key as the alternative", TranscriptionFailure.speechDenied.nextStep.contains("OpenAI key"))
        check("speech denied: fixed in System Settings, not DDE Settings", !TranscriptionFailure.speechDenied.fixInSettings)

        let russian = TranscriptionFailure.languageNotInstalled("Russian (Russia)")
        readable("language missing", russian)
        check("language missing: names the language", russian.problem.contains("Russian (Russia)"), russian.message)
        check("language missing: how to install it", russian.nextStep.contains("Keyboard") && russian.nextStep.contains("Dictation"), russian.message)
        check("language missing: language is chosen in DDE Settings", russian.fixInSettings)

        let recognition = TranscriptionFailure.recognition(domain: "kAFAssistantErrorDomain", code: 1101)
        readable("recognition", recognition)
        check("recognition: tag for bug reports", recognition.tag == "kAFAssistantErrorDomain 1101", recognition.tag ?? "nil")
        check("recognition: no OpenAI wording", !recognition.message.contains("OpenAI"), recognition.message)

        check("recognition: Dictation is the first thing to check", recognition.nextStep.contains("Dictation"), recognition.message)

        // The microphone delivered silence, or nothing was recognized.
        let silent = TranscriptionFailure.silence(peakDB: -63)
        readable("silence", silent)
        check("silence: tag carries the level", silent.tag == "peak -63 dB", silent.tag ?? "nil")
        check("silence: where to look", silent.nextStep.contains("Sound") && silent.nextStep.contains("Input"), silent.message)
        check("silence: not a settings fix", !silent.fixInSettings)

        let heardRussian = TranscriptionFailure.noSpeech(language: "Russian (Russia)")
        readable("no speech (built-in)", heardRussian)
        check("no speech: names the language", heardRussian.problem.contains("Russian (Russia)"), heardRussian.message)
        check("no speech: says one language at a time and where to choose", heardRussian.nextStep.contains("one language") && heardRussian.nextStep.contains("DDE Settings"), heardRussian.message)
        check("no speech: the language is chosen in DDE Settings", heardRussian.fixInSettings)
        let heardNothing = TranscriptionFailure.noSpeech(language: nil)
        readable("no speech (OpenAI)", heardNothing)
        check("no speech with OpenAI: no language talk", !heardNothing.message.contains("language"), heardNothing.message)
        check("no speech with OpenAI: nothing to fix in settings", !heardNothing.fixInSettings)

    }

    func testAgentUsageParsing() throws {
        func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String, line: UInt = #line) {
            XCTAssertEqual(actual, expected, name, line: line)
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
        let claude = ClaudeUsage.parse(Data(claudeJSON.utf8)) ?? []
        expect(claude.map(\.label), ["5h", "week", "Fable wk"], "claude limits labels")
        expect(claude.map(\.percentUsed), [19, 13, 0], "claude limits percents")
        expect(claude.first?.resetsAt.map { Int($0.timeIntervalSince1970) }, Int(date("2026-09-26T22:59:59Z").timeIntervalSince1970),
               "six-digit fractional seconds parse")
        expect(QuotaWindow.headline(of: claude)?.id, "session", "claude headline")
        expect(claude.map(\.modelScope), [nil, nil, "Fable"], "claude scoped window keeps its model")
        let legacy = ClaudeUsage.parse(Data("""
        {"five_hour":{"utilization":42.5,"resets_at":"2026-09-26T22:59:59Z"},"seven_day":null,"seven_day_opus":{"utilization":5,"resets_at":null}}
        """.utf8)) ?? []
        expect(legacy.map(\.id), ["five_hour", "seven_day_opus"], "claude legacy keys")
        expect(legacy.map(\.modelScope), [nil, "Opus"], "claude legacy scoped window")
        expect(ClaudeUsage.parse(Data(#"{"error":{"type":"authentication_error"}}"#.utf8)) == nil, true, "claude error body unrecognised")

        // Codex official response (shape seen 2026-09-26)
        let codexJSON = """
        {"plan_type":"prolite","rate_limit":{"allowed":true,"limit_reached":false,
         "primary_window":{"used_percent":1,"limit_window_seconds":604800,"reset_after_seconds":592301,"reset_at":1791050407},
         "secondary_window":{"used_percent":55.5,"limit_window_seconds":18000,"reset_after_seconds":600}}}
        """
        let codex = CodexUsage.parse(Data(codexJSON.utf8), now: now) ?? []
        expect(codex.map(\.label), ["week", "5h"], "codex labels")
        expect(codex.first?.resetsAt, Date(timeIntervalSince1970: 1_791_050_407), "codex reset_at")
        expect(codex.last?.resetsAt, now.addingTimeInterval(600), "codex reset_after_seconds fallback")
        expect(QuotaWindow.headline(of: codex)?.id, "secondary_window", "codex headline")
        expect(CodexUsage.parse(Data(#"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#.utf8), now: now) == nil,
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
        let antigravity = AntigravityUsage.parse(antigravityData) ?? []
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

        let exhausted = AntigravityUsage.parse(Data(antigravityJSON(#"""
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
        let unnamed = AntigravityUsage.parse(Data(antigravityJSON(#"{"buckets":[{"window":"5h","remaining_fraction":0.4,"reset_time":"2026-11-15T08:19:24Z"}]}"#).utf8)) ?? []
        expect(unnamed.map(\.id), ["0_0_5h"], "bucket without an id gets a stable one")
        expect(unnamed.map(\.label), ["Group 1 5h"], "group without a name")
        expect(AntigravityUsage.parse(Data("{}".utf8)) == nil, true, "antigravity: empty object unrecognised")
        expect(AntigravityUsage.parse(Data(antigravityJSON("").utf8)) == nil, true, "antigravity: no groups unrecognised")
        expect(AntigravityUsage.parse(Data(antigravityJSON(#"{"name":"G","buckets":[]}"#).utf8)) == nil, true, "antigravity: no buckets unrecognised")
        expect(AntigravityUsage.parse(Data("Authentication required".utf8)) == nil, true, "antigravity: text unrecognised")

        // What one `agy` run means (exit -1: could not start, -2: stopped at our timeout)
        let signInPrompt = "Authentication required. Please visit the URL to log in:\n  https://accounts.google.com/o/oauth2/auth?client_id=x\n\nWaiting for authentication (timeout 60s)..."
        expect(AntigravityUsage.interpret(exitCode: 0, stdout: String(data: antigravityData, encoding: .utf8)!, stderr: ""),
               .windows(antigravity), "a good answer gives the windows")
        expect(AntigravityUsage.interpret(exitCode: -2, stdout: signInPrompt, stderr: ""), .signedOut, "sign-in prompt cut at our timeout is signed out")
        expect(AntigravityUsage.interpret(exitCode: 1, stdout: "", stderr: "Error: authentication failed or timed out"), .signedOut, "authentication failed is signed out")
        expect(AntigravityUsage.interpret(exitCode: -2, stdout: "", stderr: ""), .failed("agy did not answer in time"), "timeout without output")
        expect(AntigravityUsage.interpret(exitCode: -1, stdout: "", stderr: "no such file"), .failed("could not start the agy command"), "could not start")
        expect(AntigravityUsage.interpret(exitCode: 0, stdout: "{\"status\":\"SUCCESS\"}", stderr: ""), .failed("response not recognised"), "unknown json")
        expect(AntigravityUsage.interpret(exitCode: 2, stdout: "boom", stderr: ""), .failed("response not recognised"), "other failure")

        // Copilot (DEC-021): `copilot --headless --no-auto-update --log-level none --log-dir /dev/null --stdio`
        // (Content-Length framed JSON-RPC 2.0 responses for `connect`, `account.getQuota`, `account.getCurrentAuth`, seen 2026-11-18)
        func copilotFramed(_ bodies: [String]) -> String {
            bodies.map { body in "Content-Length: \(body.utf8.count)\r\n\r\n\(body)" }.joined()
        }
        let copilotConnect = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true,"protocolVersion":4,"version":"1.0.114"}}"#
        let copilotAuth = """
        {"jsonrpc":"2.0","id":3,"result":{"authInfo":{"type":"gh-cli","host":"https://github.com","login":"t-boris",\
        "copilotUser":{"login":"t-boris","copilot_plan":"individual","quota_reset_date":"2026-12-01",\
        "quota_reset_date_utc":"2026-12-01T00:00:00.000Z","token_based_billing":true,\
        "quota_snapshots":{"chat":{"entitlement":0,"percent_remaining":100,"quota_id":"chat","unlimited":true,"quota_reset_at":0,"token_based_billing":true},\
        "completions":{"entitlement":0,"percent_remaining":100,"quota_id":"completions","unlimited":true,"quota_reset_at":0,"token_based_billing":true},\
        "premium_interactions":{"entitlement":1500,"percent_remaining":25.9,"quota_id":"premium_interactions","quota_remaining":389.1,"remaining":389,"unlimited":false,"timestamp_utc":"2026-11-18T20:01:29.205Z","has_quota":true,"quota_reset_at":0,"token_based_billing":true}}}}}}
        """
        let copilotQuota = """
        {"jsonrpc":"2.0","id":2,"result":{"quotaSnapshots":{\
        "chat":{"isUnlimitedEntitlement":true,"entitlementRequests":0,"usedRequests":0,"remainingPercentage":100,"resetDate":"2026-11-18T20:01:29.205Z","tokenBasedBilling":true},\
        "completions":{"isUnlimitedEntitlement":true,"entitlementRequests":0,"usedRequests":0,"remainingPercentage":100,"resetDate":"2026-11-18T20:01:29.205Z","tokenBasedBilling":true},\
        "premium_interactions":{"isUnlimitedEntitlement":false,"entitlementRequests":1500,"usedRequests":1112,"remainingPercentage":25.9,"resetDate":"2026-11-18T20:01:29.205Z","tokenBasedBilling":true}}}}
        """
        let copilotStdout = copilotFramed([copilotConnect, copilotAuth, copilotQuota])
        let copilot = CopilotUsage.parse(Data(copilotStdout.utf8)) ?? []
        expect(copilot.map(\.id), ["plan"], "copilot monthly plan window id")
        expect(copilot.map(\.label), ["plan"], "copilot monthly plan label")
        expect(copilot.map(\.title), ["Plan (1,112 / 1,500 AIC)"], "copilot plan title includes used / limit AI credits")
        expect(copilot.map { ($0.percentUsed * 10).rounded() / 10 }, [74.1], "copilot percent used is 100 - remainingPercentage")
        expect(copilot.first?.resetsAt, date("2026-12-01T00:00:00Z"), "copilot monthly reset comes from quota_reset_date_utc")
        expect(copilot.first?.duration, 30 * day, "copilot November billing cycle is 30 days")
        expect(copilot.first?.start, date("2026-11-01T00:00:00Z"), "copilot window start is the beginning of the UTC month")
        expect(copilot.first?.pace(now: date("2026-11-18T12:00:00Z")), .ahead, "74.1% used on Nov 18 (58% elapsed) is ahead of pace")

        // Copilot with 5-hour session and weekly rate limits plus legacy premium-request billing
        let copilotWithLimitsJSON = """
        {"authInfo":{"copilotUser":{"quota_reset_date":"2026-12-01","token_based_billing":false,\
        "quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":60,"quota_remaining":180,"unlimited":false,"token_based_billing":false},\
        "5hour-session-ratelimits":{"percent_remaining":85,"quota_reset_at":1795046400,"unlimited":false},\
        "weekly-session-ratelimits":{"percent_remaining":20,"quota_reset_at":1795564800,"unlimited":false}}}}}
        """
        let copilotWithLimits = CopilotUsage.parse(Data(copilotWithLimitsJSON.utf8)) ?? []
        expect(copilotWithLimits.map(\.id), ["plan", "session", "weekly"], "copilot plan + session + weekly windows")
        expect(copilotWithLimits.map(\.label), ["plan", "5h", "week"], "copilot labels")
        expect(copilotWithLimits.map(\.title), ["Plan (120 / 300 premium requests)", "5-hour session", "Weekly"], "copilot legacy billing and rate-limit titles")
        expect(copilotWithLimits.map(\.percentUsed), [40, 15, 80], "copilot percents")
        expect(copilotWithLimits.map(\.resetsAt), [date("2026-12-01T00:00:00Z"), Date(timeIntervalSince1970: 1_795_046_400), Date(timeIntervalSince1970: 1_795_564_800)],
               "copilot date-only plan reset and epoch rate-limit resets")
        expect(copilotWithLimits.map(\.duration), [30 * day, 5 * hour, 7 * day], "copilot window durations")
        expect(QuotaWindow.headline(of: copilotWithLimits)?.id, "weekly", "copilot headline is the most constrained window")

        // Copilot Free tier (only finite chat quota, limited_user_reset_date) and clamping
        let copilotFree = CopilotUsage.parse(Data("""
        {"copilotUser":{"limited_user_reset_date":"2026-12-15T00:00:00Z",\
        "quota_snapshots":{"chat":{"entitlement":50,"percent_remaining":60,"remaining":30,"unlimited":false}}}}
        """.utf8)) ?? []
        expect(copilotFree.map(\.id), ["plan"], "copilot free chat quota becomes the plan window")
        expect(copilotFree.map(\.title), ["Plan (20 / 50 chat requests)"], "copilot free title")
        expect(copilotFree.first?.resetsAt, date("2026-12-15T00:00:00Z"), "copilot free limited_user_reset_date")

        let copilotClamped = CopilotUsage.parse(Data("""
        {"quotaSnapshots":{"premium_interactions":{"isUnlimitedEntitlement":false,"entitlementRequests":100,"usedRequests":120,"remainingPercentage":-15},\
        "session":{"isUnlimitedEntitlement":false,"entitlementRequests":0,"usedRequests":0,"remainingPercentage":120}}}
        """.utf8)) ?? []
        expect(copilotClamped.map(\.percentUsed), [100, 0], "copilot percentages are clamped to 0...100% used")
        expect(copilotClamped.last?.resetsAt, nil, "copilot untouched session rate limit without epoch reset has no reset time")
        expect(CopilotUsage.parse(Data(#"{"quotaSnapshots":{"chat":{"isUnlimitedEntitlement":true,"remainingPercentage":100}}}"#.utf8)) == nil,
               true, "copilot unlimited-only response produces no finite quota window")
        expect(CopilotUsage.parse(Data("{}".utf8)) == nil, true, "copilot empty object unrecognised")

        let copilotSignedOut = copilotFramed([
            copilotConnect,
            #"{"jsonrpc":"2.0","id":3,"result":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"Request account.getQuota failed with message: Not authenticated. Please authenticate first."}}"#,
        ])
        expect(CopilotUsage.interpret(exitCode: 0, stdout: copilotStdout, stderr: ""), .windows(copilot), "copilot good response gives windows")
        expect(CopilotUsage.interpret(exitCode: 0, stdout: copilotSignedOut, stderr: ""), .signedOut, "copilot unauthenticated response is signed out")
        expect(CopilotUsage.interpret(exitCode: 0, stdout: copilotFramed([copilotConnect, #"{"jsonrpc":"2.0","id":3,"result":{}}"#]), stderr: ""),
               .signedOut, "copilot empty authInfo result is signed out")
        expect(CopilotUsage.interpret(exitCode: -2, stdout: "", stderr: ""), .failed("copilot did not answer in time"), "copilot timeout")
        expect(CopilotUsage.interpret(exitCode: -1, stdout: "", stderr: "no such file"), .failed("could not start the copilot command"), "copilot could not start")
        expect(CopilotUsage.interpret(exitCode: 0, stdout: copilotConnect, stderr: ""), .failed("response not recognised"), "copilot connect-only response unrecognised")
        let payloadText = String(data: CopilotUsage.requestPayload, encoding: .utf8) ?? ""
        expect(payloadText.contains(#""method":"connect""#) && payloadText.contains(#""method":"account.getQuota""#)
               && payloadText.contains(#""method":"account.getCurrentAuth""#), true, "copilot request payload frames connect, getQuota and getCurrentAuth")

        // The agents and what differs between them
        expect(CLITool.usageTracked.map(\.rawValue), ["claude", "codex", "copilot", "antigravity"], "agents in bar order")
        expect(AgentUsageBar.columns(for: []).map { $0.map(\.rawValue) }, [], "empty usage bar has no columns")
        expect(AgentUsageBar.columns(for: [.claude]).map { $0.map(\.rawValue) }, [["claude"]], "single agent takes one column")
        expect(AgentUsageBar.columns(for: [.claude, .codex]).map { $0.map(\.rawValue) }, [["claude", "codex"]],
               "two agents stack in one two-row column")
        expect(AgentUsageBar.columns(for: [.claude, .codex, .copilot]).map { $0.map(\.rawValue) }, [["claude", "codex"], ["copilot"]],
               "three agents take two columns of at most two rows")
        expect(AgentUsageBar.columns(for: CLITool.usageTracked).map { $0.map(\.rawValue) },
               [["claude", "codex"], ["copilot", "antigravity"]],
               "four agents form a two-by-two grid of two-row columns")
        expect(CLITool.usageTracked.map(\.hasLocalLogs), [true, true, false, false], "only Claude and Codex have local logs")
        expect(CLITool.copilot.displayName, "Copilot", "copilot name")
        expect(CLITool.copilot.dataDirectoryName, ".copilot", "copilot data directory")
        expect(Setting.usageHidden(CLITool.copilot.rawValue).name, "settings.usage.copilot.hidden", "copilot hide key")
        expect(CLITool.antigravity.displayName, "Antigravity", "antigravity name")
        expect(CLITool.antigravity.dataDirectoryName, ".gemini/antigravity-cli", "antigravity data directory")
        expect(Setting.usageHidden(CLITool.antigravity.rawValue).name, "settings.usage.antigravity.hidden", "antigravity hide key")
        expect(CLITool.usageTracked.map { $0.signedOutInterval ?? -1 }, [-1, -1, -1, 1800], "only Antigravity waits longer (30 minutes) while signed out")
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
        let parsedClaude = ClaudeUsage.Log.parse(claudeLine, dates: dates)
        expect(parsedClaude?.key, "msg_1:req_1", "claude dedupe key")
        expect(parsedClaude?.event.tokens, 2 + 27007 + 11694 + 322, "claude tokens include cache")
        expect(parsedClaude?.event.costUSD, nil, "claude no cost recorded")
        let costLine = Data(#"{"type":"assistant","timestamp":"2026-09-26T08:00:04Z","costUSD":0.5,"message":{"id":"m","usage":{"input_tokens":1}}}"#.utf8)
        expect(ClaudeUsage.Log.parse(costLine, dates: dates)?.event.costUSD, 0.5, "timestamp without fraction; cost recorded")
        let userLine = Data(#"{"type":"user","timestamp":"2026-09-26T08:00:04.131Z","message":{"usage":{}}}"#.utf8)
        expect(ClaudeUsage.Log.parse(userLine, dates: dates) == nil, true, "user lines ignored")
        let codexLine = Data("""
        {"timestamp":"2026-09-25T15:21:09.530Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":21101,"cached_input_tokens":12416,"output_tokens":368,"total_tokens":21469}},"rate_limits":{}}}
        """.utf8)
        expect(CodexUsage.Log.parse(codexLine, dates: dates)?.total, 21469, "codex cumulative total")
        let codexNull = Data(#"{"timestamp":"2026-09-25T15:21:09.530Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#.utf8)
        expect(CodexUsage.Log.parse(codexNull, dates: dates)?.total, -1, "codex null info recognised, no tokens")

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

        let claudeReader = UsageLogReader(agent: .claude, home: home)!
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
        let codexEvents = try! UsageLogReader(agent: .codex, home: home)!.events(since: .distantPast)
        expect(codexEvents.usage(from: since).tokens, 1700, "codex: deltas, repeats ignored, counter restart")
        expect(codexEvents.recordsCost, false, "codex records no cost")

        // A changed format is an error, never zero.
        let broken = home.appendingPathComponent("broken")
        try! FileManager.default.createDirectory(at: broken.appendingPathComponent(".claude/projects/p"), withIntermediateDirectories: true)
        try! (#"{"type":"assistant","usage":{"tokens":5}}"# + "\n")
            .write(to: broken.appendingPathComponent(".claude/projects/p/x.jsonl"), atomically: true, encoding: .utf8)
        do {
            _ = try UsageLogReader(agent: .claude, home: broken)!.events(since: .distantPast)
            expect("no error", "unrecognised", "changed format")
        } catch let error as UsageLogError {
            expect(error, .unrecognised("Claude Code log format not recognised"), "changed format")
        } catch { expect("\(error)", "unrecognised", "changed format") }
        do {
            _ = try UsageLogReader(agent: .codex, home: broken)!.events(since: .distantPast)
            expect("no error", "unreadable", "missing logs")
        } catch let error as UsageLogError {
            expect(error, .unreadable("No local logs in ~/.codex"), "missing logs")
        } catch { expect("\(error)", "unreadable", "missing logs") }

    }

    func testAgentActivityParsing() throws {
        func check(_ ok: Bool, _ name: String, line: UInt = #line) {
            XCTAssertTrue(ok, name, line: line)
        }
        func data(_ json: String) -> Data { json.data(using: .utf8)! }

        let now = ISO8601DateFormatter().date(from: "2026-10-12T22:20:30Z")!
        let t = "2026-10-12T22:20:14.724Z"

        func claude(_ lines: [String]) -> AgentActivity? { AgentActivityParser.claude(lines: lines.map(data), now: now) }

        let title = #"{"type":"ai-title","aiTitle":"Sign-in popups in the browser"}"#
        let edit = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/p/MarkView/Models/Browser/BrowserSession.swift","old_string":"SECRET"}}]}}"#
        var a = claude([title, edit, #"{"type":"attachment"}"#, #"{"type":"mode"}"#])
        check(a?.state == .working && a?.text == "Editing BrowserSession.swift", "edit tool -> Editing <file>")
        check(a?.topic == "Sign-in popups in the browser", "session title is the topic")
        check(!(a?.text.contains("SECRET") ?? true), "file contents never appear")

        let bash = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"API_KEY=abc123 /usr/bin/xcodebuild -scheme X"}}]}}"#
        a = claude([bash])
        check(a?.text == "Running xcodebuild", "shell command shows the program only")
        check(!(a?.text.contains("abc123") ?? true), "no secret from the command line")
        let bashDescribed = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"x","description":"Build the app"}}]}}"#
        check(claude([bashDescribed])?.text == "Build the app", "shell description is used when present")
        check(AgentActivityParser.program(of: "cd /tmp && FOO=1 swift test") == "swift test", "cd prefix and VAR= skipped, subcommand kept")
        check(AgentActivityParser.program(of: "gh pr merge 5 --merge") == "gh pr merge" && AgentActivityParser.program(of: "git push origin main") == "git push", "gh and git subcommands")
        check(AgentActivityParser.program(of: "git commit -m \"secret-token\"") == "git commit", "arguments are never shown")
        check(AgentActivityParser.program(of: "cd /tmp && d=/x && mkdir -p y") == "mkdir", "assignment segments skipped")

        let done = #"{"type":"assistant","timestamp":"\#(t)","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#
        a = claude([edit, done])
        check(a?.state == .idle && a?.text == "Waiting for you", "final text reply -> idle")

        let result = #"{"type":"user","timestamp":"\#(t)","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
        check(claude([edit, result])?.text == "After: Editing BrowserSession.swift" && claude([edit, result])?.state == .working,
              "after a tool result: what it just did, never a bare Thinking")
        check(claude([user("Do it"), said("Fixing the parser."), edit, result])?.text == "Fixing the parser", "between tools the turn's latest sentence says what the work is")

        let thinking = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"thinking","thinking":"..."}]}}"#
        check(claude([thinking])?.text == "Starting on the request", "thinking with nothing known yet")
        check(claude([thinking])?.text.contains("Thinking") == false, "no bare Thinking")

        let interrupted = #"{"type":"user","timestamp":"\#(t)","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        check(claude([edit, interrupted])?.state == .idle, "interrupted -> idle")

        // /model (BUG-048): the CLI's own command writes user entries after the reply; the agent still waits for the user.
        let caveat = #"{"type":"user","isMeta":true,"timestamp":"\#(t)","message":{"content":"<local-command-caveat>The command below was run directly in Claude Code.</local-command-caveat>"}}"#
        let commandName = #"{"type":"user","timestamp":"\#(t)","message":{"content":"<command-name>/model</command-name>\n<command-message>model</command-message>"}}"#
        let commandOutput = #"{"type":"user","timestamp":"\#(t)","message":{"content":"<local-command-stdout>Set model to `Sonnet 5.5`</local-command-stdout>"}}"#
        check(claude([done, caveat, commandName, commandOutput])?.state == .idle, "after /model the agent is still idle")
        check(claude([done, caveat, commandName, commandOutput])?.text == "Waiting for you", "after /model it still waits for the user")
        check(claude([edit, commandOutput])?.state == .working, "a command output does not end work that was under way")
        check(claude([commandName, commandOutput]) == nil, "only command entries: nothing to report")
        check(claude([done, user("Next task")])?.state == .working, "a real prompt after a reply starts work")

        let side = #"{"type":"assistant","isSidechain":true,"timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/x/y.swift"}}]}}"#
        check(claude([edit, side])?.text == "Editing BrowserSession.swift", "subagent lines are ignored")

        let late = ISO8601DateFormatter().date(from: "2026-10-12T22:50:00Z")!
        check(AgentActivityParser.claude(lines: [data(edit)], now: late)?.state == .idle, "old tool call -> idle (stale)")
        check(claude([]) == nil && claude([#"{"type":"mode"}"#]) == nil, "no usable lines -> nil")
        check(claude(["not json", edit])?.text == "Editing BrowserSession.swift", "garbage lines skipped")

        func codex(_ lines: [String]) -> AgentActivity? { AgentActivityParser.codex(lines: lines.map(data), now: now) }
        let call = #"{"type":"response_item","timestamp":"\#(t)","payload":{"type":"function_call","name":"shell","arguments":"{}"}}"#
        let complete = #"{"type":"event_msg","timestamp":"\#(t)","payload":{"type":"task_complete"}}"#
        check(codex([call])?.text == "Running a command", "codex function call")
        let cu = #"{"type":"event_msg","timestamp":"\#(t)","payload":{"type":"user_message","message":"Add the report"}}"#
        let cm = #"{"type":"response_item","timestamp":"\#(t)","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Writing the report module."}]}}"#
        check(codex([cu, cm, call])?.task == "Add the report" && codex([cu, cm])?.text == "Writing the report module", "codex task and narration")
        check(codex([call, complete])?.state == .idle, "codex task_complete -> idle")
        check(codex([#"{"type":"event_msg","payload":{"type":"token_count"}}"#, call])?.state == .working, "codex ignores token_count")

        check(AgentActivityLog.claudeFolderName(for: URL(fileURLWithPath: "/Users/boris/github.com/MarkView")) == "-Users-boris-github-com-MarkView",
              "claude folder name matches the CLI's")

        // Task, narration and failure
        func user(_ text: String) -> String { #"{"type":"user","timestamp":"\#(t)","message":{"content":"\#(text)"}}"# }
        func said(_ text: String) -> String { #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"text","text":"\#(text)"}]}}"# }
        let reminder = #"{"type":"user","message":{"content":[{"type":"text","text":"<system-reminder>x</system-reminder>"}]}}"#
        a = claude([user("Fix the sign-in popup in the browser"), said("Now I am building the app to check it. More text."), bash])
        check(a?.task == "Fix the sign-in popup in the browser", "task is the last request")
        check(a?.text == "Now I am building the app to check it" && a?.detail == "Running xcodebuild", "the agent's own sentence leads, the tool is the detail")
        a = claude([user("old request"), said("Old narration."), edit, result, user("New request"), reminder])
        check(a?.task == "New request" && a?.text == "Starting on the request", "a new request resets the narration and the system wrapper is not the task")
        a = claude([user("Do it"), said("Reading the code first."), edit, result, bash])
        check(a?.text == "Running xcodebuild", "narration from before an earlier tool result is stale")
        let failedResult = #"{"type":"user","timestamp":"\#(t)","message":{"content":[{"type":"tool_result","is_error":true,"content":"boom"}]}}"#
        a = claude([user("Do it"), bash, failedResult])
        check(a?.state == .failing && a?.text.hasPrefix("Last step failed") == true, "an error result is failing")
        a = claude([user("Do it"), bash, failedResult, done])
        check(a?.state == .idle, "a finished turn is idle even after an error")
        check(AgentActivityParser.firstSentence("## Heading") == nil && AgentActivityParser.firstSentence("Done: all good") == "Done", "sentence rules")

        // Task lists
        let todo = #"{"type":"assistant","timestamp":"\#(t)","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Parse the log","status":"completed","activeForm":"Parsing the log"},{"content":"Add the banner","status":"in_progress","activeForm":"Adding the banner"},{"content":"Release","status":"pending","activeForm":"Releasing"}]}}]}}"#
        a = claude([user("Do it"), todo, edit])
        check(a?.plan.map(\.status) == [.done, .active, .pending] && a?.plan.first?.title == "Parse the log" && a?.planDone == 1, "TodoWrite list with statuses")
        check(claude([user("Do it"), edit])?.plan.isEmpty == true, "no list, empty plan")
        let todo2 = todo.replacingOccurrences(of: "\"pending\"", with: "\"completed\"")
        check(claude([todo, edit, todo2, edit])?.planDone == 2, "the last TodoWrite wins")
        check(claude([user("a"), todo, done, user("b"), edit])?.plan.count == 3, "the list survives a new request")
        let plan = #"{"type":"response_item","timestamp":"\#(t)","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Write tests\",\"status\":\"completed\"},{\"step\":\"Ship\",\"status\":\"in_progress\"}]}"}}"#
        check(codex([plan, call])?.plan.map(\.title) == ["Write tests", "Ship"] && codex([plan, call])?.planDone == 1, "codex update_plan")

        check(AgentActivityLog.claudeFolderName(for: URL(fileURLWithPath: "/private/tmp/x.y")) == "-private-tmp-x-y", "a /private path keeps its prefix")

        // Cline and Copilot
        let clineMessages = #"{"messages":[{"role":"user","content":[{"type":"text","text":"Remove old branches"}]},{"role":"assistant","content":[{"type":"text","text":"Checking the branches first."},{"type":"tool_use","name":"run_commands","input":{"commands":["cd /p && git branch -vv"]}}]}]}"#
        var c = AgentActivityParser.cline(messagesJSON: Data(clineMessages.utf8), status: "running", now: now)
        check(c?.state == .working && c?.text == "Checking the branches first" && c?.detail == "Running git branch", "cline running: sentence and tool")
        check(c?.task == "Remove old branches", "cline task")
        c = AgentActivityParser.cline(messagesJSON: Data(clineMessages.utf8), status: "idle", now: now)
        check(c?.state == .idle && c?.text == "Waiting for you" && c?.task == "Remove old branches", "cline idle keeps the task")
        check(AgentActivityParser.cline(messagesJSON: Data("garbage".utf8), status: "idle") == nil, "cline garbage")
        check(AgentActivityParser.describe(tool: "read_files", input: ["files": [["path": "/a/b/c.txt"]]]) == "Reading c.txt", "cline read_files")
        let cp = AgentActivityParser.copilot(userMessage: "Open the page", response: "Opened the page. More.", busy: false)
        check(cp?.state == .idle && cp?.task == "Open the page" && cp?.detail == "Opened the page", "copilot idle")
        check(AgentActivityParser.copilot(userMessage: "Open the page", response: nil, busy: true)?.state == .working, "copilot working while its terminal prints")
        check(AgentActivityParser.copilot(userMessage: nil, response: nil, busy: true) == nil, "copilot without data")
        let ag = AgentActivityParser.antigravity(title: "List tabs", preview: "List MarkView Browser Tabs", status: "CASCADE_RUN_STATUS_IDLE", busy: false)
        check(ag?.state == .idle && ag?.topic == "List tabs" && ag?.task == "List MarkView Browser Tabs", "antigravity idle")
        check(AgentActivityParser.antigravity(title: "T", preview: "P", status: "CASCADE_RUN_STATUS_RUNNING", busy: false)?.state == .working, "antigravity running by status")
        check(AgentActivityParser.antigravity(title: "T", preview: "P", status: "CASCADE_RUN_STATUS_IDLE", busy: true)?.state == .working, "antigravity working while its terminal prints")
        check(AgentActivityParser.antigravity(title: nil, preview: nil, status: "", busy: true) == nil, "antigravity without data")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        check(ProcessTree.isDescendant(child.processIdentifier, of: getpid()) && ProcessTree.isDescendant(getpid(), of: getpid()) && !ProcessTree.isDescendant(getpid(), of: 999_999), "process tree")

        let wrapped = #"{"messages":[{"role":"user","content":[{"type":"text","text":"<user_input mode=\"act\"><mode_notice>The user switched.\nSecond line.</mode_notice>\nReview old branches</user_input>"}]}]}"#
        check(AgentActivityParser.cline(messagesJSON: Data(wrapped.utf8), status: "idle")?.task == "Review old branches", "cline request wrapper and notice are removed")

    }

    func testClaudeSessionModelParsing() {
        func check(_ name: String, _ condition: Bool, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, name + " " + detail, line: line)
        }
        let start = ISO8601DateFormatter().date(from: "2026-11-03T10:00:00Z")!
        func stamp(_ seconds: Int, fractional: Bool = true) -> String {
            let date = start.addingTimeInterval(TimeInterval(seconds))
            if fractional {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.string(from: date)
            }
            return ISO8601DateFormatter().string(from: date)
        }

        func line(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
        func reply(_ model: String, at seconds: Int, sidechain: Bool = false) -> Data {
            line(["type": "assistant", "timestamp": stamp(seconds), "isSidechain": sidechain,
                  "message": ["role": "assistant", "model": model, "content": [["type": "text", "text": "ok"]]]])
        }
        func switchCommand(_ shown: String, at seconds: Int, asParts: Bool = false) -> Data {
            let text = "<local-command-stdout>Set model to `\(shown)` and saved as your default for new sessions</local-command-stdout>"
            let content: Any = asParts ? [["type": "text", "text": text]] : text
            return line(["type": "user", "timestamp": stamp(seconds), "message": ["role": "user", "content": content]])
        }
        func user(_ text: String, at seconds: Int) -> Data {
            line(["type": "user", "timestamp": stamp(seconds), "message": ["role": "user", "content": text]])
        }

        // Names and families.
        check("an id names its family", ClaudeSessionModel.family(of: "claude-sonnet-5-5") == "sonnet")
        check("a display name names its family", ClaudeSessionModel.family(of: "Fable 5.1") == "fable")
        check("opus", ClaudeSessionModel.family(of: "claude-opus-5-5") == "opus")
        check("haiku", ClaudeSessionModel.family(of: "Claude Haiku 5.5") == "haiku")
        check("another vendor names none", ClaudeSessionModel.family(of: "gpt-5") == nil)

        // The reply of the session.
        check("the newest reply wins",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), reply("claude-sonnet-5-5", at: 5)])?.model == "sonnet")
        check("an id without a known family is kept as logged",
              ClaudeSessionModel.reading(lines: [reply("claude-nova-6-0", at: 1)])?.model == "claude-nova-6-0")
        check("a subagent's reply is not the session's model",
              ClaudeSessionModel.reading(lines: [reply("claude-sonnet-5-5", at: 1), reply("claude-haiku-5-5", at: 9, sidechain: true)])?.model == "sonnet")
        check("a placeholder reply is skipped",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1), reply("<synthetic>", at: 9)])?.model == "opus")
        check("the reading carries the time of the line",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 7)])?.date == start.addingTimeInterval(7))

        // /model confirms before the next reply.
        check("a /model confirmation after a reply wins",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), switchCommand("Sonnet 5.5", at: 4)])?.model == "sonnet")
        check("a reply after the confirmation wins",
              ClaudeSessionModel.reading(lines: [switchCommand("Sonnet 5.5", at: 1), reply("claude-opus-5-5", at: 4)])?.model == "opus")
        check("a confirmation whose content is a list of parts",
              ClaudeSessionModel.reading(lines: [switchCommand("Opus 5.5", at: 2, asParts: true)])?.model == "opus")
        check("a confirmation without a family is ignored",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), switchCommand("Default (recommended)", at: 4)])?.model == "fable")
        check("ordinary user text that mentions a model is not a switch",
              ClaudeSessionModel.reading(lines: [reply("claude-fable-5-1", at: 1), user("please use sonnet for this", at: 4)])?.model == "fable")

        // Only what happened since the agent started counts (a continued session carries old replies).
        check("lines older than since are ignored",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1), reply("claude-sonnet-5-5", at: 3)],
                                         since: start.addingTimeInterval(10)) == nil)
        check("a line at since counts",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 10)], since: start.addingTimeInterval(10))?.model == "opus")
        check("old lines do not hide newer ones",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1), reply("claude-sonnet-5-5", at: 20)],
                                         since: start.addingTimeInterval(10))?.model == "sonnet")

        // Odd input.
        check("no lines, no reading", ClaudeSessionModel.reading(lines: []) == nil)
        check("garbage and blank lines are skipped",
              ClaudeSessionModel.reading(lines: [Data("not json".utf8), Data(), reply("claude-haiku-5-5", at: 1), Data("{".utf8)])?.model == "haiku")
        check("a line without a time is skipped",
              ClaudeSessionModel.reading(lines: [reply("claude-opus-5-5", at: 1),
                                                 line(["type": "assistant", "message": ["model": "claude-haiku-5-5"]])])?.model == "opus")
        check("a time without fractions is read",
              ClaudeSessionModel.reading(lines: [line(["type": "assistant", "timestamp": stamp(3, fractional: false),
                                                       "message": ["model": "claude-opus-5-5"]])])?.date == start.addingTimeInterval(3))

        // Concurrent readers share the two timestamp parsers without changing their results.
        let concurrentLines = [reply("claude-opus-5-5", at: 1), line(["type": "assistant", "timestamp": stamp(3, fractional: false),
                                                                       "message": ["model": "claude-sonnet-5-5"]])]
        let expectedConcurrentDate = start.addingTimeInterval(3)
        let concurrentErrors = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let result = ClaudeSessionModel.reading(lines: concurrentLines)
            if result?.model != "sonnet" || result?.date != expectedConcurrentDate { concurrentErrors.withLock { $0 += 1 } }
        }
        check("concurrent readers parse fractional and plain timestamps consistently", concurrentErrors.withLock { $0 } == 0)

        // Titles.
        check("title: the model part is replaced", ClaudeSessionModel.title("Claude Code · fable", model: "sonnet") == "Claude Code · sonnet")
        check("title: a numbered tab keeps its number", ClaudeSessionModel.title("Claude Code 2 · fable", model: "opus") == "Claude Code 2 · opus")
        check("title: a title without a model gets one", ClaudeSessionModel.title("Claude Code", model: "sonnet") == "Claude Code · sonnet")
    }
}

extension EditorHostTests {
    func testCodexLaunchSchemaFiles() throws {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("codex-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { chmod(scratch.path, 0o755); try? FileManager.default.removeItem(at: scratch) }

        func request(schema: [String: Any]?) -> CompletionLaunchRequest {
            CompletionLaunchRequest(prompt: "Answer.", systemPrompt: nil, jsonSchema: schema, readableFolder: nil, extraReadableFolders: [],
                                    linkedFolders: { [] }, allowWeb: false, images: [], effort: nil, model: nil, workDir: scratch,
                                    scratchDirectory: { scratch })
        }
        func listing() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted() }

        let schema: [String: Any] = ["type": "object", "properties": ["answer": ["type": "string"], "tags": ["type": "array", "items": ["type": "string"]]]]
        let provider = CodexProvider()

        // No schema, no file.
        let plain = try provider.launch(request(schema: nil))
        check(plain.schemaFile == nil && !plain.arguments.contains("--output-schema") && listing().isEmpty, "a launch without a schema writes nothing")

        // A schema: saved whole in the scratch folder, strict as Codex needs it, and named in the arguments.
        let first = try provider.launch(request(schema: schema))
        let file = first.schemaFile
        check(file?.deletingLastPathComponent().standardizedFileURL.path == scratch.standardizedFileURL.path && file?.lastPathComponent.hasPrefix("schema-") == true
              && file?.pathExtension == "json", "the schema file is in the run's scratch folder")
        if let index = first.arguments.firstIndex(of: "--output-schema") {
            check(first.arguments.indices.contains(index + 1) && first.arguments[index + 1] == file?.path, "the CLI is told to read that very file")
        } else { check(false, "the CLI is told to read that very file") }
        let saved = file.flatMap { try? Data(contentsOf: $0) }
        let parsed = saved.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(parsed != nil && (parsed?["additionalProperties"] as? Bool) == false && (parsed?["required"] as? [String]) == ["answer", "tags"],
              "the file holds the whole strict schema (closed object, every property required)")
        let expected = try CompletionJSON.string(CodexProvider.strictSchema(schema))
        check(saved.map { String(decoding: $0, as: UTF8.self) } == expected, "byte for byte what the schema serialises to")
        check(file.map { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o644 } == true, "it is an ordinary file, readable by the CLI")
        check(listing().count == 1, "and nothing else is in the folder (no temporary file)")

        // Every launch has a file of its own.
        let second = try provider.launch(request(schema: ["type": "object", "properties": ["x": ["type": "string"]]]))
        check(second.schemaFile != nil && second.schemaFile != file && listing().count == 2 && (file.flatMap { try? Data(contentsOf: $0) }) == saved,
              "a second launch has its own file and leaves the first as it was")

        // A scratch folder that refuses the file: the launch fails, with no partial schema, and the earlier files are as they were.
        let before = listing()
        chmod(scratch.path, 0o555)
        var refused = false
        do { _ = try provider.launch(request(schema: schema)) } catch { refused = true }
        chmod(scratch.path, 0o755)
        check(refused, "a scratch folder that refuses the schema fails the launch")
        check(listing() == before && (file.flatMap { try? Data(contentsOf: $0) }) == saved, "and adds no partial file, and the earlier schema keeps its bytes")
    }
}

private extension CLITool {
    static var claude: CLITool { CLITool(rawValue: "claude")! }
    static var codex: CLITool { CLITool(rawValue: "codex")! }
    static var copilot: CLITool { CLITool(rawValue: "copilot")! }
    static var antigravity: CLITool { CLITool(rawValue: "antigravity")! }
}

private struct ExtensionFixtureProvider: AssistantProvider, AssistantCompletionSupport {
    let id = "fakeassist"
    let displayName = "Fake Assistant"
    let binaryName = "fakeassist"
    let authStatusArgs: [String] = []
    let loginCommand = ""
    let fullAccessArgs = ["--yolo"]
    let continueArgs = ["--resume-last"]
    let terminalIcon = "star"
    let fixesBugsAsGoal = true
    func modelOptions() -> [AIModelOption] { [AIModelOption(id: "", name: "Default", detail: "")] }
    func goalPrompt(_ objective: String, closing: String) -> String { "FAKE GOAL: \(objective)" }
    var usage: (any AssistantUsageSupport)? { ExtensionFixtureUsage() }
    var completion: (any AssistantCompletionSupport)? { self }
    func launch(_ request: CompletionLaunchRequest) throws -> CompletionLaunch {
        CompletionLaunch(arguments: ["--fake-run"] + modelArgs(request.model) + (request.effort.map { ["--effort", $0] } ?? []),
                         input: request.prompt, schemaFile: nil)
    }
    func makeParser() -> any CompletionStreamParser { ExtensionFixtureParser() }
}

private final class ExtensionFixtureParser: CompletionStreamParser {
    func handle(_ json: [String: Any], output: inout CompletionOutput, sink: CompletionSink) {
        guard let answer = json["answer"] as? String else { return }
        output.text = answer
        output.outputTokens = json["tokens"] as? Int ?? 0
        sink.onDelta?(answer)
    }
}

private struct ExtensionFixtureUsage: AssistantUsageSupport {
    let shortName = "Fake"
    let dataDirectoryName = ".fakeassist"
    var localLogs: (any UsageLogFormat)? { ExtensionFixtureLog() }
    func fetchOfficial(using transport: any UsageTransport) async -> UsageFetchResult { .signedOut }
}

private struct ExtensionFixtureLog: UsageLogFormat {
    var marker: Data { Data("tokens".utf8) }
    func roots(in dataDirectory: URL) -> [URL] { [dataDirectory.appendingPathComponent("logs", isDirectory: true)] }
    func read(line: Data, dates: ISO8601DateFormatter, lastTotal: inout Int) -> UsageLineReading {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let tokens = object["tokens"] as? Int, let date = UsageLogLine.date(object["ts"], dates) else { return .unrecognised }
        return .counted(key: nil, event: UsageEvent(date: date, tokens: tokens, costUSD: nil))
    }
}

/// Isolated because registering a fixture provider affects the process-wide registry.
final class AssistantExtensionHostTests: XCTestCase {
    @MainActor func testProviderExtension() async throws {
        executionTimeAllowance = 120
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.markview.tests.apphost", AgentProcesses.count == 0,
              let homePath = environment["MARKVIEW_CLI_TEST_HOME"], environment["CFFIXED_USER_HOME"] == homePath,
              let fixturePath = environment["MARKVIEW_CLI_TEST_FIXTURE"], let scratchPath = environment["MARKVIEW_CLI_TEST_SCRATCH"] else {
            XCTFail("Provider extension checks require an isolated host and local fixture")
            return
        }
        let home = URL(fileURLWithPath: homePath).resolvingSymlinksInPath()
        let root = home.deletingLastPathComponent()
        let fixture = URL(fileURLWithPath: fixturePath).resolvingSymlinksInPath()
        let scratch = URL(fileURLWithPath: scratchPath).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath()
        guard home.lastPathComponent == "home", root.lastPathComponent.hasPrefix("mvcli-test-"),
              root.deletingLastPathComponent().path == temporary.path,
              home.path == URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path,
              fixture.path == root.appendingPathComponent("extension.py").path,
              scratch.path == root.appendingPathComponent("scratch", isDirectory: true).path,
              FileManager.default.isExecutableFile(atPath: fixture.path),
              AICallLog.url.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(home.path + "/") else {
            XCTFail("Provider extension checks refused a nonisolated home, log or fixture")
            return
        }
        let defaults = UserDefaults.standard
        let domain = "com.markview.tests.apphost"
        defaults.removePersistentDomain(forName: domain)
        AssistantProviderRegistry.setTestProviders([ExtensionFixtureProvider()])
        defer {
            AICallLog.waitForPendingWrites()
            AgentProcesses.terminateAll(grace: 0.2)
            AssistantProviderRegistry.setTestProviders([])
            defaults.removePersistentDomain(forName: domain)
            defaults.synchronize()
        }
        let stored: [(String, String, String, String)] = [
            ("claude", "Claude Code", "claude", "sparkle"), ("codex", "Codex", "codex", "chevron.left.forwardslash.chevron.right"),
            ("cline", "Cline", "cline", "circle.hexagongrid"), ("copilot", "Copilot", "copilot", "airplane"),
            ("antigravity", "Antigravity", "agy", "wand.and.stars")]
        for (raw, name, binary, icon) in stored {
            let tool = try XCTUnwrap(CLITool(rawValue: raw))
            XCTAssertEqual(tool.displayName, name)
            XCTAssertEqual(tool.binaryName, binary)
            XCTAssertEqual(Setting.cliPath(raw).name, "settings.cli.\(raw)Path")
            XCTAssertEqual(try JSONDecoder().decode(CLITool.self, from: Data("\"\(raw)\"".utf8)), tool)
            XCTAssertEqual(TerminalProfile(rawValue: raw), .assistant(tool))
            XCTAssertEqual(TerminalProfile(rawValue: raw)?.icon, icon)
        }
        XCTAssertEqual(TerminalProfile(rawValue: "shell"), .shell)
        XCTAssertEqual(TerminalProfile.shell.icon, "terminal")
        XCTAssertEqual(TerminalProfile.shell.title, "Shell")
        XCTAssertNil(CLITool(rawValue: "gemini"))
        XCTAssertNil(TerminalProfile(rawValue: "gemini"))
        XCTAssertThrowsError(try JSONDecoder().decode(CLITool.self, from: Data("\"gemini\"".utf8)))
        XCTAssertEqual(TerminalProfile.allCases.map(\.rawValue), ["claude", "codex", "cline", "copilot", "antigravity", "fakeassist", "shell"])
        XCTAssertEqual(AssistantProviderRegistry.defaultTool.rawValue, "claude")
        let fake = try XCTUnwrap(CLITool(rawValue: "fakeassist"))
        XCTAssertEqual(CLITool.allCases.last, fake)
        XCTAssertEqual(CLITool.allCases.count, 6)
        XCTAssertEqual(fake.displayName, "Fake Assistant")
        XCTAssertEqual(fake.binaryName, "fakeassist")
        XCTAssertEqual(Setting.cliPath(fake.rawValue).name, "settings.cli.fakeassistPath")
        XCTAssertEqual(fake.fullAccessArgs, ["--yolo"])
        XCTAssertEqual(fake.continueArgs, ["--resume-last"])
        XCTAssertEqual(fake.modelArgs("m"), ["--model", "m"])
        XCTAssertTrue(fake.modelArgs(nil).isEmpty)
        let profile = try XCTUnwrap(TerminalProfile(rawValue: "fakeassist"))
        XCTAssertEqual(profile, .assistant(fake))
        XCTAssertEqual(profile.tool, fake)
        XCTAssertEqual(profile.title, "Fake Assistant")
        XCTAssertEqual(profile.icon, "star")
        XCTAssertEqual(HandoffPrompt.goal("tests pass", tool: fake), "FAKE GOAL: tests pass")
        XCTAssertTrue(HandoffPrompt.feature("docs/features/x", tool: fake).hasPrefix("FAKE GOAL: Implement what docs/features/x specifies."))
        XCTAssertTrue(HandoffPrompt.bug("docs/bugs/BUG-1.md", tool: fake).hasPrefix("FAKE GOAL: fix the bug described in docs/bugs/BUG-1.md"))
        XCTAssertTrue(HandoffPrompt.bug("docs/bugs/BUG-1.md", tool: CLITool(rawValue: "cline")).hasPrefix("Fix the bug described in"))
        XCTAssertTrue(CLITool.usageTracked.contains(fake) && fake.hasLocalLogs && fake.shortName == "Fake")
        XCTAssertEqual(Setting.usageHidden(fake.rawValue).name, "settings.usage.fakeassist.hidden")
        XCTAssertEqual(Setting.usageLimit(fake.rawValue).name, "settings.usage.fakeassist.limit")
        let logs = root.appendingPathComponent("usage/.fakeassist/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let now = Date(), stamp = UsageLogLine.timestampFormatter().string(from: Date())
        try (["{\"ts\":\"\(stamp)\",\"tokens\":40}", "{\"ts\":\"\(stamp)\",\"tokens\":2}", "invalid"].joined(separator: "\n") + "\n")
            .write(to: logs.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let reader = try XCTUnwrap(UsageLogReader(agent: fake, home: root.appendingPathComponent("usage")))
        let events = try reader.events(since: now.addingTimeInterval(-60))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.tokens).reduce(0, +), 42)
        XCTAssertNil(UsageLogReader(agent: CLITool(rawValue: "antigravity")!, home: root.appendingPathComponent("usage")))
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        CLIToolLocator.setOverride(fixture.path, for: fake)
        guard CLIToolLocator.resolve(fake) == fixture.path else { XCTFail("The fake provider must resolve to the fixture"); return }
        var request = CLICompletion.Request(project: project, prompt: "hello fake")
        request.tool = fake; request.model = "model-x"; request.effort = "low"
        let result = try await CLICompletion.run(request)
        XCTAssertEqual(result.text, "echo:hello fake|--model model-x --effort low")
        XCTAssertEqual(result.outputTokens, 7)
    }
}

extension EditorHostTests {
    @MainActor func testLaunchCapabilitiesResolverAndOperationTelemetry() async throws {
        let claude = try XCTUnwrap(CLITool(rawValue: "claude"))
        let codex = try XCTUnwrap(CLITool(rawValue: "codex"))
        let cline = try XCTUnwrap(CLITool(rawValue: "cline"))
        let copilot = try XCTUnwrap(CLITool(rawValue: "copilot"))
        let antigravity = try XCTUnwrap(CLITool(rawValue: "antigravity"))

        // 1. Launch capability matrix across all 5 registered providers (REQ-006).
        XCTAssertTrue(claude.launchCapabilities.backgroundWebSearch && claude.launchCapabilities.enforcesWebOptOutAtCLI && claude.launchCapabilities.backgroundReportsCostUSD)
        XCTAssertTrue(codex.launchCapabilities.backgroundWebSearch && codex.launchCapabilities.enforcesWebOptOutAtCLI && !codex.launchCapabilities.backgroundReportsCostUSD)
        XCTAssertTrue(antigravity.launchCapabilities.backgroundWebSearch && !antigravity.launchCapabilities.enforcesWebOptOutAtCLI)
        XCTAssertFalse(copilot.launchCapabilities.backgroundWebSearch)
        XCTAssertFalse(cline.launchCapabilities.backgroundWebSearch)

        // 2. Codex and Antigravity background launch profiles enforce allowWeb on/off and read-only rules.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cap-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        func launchReq(allowWeb: Bool, readable: URL?) -> CompletionLaunchRequest {
            CompletionLaunchRequest(prompt: "Check.", systemPrompt: "System.", jsonSchema: nil,
                                    readableFolder: readable, extraReadableFolders: [], linkedFolders: { [] },
                                    allowWeb: allowWeb, images: [], effort: "low", model: nil,
                                    workDir: scratch, scratchDirectory: { scratch })
        }
        let codexWebOn = try CodexProvider().launch(launchReq(allowWeb: true, readable: scratch))
        XCTAssertTrue(codexWebOn.arguments.contains("--search"))
        XCTAssertFalse(codexWebOn.arguments.contains("web_search=\"disabled\""))
        let codexWebOff = try CodexProvider().launch(launchReq(allowWeb: false, readable: scratch))
        XCTAssertFalse(codexWebOff.arguments.contains("--search"))
        XCTAssertTrue(codexWebOff.arguments.contains("web_search=\"disabled\""))

        let agyWebOn = try AntigravityProvider().launch(launchReq(allowWeb: true, readable: scratch))
        XCTAssertTrue(agyWebOn.arguments.contains("--disable-slash-commands"))
        let agySettingsOnIdx = try XCTUnwrap(agyWebOn.arguments.firstIndex(of: "--settings"))
        let agySettingsOn = agyWebOn.arguments[agySettingsOnIdx + 1]
        XCTAssertTrue(agySettingsOn.contains("\"allow\":[\"read_url(*)\"]"))
        XCTAssertTrue(agySettingsOn.contains("write_file(*)"))
        XCTAssertFalse(agySettingsOn.contains("read_file(*)"))

        let agyWebOffNoFiles = try AntigravityProvider().launch(launchReq(allowWeb: false, readable: nil))
        let agySettingsOffIdx = try XCTUnwrap(agyWebOffNoFiles.arguments.firstIndex(of: "--settings"))
        let agySettingsOff = agyWebOffNoFiles.arguments[agySettingsOffIdx + 1]
        XCTAssertTrue(agySettingsOff.contains("read_url(*)"))
        XCTAssertTrue(agySettingsOff.contains("read_file(*)"))
        XCTAssertTrue(agyWebOffNoFiles.input.contains("Web access is disabled for this run"))

        // 3. Explicit confirmation before substituting a provider lacking a needed capability (DEC-013).
        @MainActor
        final class SpyPrompts: UserPrompts {
            var nextChoice: Int?
            private(set) var asked: [UserPrompt] = []
            func ask(_ prompt: UserPrompt) -> Int? { asked.append(prompt); return nextChoice }
        }
        let spy = SpyPrompts()

        // Capable provider proceeds immediately without prompting.
        let direct = AgentCapabilityResolver.resolve(
            selected: claude, capability: .backgroundWebSearch, taskName: "research",
            canProceedWithoutCapability: true, fallbackDescription: "stay repo-only",
            prompts: spy, isAvailable: { _ in true }
        )
        XCTAssertEqual(direct, .proceed(tool: claude, capabilityAvailable: true, limitationNote: nil))
        XCTAssertTrue(spy.asked.isEmpty)

        // Incompatible provider + compatible installed alternative: button 1 explicitly confirms substitution.
        spy.nextChoice = 1
        let confirmed = AgentCapabilityResolver.resolve(
            selected: copilot, capability: .backgroundWebSearch, taskName: "research",
            canProceedWithoutCapability: true, fallbackDescription: "stay repo-only",
            prompts: spy, isAvailable: { $0 == claude || $0 == copilot }
        )
        XCTAssertEqual(confirmed, .proceed(tool: claude, capabilityAvailable: true, limitationNote: nil))
        XCTAssertEqual(spy.asked.count, 1)
        XCTAssertTrue(spy.asked[0].detail.contains("Claude Code"))
        XCTAssertTrue(spy.asked[0].buttons.first?.contains("Copilot") == true, "Safe default button stays with original provider")

        // Button 0 (decline) or nil (non-interactive) NEVER substitutes; proceeds repo-only with limitation note.
        spy.nextChoice = 0
        let declined = AgentCapabilityResolver.resolve(
            selected: copilot, capability: .backgroundWebSearch, taskName: "research",
            canProceedWithoutCapability: true, fallbackDescription: "stay repo-only",
            prompts: spy, isAvailable: { $0 == claude || $0 == copilot }
        )
        if case .proceed(let tool, let available, let note) = declined {
            XCTAssertEqual(tool, copilot)
            XCTAssertFalse(available)
            XCTAssertNotNil(note)
        } else { XCTFail("Declining must fall back to original provider when feasible") }

        let headless = AgentCapabilityResolver.resolve(
            selected: copilot, capability: .backgroundWebSearch, taskName: "research",
            canProceedWithoutCapability: true, fallbackDescription: "stay repo-only",
            prompts: NoPrompts(), isAvailable: { $0 == claude || $0 == copilot }
        )
        if case .proceed(let tool, let available, _) = headless {
            XCTAssertEqual(tool, copilot)
            XCTAssertFalse(available)
        } else { XCTFail("Headless prompt must never silently substitute") }

        // Button 2 cancels before sending context anywhere.
        spy.nextChoice = 2
        let cancelled = AgentCapabilityResolver.resolve(
            selected: copilot, capability: .backgroundWebSearch, taskName: "research",
            canProceedWithoutCapability: true, fallbackDescription: "stay repo-only",
            prompts: spy, isAvailable: { $0 == claude || $0 == copilot }
        )
        XCTAssertEqual(cancelled, .cancelled)

        // When task cannot proceed without capability and declined or no alternative exists -> blocked.
        spy.nextChoice = 0
        let blockedDeclined = AgentCapabilityResolver.resolve(
            selected: copilot, capability: .backgroundWebSearch, taskName: "web lookup",
            canProceedWithoutCapability: false, fallbackDescription: "",
            prompts: spy, isAvailable: { $0 == claude || $0 == copilot }
        )
        if case .blocked(let msg) = blockedDeclined { XCTAssertTrue(msg.contains("not confirmed")) }
        else { XCTFail("Expected blocker when substitution declined and fallback infeasible") }

        let blockedNone = AgentCapabilityResolver.resolve(
            selected: copilot, capability: .backgroundWebSearch, taskName: "web lookup",
            canProceedWithoutCapability: false, fallbackDescription: "",
            prompts: spy, isAvailable: { $0 == copilot }
        )
        if case .blocked(let msg) = blockedNone { XCTAssertTrue(msg.contains("No compatible assistant")) }
        else { XCTFail("Expected blocker when no compatible assistant is available") }

        // 4. AICallLog distinguishes process outcome from AIOperation acceptance (REQ-009).
        let opLog = scratch.appendingPathComponent("ai-operations.jsonl")
        let entry = AICallLog.Entry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            project: scratch.path, label: "verify-test", tool: "claude", model: "sonnet", effort: "low",
            seconds: 1.2, inputTokens: 100, outputTokens: 25, costUSD: 0.002,
            outcome: "ok", acceptance: "repair_needed", attempt: 1, rejectionReason: "missing required key"
        )
        AICallLog.recordOperation(entry, to: opLog)
        AICallLog.waitForPendingWrites()
        let decoded = AICallLog.read(from: opLog)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].outcome, "ok")
        XCTAssertEqual(decoded[0].acceptance, "repair_needed")
        XCTAssertEqual(decoded[0].attempt, 1)
        XCTAssertEqual(decoded[0].rejectionReason, "missing required key")
    }
}

extension EditorHostTests {
    /// A run that reads the folder but is asked to start no subagents (X-Ray's code analysis, BUG-135) reads it itself: Claude has
    /// the read-only tools without Agent; Codex keeps no session, its subagent tools are off and it is not asked to start any.
    func testAOneShotRunAskedForNoSubagentsReadsTheFolderItself() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("no-subagents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var request = CompletionLaunchRequest(prompt: "Check.", systemPrompt: nil, jsonSchema: nil, readableFolder: scratch,
                                              extraReadableFolders: [], linkedFolders: { [] }, allowWeb: false, images: [], effort: nil,
                                              model: nil, workDir: scratch, scratchDirectory: { scratch })
        request.subagents = false
        let claude = try ClaudeProvider().launch(request)
        let tools = try XCTUnwrap(claude.arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(claude.arguments[tools + 1], "Read,Grep,Glob")
        let codex = try CodexProvider().launch(request)
        XCTAssertFalse(codex.keepsSession)
        XCTAssertTrue(codex.arguments.contains("--ephemeral"))
        let off = try XCTUnwrap(codex.arguments.firstIndex(of: "agents.enabled=false"))
        XCTAssertLessThan(off, try XCTUnwrap(codex.arguments.firstIndex(of: "exec")))
        XCTAssertFalse(codex.input.contains(CodexProvider.oneShotSubagents))
    }

    /// A one-shot run that may read files lets the assistant start its own read-only subagents: Claude gets the Agent tool, Codex
    /// keeps its session (a subagent loads it) and is asked to start them. A run without files gets none.
    func testOneShotRunsLetTheAssistantStartItsOwnReadOnlySubagents() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("subagents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func request(readable: URL?) -> CompletionLaunchRequest {
            CompletionLaunchRequest(prompt: "Check.", systemPrompt: nil, jsonSchema: nil, readableFolder: readable,
                                    extraReadableFolders: [], linkedFolders: { [] }, allowWeb: false, images: [], effort: nil,
                                    model: nil, workDir: scratch, scratchDirectory: { scratch })
        }
        func tools(_ launch: CompletionLaunch) throws -> [String] {
            let index = try XCTUnwrap(launch.arguments.firstIndex(of: "--tools"))
            return launch.arguments[index + 1].split(separator: ",").map(String.init)
        }
        // Claude: subagents only next to the read-only tools (a subagent gets the run's tools), never in a run without files.
        XCTAssertEqual(try tools(ClaudeProvider().launch(request(readable: scratch))), ["Read", "Grep", "Glob", "Agent"])
        XCTAssertEqual(try tools(ClaudeProvider().launch(request(readable: nil))), [])
        // Codex: a run that may read files keeps its session and is asked to start subagents for independent parts; a run without
        // files keeps none (`--ephemeral`) and its subagent tools are off (a global option, before `exec`).
        let reading = try CodexProvider().launch(request(readable: scratch))
        XCTAssertTrue(reading.keepsSession)
        XCTAssertFalse(reading.arguments.contains("--ephemeral") || reading.arguments.contains("agents.enabled=false"))
        XCTAssertTrue(reading.input.contains(CodexProvider.oneShotSubagents))
        let textOnly = try CodexProvider().launch(request(readable: nil))
        XCTAssertFalse(textOnly.keepsSession)
        XCTAssertTrue(textOnly.arguments.contains("--ephemeral"))
        let off = try XCTUnwrap(textOnly.arguments.firstIndex(of: "agents.enabled=false"))
        XCTAssertEqual(textOnly.arguments[off - 1], "-c")
        XCTAssertLessThan(off, try XCTUnwrap(textOnly.arguments.firstIndex(of: "exec")))
        XCTAssertFalse(textOnly.input.contains(CodexProvider.oneShotSubagents))
        // The session id the run deletes at its end comes from Codex's first event.
        let sessions = OSAllocatedUnfairLock(initialState: [String]())
        var sessionSink = CompletionSink(onDelta: nil, onActivity: nil)
        sessionSink.onSession = { id in sessions.withLock { $0.append(id) } }
        var codexOutput = CompletionOutput()
        CodexProvider().makeParser().handle(["type": "thread.started", "thread_id": "01a21c45-6bef-7123-8273-4b2043bd31c1"],
                                            output: &codexOutput, sink: sessionSink)
        XCTAssertEqual(sessions.withLock { $0 }, ["01a21c45-6bef-7123-8273-4b2043bd31c1"])

        // A Claude run that starts two subagents (the stream's shape as claude 2.1.332 writes it): the subagents' tasks are not
        // part of the answer, their reads show as the run's activity, and the schema answer arrives as before.
        let first = scratch.appendingPathComponent("a.txt").path, second = scratch.appendingPathComponent("b.txt").path
        func block(_ index: Int, tool: String, id: String, input: [String]) -> [[String: Any]] {
            [["type": "stream_event", "event": ["type": "content_block_start", "index": index,
                                                "content_block": ["type": "tool_use", "id": id, "name": tool, "input": [String: Any]()]]]]
                + input.map { part in
                    ["type": "stream_event", "event": ["type": "content_block_delta", "index": index,
                                                       "delta": ["type": "input_json_delta", "partial_json": part]]]
                }
        }
        var events = block(1, tool: "Agent", id: "toolu_a", input: [#"{"description": "Read a.txt", "#, #""prompt": "Read a.txt"}"#])
            + block(2, tool: "Agent", id: "toolu_b", input: [#"{"description": "Read b.txt", "#, #""prompt": "Read b.txt"}"#])
        events += [("toolu_a", first), ("toolu_b", second)].map { parent, path in
            ["type": "assistant", "parent_tool_use_id": parent,
             "message": ["content": [["type": "tool_use", "id": "read-\(parent)", "name": "Read", "input": ["file_path": path]]]]]
        }
        events += block(0, tool: "StructuredOutput", id: "toolu_s", input: [#"{"a": "al"#, #"pha", "b": "beta"}"#])
        events.append(["type": "result", "result": "", "structured_output": ["a": "alpha", "b": "beta"], "is_error": false])

        let seen = OSAllocatedUnfairLock(initialState: [CompletionActivity]())
        let sink = CompletionSink(onDelta: nil, onActivity: { activity in seen.withLock { $0.append(activity) } })
        let parser = ClaudeProvider().makeParser()
        var output = CompletionOutput()
        for event in events { parser.handle(event, output: &output, sink: sink) }
        let activities = seen.withLock { $0 }
        let answer = activities.compactMap { activity -> String? in
            if case .answerDelta(let part) = activity { return part }
            return nil
        }
        XCTAssertEqual(answer.joined(), #"{"a": "alpha", "b": "beta"}"#)
        let reads = activities.compactMap { activity -> String? in
            if case .read(let path) = activity { return path }
            return nil
        }
        XCTAssertEqual(reads, [first, second])
        XCTAssertEqual(output.structured as? [String: String], ["a": "alpha", "b": "beta"])
        XCTAssertNil(output.errorMessage)
    }
}

extension EditorHostTests {
    /// The AI panel's Codex activity follows the terminal's own session in a folder, not a one-shot run (or one of its subagents)
    /// that reads the same folder at the same time and wrote its rollout later.
    func testCodexActivityFollowsTheTerminalSessionNotAOneShotRun() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("codex-activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let folder = home.appendingPathComponent("project", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let day = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let logs = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", day.year ?? 0, day.month ?? 0,
                                                      day.day ?? 0), isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        func rollout(_ name: String, originator: String, source: Any, age: TimeInterval) throws {
            let meta: [String: Any] = ["type": "session_meta",
                                       "payload": ["cwd": folder.path, "originator": originator, "source": source]]
            let file = logs.appendingPathComponent(name)
            try (try JSONSerialization.data(withJSONObject: meta) + Data("\n".utf8)).write(to: file)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        try rollout("rollout-terminal.jsonl", originator: "codex-tui", source: "cli", age: 60)
        try rollout("rollout-one-shot.jsonl", originator: "codex_exec", source: "exec", age: 5)
        try rollout("rollout-subagent.jsonl", originator: "codex_exec",
                    source: ["subagent": ["thread_spawn": ["parent_thread_id": "one-shot", "depth": 1]]], age: 1)
        XCTAssertEqual(AgentActivityLog.newestCodexLog(for: folder, home: home, now: now)?.lastPathComponent, "rollout-terminal.jsonl")
    }
}

extension EditorHostTests {
    /// Antigravity's model menu lists the account's models from `agy models` (BUG-136): the first menu asks the CLI set in Settings,
    /// keeps the list, and the next menu reads the kept list; a CLI that lists nothing leaves the menu at Default.
    @MainActor func testAntigravityModelMenuListsTheAccountsModels() async throws {
        let tool = try XCTUnwrap(CLITool(rawValue: "antigravity"))
        let settings = Settings.standard
        let pathKey = Setting.cliPath(tool.rawValue), listKey = Setting.cliModelList(tool.rawValue)
        let oldPath = settings.stored(pathKey), oldList = settings.stored(listKey)
        defer {
            settings.set(oldPath, for: pathKey)
            settings.set(oldList, for: listKey)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agy-models-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agy = folder.appendingPathComponent("agy")
        func script(_ body: String) throws {
            try ("#!/bin/sh\n" + body).write(to: agy, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
        }
        // What agy 1.5.18 prints: a progress line on stderr, then `<id>\t<name>` per model on stdout.
        try script("""
        [ "$*" = "--log-file /dev/null models" ] || exit 9
        echo "Fetching available models..." >&2
        printf 'gemini-4-neon-high\\tGemini 4 Neon (High)\\ngemini-pro-orchestrator\\tOrchestrator (Carbon)\\ngpt-oss-120b-medium\\tGPT-OSS 120B (Medium)\\n'
        """)
        settings.set(agy.path, for: pathKey)
        settings.set(Data(), for: listKey)

        let listed = await AIToolbarMenu.loadOptions(for: tool)
        XCTAssertEqual(listed.map(\.id), ["", "gemini-4-neon-high", "gemini-pro-orchestrator", "gpt-oss-120b-medium"])
        XCTAssertEqual(listed.last?.name, "GPT-OSS 120B (Medium)")
        XCTAssertEqual(AIAssistantPreferences.modelOptions(for: tool).map(\.id), listed.map(\.id), "the list is kept for the next menu")

        // A CLI that lists nothing (signed out, an error) adds nothing.
        settings.set(Data(), for: listKey)
        try script("echo 'Not signed in' >&2\nexit 1\n")
        let none = await AIToolbarMenu.loadOptions(for: tool)
        XCTAssertEqual(none.map(\.id), [""])
    }
}
