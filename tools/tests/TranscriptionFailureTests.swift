// Failed transcriptions read as a problem, a next step and a short tag (BUG-009).
import Foundation
var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name) \(detail)") }
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

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("all transcription failure checks passed")
