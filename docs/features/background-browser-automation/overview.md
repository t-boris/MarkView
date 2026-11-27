---
type: feature
id: background-browser-automation
title: Background Browser Automation
status: done
owner: Boris Tsekinovsky
created: 2026-11-25
provenance: Created from the quick feature intake
understanding:
  Problem: unknown
  Target Users: unknown
  Primary Workflow: unknown
  Permissions: unknown
  Failure Scenarios: unknown
  Data Model: unknown
  Notifications: unknown
  Security: unknown
  Analytics: unknown
  Dependencies: unknown
  Acceptance Criteria: unknown
schema: 1
intake: quick
questions_left: 0
issue: "#441"
---

# Background Browser Automation

## Idea

Run browser automation in background tabs so the user can keep typing, editing, and switching tabs while an assistant works.

## Problem

MarkView's browser tools repeatedly select the tabs they open or operate on. This interrupts typing in Copilot and makes it difficult to work elsewhere in MarkView while automation is running.

## Scope

Applies to MarkView's browser tools across assistants, including new tabs, operations on existing tabs, and tabs or popups opened by automated page actions. Manual browsing, terminal URL forwarding, and the explicit `markview_focus_window` command retain their current behavior.

## Analysis

The architecture guide documents named browser tabs and Copilot's browser tool connection. `browser_open_tab` currently uses the host's default `activate: true`. Other browser tools call `show(session)` before executing, which selects the tab, switches the workspace to Files, and shows the center pane. The host already supports `activate: false`, but the agent path does not use it. An existing hosted test explicitly expects both opening and inspecting a tab to select it. [Architecture guide](docs/architecture/modules/git-github-terminal-lifecycle-usage.md:330) · [BrowserAgentTabs.swift](MarkView/Models/Browser/BrowserAgentTabs.swift:17) · [BrowserHost.swift](MarkView/Models/Workspace/BrowserHost.swift:73) · [BrowserHostHostTests.swift](MarkViewHostedTests/BrowserHostHostTests.swift:214)

`ContentView` mounts the selected browser tab. The executor already has script fallbacks for click, type, and key input, but PNG capture currently requires a mounted WebView. Page-created links use the default foreground open path, and script popups can open a separate window. Removing the direct selection calls alone would leave those paths to address. [ContentView.swift](MarkView/Views/Workspace/ContentView.swift:723) · [BrowserAgentExecutor.swift](MarkView/Models/Browser/BrowserAgentExecutor.swift:163) · [BrowserAgentExecutor.swift, PNG capture](MarkView/Models/Browser/BrowserAgentExecutor.swift:371) · [BrowserSession.swift](MarkView/Models/Browser/BrowserSession.swift:466) · [BrowserHost.swift, new-tab callback](MarkView/Models/Workspace/BrowserHost.swift:191)

## Assumptions

Made by the AI where the request left a choice open; correct them in the discussion.

- Background operation is the default for every assistant using MarkView's browser tools, including Copilot. The user can bring a tab forward by selecting it.
- The existing target fallback stays in place when `tab` is omitted: the selected browser tab, then the first browser tab, then a new background tab. Multi-step workflows should use the returned tab name to keep targeting stable.
- Foreground-dependent operations may return an actionable error when they cannot complete in the background. Full background parity for PNG capture and trusted input is outside this release.

## Acceptance Criteria

- [x] `browser_open_tab`, with or without a URL, opens a named tab in the background. The tool returns its name, `browser_tabs` lists it, and the user's current tab stays selected, including when Welcome is selected and this is the first browser tab.
- [x] An agent can navigate, inspect, and interact with a named background tab while the user types in Copilot, edits a document, or switches tabs. The user's keystrokes continue to reach the intended input, and a pending tool call never overrides a later user selection.
- [x] Browser tool calls preserve the current workspace area, panel visibility, and keyboard focus. When another macOS app is active, MarkView stays in the background.
- [x] New-tab requests caused by automated page actions open in the background. Verify that a delayed request still opens in the background after the initiating tool returns and the user has selected the originating tab, preserving the user's selection and keyboard focus. If an operation requires foreground interaction, such as an unsupported background screenshot or trusted input, the tool explains what the user needs to do without bringing the tab or window forward.
- [x] When an automated action triggers a sign-in popup that requires user interaction, MarkView keeps it hidden and preserves its connection to the originating page. The tool names the originating tab and explains how to use the explicit action in that tab to open the pending popup. MarkView displays the popup only when the user invokes that action. If the popup is no longer available, MarkView explains how to retry sign-in manually.
- [x] In a separate test, verify that a subsequent manual click on the same page that opens a new tab follows ordinary browsing behavior.
- [x] `browser_tabs` reports the user's actual active tab. Named targeting, missing or ambiguous target errors, and the tab's Stop and Allow controls continue to work. The user can select and use an automation-created tab manually.
