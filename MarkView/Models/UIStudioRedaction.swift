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

    // MARK: Kept cookies and storage (REQ-008)

    /// Markers of a session, a sign-in or a CSRF value in a cookie or storage entry's name (`JSESSIONID`, `XSRF-TOKEN`).
    static let sessionNameMarkers = ["session", "sessid", "credential", "bearer", "csrf", "xsrf", "jwt", "oauth", "saml"]
    /// Short markers that count only as a whole part of the name (`connect.sid`, `authToken`), not inside a word (`sidebar`).
    static let sessionNameParts: Set<String> = ["sid", "sess", "auth", "sso"]

    /// Why a cookie or localStorage entry must not be kept in the committable environment, or nil when it may be kept: a
    /// name or value that is too long, a name that looks confidential, or a value that looks like a credential.
    func confidentialEntryProblem(name: String, value: String) -> String? {
        if name.isEmpty || name.utf8.count > StudioKeptBrowserData.maxName { return "its name is empty or too long" }
        if value.utf8.count > StudioKeptBrowserData.maxValue { return "its value is too large" }
        if isConfidentialEntryName(name) { return "its name looks confidential" }
        if isConfidentialEntryValue(value) { return "its value looks like a credential" }
        return nil
    }

    /// A confidential field name, or a session, sign-in or CSRF marker. Every such entry is a cookie or stored by the
    /// page, so `cookie` in its name (`cookie_consent`) says nothing about it.
    func isConfidentialEntryName(_ name: String) -> Bool {
        let key = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if fields.contains(where: { $0 != "cookie" && key.contains($0) }) { return true }
        if Self.sessionNameMarkers.contains(where: { key.contains($0) }) { return true }
        return Self.nameParts(name).contains { Self.sessionNameParts.contains($0) }
    }

    /// A credential shape (provider keys, JWTs, private keys), a long random-looking token, or — in a JSON value — a
    /// confidential field or such a value at any depth.
    func isConfidentialEntryValue(_ value: String) -> Bool { confidentialValue(value, depth: 0) }

    private func confidentialValue(_ value: String, depth: Int) -> Bool {
        let decoded = value.removingPercentEncoding ?? value
        let credential = [value, decoded].contains { text in
            Self.secretPatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
        }
        if credential { return true }
        if let json = StudioJSON(text: decoded), json.objectValue != nil || json.arrayValue != nil {
            return depth < 6 && confidentialJSON(json, depth: depth + 1)
        }
        return Self.tokens(in: decoded).contains(where: Self.looksRandom)
    }

    private func confidentialJSON(_ json: StudioJSON, depth: Int) -> Bool {
        switch json {
        case .object(let object):
            return object.contains { key, inner in
                let present: Bool
                switch inner {
                case .null: present = false
                case .string(let text): present = !text.isEmpty
                default: present = true
                }
                return (present && isConfidentialEntryName(key)) || confidentialJSON(inner, depth: depth)
            }
        case .array(let array): return array.contains { confidentialJSON($0, depth: depth) }
        case .string(let text): return confidentialValue(text, depth: depth)
        default: return false
        }
    }

    /// The words of a name: split at punctuation and at lower-to-upper case changes (`authToken` → auth, token).
    static func nameParts(_ name: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var previousLower = false
        for character in name {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { parts.append(current.lowercased()) }
                current = ""
                previousLower = false
                continue
            }
            if character.isUppercase && previousLower, !current.isEmpty {
                parts.append(current.lowercased())
                current = ""
            }
            current.append(character)
            previousLower = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { parts.append(current.lowercased()) }
        return parts
    }

    /// The runs of token characters in a value (letters, digits and `+/=_-.~`), the shapes generated identifiers take.
    static func tokens(in text: String) -> [String] {
        text.split { character in !(character.isASCII && (character.isLetter || character.isNumber || "+/=_-.~".contains(character))) }
            .map(String.init)
    }

    /// A token of 24 or more characters that reads like generated data rather than words: hexadecimal mixing letters and
    /// digits (hashes, UUIDs), or letters and digits that change class every one or two characters (base64, base62),
    /// or every two or three with a large share of digits (base36). Words and camelCase names have long runs.
    static func looksRandom(_ token: String) -> Bool {
        let characters = Array(token)
        guard characters.count >= 24 else { return false }
        let kinds: [Int] = characters.compactMap { character in
            guard character.isASCII else { return nil }
            return character.isNumber ? 0 : character.isUppercase ? 1 : character.isLowercase ? 2 : nil
        }
        guard Set(kinds).count >= 2 else { return false }
        let digits = kinds.filter { $0 == 0 }.count
        let letters = kinds.count - digits
        if characters.allSatisfy({ $0.isHexDigit || $0 == "-" }), digits >= 4, letters >= 4 { return true }
        var runs = 1
        for (previous, next) in zip(kinds, kinds.dropFirst()) where previous != next { runs += 1 }
        let meanRun = Double(kinds.count) / Double(runs)
        let digitShare = Double(digits) / Double(kinds.count)
        let letterShare = Double(letters) / Double(kinds.count)
        return meanRun <= 2.2 || (digitShare >= 0.2 && letterShare >= 0.2 && meanRun <= 3)
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

    /// A JSON value (the arguments of a preload bridge call, REQ-016) is redacted field by field, anything else as text.
    func redact(headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            result[name] = Self.confidentialHeaders.contains(name.lowercased()) || isConfidential(name) ? Self.placeholder : redact(body: value)
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
