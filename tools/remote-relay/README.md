# MarkView remote relay

This service joins the outgoing HTTPS connections of a home MarkView and a work MarkView.
It requires Node 22 or later and no npm packages. No extra client, VPN, inbound port or
SSH connection is required on the work computer. The public endpoint must be HTTPS;
plain HTTP is accepted by MarkView only for a loopback development endpoint.

The relay stores bounded encrypted mailboxes. It never receives the shared encryption
key, provider credentials, file paths or plaintext terminal/file contents. Standalone
and Worker deployments keep mailboxes in memory; Vercel uses atomic shared Redis state.
Invitations expire after eight hours. Restarting an in-memory deployment revokes them;
Vercel function cold starts retain the Redis mailboxes and deduplication records.
Do not enable request-body or Authorization-header logging in a reverse proxy.

## Managed hosting with Vercel

Deploy `tools/remote-relay` as a Vercel project with no frontend framework. `vercel.json`
routes the protocol to `api/relay.js`, a Node 22 Function. The function requires a shared
Upstash-compatible Redis store; never deploy the in-memory Node server as a substitute.
Use the project's existing Redis integration or provision one through Vercel Marketplace.

For a new project, the CLI can provision a dedicated free Redis resource and connect it
only to production. Complete any Marketplace terms prompt in the account before retrying:

```sh
vercel link --yes --project markview-remote-relay --cwd tools/remote-relay
vercel integration add upstash/upstash-kv --name markview-remote-relay --plan free \
  --metadata primaryRegion=iad1 --metadata autoUpgrade=false --metadata eviction=false \
  --metadata prodPack=false --environment production --no-env-pull --cwd tools/remote-relay
```

Configure server-side environment variables:

- `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`, or the Marketplace-provided
  `KV_REST_API_URL` and `KV_REST_API_TOKEN`.
- `REGISTRATION_TOKEN`: a private random access key, also entered in MarkView's home
  **Relay access key** field. It is not included in the work-computer pairing code.

After linking the Vercel project and configuring its environment:

```sh
vercel deploy --prod --cwd tools/remote-relay
```

Use its production HTTPS `vercel.app` URL in MarkView. Keep deployment protection
compatible with non-browser authenticated clients; the protocol authenticates both
endpoints and encrypts application messages. Do not remove account-wide protections.
Health checks fail with 503 when configuration or Redis is unavailable.

Atomic Redis scripts authenticate and deduplicate each operation, retain delivery IDs
through acknowledgement, and expire the entire room. Redis Pub/Sub wakes HTTP long polls
without continuous store polling. The app fragments large tool results below 2 MB of
ciphertext per frame to fit Vercel's request limits while preserving complete results.

## Managed hosting with Cloudflare Workers

`worker.mjs` adapts the same relay handler to a Cloudflare Durable Object per invitation.
The included `wrangler.jsonc` uses SQLite-backed namespaces, which are supported on the
[Workers Free plan](https://developers.cloudflare.com/durable-objects/platform/pricing/).
The platform supplies the HTTPS `workers.dev` address; no VPS or custom domain is required.
Normal activity is subject to the platform's request and compute limits.

With Wrangler installed and authenticated to the account that should own the relay:

```sh
wrangler secret put REGISTRATION_TOKEN --config tools/remote-relay/wrangler.jsonc
wrangler deploy --config tools/remote-relay/wrangler.jsonc
```

Choose a private random access key for `REGISTRATION_TOKEN` and enter it in MarkView's
**Allow This Mac > Relay access key**. This secret authorizes creating invitations; it is
not included in the work-computer pairing code. The Worker rejects registration until the
secret is set. Do not commit the key or print it in deployment logs.

Use the HTTPS URL printed by the deployment in MarkView on the home Mac. The work Mac
connects through the pairing code. A relay restart/object eviction revokes its in-memory
invitations; create another code to reconnect. Application-level messages remain encrypted.

Local packaging can be checked without deploying or authenticating:

```sh
wrangler deploy --dry-run --config tools/remote-relay/wrangler.jsonc --outdir /tmp/markview-relay-worker
```

## Self-hosting with a DNS hostname

Point the hostname at your server. From this directory, with Docker Compose installed:

```sh
RELAY_HOST=relay.example.com REGISTRATION_TOKEN='<private random key>' docker compose up -d --build
```

Caddy obtains and renews the certificate. Ports 80 and 443 must be reachable on the
relay server. The relay's internal port is not published. Both Macs connect only to
`https://relay.example.com` on port 443. Configure the reverse proxy to allow requests
of at least 6 MB and response times of at least 40 seconds; disable caching and response
buffering. This transport uses ordinary JSON GET/POST requests, not WebSockets.

Alternatively, run `node server.mjs` behind an existing HTTPS reverse proxy. The default
listener is `127.0.0.1:8787`; `HOST` and `PORT` override it. `TLS_CERT` and `TLS_KEY` enable
direct HTTPS with PEM certificate and key files. `GET /healthz` returns protocol version 1.

## Connect the apps

1. On the home Mac, install and sign in to Claude Code or Codex using its normal login.
2. In MarkView's DDE Settings, choose **Remote Assistants > Connections > Allow This Mac**.
3. Enter the relay's HTTPS URL and access key, choose **Allow Connection**, then **Copy Connection Code**.
4. On the work Mac, open the folder to work in. In the terminal's plus menu, choose
   **Connect to Home…**, paste the code, choose Claude Code or Codex, then **Connect**.
5. Keep both Macs awake and both apps running. **Stop Hosting** revokes access.

Each invitation binds one work-computer terminal. Create a new invitation for another
terminal or reconnection. The home CLI stores its conversation in a stable per-workspace
transport directory, so **Continue the last home conversation for this folder** can
resume it. That directory contains connection configuration, not a synchronized copy of
the work project. The workspace root, file tools, Git and command sessions are on the
work Mac. Commands run with the local user's normal permissions.

Current implementation is under verification. Live two-Mac/provider acceptance, a
published relay, and the repository's merged-release workflow remain required before
this feature is complete. Use the acceptance record in `tasks/todo.md` for current evidence.

## Verify

```sh
node --test tools/remote-relay/*.test.mjs     # from repository root
bash tools/tests/remote-workspace-tests.sh   # macOS; includes a real Unix bridge
```

The `durable-relay` CI job also supplies an isolated Redis service and runs the production
Lua scripts with `REDIS_TEST_PORT` set. Without that explicit test-service port, native
Redis integration checks are reported as skipped, never run against a developer's DB.

An opt-in live check uses the installed home CLIs and their existing logins against a
published relay, with separate generated work/home folders. It verifies file reads,
creation, exact edits, Git, home-file isolation and conversation continuation:

```sh
bash tools/tests/remote-workspace-live.sh https://your-relay.vercel.app \
  /path/to/private-access-key /path/to/MarkView.app both
```

Use `claude` or `codex` instead of `both` to select one provider. The private relay key is
read from its file and never printed or passed to a provider. Test conversations use the
normal provider allowance and history. Fixtures and diagnostic logs stay in the printed
temporary folder; production work folders are never selected by this check.

For a sandbox that forbids binding Unix listeners, pass `--core-only` to the Swift
check. This runs file, command, encryption, deduplication and configuration checks,
but is explicitly not evidence of a working socket bridge or two-Mac connection.
