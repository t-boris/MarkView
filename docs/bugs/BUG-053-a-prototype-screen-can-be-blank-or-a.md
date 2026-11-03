---
type: bug
id: BUG-053
title: A prototype screen can be blank or a stub and nothing reports it
status: fixing
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
---

# A prototype screen can be blank or a stub and nothing reports it

## Summary

The build and the "Fix preview errors" loop only see uncaught JavaScript errors and the shape of the files. A screen that renders nothing, or a screen that is only a comment saying it is not implemented, is accepted as built and never reported.

## Steps to reproduce

1. Open the strikedesk prototype in broker-fabric (v8) and go to the Trade screen (route /widgets/trade).
2. Compare with the other screens, for example /widgets/positions.
3. Read screens/settings.js.

## Expected

After a build, a sync or a revision every screen is checked: it must render something and must not be a stub. A blank or stub screen is retried, and if it still is one the person is told which screen it is.

## Actual

Trade (screens/trade.js, 16 KB, with the option chain and the order ticket) renders an empty page: the callback of App.load returns the screen's own root element, which already contains the loader, so the root leaves the page; no error is thrown, App.renderScreen and renderRoute catch nothing, and Studio reported none. With that one line changed in a scratch copy the chain renders (14 KB). Settings (screens/settings.js) is a 255-byte comment "not implemented" after two tiny answers (621 and 789 tokens) that the build accepted. The first build also left the Trade screen as a stub (1104 tokens), which is what the person complained about in v5. The "Fix preview errors" round in v8 fixed an unrelated syntax error in stats.js.

## Environment

MarkView 5.5.0, project broker-fabric, prototype strikedesk v8, rendered in headless Chrome (not in the Studio window)
