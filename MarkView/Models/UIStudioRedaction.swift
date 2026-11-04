import Foundation

/// Keeps confidential values out of the model's context, the logs and exported evidence (REQ-006, §11): values of
/// confidential fields and headers, and text that looks like a credential.
struct StudioRedactor {
    static let placeholder = "[redacted]"

    /// Field names treated as confidential unless the project configures its own list.
    static let defaultConfidentialFields = ["password", "passwd", "secret", "token", "apiKey", "api_key", "accessToken",
                                            "refreshToken", "authorization", "cookie", "ssn", "creditCard", "cardNumber",
                                            "cvv", "cvc", "iban", "privateKey", "private_key", "clientSecret"]

    /// Headers whose values are always confidential.
    static let confidentialHeaders: Set<String> = ["authorization", "cookie", "set-cookie", "proxy-authorization",
                                                   "x-api-key", "x-auth-token", "x-csrf-token", "x-xsrf-token"]

    /// Credential shapes in free text: provider keys, GitHub and Slack tokens, AWS key ids, JWTs, private key blocks.
    static let secretPatterns = [
        #"sk-[A-Za-z0-9_\-]{16,}"#, #"sk-ant-[A-Za-z0-9_\-]{16,}"#, #"gh[pousr]_[A-Za-z0-9]{20,}"#, #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"xox[abposr]-[A-Za-z0-9\-]{10,}"#, #"AKIA[0-9A-Z]{16}"#, #"AIza[0-9A-Za-z_\-]{30,}"#,
        #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
    ]

    private let fields: [String]

    init(fields: [String] = StudioRedactor.defaultConfidentialFields) {
        self.fields = fields.map { $0.lowercased().replacingOccurrences(of: "_", with: "") }.filter { !$0.isEmpty }
    }

    /// `newPassword`, `user_password` and `X-Api-Key` are confidential when `password` / `apiKey` are.
    func isConfidential(_ name: String) -> Bool {
        let key = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        return fields.contains { key.contains($0) }
    }

    func redact(_ value: StudioJSON) -> StudioJSON {
        switch value {
        case .object(let object):
            var result: [String: StudioJSON] = [:]
            for (key, inner) in object { result[key] = isConfidential(key) && !inner.isNull ? .string(Self.placeholder) : redact(inner) }
            return .object(result)
        case .array(let array): return .array(array.map(redact))
        case .string(let text): return .string(redact(text: text))
        default: return value
        }
    }

    func redact(headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            result[name] = Self.confidentialHeaders.contains(name.lowercased()) || isConfidential(name) ? Self.placeholder : redact(text: value)
        }
        return result
    }

    /// A body that may be JSON: JSON is redacted field by field, anything else as text.
    func redact(body: String) -> String {
        if let json = StudioJSON(text: body), json.objectValue != nil || json.arrayValue != nil { return redact(json).text }
        return redact(text: body)
    }

    /// Credential shapes, and `name=value` / `"name": "value"` pairs of confidential names, in free text (HTML, logs).
    func redact(text: String) -> String {
        var result = text
        for pattern in Self.secretPatterns {
            result = result.replacingOccurrences(of: pattern, with: Self.placeholder, options: .regularExpression)
        }
        for field in fields {
            let assignment = #"(?i)(\b[\w-]*"# + NSRegularExpression.escapedPattern(for: field) + #"[\w-]*["']?\s*[:=]\s*["']?)([^"'\s,;&<>}]{3,})"#
            result = result.replacingOccurrences(of: assignment, with: "$1" + Self.placeholder, options: .regularExpression)
        }
        return result
    }

    /// The environment of a process UI Studio starts: production secrets are not inherited (§11). Returns the environment
    /// and the names that were left out (never their values).
    static func sanitizedEnvironment(_ environment: [String: String]) -> (environment: [String: String], removed: [String]) {
        let secretName = #"(?i)(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|CREDENTIAL|ACCESS_?KEY|SESSION_?KEY|AUTH|DSN|DATABASE_URL|CONNECTION_STRING|WEBHOOK)"#
        let secretPrefixes = ["AWS_", "AZURE_", "GCP_", "GOOGLE_APPLICATION_CREDENTIALS", "ANTHROPIC_", "OPENAI_", "STRIPE_",
                              "GITHUB_", "GH_", "NPM_TOKEN", "SUPABASE_", "FIREBASE_", "SENTRY_", "VERCEL_", "NETLIFY_",
                              "CLOUDFLARE_", "HEROKU_", "DIGITALOCEAN_", "TWILIO_", "SENDGRID_", "SLACK_", "DATADOG_"]
        var kept: [String: String] = [:]
        var removed: [String] = []
        for (name, value) in environment {
            if name.range(of: secretName, options: .regularExpression) != nil || secretPrefixes.contains(where: { name.hasPrefix($0) }) {
                removed.append(name)
            } else {
                kept[name] = value
            }
        }
        return (kept, removed.sorted())
    }
}
