// REQ-010 in a real session (called by UIStudioSessionHarness.swift): sign-in always passes in the mock-up. The fixture is
// a Supabase project (package.json depends on @supabase/ssr) whose server protects /account the way an @supabase/ssr
// middleware does. It reads the `sb-api-auth-token` cookie ("base64-" + base64url of the session JSON, in chunks when
// long), asks GET /auth/v1/user with the access token, and also verifies the token itself with the project's JWT secret.
// Without a session it redirects to the sign-in page. The page signs in with a password, through OAuth (a simulated
// /authorize and the app's callback exchanging the code on the server), and through an external provider's page.
import AppKit
import WebKit

let authServer = #"""
import base64, hashlib, hmac, json, os, sys, urllib.error, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
for line in open('.env.local'):
    line = line.strip()
    if line and not line.startswith('#') and '=' in line:
        key, value = line.split('=', 1)
        os.environ.setdefault(key.strip(), value.strip())
SUPABASE = os.environ.get('NEXT_PUBLIC_SUPABASE_URL', '').rstrip('/')
ANON = os.environ.get('NEXT_PUBLIC_SUPABASE_ANON_KEY', '')
SECRET = os.environ.get('SUPABASE_JWT_SECRET', '')
COOKIE = 'sb-api-auth-token'
CHUNK = 3180

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

def unb64url(text):
    return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4))

def cookies_of(header):
    found = {}
    for part in (header or '').split(';'):
        if '=' in part:
            name, value = part.strip().split('=', 1)
            found[name] = value
    return found

def session_from(cookies):
    # @supabase/ssr keeps the session in one cookie or in chunks NAME.0, NAME.1...
    raw = cookies.get(COOKIE)
    chunks = 1
    if raw is None:
        parts = []
        while '%s.%d' % (COOKIE, len(parts)) in cookies:
            parts.append(cookies['%s.%d' % (COOKIE, len(parts))])
        raw, chunks = ''.join(parts), len(parts)
    if not raw.startswith('base64-'):
        return None, 0
    try:
        return json.loads(unb64url(raw[len('base64-'):])), chunks
    except Exception:
        return None, 0

def session_cookies(session):
    value = 'base64-' + b64url(json.dumps(session).encode())
    if len(value) <= CHUNK:
        return ['%s=%s; Path=/; SameSite=Lax' % (COOKIE, value)]
    count = (len(value) + CHUNK - 1) // CHUNK
    return ['%s.%d=%s; Path=/; SameSite=Lax' % (COOKIE, i, value[i * CHUNK:(i + 1) * CHUNK]) for i in range(count)]

def verified(token):
    parts = token.split('.')
    if len(parts) != 3 or not SECRET:
        return False
    mac = hmac.new(SECRET.encode(), (parts[0] + '.' + parts[1]).encode(), hashlib.sha256).digest()
    return hmac.compare_digest(b64url(mac), parts[2])

def supabase(method, path, token=None, body=None):
    headers = {'apikey': ANON, 'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(SUPABASE + '/auth/v1' + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=5) as answer:
            return answer.status, json.loads(answer.read() or b'null')
    except urllib.error.HTTPError as error:
        return error.code, None
    except Exception:
        return 0, None

LOGIN = '''<!doctype html><html><head><title>Sign in</title></head><body><p id="login">Sign in</p>
<button id="password" onclick="signIn()">Sign in</button> <button id="google" onclick="google()">Google</button>
<button id="external" onclick="external()">Example IdP</button>
<script>
const SUPABASE = %s, KEY = %s, COOKIE = 'sb-api-auth-token';
const next = new URLSearchParams(location.search).get('redirect') || '/account';
function b64url(text) { return btoa(unescape(encodeURIComponent(text))).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, ''); }
function store(session) {
  const value = 'base64-' + b64url(JSON.stringify(session)), size = 3180;
  if (value.length <= size) { document.cookie = COOKIE + '=' + value + '; path=/'; return; }
  for (let i = 0; i * size < value.length; i++) document.cookie = COOKIE + '.' + i + '=' + value.slice(i * size, (i + 1) * size) + '; path=/';
}
async function signIn() {
  const answer = await fetch(SUPABASE + '/auth/v1/token?grant_type=password', { method: 'POST',
    headers: { 'content-type': 'application/json', apikey: KEY }, body: JSON.stringify({ email: 'nobody@nowhere.test', password: 'not-it' }) });
  if (answer.status !== 200) { document.getElementById('login').textContent = 'Refused ' + answer.status; return; }
  store(await answer.json());
  location.href = next;
}
function google() {
  document.cookie = COOKIE + '-code-verifier=fixture-verifier; path=/';
  const back = location.origin + '/auth/callback?redirect=' + encodeURIComponent(next);
  location.href = SUPABASE + '/auth/v1/authorize?provider=google&redirect_to=' + encodeURIComponent(back)
    + '&code_challenge=fixture-challenge&code_challenge_method=s256';
}
function external() {
  location.href = 'https://accounts.idp.example/authorize?response_type=code&client_id=fixture&state=st-42&redirect_uri='
    + encodeURIComponent(location.origin + '/oauth/callback');
}
</script></body></html>'''

class Handler(BaseHTTPRequestHandler):
    def send(self, status, body=b'', location=None, cookies=()):
        self.send_response(status)
        if location:
            self.send_header('Location', location)
        for cookie in cookies:
            self.send_header('Set-Cookie', cookie)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = dict(urllib.parse.parse_qsl(url.query))
        cookies = cookies_of(self.headers.get('Cookie'))
        if url.path == '/account':
            # The middleware: no session, or one the auth server does not know, goes to the sign-in page.
            session, chunks = session_from(cookies)
            token = (session or {}).get('access_token', '')
            status, user = supabase('GET', '/user', token) if token else (0, None)
            if status != 200 or not user:
                return self.send(307, location='/auth/login?redirect=/account')
            role = (user.get('app_metadata') or {}).get('role', '')
            body = '<!doctype html><title>Account</title><p id="email">%s</p><p id="verified">%s</p><p id="role">%s</p><p id="chunks">%d</p>' % (
                user.get('email', ''), verified(token), role, chunks)
            return self.send(200, body.encode())
        if url.path == '/auth/login':
            return self.send(200, (LOGIN % (json.dumps(SUPABASE), json.dumps(ANON))).encode())
        if url.path == '/auth/server-oauth':
            # A server action's signInWithOAuth: the verifier cookie, then a redirect to /authorize.
            back = 'http://%s/auth/callback?redirect=/account' % self.headers.get('Host')
            target = SUPABASE + '/auth/v1/authorize?provider=github&code_challenge=c&code_challenge_method=s256&redirect_to=' + urllib.parse.quote(back, safe='')
            return self.send(307, location=target, cookies=[COOKIE + '-code-verifier=server-verifier; Path=/'])
        if url.path == '/auth/callback':
            verifier = cookies.get(COOKIE + '-code-verifier', '')
            with open('callbacks.log', 'a') as log:
                log.write(json.dumps({'code': query.get('code', ''), 'verifier': verifier}) + '\n')
            status, session = supabase('POST', '/token?grant_type=pkce', body={'auth_code': query.get('code', ''), 'code_verifier': verifier})
            if not verifier or status != 200 or not session:
                return self.send(307, location='/auth/login?error=exchange')
            expired = COOKIE + '-code-verifier=; Path=/; Max-Age=0'
            return self.send(307, location=query.get('redirect', '/account'), cookies=session_cookies(session) + [expired])
        if url.path == '/oauth/callback':
            body = '<!doctype html><title>Callback</title><p id="code">%s</p><p id="state">%s</p>' % (query.get('code', ''), query.get('state', ''))
            return self.send(200, body.encode())
        if url.path == '/signout':
            session, _ = session_from(cookies)
            supabase('POST', '/logout', (session or {}).get('access_token'))
            gone = ['%s=; Path=/; Max-Age=0' % name for name in cookies if name.startswith(COOKIE)]
            return self.send(307, location='/auth/login', cookies=gone)
        self.send(200, b'<!doctype html><title>Home</title><p id="home">Home</p>')
    def log_message(self, *args):
        pass
HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
"""#

/// The fixture's real values in its `.env.local`: they must reach no prompt or log.
let authFixtureAnonKey = "fixture-anon-key-do-not-leak-5523"
let authFixtureJWTSecret = "fixture-jwt-secret-do-not-leak-9031"

@MainActor
func authChecks() async {
    watchdog.reached("Sign-in always passes in the mock-up (REQ-010)")
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-auth-\(UUID().uuidString)").resolvingSymlinksInPath()
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try? authServer.write(to: root.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    try? #"{"name":"auth-fixture","private":true,"dependencies":{"@supabase/ssr":"0.8.0","@supabase/supabase-js":"2.99.3"}}"#
        .write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try? ("NEXT_PUBLIC_SUPABASE_URL=http://supabase.example.test\nNEXT_PUBLIC_SUPABASE_ANON_KEY=\(authFixtureAnonKey)\n"
          + "SUPABASE_JWT_SECRET=\(authFixtureJWTSecret)\n").write(to: root.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    let assistant = Assistant()
    assistant.proposal = ["rules": [], "assumptions": ["Nothing else is needed."]]
    CLICompletion.answer = { request in assistant.respond(request) }
    let promptsBefore = CLICompletion.requests.count
    let port = freePort()
    let session = StudioSession(root: root)
    func value(_ id: String) async -> String {
        ((try? await session.call("const e = document.getElementById(id); return e ? e.textContent : '';", ["id": id])) as? String) ?? ""
    }
    func waitFor(_ id: String) async -> String {
        var found = ""
        for _ in 0..<150 where found.isEmpty {
            found = await value(id)
            if found.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        return found
    }
    func click(_ id: String) async { _ = try? await session.call("document.getElementById(id).click(); return true;", ["id": id]) }
    func go(_ path: String) async {
        let target = URL(string: path, relativeTo: session.appURL)?.absoluteString ?? path
        _ = try? await session.call("location.href = target; return true;", ["target": target])
    }
    func path() -> String { session.webView.url?.path ?? "" }
    func runtime() async -> Bool { ((try? await session.call("return typeof window.__markviewStudio === 'object';")) as? Bool) == true }
    func callbacks() -> [[String: String]] {
        ((try? String(contentsOf: root.appendingPathComponent("callbacks.log"), encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String] }
    }
    func logged(_ text: String) -> Bool { session.sessionLog.entries.contains { $0.kind == .navigation && $0.text.contains(text) } }

    session.start(WebAppTarget(folder: root, label: "auth", command: "python3 server.py \(port)", ports: [port]))
    _ = await waitUntil(90) { [.ready, .degraded, .failed].contains(session.state) && session.busy == nil }
    check("REQ-010 a Supabase project opens with the built-in Supabase Auth in the Environment panel", session.appURL != nil
          && session.dependencies.contains { $0.id == StudioAuthMock.dependencyID && $0.mode == .simulated },
          "\(session.state) \(session.stateDetail) \(session.dependencies.map(\.id))")

    // The protected page sends a signed-out visitor to sign in.
    await go("/account")
    let login = await waitFor("login")
    check("REQ-010 the server's session check sends a signed-out visitor to the sign-in page", login == "Sign in" && path() == "/auth/login",
          "\(login) at \(path())")

    // A password sign-in with made-up credentials.
    await click("password")
    let email = await waitFor("email")
    let refused = await value("login")
    check("REQ-010 any e-mail and password sign in, and the server's check (GET /user) lets the test user in",
          email == "tester@example.test" && path() == "/account", "\(email) at \(path()) · \(refused)")
    check("REQ-010 a server that verifies the access token with its JWT secret accepts it", await value("verified") == "True")
    check("REQ-010 the scenario's role is the user's app_metadata role", await value("role") == "member")
    check("REQ-010 the session cookie is in @supabase/ssr's format", Int(await value("chunks")) ?? 0 >= 1)
    check("REQ-010 the server's own auth requests are simulated", session.requests.contains {
        $0.transport == "server" && $0.contract == "GET http://supabase.example.test/auth/v1/user" && $0.outcome == "simulated" && $0.status == 200
    }, session.requests.map { "\($0.transport) \($0.contract) \($0.outcome)" }.joined(separator: " | "))

    // OAuth: the simulated /authorize returns to the application's callback, whose server exchanges the code.
    await go("/signout")
    _ = await waitFor("login")
    await click("google")
    let oauthEmail = await waitFor("email")
    check("REQ-010 OAuth: the simulated /authorize lands on the app callback with the code, and its exchange signs in",
          oauthEmail == "tester@example.test" && path() == "/account" && callbacks().last == ["code": StudioAuthMock.code, "verifier": "fixture-verifier"],
          "\(oauthEmail) at \(path()) · \(callbacks())")
    check("REQ-010 the navigation to /authorize and its redirect are in the session log",
          logged("/auth/v1/authorize?provider=google") && logged("Simulated redirect 302") && logged("back into the application"),
          session.sessionLog.entries.filter { $0.kind == .navigation }.suffix(6).map(\.text).joined(separator: "\n"))

    // The same from a server redirect (a server action's signInWithOAuth).
    await go("/signout")
    _ = await waitFor("login")
    await go("/auth/server-oauth")
    let serverEmail = await waitFor("email")
    check("REQ-010 a server redirect to /authorize is followed the same way", serverEmail == "tester@example.test"
          && callbacks().last == ["code": StudioAuthMock.code, "verifier": "server-verifier"], "\(serverEmail) at \(path()) · \(callbacks())")
    check("REQ-010 the redirect the session took over is not reported as a page that did not load",
          !session.sessionLog.entries.contains { $0.text.contains("did not load") } && session.notice == nil,
          session.sessionLog.entries.filter { $0.problem }.map(\.text).joined(separator: "\n"))

    // An external provider: a local stand-in page, then back with a code and the state.
    await go("/auth/login")
    _ = await waitFor("login")
    await click("external")
    let proceed = await waitFor("continue")
    let title = ((try? await session.call("return document.title;")) as? String) ?? ""
    check("REQ-010 an external sign-in page is a local stand-in that sends nothing", proceed == "Continue as Test User"
          && session.webView.url?.host == "accounts.idp.example" && title.contains("nothing is sent"), "\(proceed) \(title) \(session.webView.url?.absoluteString ?? "")")
    check("REQ-010 the stand-in page runs without the page runtime", !(await runtime()))
    await click("continue")
    let code = await waitFor("code")
    let state = await value("state")
    check("REQ-010 Continue as Test User returns to redirect_uri with a code and the state", code == StudioAuthMock.code
          && state == "st-42" && path() == "/oauth/callback", "\(code) \(state) at \(path())")
    check("REQ-010 the application's page has the runtime again, and no page message was rejected", await runtime() && session.rejectedMessages == 0,
          "rejected \(session.rejectedMessages)")
    check("REQ-010 the external page is in the session log", logged("leaves the application: a simulated external page is shown"))

    // A navigate step must hit the server, not just change the address in browser history: middleware redirects it.
    await go("/signout")
    _ = await waitFor("login")
    let originalScenario = session.scenario
    var protectedNavigation = originalScenario
    protectedNavigation.route = "/auth/login"
    protectedNavigation.steps = [StudioStep(action: .navigate, text: "/account")]
    protectedNavigation.expectedPath = "/auth/login"
    session.activate(protectedNavigation)
    _ = await waitUntil(60) { session.busy == nil }
    let redirectedLogin = await value("login")
    check("a navigate step follows the server's authentication redirect", path() == "/auth/login" && redirectedLogin == "Sign in",
          "at \(path())")

    let everything = session.sessionLog.entries.map(\.text).joined() + session.requests.map(\.url).joined()
        + CLICompletion.requests.dropFirst(promptsBefore).map(\.prompt).joined() + session.serverLog
    check("REQ-010 the fixture's real key and JWT secret reach no log or prompt", !everything.contains(authFixtureAnonKey)
          && !everything.contains(authFixtureJWTSecret))
    await session.close()
}
