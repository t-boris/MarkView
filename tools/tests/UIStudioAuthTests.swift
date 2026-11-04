// Checks the sign-in mock-up of UI Studio (REQ-010, MarkView/Models/UIStudioAuthMock.swift): the built-in Supabase Auth
// (answer shapes, any input passes, signed test JWTs, refresh, the OAuth redirect), `{{studio.*}}` placeholders in fixed
// answers, the redirect parameter of an external page and the project detection. Called by UIStudioTests.swift.
import CryptoKit
import Foundation

/// Whether `token` is an HS256 JWT signed with the test key, as a server holding the test secret verifies it.
func verifiesWithTestKey(_ token: String) -> Bool {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return false }
    let mac = HMAC<SHA256>.authenticationCode(for: Data("\(parts[0]).\(parts[1])".utf8), using: SymmetricKey(data: Data(StudioTestJWT.key.utf8)))
    let signature = Data(mac).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return signature == parts[2]
}

func authMockChecks() {
    let app = "http://localhost:3000"
    let connections = [
        StudioServerConnection(variable: "SUPABASE_INTERNAL_URL", origin: "http://kong:8000", basePath: "", mode: .simulated, foundIn: ".env"),
        StudioServerConnection(variable: "NEXT_PUBLIC_SUPABASE_URL", origin: "http://supabase.example.test", basePath: "", mode: .simulated, foundIn: ".env"),
        StudioServerConnection(variable: "API_URL", origin: "http://api.example.test", basePath: "/v1", mode: .simulated, foundIn: ".env"),
    ]
    let mock = StudioAuthMock(connections: connections)
    check("REQ-010 the mock answers every simulated Supabase address, the public one first",
          mock.bases == ["http://supabase.example.test/auth/v1", "http://kong:8000/auth/v1"] && mock.issuer == "http://supabase.example.test/auth/v1",
          "\(mock.bases)")

    let scenario = StudioScenario(id: "signed-in", name: "Signed in", kind: .populated)
    let testTime = scenario.testTime.timeIntervalSince1970
    var sim = StudioSimulator(spec: StudioEnvironmentSpec(), scenario: scenario, appOrigin: app)
    sim.authMock = mock
    var counter = 0
    func send(_ method: String, _ url: String, body: StudioJSON? = nil, headers: [String: String] = [:]) -> (StudioSimOutcome, StudioSimResponse?, StudioJSON?) {
        counter += 1
        let outcome = sim.handle(StudioHTTPRequest(method: method, url: URL(string: url)!, headers: headers, body: body?.text, requestId: "auth\(counter)"))
        guard case .respond(let response, _) = outcome else { return (outcome, nil, nil) }
        return (outcome, response, response.body.flatMap { StudioJSON(text: $0) })
    }
    let base = "http://supabase.example.test/auth/v1"

    // Sign-in with any input.
    let (signIn, signInResponse, session) = send("POST", base + "/token?grant_type=password",
                                                 body: .object(["email": .string("anyone@example.test"), "password": .string("wrong")]))
    let token = session?["access_token"]?.stringValue ?? ""
    let claims = StudioTestJWT.claims(of: token) ?? [:]
    check("REQ-010 a password sign-in with any e-mail and password signs in the scenario's test user",
          signInResponse?.status == 200 && session?["token_type"]?.stringValue == "bearer"
          && session?["user"]?["email"]?.stringValue == "tester@example.test" && session?["user"]?["id"]?.stringValue == "user-1"
          && session?["refresh_token"]?.stringValue == StudioAuthMock.refreshToken, "\(signInResponse?.body ?? "nil")")
    if case .respond(_, let rule) = signIn { check("REQ-010 the answer names the built-in mock-up", rule == StudioAuthMock.ruleID, rule) }
    check("REQ-010 the session is valid for a year from the test time", session?["expires_at"]?.identityKey == String(Int(testTime + 365 * 24 * 3600))
          && session?["expires_in"]?.identityKey == String(365 * 24 * 3600), "\(String(describing: session?["expires_at"]))")
    check("REQ-010 the access token is a JWT signed with the test key", verifiesWithTestKey(token), token)
    check("REQ-010 the access token carries Supabase's claims and the scenario's role in app_metadata",
          claims["sub"]?.stringValue == "user-1" && claims["role"]?.stringValue == "authenticated" && claims["aud"]?.stringValue == "authenticated"
          && claims["email"]?.stringValue == "tester@example.test" && claims["app_metadata"]?["role"]?.stringValue == "member"
          && claims["iss"]?.stringValue == base && claims["exp"]?.identityKey == String(Int(testTime + 365 * 24 * 3600)),
          "\(claims)")
    let (_, emptyResponse, emptySession) = send("POST", "http://kong:8000/auth/v1/token?grant_type=password",
                                                body: .object(["email": .string(""), "password": .string("")]))
    check("REQ-010 an empty form signs in too, at the server's own address, with the same token",
          emptyResponse?.status == 200 && emptySession?["access_token"]?.stringValue == token)
    let (_, refreshed, refreshSession) = send("POST", base + "/token?grant_type=refresh_token", body: .object(["refresh_token": .string("anything")]))
    check("REQ-010 a refresh with any refresh token gives the session again", refreshed?.status == 200
          && refreshSession?["access_token"]?.stringValue == token && refreshSession?["refresh_token"]?.stringValue == StudioAuthMock.refreshToken)
    let (_, exchanged, exchangedSession) = send("POST", base + "/token?grant_type=pkce",
                                                body: .object(["auth_code": .string("whatever"), "code_verifier": .string("v")]))
    check("REQ-010 an OAuth code exchange (PKCE) gives the session", exchanged?.status == 200 && exchangedSession?["user"]?["id"]?.stringValue == "user-1")
    let (_, idToken, _) = send("POST", base + "/token?grant_type=id_token", body: .object(["provider": .string("apple"), "id_token": .string("x")]))
    check("REQ-010 an ID-token sign-in passes", idToken?.status == 200)

    // The current user.
    let (_, noBearer, _) = send("GET", base + "/user")
    let anonKey = StudioConnections.testValue(for: "SUPABASE_ANON_KEY", real: StudioTestJWT.make(["role": .string("anon")]))
    let (_, anon, _) = send("GET", base + "/user", headers: ["authorization": "Bearer " + anonKey])
    let (_, signedIn, user) = send("GET", base + "/user", headers: ["authorization": "Bearer " + token])
    check("REQ-010 GET /user: 401 without a token, 403 with the API key, the user with the session's token",
          noBearer?.status == 401 && anon?.status == 403 && signedIn?.status == 200 && user?["email"]?.stringValue == "tester@example.test"
          && user?["aud"]?.stringValue == "authenticated" && user?["identities"]?.arrayValue?.count == 1,
          "\(noBearer?.status ?? 0) \(anon?.status ?? 0) \(signedIn?.status ?? 0)")

    // Sign-up data and profile changes last until Reset.
    let (_, signedUp, signUpSession) = send("POST", base + "/signup", body: .object(["email": .string("new@example.test"), "password": .string("x"),
                                                                                    "data": .object(["first_name": .string("Ann")])]))
    check("REQ-010 a sign-up is confirmed at once and keeps its data", signedUp?.status == 200
          && signUpSession?["access_token"]?.stringValue?.isEmpty == false
          && signUpSession?["user"]?["user_metadata"]?["first_name"]?.stringValue == "Ann")
    let (_, updated, updatedUser) = send("PUT", base + "/user", body: .object(["data": .object(["city": .string("Oslo")]), "password": .string("new")]),
                                         headers: ["authorization": "Bearer " + token])
    let (_, _, reread) = send("GET", base + "/user", headers: ["authorization": "Bearer " + token])
    check("REQ-010 PUT /user merges into the test user", updated?.status == 200 && updatedUser?["user_metadata"]?["city"]?.stringValue == "Oslo"
          && reread?["user_metadata"]?["first_name"]?.stringValue == "Ann" && reread?["user_metadata"]?["city"]?.stringValue == "Oslo")
    sim.reset()
    let (_, _, afterReset) = send("GET", base + "/user", headers: ["authorization": "Bearer " + token])
    check("REQ-010 Reset brings back the scenario's user", afterReset?["user_metadata"]?["first_name"] == nil
          && afterReset?["user_metadata"]?["full_name"]?.stringValue == "Test User")

    // Everything else of a sign-in flow.
    let (_, logout, _) = send("POST", base + "/logout?scope=global", headers: ["authorization": "Bearer " + token])
    check("REQ-010 sign-out answers 204", logout?.status == 204 && logout?.body == nil)
    let others = ["/otp", "/recover", "/magiclink", "/resend"].map { send("POST", base + $0, body: .object(["email": .string("a@b.test")])).1 }
    check("REQ-010 one-time codes, password reset, magic links and resends succeed",
          others.allSatisfy { $0?.status == 200 && $0?.body == "{}" }, "\(others.map { $0?.status ?? 0 })")
    let (_, settings, settingsBody) = send("GET", base + "/settings")
    check("REQ-010 the settings enable every provider and sign-up", settings?.status == 200
          && settingsBody?["external"]?["google"] == .bool(true) && settingsBody?["external"]?["email"] == .bool(true)
          && settingsBody?["disable_signup"] == .bool(false) && settingsBody?["mailer_autoconfirm"] == .bool(true))
    let (_, jwks, jwksBody) = send("GET", base + "/.well-known/jwks.json")
    check("REQ-010 the JWKS is empty: the HS256 tokens are checked through GET /user", jwks?.status == 200 && jwksBody?["keys"]?.arrayValue?.isEmpty == true)

    // OAuth: no provider is asked.
    let callback = app + "/auth/callback?next=%2Fdashboard"
    let encoded = callback.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let (_, authorize, _) = send("GET", base + "/authorize?provider=google&redirect_to=\(encoded)&code_challenge=abc&code_challenge_method=s256")
    check("REQ-010 /authorize redirects back to redirect_to with the test code", authorize?.status == 302
          && authorize?.headers["location"] == callback + "&code=" + StudioAuthMock.code, authorize?.headers["location"] ?? "no location")
    let (_, implicit, _) = send("GET", base + "/authorize?provider=github&redirect_to=\(encoded)")
    let fragment = implicit?.headers["location"].flatMap { URL(string: $0)?.fragment } ?? ""
    check("REQ-010 the implicit flow gets the tokens in the fragment", implicit?.status == 302 && fragment.contains("access_token=" + token)
          && fragment.contains("refresh_token=" + StudioAuthMock.refreshToken), fragment)
    let (_, bare, _) = send("GET", base + "/authorize?provider=google&code_challenge=abc")
    check("REQ-010 /authorize without redirect_to returns to the application", bare?.headers["location"] == app + "/?code=" + StudioAuthMock.code,
          bare?.headers["location"] ?? "none")
    let (_, verify, _) = send("GET", base + "/verify?token=pkce_abc&type=signup&redirect_to=\(encoded)")
    check("REQ-010 an e-mail confirmation link returns to the application with a code", verify?.status == 303
          && verify?.headers["location"] == callback + "&code=" + StudioAuthMock.code, verify?.headers["location"] ?? "none")

    // What the mock does not answer.
    let (admin, _, _) = send("GET", base + "/admin/users")
    if case .unknown = admin {} else { check("REQ-010 an endpoint the mock does not know goes to the rules", false, "\(admin)") }
    let (other, _, _) = send("GET", app + "/api/me")
    if case .unknown = other {} else { check("REQ-010 the application's own requests go to the rules", false, "\(other)") }
    let (_, hosted, _) = send("GET", "https://abcdefgh.supabase.co/auth/v1/user", headers: ["authorization": "Bearer " + token])
    check("REQ-010 hosted Supabase is answered too", hosted?.status == 200)
    var keptReal = connections
    keptReal.append(StudioServerConnection(variable: "SUPABASE_URL", origin: "https://abcdefgh.supabase.co", basePath: "", mode: .real, foundIn: ".env"))
    sim.authMock = StudioAuthMock(connections: keptReal)
    let (real, _, _) = send("GET", "https://abcdefgh.supabase.co/auth/v1/user")
    if case .unknown = real {} else { check("REQ-010 a Supabase address the person keeps real is not answered", false, "\(real)") }
    sim.authMock = nil
    let (off, _, _) = send("POST", base + "/token?grant_type=password")
    if case .unknown = off {} else { check("REQ-010 without the mock (no Supabase in the project) the request goes to the rules", false, "\(off)") }

    // Placeholders in fixed answers.
    var spec = StudioEnvironmentSpec()
    let fixed: StudioJSON = .object([
        "token": .string("{{studio.token}}"), "refresh": .string("{{ studio.refreshToken }}"), "user": .string("{{studio.user}}"),
        "email": .string("{{studio.user.email}}"), "greeting": .string("Hi {{studio.user.name}}, it is {{studio.now}}"),
        "expires": .string("{{studio.expiresAtSeconds}}"), "expiresAt": .string("{{studio.expiresAt}}"), "missing": .string("{{studio.user.nope}}"),
        "unknown": .string("{{studio.nope}}"), "list": .array([.string("{{studio.user.id}}")]),
    ])
    spec.rules = [
        StudioRule(id: "login", method: "POST", path: "/api/login", operation: .respond,
                   response: StudioFixedResponse(status: 200, body: fixed, headers: ["X-Token": "Bearer {{studio.token}}"])),
        StudioRule(id: "items", method: "GET", path: "/api/items", operation: .list, entity: "items"),
    ]
    spec.seed = ["items": [.object(["id": .number(1), "name": .string("{{studio.token}}")])]]
    var placeholders = StudioSimulator(spec: spec, scenario: scenario, appOrigin: app)
    placeholders.authMock = mock
    guard case .respond(let login, _) = placeholders.handle(StudioHTTPRequest(method: "POST", url: URL(string: app + "/api/login")!, headers: [:],
                                                                                body: "{}", requestId: "p1")),
          let answer = login.body.flatMap({ StudioJSON(text: $0) }) else {
        return check("REQ-010 a fixed answer with placeholders is answered", false)
    }
    check("REQ-010 {{studio.token}} is the token the built-in Supabase Auth issues", answer["token"]?.stringValue == token
          && login.headers["x-token"] == "Bearer " + token, "\(answer)")
    check("REQ-010 {{studio.user}} is the scenario's user, {{studio.user.<field>}} one of its fields",
          answer["user"]?["name"]?.stringValue == "Test User" && answer["email"]?.stringValue == "tester@example.test"
          && answer["list"]?.arrayValue?.first?.stringValue == "user-1" && answer["missing"] == .null)
    check("REQ-010 times are the test time and a year after it", answer["greeting"]?.stringValue == "Hi Test User, it is 2026-01-15T12:00:00Z"
          && answer["expiresAt"]?.stringValue == "2027-01-15T12:00:00Z" && answer["expires"]?.identityKey == String(Int(testTime + 365 * 24 * 3600))
          && answer["refresh"]?.stringValue == StudioAuthMock.refreshToken, "\(answer)")
    check("REQ-010 an unknown placeholder is left as it is", answer["unknown"]?.stringValue == "{{studio.nope}}")
    guard case .respond(let items, _) = placeholders.handle(StudioHTTPRequest(method: "GET", url: URL(string: app + "/api/items")!, headers: [:],
                                                                                body: nil, requestId: "p2")) else {
        return check("REQ-010 records are answered", false)
    }
    check("REQ-010 records keep their own text: placeholders are for fixed answers", items.body?.contains("{{studio.token}}") == true, items.body ?? "nil")
    check("REQ-010 the preparation prompt names the placeholders", StudioPrompts.preparationSystem.contains("{{studio.user.<field>}}")
          && StudioPrompts.preparationSystem.contains("{{studio.token}}") && StudioPrompts.preparationSystem.contains("add no rules for it"))
    check("REQ-010 a placeholder in text that is not JSON is replaced too",
          StudioPlaceholders.substitute(text: "token={{studio.token}}&u={{studio.user.id}}", placeholders.placeholderValues) == "token=\(token)&u=user-1")

    // The external page returns where the request says.
    func returnURL(_ text: String) -> String? { StudioExternalPage.returnURL(for: URL(string: text)!, appOrigin: app)?.absoluteString }
    check("REQ-010 an OAuth request returns to redirect_uri with a code and its state",
          returnURL("https://accounts.google.com/o/oauth2/v2/auth?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fapi%2Fauth%2Fcallback%2Fgoogle"
                    + "&response_type=code&scope=openid%20email&state=s%20t%26u")
          == "http://localhost:3000/api/auth/callback/google?code=markview-test-code&state=s%20t%26u",
          returnURL("https://accounts.google.com/o/oauth2/v2/auth?redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fcb&response_type=code&state=s%20t%26u") ?? "nil")
    check("REQ-010 the parameters are looked for in order", returnURL("https://idp.example/login?next=%2Fa&redirect_to=http%3A%2F%2Flocalhost%3A3000%2Fb")
          == "http://localhost:3000/b")
    check("REQ-010 a checkout returns to success_url as it is", returnURL("https://checkout.stripe.com/pay?success_url=http%3A%2F%2Flocalhost%3A3000%2Fthanks%3Fsession%3D1")
          == "http://localhost:3000/thanks?session=1")
    check("REQ-010 a path is the application's", returnURL("https://idp.example/login?returnTo=%2Fdashboard%3Ftab%3D2") == "http://localhost:3000/dashboard?tab=2"
          && returnURL("https://idp.example/login?callbackUrl=http%3A%2F%2Flocalhost%3A3000%2Fhome&response_type=code") == "http://localhost:3000/home?code=markview-test-code")
    check("REQ-010 no return address, or one that is not a web address, goes back",
          returnURL("https://idp.example/login") == nil && returnURL("https://idp.example/login?next=%2F%2Fevil.example") == nil
          && returnURL("https://idp.example/login?redirect_uri=javascript%3Aalert(1)") == nil && returnURL("https://idp.example/login?next=") == nil)
    let page = StudioExternalPage.html(for: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                                       returnTo: URL(string: "http://localhost:3000/cb?code=markview-test-code&state=a\"b"),
                                       user: .object(["email": .string("<b>tester</b>@example.test")]))
    check("REQ-010 the external page says nothing is sent and offers Continue as Test User",
          page.contains("Simulated sign-in / external page — nothing is sent") && page.contains(">Continue as Test User</a>")
          && page.contains("accounts.google.com") && page.contains("href=\"http://localhost:3000/cb?code=markview-test-code&amp;state=a%22b\""), page)
    check("REQ-010 the external page escapes what it shows", page.contains("&lt;b&gt;tester&lt;/b&gt;@example.test") && !page.contains("<b>tester"))
    check("REQ-010 without a return address Continue goes back", StudioExternalPage.html(for: URL(string: "https://example.org/pay")!, returnTo: nil,
                                                                                         user: .object([:])).contains("history.back()"))

    // Which projects get the mock, and the signing secret.
    let projects = tmp.appendingPathComponent("auth-projects")
    func write(_ path: String, _ json: [String: Any]) {
        let url = projects.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: json).write(to: url)
    }
    write("direct/package.json", ["dependencies": ["@supabase/ssr": "0.8.0", "next": "15.0.0"]])
    write("plain/package.json", ["dependencies": ["next": "15.0.0"]])
    write("mono/apps/web/package.json", ["dependencies": ["@acme/auth": "workspace:*"]])
    write("mono/packages/auth/package.json", ["name": "@acme/auth", "dependencies": ["@supabase/supabase-js": "2.99.3"]])
    check("REQ-010 a project that depends on @supabase/ is a Supabase project, directly or through a workspace package",
          StudioAuthMock.usesSupabase(appFolder: projects.appendingPathComponent("direct"), root: projects.appendingPathComponent("direct"))
          && !StudioAuthMock.usesSupabase(appFolder: projects.appendingPathComponent("plain"), root: projects.appendingPathComponent("plain"))
          && StudioAuthMock.usesSupabase(appFolder: projects.appendingPathComponent("mono/apps/web"), root: projects.appendingPathComponent("mono")))
    check("REQ-010 a JWT signing secret's test value is the test key, so a server verifies the mock's tokens",
          StudioConnections.testValue(for: "SUPABASE_JWT_SECRET", real: "a-real-secret") == StudioTestJWT.key
          && StudioConnections.testValue(for: "JWT_SECRET", real: nil) == StudioTestJWT.key
          && StudioConnections.testValue(for: "API_SECRET", real: "x") == "markview-test-api-secret")
}
