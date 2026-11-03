---
type: bug
id: BUG-055
title: Web app discovery does not find the StrikeDesk Electron app in broker-fabric
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
updated: 2026-11-03
---

# Web app discovery does not find the StrikeDesk Electron app in broker-fabric

## Summary

Preview Web App and the code hints of Prototype from Code do not detect StrikeDesk. The discovery lists only apps/bf-signal-worker for broker-fabric, because it looks no deeper than two folder levels and does not know rspack. The Electron app is apps/strikedesk/app/packages/shell, five levels below the project root, and its renderer is served by `rspack serve`.

## Steps to reproduce

1. Open broker-fabric (/Users/boris/github.com/broker-fabric) in MarkView.
2. Use Preview Web App, or AI Tools > New Prototype from Code with apps/strikedesk selected.
3. Look at the detected apps: StrikeDesk is not listed; the only app found is apps/bf-signal-worker.

## Expected

StrikeDesk is found as an Electron app whose renderer is served without Electron (apps/strikedesk/app/packages/shell, `pnpm dev:renderer`, port 3010), so Preview Web App can start it and Prototype from Code and Sync from code give the planner the Electron renderer hints.

## Actual

WebAppPreview.targets(root:) returns only apps/bf-signal-worker. It scans the root and two levels of folders (root, apps, apps/strikedesk); the app lives in apps/strikedesk/app/packages/shell. Even when pointed straight at that folder, WebAppPreview.target(in:) returns nil: its renderer script is `rspack serve -c rspack.renderer.config.ts`, and servesWebOnly and the web dependency list know vite, next, webpack, ng, vue-cli, astro, nuxt and parcel but not rspack or rsbuild; the launcher fallback understands only electron-vite and Vite configs. The prototype creator still starts (it accepts any UI files), but without app hints.

## Environment

MarkView 5.8.0 (the discovery code is unchanged since 5.5.0), project broker-fabric, app apps/strikedesk (pnpm workspace apps/strikedesk/app with packages/shell, trading-core, shared; Electron 35, rspack)

## Cause

`WebAppPreview.targets(root:)` listed only the project root and two levels of folders. StrikeDesk's Electron app is `apps/strikedesk/app/packages/shell`, five levels down; the folders above it (`apps/strikedesk`, `apps/strikedesk/app`) are a Go service and a pnpm workspace root whose own `dev` script is `pnpm --filter … dev`, which is no web app. Pointed at the shell package directly, discovery still returned nothing: its renderer script is `rspack serve -c rspack.renderer.config.ts`, and neither `servesWebOnly` nor the web-framework lists knew rspack or rsbuild, and the launcher fallback only reads electron-vite and Vite configs. Related: the package manager was taken from the app's own folder only, but a workspace package has no lockfile of its own (`pnpm-lock.yaml` is in `apps/strikedesk/app`), so the command would have been `npm run dev:renderer`.

## Resolution

- `WebAppPreview.workspacePackages`: finds JavaScript workspaces (`pnpm-workspace.yaml` `packages:`, `package.json` `workspaces` as an array or `{packages}`) declared up to four levels below the project root (at most 400 folders listed, shallowest first), expands `*`, `**`, `?`/`[]` globs and `!` exclusions, and adds their packages after the unchanged two-level scan, without duplicates. `node_modules`, `dist` and the other skipped folders are never entered.
- rspack and rsbuild: `rspack serve`/`dev`, `rsbuild dev` and `rspack-dev-server` count as web-only servers; `@rspack/cli` and `@rsbuild/core` as web frameworks; default ports 8080 and 3000; `rspack.config.*` and `rsbuild.config.*` are read for a port, and so is the config file a script names with `-c`/`--config` (StrikeDesk: `rspack.renderer.config.ts`, port 3010).
- The package manager comes from the closest lockfile between the app and the project root, so a workspace package runs `pnpm run dev:renderer`.
- Not changed: apps found by the two-level scan, Electron handling (only the renderer is previewed, Electron is never started), prototype creation (the creator sheet and Sync from code use the same discovery and now get the Electron renderer hint for StrikeDesk).

## Verification

- `tools/tests/web-preview-tests.sh` (81 checks): a StrikeDesk-shaped fixture (Go service next to a pnpm workspace three levels down, Electron shell with an rspack renderer, lockfile in the workspace root), npm workspaces with an exclusion, the object form with `**` and an rsbuild app, a workspace declared too deep, `node_modules`, the YAML list reader, the script config reader, rspack/rsbuild scripts. The script itself had stopped compiling (BrowserSession needs `BrowserElementPick.swift` and `Views/BrowserPopup.swift`); both are in its file list now.
- The app's own discovery on broker-fabric: `apps/strikedesk/app/packages/shell (web only)`, `pnpm run dev:renderer`, ports 3010 and 8080, Electron, in 52 ms; the path is inside the source scope `apps/strikedesk`.
- Debug build passes. Not done: starting the dev server in broker-fabric, clicking Preview Web App and the creator sheet in the app window. A workspace declared deeper than four levels is still not found.
