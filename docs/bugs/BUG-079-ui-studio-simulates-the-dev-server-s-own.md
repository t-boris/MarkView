---
type: bug
id: BUG-079
title: UI Studio simulates the dev server's own lazy-compilation request, and hides a page handler's error as "Script error."
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
updated: 2026-11-04
---

# UI Studio simulates the dev server's own lazy-compilation request, and hides a page handler's error as "Script error."

## Summary

On broker-fabric's StrikeDesk shell (an rspack dev server on :3010, an Electron renderer run as web only), three things went wrong.
- **The dev server's own request was simulated.** `POST /lazy-compilation-using-` waited 41.6 s for a prepared rule and then got a fake 200, so the real server never learned which lazy modules to build.
- **The renderer crashed.** The Electron stand-ins do nothing, so it got proxies instead of data (REQ-016).
- **The crash reached the overlay and the log only as "Script error.".**
  - The cause is MarkView's runtime. When a page handler that a simulated XHR calls throws (and likewise for WebSocket, EventSource and Notification), the runtime rethrew the error from its own user script. That script has no address, so WebKit hid the message.
  - A web-harness probe confirmed this. It also confirmed that eval'd `webpack://` code keeps its message.

## Steps to reproduce

1. Open UI Studio on broker-fabric apps/strikedesk/app/packages/shell
2. Wait for the page
3. Read .dde/studio/session.log

## Expected

The dev server's own requests (lazy compilation, webpack-dev-server, Rsbuild and Parcel endpoints) go to it unchanged. A page error is logged with its message and stack when the application logs it.

## Actual

`POST /lazy-compilation-using-` is simulated by a prepared rule. The overlay shows "Uncaught runtime errors: Script error." and the log has nothing more.

## Environment

MarkView 5.21.0; rspack 1.7.12; StudioConnectionPolicy.isDevelopmentResource; markview-ui-studio.js error listener

## Fix

- The dev server's own routes always pass to it, never simulated. These are lazy compilation, webpack-dev-server, Rsbuild and Parcel, plus the overlays' stack-frame lookups.
- A handler's error is surfaced with `reportError`, so the page and its overlay see the real message.
- An Error the application passes to console.error or reportError is logged with its message and stack (event `logged`).
- A remaining "Script error." is explained, with what was logged just then.
- Commit 46add68.
