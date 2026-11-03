---
type: bug
id: BUG-053
title: A prototype screen can be blank or a stub and nothing reports it
status: fixed
branch: fix/bug-053-prototype-blank-screens
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

## Cause

1. The build accepted any answer that held a file with the right path. The Settings screen was a 255-byte comment ("not implemented") and the
   first Trade screen a stub; both passed.
2. After a build only the first screen was ever rendered, and only uncaught JavaScript errors were reported. `App.load` catches the errors of its
   callback and shows an error card, and a render function that returns an empty element throws nothing, so a blank screen reached nobody.
3. The screen prompt did not say what the callback of `App.load` must return. In the strikedesk Trade screen it returned the container that
   `App.load` had returned itself.

## Resolution

- `PrototypeAudit.stubProblem` (new file `Models/PrototypeAudit.swift`) checks every screen the build writes: no code besides comments, no
  `App.register`, no `render`, or a short file (under 400 characters) whose text says "not implemented", "TODO", "coming soon". Such an answer is
  not saved; the second try is told why and runs at medium effort; a screen that is still a stub is listed as failed (the build reply names it).
- `PrototypeAudit.script` is injected into the Studio preview. After a build, a sync, or a revision that touched a screen, `app.js` or `index.html`,
  the session asks the preview to open every route of `App.plan` (not the routes with parameters and not `/modals/`, which need an argument or a
  host), wait until the page settles and report what is blank, still on its loading indicator, in an error card or a placeholder. The shell is
  recognised by text that most routes share and by header/nav/aside/footer elements, so a screen is measured by what it adds.
- The findings join the preview's JavaScript errors in the existing single fix round ("Fix the errors and the blank or unfinished screens");
  screens the build already reported as failed are skipped; after a fix the screens are checked once more and what is still wrong is named in the
  chat. Opening every screen also surfaces the JavaScript errors of screens that were never visited before.
- The screen prompt says that the callback of `App.load` returns the content, never the container `App.load` returned.

## Verification

- `tools/tests/prototype-tests.sh`: stub detection (comment only, empty, App.register only in a comment, no render, placeholder text, TODO, a
  long screen with a `placeholder` attribute, a real short screen), comment stripping, the report parser, the messages, the prompt rule; the pinned
  `screenSystem` digest was updated on purpose.
- `tools/tests/prototype-deadline-tests.sh` (`stubMode`): a stub answer is asked again once with the reason at medium effort and the real screen is
  saved; a screen that stays a stub is failed and no file is written.
- `tools/tests/prototype-audit-check.sh`: the audit script in headless Chrome against `Tests/Fixtures/prototype-audit` reports the placeholder, the
  blank, the error-card, the stuck and the unbuilt screen and none of the four real ones, the parameter route or the modal.
- The same script in a real `WKWebView` with the `mvproto://` scheme handler (scratch harness): identical findings on the fixture; on a copy of the
  strikedesk prototype v8 it reports Trade (blank, the screen of this report), Transport (blank: the original hides the bar without playback state,
  which the prototype does not simulate) and Trade journal (error card). Settings is a modal route and is caught by the static check at build time.
- Debug `xcodebuild`: build succeeded, app version 5.5.2.
- Not verified: the fix round on a real blank screen through the assistant (one run per build); the Studio window itself (no UI click-through).
