---
type: bug
id: BUG-060
title: "Prototype from code: the shell's root has no height, so the main widget (option chain) collapses and the repair round declines"
status: fixing
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
---

# Prototype from code: the shell's root has no height, so the main widget (option chain) collapses and the repair round declines

## Summary

In the StrikeDesk prototype (v7, MarkView 5.11.0) the main Trade widget shows only its toolbar; the option chain below it is empty. Same symptom as BUG-058, different cause. Measured in the prototype's own files (headless Chrome): html, body and #app have no height, so main.app-main.app-main-single, the host and the widget are all 66 px tall (their content height) and every flex:1 / height:100% box inside the widget is 0 px. app.js documents the structural rules the stylesheet writer must provide in styles.css (html, body, #app: height:100%; margin:0; overflow:hidden; #app flex column; .app-main-single flex column; .app-screen-fill and .app-load fill) and styles.css has none of them. The preview audit did find the collapse and named main.app-main-single at 66px, but the repair round answered "The reported fixes span more than three files, so no changes were made in this run", so nothing was fixed and nothing was reported as a failure in the toolbar.

## Steps to reproduce

1. Open broker-fabric in MarkView 5.11.0 and the prototype strikedesk (v7, made from apps/strikedesk).
2. Look at the first screen (the workspace with the Trade tab): below the toolbar (SPX, TABLE/ANALYSIS, GO, CONFIG, REFRESH) the area is empty.
3. Open docs/prototypes/strikedesk/site/index.html in any browser: same result; measure main.app-main, .ws-host, .ws-dock, .sd-widget: all 66 px high.

## Expected

The shell gives the page a definite height (the contract in app.js), so the dock fills the window and the Trade widget shows the option chain. A prototype whose shell does not satisfy the contract is repaired without asking the model, because the contract is fixed text.

## Actual

styles.css of the prototype contains only the header, nav, .app-main, toast and skeleton rules. html, body, #app, .app-main-single, .app-screen-fill and .app-load have no height rules, so percentage and flex heights collapse. The audit's repair round refused the request (more than three files) and the prototype stayed broken without a clear message.

## Environment

MarkView 5.11.0, prototype strikedesk v7 in broker-fabric (docs/prototypes/strikedesk). Related: BUG-058 (clipped content audit, 5.10.0), BUG-059.
