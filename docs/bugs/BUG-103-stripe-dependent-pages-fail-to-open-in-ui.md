---
type: bug
id: BUG-103
title: Stripe-dependent pages fail to open in UI Studio
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-07
provenance: Created from the bug intake
issue: "#306"
updated: 2026-11-07
---

# Stripe-dependent pages fail to open in UI Studio

## Summary

A reported Viva Platform page fails to open in UI Studio when Stripe.js fails to load. The error is surfaced, but Fix data does not recover the page. The user requests continued work through simulation or a graceful fallback when an external service is unavailable.

## Steps to reproduce

1. Start the Viva Platform development server on localhost:3000 and open it in UI Studio.
2. Navigate to an affected page that loads Stripe.js. The exact route is not yet known.
3. Observe that the page does not open as expected. Inspect the UI Studio log for the failed Stripe.js script and the unhandled rejection.
4. Invoke Fix data on the error and observe that it reports the error is unrelated to simulated records and makes no changes.

## Expected

When an external dependency such as Stripe.js is unavailable, UI Studio should let the user continue working with the affected page through an appropriate simulation or graceful fallback. A payment simulation should be distinguishable from a real integration.

## Actual

The user reports that some Viva Platform pages do not open. The session log records a failed Stripe.js resource as `blocked: script https://js.stripe.com/v3`, followed by an unhandled rejection: `Error: Failed to load Stripe.js`. Two Fix data attempts reported that simulated records did not cause the error and made no changes. The precise visible page state is unknown.

## Environment

MarkView UI Studio running Viva Platform against a development server at http://localhost:3000. The logged /_next/static/chunks/ path indicates Next.js. The session log is dated 2026-11-07 07:53–08:00 UTC−06:00. MarkView and macOS versions and connection settings are unknown. Code reviewed at local HEAD e88b8d1, matching the report's stated origin/main snapshot.

## Suspected code

- `MarkView/Models/UIStudioPolicy.swift` — StudioConnectionPolicy blocks resources by default and permits the application origin and explicitly allowed addresses. It may block Stripe.js when its address is not allowed.
- `MarkView/Resources/Editor/vendor/js/markview-ui-studio.js` — The runtime reports failed cross-origin resources as blocked and reports page errors. Its event label does not establish the underlying reason for a resource failure.
- `MarkView/Models/UIStudioSession.swift` — The session records blocked resources as unsupported dependencies and substitutes a simulated page for external navigation; investigate recovery when an in-page SDK fails to initialize.
- `MarkView/Models/UIStudioAuthMock.swift` — StudioExternalPage supplies a local stand-in for external navigation, including checkout-like pages, but is not itself a Stripe.js replacement.
- `docs/features/markview-ui-studio/requirements/REQ-017.md` — Defines Fix data as a repair for errors caused by simulated data, explaining why this action does not address the reported script failure.

## Likely causes

- Likely: the WebKit connection policy blocks Stripe.js when its address is not explicitly allowed. The recorded `blocked` event alone does not prove that the policy caused this particular failure: the page runtime uses that label for failed cross-origin resources generally.
- Likely: the existing external-page simulation handles navigation to an external site, while the inspected paths do not provide a replacement for Stripe.js initialization within the application page.
- Fix data addresses errors caused by simulated records; it does not recover an unavailable external script.

## Missing information

- The exact affected route and visible failure state.
- The MarkView and macOS versions and whether the Stripe address was explicitly allowed in Environment connection settings.
- Whether the same route loads outside UI Studio under the same network conditions.
- The Stripe APIs used by the affected page and the required scope and fidelity of simulation.

## Validity check

**Outcome:** Still present on main (checked 2026-11-07).

**Verified against:** `origin/main` @ `e88b8d1be6` (2026-11-06) — Merge pull request #305 from t-boris/feat/build-deployment-commands

**Reason:** The snapshot still blocks external scripts by default unless their addresses are explicitly allowed. When a cross-origin script fails, the page runtime reports it and any resulting unhandled rejection; the session marks the dependency unsupported but does not provide a script-level replacement or recovery. The existing simulated external page handles navigation, not Stripe.js initialization, and Fix data only repairs simulated records. Thus the reported failure remains possible when Stripe.js is unavailable. The log alone does not establish whether the connection policy caused the original load failure.

## Original description

Тебе нужно подумать сейчас над UI Studio. В некоторых случаях, например, у меня есть проект Viva Platform, некоторые странички не открываются. И они не открываются, потому что там, например, payment, и нет доступа к Stripe. Хорошо, но в таком случае его можно, во-первых, симулировать. Во-вторых, если на странице есть доступ к Stripe, и он недоступен, и появляется эта ошибка, мы продолжаем, нету доступа, значит мы какую-то свою симуляцию добавим, что не в этом роде. В общем, сделай UI Studio более стабильным для таких ситуаций.

——

2026-11-07T07:53:27.706-0600 page        ! blocked: script https://js.stripe.com/v3
2026-11-07T07:53:27.713-0600 page        ! runtimeError: Unhandled rejection: Error: Failed to load Stripe.js\n@http://localhost:3000/_next/static/chunks/node_modules_0uw~hrp._.js:1238:25
2026-11-07T07:53:27.744-0600 server      ! [browser] Error: Failed to load Stripe.js
2026-11-07T07:53:27.748-0600 server      ! [browser] ⨯ unhandledRejection: Error: Failed to load Stripe.js
2026-11-07T08:00:04.383-0600 notice      ! Fix data: data did not cause this error. Stripe.js failed to load its external script. The reported error is raised by the script's error handler and does not depend on any of the supplied records; investigate script loading or the runtime environment. Look at node_modules/@stripe/stripe-js/src/shared.ts:84. Nothing was changed.
2026-11-07T08:00:40.745-0600 notice      ! Fix data: data did not cause this error. The error comes from the Stripe.js script's load error handler. It indicates that the external Stripe script failed to load, and no supplied record field controls that script request. Look at node_modules/@stripe/stripe-js/src/shared.ts:84. Nothing was changed.

## Clarifications

Answered by Boris Tsekinovsky on 2026-11-07 while the fix was being planned.

- **Scope of the built-in stand-ins:** Stripe.js, reCAPTCHA, Google Maps and analytics SDKs, all in this change (not Stripe alone). Stand-ins are registered by script address, so further SDKs can be added later without reworking the mechanism.
- **Fidelity of the payment stand-in:** a placeholder form whose outcome follows the scenario. The Payment Element renders a placeholder that offers the payment methods the page uses (card, BLIK, P24) and calls onChange. confirmPayment, confirmSetup and createPaymentMethod succeed in a normal scenario and fail with a card decline in an error scenario. Full 3-D Secure and processing variants are not part of this change.
- **Distinguishable from a real integration:** every payment stand-in is labelled on the page as "Simulated payment — no card is charged" and is listed in the session's dependencies as simulated.
