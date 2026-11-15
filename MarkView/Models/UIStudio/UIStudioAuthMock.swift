import Foundation

// The mock-up policy of UI Studio for sign-in and forms (REQ-010, DEC-007): whatever was typed, signing in, signing up,
// verifying, resetting a password and signing out succeed and sign in the scenario's test user, and no real service is
// contacted.
// - `StudioAuthMock` answers Supabase Auth (GoTrue) itself, with signed test JWTs, for the page and for the development
//   server's own requests through a simulated connection.
// - `StudioPlaceholders` gives the fixed answers of other providers' rules the same test user, token and times.
// - `StudioExternalPage` stands in for a site outside the application (an OAuth provider, a checkout) and returns to the
//   application as if the person had signed in or paid there.

/// A built-in Supabase Auth (GoTrue) for a project that uses Supabase (REQ-010). The simulator asks it before any rule. It
/// answers the `/auth/v1/` endpoints of the project's simulated Supabase connections, and those of hosted Supabase
/// (`https://<ref>.supabase.co`) unless the person keeps that address real. Every sign-in passes with any input: the
/// session is the scenario's test user's, its access token a `StudioTestJWT` valid from the test time for a year.
struct StudioAuthMock: Equatable, Sendable {
    /// The name answers carry in place of a rule's id.
    static let ruleID = "builtin-supabase-auth"
    /// How the Environment panel lists it.
    static let dependencyID = "Supabase Auth — built-in mock-up"
    /// The authorization code every simulated OAuth sign-in returns.
    static let code = "markview-test-code"
    static let refreshToken = "markview-test-refresh-token"
    static let sessionID = "markview-test-session"
    /// How long a session is valid from the scenario's test time.
    static let lifetime: Double = 365 * 24 * 3600

    /// `<origin><path>/auth/v1` of each simulated Supabase address, the public one first.
    var bases: [String] = []
    /// The tokens' `iss`: GoTrue names its public address, whichever address a client used.
    var issuer: String?
    /// Origins of Supabase connections the person switched to Real: never answered, hosted or not.
    var realOrigins: [String] = []
    /// What the application changed of the test user in the current generation (sign-up data, `PUT /user`).
    private(set) var state = State()

    struct State: Equatable, Sendable {
        var generation = 0
        var metadata: [String: StudioJSON] = [:]
        var email: String?
        var phone: String?
    }

    /// The mock for a server's connections: the simulated ones whose variable names Supabase (`NEXT_PUBLIC_SUPABASE_URL`,
    /// `SUPABASE_INTERNAL_URL`). Without any (a server started outside MarkView) it still answers hosted Supabase.
    init(connections: [StudioServerConnection]) {
        let supabase = connections.filter { $0.variable.uppercased().contains("SUPABASE") }
        let simulated = supabase.filter { $0.mode == .simulated }
            .sorted { ($0.variable.contains("PUBLIC") ? 0 : 1, $0.variable) < ($1.variable.contains("PUBLIC") ? 0 : 1, $1.variable) }
        var seen = Set<String>()
        bases = simulated.map { Self.authBase(origin: $0.origin, basePath: $0.basePath) }.filter { seen.insert($0).inserted }
        issuer = bases.first
        realOrigins = supabase.filter { $0.mode == .real }.map(\.origin)
    }

    static func authBase(origin: String, basePath: String) -> String {
        basePath.hasSuffix("/auth/v1") ? origin + basePath : origin + basePath + "/auth/v1"
    }

    /// The same addresses answered, whatever the state.
    func sameConfiguration(_ other: StudioAuthMock?) -> Bool {
        guard let other else { return false }
        return bases == other.bases && issuer == other.issuer && realOrigins == other.realOrigins
    }

    // MARK: Addresses

    /// The GoTrue endpoint `url` names (`/token`, `/user`…) and the base it was reached at; nil when it is not this mock's.
    func endpoint(of url: URL) -> (path: String, base: String)? {
        guard let origin = StudioBridge.Origin(url: url) else { return nil }
        let path = url.path
        for base in bases {
            guard let baseURL = URL(string: base), let baseOrigin = StudioBridge.Origin(url: baseURL), baseOrigin == origin else { continue }
            let prefix = baseURL.path
            if path.hasPrefix(prefix + "/") { return (String(path.dropFirst(prefix.count)), base) }
        }
        let host = origin.host
        let hosted = origin.scheme == "https" && (host.hasSuffix(".supabase.co") || host.hasSuffix(".supabase.in"))
        let real = realOrigins.contains { URL(string: $0).flatMap(StudioBridge.Origin.init(url:)) == origin }
        guard hosted, !real, path.hasPrefix("/auth/v1/") else { return nil }
        return (String(path.dropFirst("/auth/v1".count)), origin.text + "/auth/v1")
    }

    // MARK: Answers

    /// The answer to `request`, or nil when it is not a request for this mock (it then goes to the rules).
    mutating func answer(_ request: StudioHTTPRequest, role: StudioRole, testTime: Date, generation: Int,
                         appOrigin: String?) -> StudioSimResponse? {
        guard let (endpoint, base) = endpoint(of: request.url) else { return nil }
        if state.generation != generation { state = State(generation: generation) }
        let issuer = self.issuer ?? base
        let body = request.jsonBody?.objectValue ?? [:]
        let query = request.query
        func session() -> StudioSimResponse { .json(200, Self.session(user: user(role: role, testTime: testTime), issuer: issuer, testTime: testTime)) }

        switch (request.method.uppercased(), endpoint) {
        case ("POST", "/token"), ("POST", "/verify"):
            // Every grant (password, refresh_token, pkce, id_token…) and every one-time code pass.
            return session()
        case ("POST", "/signup"):
            if let data = body["data"]?.objectValue { state.metadata.merge(data) { $1 } }
            // Auto-confirmed, so the application gets a session at once.
            return session()
        case ("GET", "/verify"):
            // The link of a confirmation or magic-link e-mail.
            guard let target = query["redirect_to"].flatMap(Self.httpURL) ?? appOrigin.flatMap({ URL(string: $0 + "/") }) else { return session() }
            let pkce = (query["token"] ?? query["token_hash"] ?? "").hasPrefix("pkce_")
            return redirect(303, to: target, pkce: pkce, user: user(role: role, testTime: testTime), issuer: issuer, testTime: testTime)
        case ("GET", "/user"):
            if let refusal = Self.bearerRefusal(request.headers["authorization"]) { return refusal }
            return .json(200, user(role: role, testTime: testTime))
        case ("PUT", "/user"):
            if let data = body["data"]?.objectValue { state.metadata.merge(data) { $1 } }
            if let email = body["email"]?.stringValue, !email.isEmpty { state.email = email }
            if let phone = body["phone"]?.stringValue, !phone.isEmpty { state.phone = phone }
            // A new password is accepted and never kept.
            return .json(200, user(role: role, testTime: testTime))
        case ("POST", "/logout"):
            return StudioSimResponse(status: 204, headers: [:], body: nil)
        case ("POST", "/otp"), ("POST", "/recover"), ("POST", "/magiclink"), ("POST", "/resend"):
            return .json(200, .object(body["phone"] == nil ? [:] : ["message_id": .string("markview-test-message")]))
        case ("GET", "/settings"):
            return .json(200, Self.settings)
        case ("GET", "/authorize"):
            // OAuth: no provider is asked; the application gets its code (PKCE) or its tokens (implicit flow) at once.
            guard let target = query["redirect_to"].flatMap(Self.httpURL) ?? appOrigin.flatMap({ URL(string: $0 + "/") }) else {
                return .json(400, .object(["code": .number(400), "error_code": .string("validation_failed"), "msg": .string("redirect_to is missing")]))
            }
            let pkce = query["code_challenge"] != nil || query["flow_type"] == "pkce"
            return redirect(302, to: target, pkce: pkce, user: user(role: role, testTime: testTime), issuer: issuer, testTime: testTime)
        case ("GET", "/.well-known/jwks.json"):
            // The tokens are HS256: clients verify them through GET /user, and no asymmetric key is published.
            return .json(200, .object(["keys": .array([])]))
        default:
            return nil
        }
    }

    /// The test user as GoTrue describes a user, with what the application changed in this generation.
    func user(role: StudioRole, testTime: Date) -> StudioJSON { Self.user(role: role, state: state, testTime: testTime) }

    /// The state that holds for `generation`: a new generation starts from the scenario's user again.
    func state(for generation: Int) -> State { state.generation == generation ? state : State(generation: generation) }

    static func user(role: StudioRole, state: State, testTime: Date) -> StudioJSON {
        let given = role.user.objectValue ?? [:]
        let id = given["id"]?.identityKey ?? "user-1"
        let email = state.email ?? given["email"]?.stringValue ?? "tester@example.test"
        let phone = state.phone ?? given["phone"]?.stringValue ?? ""
        let time = StudioJSON.string(iso(testTime))
        var app = given["app_metadata"]?.objectValue ?? ["provider": .string("email"), "providers": .array([.string("email")])]
        // The scenario's role is the application's role, which only the server sets (app_metadata).
        if given["app_metadata"] == nil, let appRole = given["role"], appRole.stringValue != nil { app["role"] = appRole }
        var metadata = given["user_metadata"]?.objectValue ?? defaultMetadata(given, id: id, email: email)
        metadata.merge(state.metadata) { $1 }
        let identity = StudioJSON.object([
            "identity_id": .string("markview-test-identity"), "id": .string(id), "user_id": .string(id), "provider": .string("email"),
            "identity_data": .object(["email": .string(email), "email_verified": .bool(true), "phone_verified": .bool(false), "sub": .string(id)]),
            "email": .string(email), "last_sign_in_at": time, "created_at": time, "updated_at": time,
        ])
        return .object([
            "id": .string(id), "aud": .string("authenticated"), "role": .string("authenticated"), "email": .string(email),
            "phone": .string(phone), "email_confirmed_at": time, "confirmed_at": time, "last_sign_in_at": time,
            "created_at": time, "updated_at": time, "app_metadata": .object(app), "user_metadata": .object(metadata),
            "identities": .array([identity]), "is_anonymous": .bool(false),
        ])
    }

    /// The scenario user's own fields (first name, avatar…) as sign-up data, with the names Supabase uses.
    private static func defaultMetadata(_ given: [String: StudioJSON], id: String, email: String) -> [String: StudioJSON] {
        let reserved: Set<String> = ["id", "email", "phone", "role", "app_metadata", "user_metadata", "token", "password"]
        var metadata = given.filter { !reserved.contains($0.key) }
        if let name = given["name"], name.stringValue != nil, metadata["full_name"] == nil { metadata["full_name"] = name }
        metadata["email"] = .string(email)
        metadata["email_verified"] = .bool(true)
        metadata["sub"] = .string(id)
        return metadata
    }

    static func session(user: StudioJSON, issuer: String, testTime: Date) -> StudioJSON {
        .object([
            "access_token": .string(accessToken(user: user, issuer: issuer, testTime: testTime)), "token_type": .string("bearer"),
            "expires_in": .number(lifetime), "expires_at": .number(expiresAt(testTime)), "refresh_token": .string(refreshToken),
            "user": user,
        ])
    }

    /// A Supabase access token of `user`: the claims GoTrue writes, signed by `StudioTestJWT`. It depends only on the user,
    /// the issuer and the test time, so every answer of a generation carries the same token.
    static func accessToken(user: StudioJSON, issuer: String, testTime: Date) -> String {
        let issued = seconds(testTime)
        return StudioTestJWT.make([
            "iss": .string(issuer), "sub": user["id"] ?? .string("user-1"), "aud": .string("authenticated"),
            "exp": .number(issued + lifetime), "iat": .number(issued), "email": user["email"] ?? .string(""),
            "phone": user["phone"] ?? .string(""), "app_metadata": user["app_metadata"] ?? .object([:]),
            "user_metadata": user["user_metadata"] ?? .object([:]), "role": .string("authenticated"), "aal": .string("aal1"),
            "amr": .array([.object(["method": .string("password"), "timestamp": .number(issued)])]),
            "session_id": .string(sessionID), "is_anonymous": .bool(false),
        ])
    }

    static func seconds(_ date: Date) -> Double { floor(date.timeIntervalSince1970) }
    /// A year after the test time: the page's clock and a server on the scenario's clock both accept the session.
    static func expiresAt(_ testTime: Date) -> Double { seconds(testTime) + lifetime }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    private func redirect(_ status: Int, to target: URL, pkce: Bool, user: StudioJSON, issuer: String, testTime: Date) -> StudioSimResponse {
        guard var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else {
            return .json(400, .object(["code": .number(400), "error_code": .string("validation_failed"), "msg": .string("redirect_to is not an address")]))
        }
        if pkce {
            components.percentEncodedQuery = [components.percentEncodedQuery, "code=" + Self.code].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: "&")
        } else {
            let token = Self.accessToken(user: user, issuer: issuer, testTime: testTime)
            components.percentEncodedFragment = "access_token=\(token)&expires_at=\(Int(Self.expiresAt(testTime)))&expires_in=\(Int(Self.lifetime))"
                + "&refresh_token=\(Self.refreshToken)&token_type=bearer&type=signup"
        }
        let location = components.url?.absoluteString ?? target.absoluteString
        return StudioSimResponse(status: status, headers: ["location": location, "content-type": "text/html; charset=utf-8"], body: nil)
    }

    /// GoTrue's answer to `GET /user` without a user's token: signed out, or an API key in place of a session.
    private static func bearerRefusal(_ header: String?) -> StudioSimResponse? {
        let token = header.flatMap { $0.lowercased().hasPrefix("bearer ") ? String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil } ?? ""
        guard !token.isEmpty else {
            return .json(401, .object(["code": .number(401), "error_code": .string("no_authorization"),
                                       "msg": .string("This endpoint requires a valid Bearer token")]))
        }
        guard StudioTestJWT.claims(of: token)?["sub"]?.identityKey?.isEmpty == false else {
            return .json(403, .object(["code": .number(403), "error_code": .string("bad_jwt"), "msg": .string("invalid claim: missing sub claim")]))
        }
        return nil
    }

    private static func httpURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }

    /// Every sign-in method enabled, sign-up open and auto-confirmed.
    static let settings: StudioJSON = .object([
        "external": .object(Dictionary(uniqueKeysWithValues: [
            "anonymous_users", "apple", "azure", "bitbucket", "discord", "email", "facebook", "figma", "github", "gitlab", "google",
            "kakao", "keycloak", "linkedin", "linkedin_oidc", "notion", "phone", "slack", "slack_oidc", "spotify", "twitch", "twitter",
            "workos", "zoom",
        ].map { ($0, StudioJSON.bool(true)) })),
        "disable_signup": .bool(false), "mailer_autoconfirm": .bool(true), "phone_autoconfirm": .bool(true),
        "sms_provider": .string("twilio"), "saml_enabled": .bool(false),
    ])

    // MARK: Project

    /// Whether the app at `appFolder` uses Supabase: it, or a workspace package it depends on, depends on a `@supabase/`
    /// package (`@supabase/supabase-js`, `@supabase/ssr`, the auth helpers). Reads files: call it off the main thread.
    static func usesSupabase(appFolder: URL, root: URL) -> Bool {
        func depends(_ folder: URL) -> Bool {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")), data.count <= 1_000_000,
                  let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return ["dependencies", "devDependencies", "peerDependencies"].contains { key in
                ((manifest[key] as? [String: Any]) ?? [:]).keys.contains { $0.hasPrefix("@supabase/") }
            }
        }
        return depends(appFolder) || StudioConnections.workspacePackages(of: appFolder, root: root).contains(where: depends)
    }

    /// The test value of a variable holding the secret JWTs are signed with (`SUPABASE_JWT_SECRET`, `JWT_SECRET`): the test
    /// signing key, so a server that verifies the mock's access tokens itself accepts them; nil for other variables.
    static func signingSecretTestValue(for name: String) -> String? {
        let upper = name.uppercased()
        return upper.contains("JWT") && upper.contains("SECRET") ? StudioTestJWT.key : nil
    }

    /// What the Environment panel says about the mock.
    var note: String {
        let addresses = bases.isEmpty ? "hosted Supabase" : bases.joined(separator: ", ") + " and hosted Supabase"
        return "Sign-in, sign-up, verification, password reset, OAuth and sign-out at \(addresses) succeed with any input and sign "
            + "in the scenario's test user, with test tokens. Nothing reaches Supabase."
    }
}

// MARK: - Placeholders

/// `{{studio.*}}` in the fixed answers of rules (REQ-010): other providers' sign-ins and forms answer with the scenario's
/// test user and the same signed test token as the built-in Supabase Auth.
/// - `{{studio.token}}`, `{{studio.refreshToken}}`;
/// - `{{studio.user}}` and `{{studio.user.<field>}}` (dotted for nested fields), from the scenario's user;
/// - `{{studio.now}}` and `{{studio.expiresAt}}` as ISO 8601 times, `{{studio.nowSeconds}}` and `{{studio.expiresAtSeconds}}`
///   as Unix seconds.
/// A JSON string that is only a placeholder becomes the value itself (a number, an object); inside other text it is written
/// as text. An unknown placeholder is left as it is.
/// Which cookies keep an application signed in (BUG-088): a restore for the same test user carries these over, so that a scenario
/// switch does not send the page back to its sign-in page. Consent, preferences and analytics are cleared as before (REQ-008).
enum StudioSignInCookies {
    static func isSignIn(name: String) -> Bool {
        let lower = name.lowercased()
        if ["consent", "gdpr", "cookiebanner", "analytics", "_ga", "_gid", "locale", "lang", "theme", "tracking"].contains(where: lower.contains) { return false }
        return ["auth", "session", "sess", "token", "jwt", "sb-", "sid", "login", "access", "refresh", "csrf", "xsrf"].contains { lower.contains($0) }
    }
}

enum StudioPlaceholders {
    struct Values {
        var token: String
        var refreshToken: String
        var user: [String: StudioJSON]
        var now: Date
        var expiresAt: Date
    }

    /// What the preparation prompt says about sign-in answers (`StudioPrompts.preparationSystem`).
    static let promptGuide = "- Sign-in is a mock-up too (REQ-010). When the project uses Supabase, MarkView answers its Supabase Auth "
        + "(`/auth/v1/...`) itself: add no rules for it. For another provider's sign-in, sign-up, token refresh or current "
        + "user, write a respond rule whose fixed body uses these placeholders, which MarkView fills with the scenario's test "
        + "user: `{{studio.token}}` (a signed test JWT), `{{studio.refreshToken}}`, `{{studio.user}}` or "
        + "`{{studio.user.<field>}}` (for example `{{studio.user.email}}`), `{{studio.now}}` and `{{studio.expiresAt}}` (ISO 8601; "
        + "`{{studio.nowSeconds}}` and `{{studio.expiresAtSeconds}}` in Unix seconds). A string that is only a placeholder "
        + "becomes that value."

    private static let pattern = try? NSRegularExpression(pattern: #"\{\{\s*studio\.([A-Za-z0-9_.\-]+)\s*\}\}"#)

    static func mayContain(_ text: String) -> Bool { text.contains("{{") && text.contains("studio.") }

    static func mayContain(_ response: StudioSimResponse) -> Bool {
        (response.body.map(mayContain) ?? false) || response.headers.values.contains(where: mayContain)
    }

    static func value(_ name: String, in values: Values) -> StudioJSON? {
        switch name {
        case "token": return .string(values.token)
        case "refreshToken": return .string(values.refreshToken)
        case "now": return .string(StudioAuthMock.iso(values.now))
        case "nowSeconds": return .number(StudioAuthMock.seconds(values.now))
        case "expiresAt": return .string(StudioAuthMock.iso(values.expiresAt))
        case "expiresAtSeconds": return .number(StudioAuthMock.seconds(values.expiresAt))
        case "user": return .object(values.user)
        default:
            guard name.hasPrefix("user.") else { return nil }
            var current: StudioJSON? = .object(values.user)
            for part in name.dropFirst("user.".count).split(separator: ".") { current = current?[String(part)] }
            return current ?? .null
        }
    }

    static func substitute(_ response: StudioSimResponse, _ values: Values) -> StudioSimResponse {
        var next = response
        for (name, value) in response.headers where mayContain(value) {
            // A header value never gets a line break from a value.
            next.headers[name] = substitute(text: value, values).components(separatedBy: .newlines).joined(separator: " ")
        }
        if let body = response.body, mayContain(body) {
            next.body = StudioJSON(text: body).map { substitute($0, values).text } ?? substitute(text: body, values)
        }
        return next
    }

    static func substitute(_ json: StudioJSON, _ values: Values) -> StudioJSON {
        switch json {
        case .string(let text):
            guard mayContain(text) else { return json }
            if let name = wholeName(text), let value = value(name, in: values) { return value }
            return .string(substitute(text: text, values))
        case .array(let items): return .array(items.map { substitute($0, values) })
        case .object(let fields): return .object(fields.mapValues { substitute($0, values) })
        default: return json
        }
    }

    static func substitute(text: String, _ values: Values) -> String {
        guard mayContain(text), let pattern else { return text }
        var result = ""
        var rest = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            result += text[rest..<range.lowerBound]
            result += value(String(text[nameRange]), in: values).map(inline) ?? String(text[range])
            rest = range.upperBound
        }
        return result + text[rest...]
    }

    /// The placeholder's name when `text` is that placeholder and nothing else.
    private static func wholeName(_ text: String) -> String? {
        guard let pattern, let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range == NSRange(text.startIndex..., in: text), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func inline(_ value: StudioJSON) -> String {
        switch value {
        case .string(let text): return text
        case .null: return ""
        case .number, .bool: return value.identityKey ?? ""
        case .array, .object: return value.text
        }
    }
}

extension StudioSimulator {
    /// The built-in Supabase Auth's answer (REQ-010), asked before any rule; nil when the request is not for it.
    mutating func authAnswer(_ request: StudioHTTPRequest) -> StudioSimOutcome? {
        guard var mock = authMock,
              let response = mock.answer(request, role: scenario.role, testTime: scenario.testTime, generation: generation, appOrigin: appOrigin)
        else { return nil }
        authMock = mock
        return .respond(response, rule: StudioAuthMock.ruleID)
    }

    /// The scenario's test values for `{{studio.*}}`: the token is the one the built-in Supabase Auth issues now.
    var placeholderValues: StudioPlaceholders.Values {
        let role = scenario.role, testTime = scenario.testTime
        let user = StudioAuthMock.user(role: role, state: authMock?.state(for: generation) ?? StudioAuthMock.State(), testTime: testTime)
        let token = StudioAuthMock.accessToken(user: user, issuer: authMock?.issuer ?? "markview-test", testTime: testTime)
        return StudioPlaceholders.Values(token: token, refreshToken: StudioAuthMock.refreshToken, user: role.user.objectValue ?? [:],
                                         now: testTime, expiresAt: Date(timeIntervalSince1970: StudioAuthMock.expiresAt(testTime)))
    }

    /// `response` with the `{{studio.*}}` placeholders of its body and headers replaced (REQ-010).
    func withPlaceholders(_ response: StudioSimResponse) -> StudioSimResponse {
        StudioPlaceholders.mayContain(response) ? StudioPlaceholders.substitute(response, placeholderValues) : response
    }
}

// MARK: - External pages

/// A local stand-in for a page outside the application (REQ-010): an OAuth provider's sign-in, a checkout, any other site.
/// Nothing is sent to it. Continue as Test User returns to the address the request names, as if the person had signed in
/// or paid there, and goes back when it names none.
enum StudioExternalPage {
    /// The query parameters that name where a provider returns, in the order they are looked for.
    static let redirectParameters = ["redirect_uri", "redirect_to", "redirect_url", "return_to", "returnTo", "callbackUrl",
                                     "success_url", "next"]

    /// Where Continue goes: the address of the first redirect parameter (a path is the application's), with `code` and the
    /// original `state` added for an OAuth request (`response_type=code`); nil when the URL names none.
    static func returnURL(for url: URL, appOrigin: String?) -> URL? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        for name in redirectParameters {
            guard let raw = value(name) else { continue }
            let target = raw.hasPrefix("/") && !raw.hasPrefix("//") ? appOrigin.flatMap { URL(string: $0 + raw) } : URL(string: raw)
            guard let target, let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme), target.host != nil,
                  var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else { continue }
            if (value("response_type") ?? "").split(separator: " ").contains("code") {
                var added = ["code=" + StudioAuthMock.code]
                if let state = value("state") { added.append("state=" + encodedValue(state)) }
                components.percentEncodedQuery = ([components.percentEncodedQuery ?? ""].filter { !$0.isEmpty } + added).joined(separator: "&")
            }
            if let result = components.url { return result }
        }
        return nil
    }

    private static func encodedValue(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The simulated page for `url`. `returnTo` nil: Continue goes back.
    static func html(for url: URL, returnTo: URL?, user: StudioJSON) -> String {
        let host = url.host ?? url.absoluteString
        let email = user["email"]?.stringValue ?? user["name"]?.stringValue ?? "the test user"
        let action: String
        if let returnTo {
            let shown = (returnTo.scheme.map { $0 + "://" } ?? "") + (returnTo.host ?? "") + (returnTo.port.map { ":\($0)" } ?? "") + returnTo.path
            action = "<p>Continue signs in as the scenario's test user <code>\(escape(email))</code> and returns to <code>\(escape(shown))</code>.</p>\n"
                + "<a id=\"continue\" class=\"button\" href=\"\(escape(returnTo.absoluteString))\">Continue as Test User</a>"
        } else {
            action = "<p>The request names no address to return to, so Continue goes back to the application.</p>\n"
                + "<a id=\"continue\" class=\"button\" href=\"#\" onclick=\"history.back(); return false;\">Continue as Test User</a>"
        }
        return page(title: "Simulated sign-in / external page — nothing is sent",
                    body: "<p>The application opened <code>\(escape(host))</code>. MarkView UI Studio is a mock-up: it does not contact that "
                        + "site, and this page stands in for it.</p>\n" + action)
    }

    /// A Studio page in the style of the simulated external page (also used to say why a navigation stopped).
    static func page(title: String, body: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; --bg: #f5f6f8; --card: #ffffff; --text: #1c2027; --dim: #5a6270; --accent: #2f6fde; --line: #dde1e8; }
        @media (prefers-color-scheme: dark) { :root { --bg: #17191d; --card: #22252b; --text: #e7e9ed; --dim: #a1a8b4; --accent: #5b93ff; --line: #353943; } }
        body { margin: 0; min-height: 100vh; box-sizing: border-box; padding: 16px; display: flex; align-items: center; justify-content: center;
               background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
        main { width: 100%; max-width: 460px; background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 28px; }
        .badge { font-size: 12px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--dim); }
        h1 { font-size: 20px; line-height: 1.3; margin: 6px 0 14px; }
        p { margin: 0 0 12px; color: var(--dim); }
        code { font: 13px ui-monospace, Menlo, monospace; color: var(--text); word-break: break-all; }
        .button { display: inline-block; margin-top: 6px; padding: 10px 18px; border-radius: 8px; background: var(--accent); color: #fff;
                  font-weight: 600; text-decoration: none; }
        </style></head>
        <body><main>
        <div class="badge">MarkView UI Studio · mock-up</div>
        <h1>\(escape(title))</h1>
        \(body)
        </main></body></html>
        """
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}

/// A session's navigations that leave the application (REQ-010).
struct StudioSimulatedNavigation {
    /// The simulated page being loaded, which the navigation policy allows once.
    var pending: URL?
    /// The page runtime is out while a simulated page is shown.
    var runtimePaused = false
    /// Bumped by every navigation that is followed, so an older one's late answer is dropped.
    var serial = 0
    /// The last navigation the policy cancelled to answer it: its "frame load interrupted" is no failure.
    var cancelled: URL?

    static func samePage(_ a: URL, _ b: URL) -> Bool {
        func path(_ url: URL) -> String { url.path.isEmpty ? "/" : url.path }
        return StudioBridge.Origin(url: a) == StudioBridge.Origin(url: b) && path(a) == path(b)
    }
}
