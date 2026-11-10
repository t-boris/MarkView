---
type: bug
id: BUG-119
title: UI Studio cannot connect to unified-partner-portal on localhost:3000
status: done
severity: high
reporter: t-boris
created: 2026-11-09
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Immediately after the failure, does http://localhost:3000/ open in your regular browser?
    why: Distinguishes general server unavailability from a UI Studio-specific connection problem.
    options:
      - label: Loads
        text: The application loads successfully.
      - label: Connection fails
        text: The browser also cannot connect.
      - label: Other error
        text: The server responds, but displays another error.
    status: answered
    answer: Connection fails. The browser also cannot connect.
  - id: BQ-2
    text: Can you share the development-server output and nearby UI Studio log entries from opening the project through this failure, with secrets removed?
    why: Startup commands, listening addresses and exit messages can identify why the selected server was unreachable.
    status: skipped
    answer: The user does not know.
  - id: BQ-3
    text: Which MarkView and macOS versions are you using, and did this happen immediately on opening UI Studio or after a reset or scenario change?
    why: Identifies the affected build and the lifecycle path leading to generation 4.
    status: open
  - id: BQ-4
    text: For this session, did you start the development server yourself before opening UI Studio?
    why: Distinguishes an attached external server from one managed by UI Studio, which determines which startup and exit-handling path to investigate.
    options:
      - label: Started separately
        text: I started the server in a terminal or another tool.
      - label: UI Studio only
        text: I did not start a server separately; I expected UI Studio to start it.
      - label: Unsure
        text: I do not know whether a server was already running.
    status: open
  - id: BQ-5
    text: When you said UI Studio should mimic server calls, did you expect it to start the application's development server automatically, or display the UI without running that server?
    why: This distinguishes an automatic-startup expectation from serverless UI rendering, without assuming that simulated API responses replace the application server.
    options:
      - label: Automatic startup
        text: UI Studio should start the application's development server for me.
      - label: No application server
        text: UI Studio should display the UI without running the application's development server.
      - label: Unsure
        text: I expected simulated API calls but am unsure how the UI itself should be served.
    status: answered
    answer: Settled by the clarifications.
  - id: BQ-6
    text: Where is the unified-partner-portal checkout used in this session, or can you make it available for read-only inspection?
    why: Its launch scripts and dependency configuration can distinguish a startup or simulation-setup failure from incorrect endpoint selection without asking you to diagnose logs.
    status: answered
    answer: Settled by the clarifications.
updated: 2026-11-09
---

# UI Studio cannot connect to unified-partner-portal on localhost:3000

## Summary

Reproduced on origin/main bda0dc6 against unified-partner-portal ad00d623. The application opens localhost:3000 and prints Ready, then its Next.js instrumentation hook rejects missing APP_ENVIRONMENT and the listener disappears. UI Studio prepared simulated service addresses and test secrets but omitted the documented local-development configuration. The fix supplies explicitly documented, referenced local/test selectors and USE_MOCKS=true without copying credentials, service addresses, executable paths, or production settings. Local verification passed; delivery still requires a merged implementation, CI and release evidence.

## Steps to reproduce

1. Open /Users/a806318/Projects/unified-partner-portal in MarkView and open UI Studio.
2. Reach the Populated scenario, generation 4. The preceding actions and launch settings are unknown, so this is a partial reproduction sequence.
3. Observe navigation to http://localhost:3000/ fail with NSURLErrorDomain -1004.
4. Immediately try the same URL in a regular browser; the user reports that connection also fails.

## Expected

UI Studio displays the project's actual UI with simulated backend dependencies, without requiring real backend services. The user reports that this workflow already works for other projects. A generated replacement UI is not requested.

## Actual

The supplied log records loading http://localhost:3000/ at 2026-11-09T16:21:05.666-0600 for Populated, generation 4, followed by provisional navigation failure at 16:21:05.707 with NSURLErrorDomain -1004. The user reports immediate browser connection failure too. This supports an unreachable selected endpoint, not an HTTP error or a demonstrated API-simulation failure.

## Environment

MarkView UI Studio on macOS; unified-partner-portal at /Users/a806318/Projects/unified-partner-portal; localhost:3000; Populated scenario; generation 4. Exact application and macOS versions, project framework and launch settings remain unknown. Read-only inspection confirmed local MarkView source includes real-UI launch and simulated-connection paths. Access to the partner-portal package.json was rejected, preventing project-specific inspection. No runtime reproduction, current-origin/main verification or attached-image inspection was possible; no images were supplied. Severity reflects the reported blocked primary flow for this project, not confirmed data loss, security impact or a wider outage.

## Suspected code

- `MarkView/Models/UIStudioSession.swift` — The local source identifies endpoint reuse, server startup, simulated-connection preparation, owned-process exit handling and page loading as relevant paths. Whether the failing session reused or launched its endpoint remains unknown.
- `MarkView/Models/WebAppPreview.swift` — Endpoint readiness and firstListening selection warrant investigation. The supplied prior inspection describes TCP-only selection without application identity verification; this does not establish that the wrong endpoint was selected.
- `MarkView/Models/UIStudioServer.swift` — Read-only inspection confirms that the managed shell runs in a separate process group and remaining group members are terminated when its leader exits. A project-specific launch command could therefore affect listener lifetime, but no correlated exit evidence is available.
- `MarkView/Models/UIStudioConnections.swift` — Connection discovery and launch overrides are relevant if startup requires backend dependencies. Partner-portal configuration must be inspected before attributing failure to unsupported or undiscovered dependency simulation.
- `MarkView/Models/UIStudioPolicy.swift` — The supplied prior inspection describes intentional permission for the local application runtime and development resources. That boundary must not be interpreted as proof that backend simulation is missing.
- `docs/plans/markview-ui-sudio-tech-reqs.md` — The supplied design context specifies real project UI with simulated dependencies, not an HTML imitation. Draft requirements do not prove current support for this project's framework.

## Likely causes

- Root cause is unconfirmed. The two reported connection failures favor endpoint unavailability over a WebKit-only rendering defect.
- Hypothesis: the UI-serving process stopped or restarted between readiness detection and navigation, possibly because of startup dependencies or launch-command behavior.
- Hypothesis: discovery selected an unrelated listener or reused an endpoint that subsequently disappeared.
- Hypothesis: a server-side dependency required during startup was not redirected to simulation, preventing the UI runtime from remaining available.
- Lower-priority hypothesis: readiness probing and navigation used different loopback addresses or address families.
- The existence of a local UI-serving process does not establish a capability gap. Earlier claims that a new serverless renderer was required are withdrawn.

## Missing information

- Read-only access to the now-identified partner-portal checkout, including its revision, package scripts, framework and dependency configuration. The attempted package.json read was rejected.
- Saved Studio target settings: selected command, working directory, configured ports and endpoint-reuse setting.
- Evidence identifying whether Studio owned or reused the process serving localhost:3000.
- Sanitized startup output and Studio events correlating readiness detection, navigation failure, listener state and process exit or restart. BQ-2 established that the user does not know how to provide these, not that no startup error occurred.
- MarkView/macOS versions and actions leading to generation 4, already requested in BQ-3.
- Whether the user manually started the development server, already requested in BQ-4.
- A reproduction using the relevant project revision and launch settings on current origin/main. The supplied bda0dc6cb1 validity check remains inconclusive; source inspection alone cannot establish persistence or resolution.

## Validity check

**Outcome:** Inconclusive (checked 2026-11-09). The status was not changed.

**Verified against:** `origin/main` @ `bda0dc6cb1` (2026-11-09) — docs: cycle time feature - acceptance criteria ticked for what was verified, in review after release v5.54.0

**Reason:** The snapshot implements launching the real UI with simulated backend connections, but source inspection cannot establish whether partner-portal still loses its localhost:3000 endpoint. TCP-only endpoint selection, process termination and missing dependency redirection remain hypotheses, not confirmed causes. Verification requires the partner-portal revision and launch settings plus runtime evidence correlating readiness, process exit and navigation failure. Requiring a local UI-serving process does not demonstrate the previously claimed capability gap or prove this incident persists.

## Clarifications

**BQ-1** Immediately after the failure, does http://localhost:3000/ open in your regular browser?
→ Connection fails. The browser also cannot connect.

**BQ-2** Can you share the development-server output and nearby UI Studio log entries from opening the project through this failure, with secrets removed?
→ The user does not know.

## Discussion

### t-boris · 2026-11-09

I thought that UI Studio should mimic calls to the server

### AI · 2026-11-09

Yes—UI Studio simulates service/API responses, but it still needs the application's development server to serve the actual UI. Rechecking UIStudioSession.swift confirms both paths: simulated requests go through the simulation handlers, while the initial page loads from the real appURL using WKWebView. BUG-076 also documents why startup checks use TCP rather than repeated page requests. No attached images were available in this report.

Your comment changes my understanding: we need to distinguish your expectation of simulated backend calls from the separate requirement for a running UI server. The localhost:3000 connection failure happens before the page can load; it does not establish that API simulation failed. The cause remains inconclusive, and this is not ready for a fix handoff.

Did you expect UI Studio to start the application's development server automatically, or to display the UI without running that server at all? This distinguishes a possible startup/lifecycle defect from a different product expectation. The bug status remains unchanged; any eventual development handoff requires your confirmation.

### t-boris · 2026-11-09

The goal is to run UI without server at all because we simulate ALL calls

### AI · 2026-11-09

Understood: your goal is UI rendering with no application server, not automatic server startup. That resolves the expectation question and exposes a capability gap rather than establishing the cause of the original connection failure.

Rechecking UIStudioSession.swift confirms that launch() requires a running or newly started development server and loadPage() navigates to its URL. UIStudioPolicy.swift explicitly excludes application assets and framework-rendering requests from simulation. BUG-076 also assumes a running development server. Simulating API responses alone therefore does not currently replace everything needed to render the UI. No attached images were available.

For the first implementation, must UI Studio run the actual application's UI code without a server, or may it generate a simulated UI from the project/specification? The former preserves fidelity but needs a defined strategy for assets and server-rendered components; the latter avoids that runtime dependency but may differ from the actual application.

This scope decision is needed before development handoff. The bug status remains unchanged, and any handoff requires your confirmation.

### t-boris · 2026-11-09

I’m confused, maybe you are unaware about UI Studo but the whole idea was to start the app without any servre side by simulating it and we do it now for many other projects, somehow it doesn’t work for partner portal

### AI · 2026-11-09

You’re right—I misframed this as a request for a new serverless renderer. Your clarification is that an existing UI Studio workflow works for other projects but fails for partner portal, not that you want a generated replacement UI.

Rechecking the code confirms that UI Studio starts the actual application with simulated server-side connections (`prepareServerConnections` and the Node preload). The design document also specifies real project components, not an HTML imitation. The local process serving that UI is distinct from the backend services being simulated; its existence alone does not establish a capability gap. My earlier conclusion was too strong.

The reported -1004 and browser failure establish an unreachable localhost endpoint, but not why it became unreachable. Startup failure, process exit and incorrect endpoint selection remain hypotheses. No attached images were available.

Can you make the partner-portal checkout available for read-only inspection, or identify its location if already accessible? That would let us inspect its launch configuration and dependencies without asking you to diagnose logs. This is not yet ready for a specific fix handoff; the bug status remains unchanged, and any handoff requires your confirmation.

### t-boris · 2026-11-09

The code is in /Users/a806318/Projects/unified-partner-portal

### AI · 2026-11-09

The checkout location is now known, but access to it was denied, so I could not inspect partner-portal’s launch configuration or dependencies. The MarkView code and design draft still support running the actual UI with simulated dependencies—not a generated replacement. No attached images were available.

The cause remains unconfirmed, and persistence on current origin/main has not been verified. Please allow read-only access to /Users/a806318/Projects/unified-partner-portal so we can inspect its startup configuration without asking you to diagnose logs. This is not yet ready for a specific fix handoff; the bug status remains unchanged, and any handoff requires your confirmation.

## Original description

I'm trying to open your eyes studio on for unified – partner – portal application and getting errors So I think that this this is a box errors are below

2026-11-09T16:21:05.666-0600 navigation  - Loading http://localhost:3000/ (scenario Populated, generation 4)
2026-11-09T16:21:05.707-0600 navigation  ! The page at http://localhost:3000/ did not load: Could not connect to the server. (NSURLErrorDomain -1004)

## Verification

Before the fix: launched the actual project command npm run dev with a sanitized development environment; observed TCP readiness on 3000, navigation disconnect, the Invalid environment undefined instrumentation failure and launcher exit. A control run with APP_ENVIRONMENT=dev returned HTTP 200 and stayed running. After the fix: compiled the real StudioSession with test-only assistant stand-ins, used a clean local archive of portal ad00d623 with cloned installed dependencies and a private free port, and kept real backend services unused. Studio discovered APP_ENVIRONMENT=dev and USE_MOCKS=true from README.md, rendered the actual Bread Connect sign-in UI in WKWebView, reached Ready, stayed Ready with a live listener across Reset generations 3 and 4, and stopped its owned listener on close. A screenshot is retained locally in the agent session artifacts, not uploaded. UI Studio pure tests, the complete real-session harness (including startup settings required by its server), and the Debug app build passed. Existing partner-portal working-tree edits were preserved. Scope: endpoint startup and rendering; not every portal route or authentication integration. Release signing is currently unavailable locally (zero Developer ID identities and no markview-notary profile). No new user answers were requested; existing Clarifications are unchanged.

## Root cause

The project README documents APP_ENVIRONMENT=dev and USE_MOCKS=true for local development. apps/unified-partner-portal/src/instrumentation.ts calls getServerConfig(), whose getEnvironment(process.env.APP_ENVIRONMENT) in src/lib/config.ts throws when the selector is absent. StudioConnections.discover previously only produced service URL overrides and synthetic secrets, so its managed launch did not supply the required selector. Next.js 16.2.12 printed Ready and accepted TCP connections before the instrumentation failure; Nx reported exit 0 despite next dev failing. The recorded generation-4 connection refusal was a later Reset against that stopped endpoint, not evidence that a replacement UI renderer was needed.
