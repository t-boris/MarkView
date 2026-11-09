---
type: bug
id: BUG-064
title: Preview check reports working screens as broken (sign-in gates, loader check), so the fix round rewrites screens that work
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
updated: 2026-11-04
---

# Preview check reports working screens as broken (sign-in gates, loader check), so the fix round rewrites screens that work

## Summary

On the vivaa client-web-app prototype the preview check reported four screens as "renders nothing" (Studio, Celebration poster, Poster notes, Orders). Studio renders "Studio" and a Sign in button for a guest (checked in headless Chrome). The cause is in PrototypeAudit's script: a text chunk that appears on at least 80 percent of the routes counts as shell, and the words of a sign-in gate ("Studio", "Sign in", "Orders") are also navigation labels in the header, so the whole screen is classified as shell and reported blank. Separately, the loader check added in 5.13.1 (PrototypeAudit.loadProblem, BUG-062) flags 7 of the 40 screens of this prototype, and only the Orders one is reported by the preview; gallery.js, which renders fine, is flagged. The check treats any call to a function that clears the host, anywhere in the text of the callback of App.load (including an event handler for retry that runs later), as a defect, and it does not look at what the callback returns. The real defect in strikedesk's trade.js is narrower: the callback clears the host synchronously and then moves the host's child nodes into the element it returns, which App.load puts into its detached container. With 5.13.1 the fix round of this prototype would start per-file runs over four to ten screens that are not broken.

## Steps to reproduce

1. Open docs/prototypes/client-web-app (vivaa-platform) in 5.13.1, wait for the preview check or press Fix again.
2. The chat lists Studio, Celebration poster, Poster notes and Orders as rendering nothing.
3. Render #/studio in a browser as a guest: a heading and a Sign in button are shown.
4. Run PrototypeAudit.loadProblem over site/screens/*.js: seven files are flagged, among them gallery.js, which works.

## Expected

Only a screen that really shows nothing is reported, and only a loader defect that empties the screen is flagged (clearing the host synchronously and returning its moved children or the host itself). Working screens are never sent to the assistant as problems.

## Actual

Working screens are reported and, in 5.13.1, would be revised one by one at medium effort; the loader check gives the model a wrong reason when a screen is written.

## Environment

MarkView 5.12.1 installed, 5.13.1 released (introduced the loader check), main 57cdeff. Project: vivaa-platform, docs/prototypes/client-web-app (40 screens). Related: BUG-062, BUG-063.

## Resolution

Fixed in 5.13.2 (pull request #282, together with BUG-063; release v5.13.2).

- Audit: chunks that no route shows as its own content are the only ones counted as shell, chrome text is left out of the shell count, and a header, nav, aside or footer inside `<main>` is the screen's content.
- Loader check: `PrototypeAudit.loadProblem` reads only code that runs before the callback returns (function literals and strings are skipped, functions called synchronously are followed to a depth of four) and needs the host cleared and then returned or its child nodes taken. That is what strikedesk's `trade.js` does; the shapes that work are not flagged.
- The message names what the callback returns.

## Cause

- The audit script counted a text chunk as shell when it appeared on at least 80 percent of the routes, and read the words of a sign-in gate ("Studio", "Sign in", "Orders") as navigation labels, so the whole screen was classified as shell and reported blank. A widget whose root is an `<aside>` was also counted as chrome, though it sits inside `<main>`.
- The loader check of 5.13.1 (BUG-062, my own change) took any call to a function that clears the host anywhere in the callback's text, an event handler for retry included, and ignored what the callback returns. It was checked on a small corpus, so 7 of 40 vivaa screens were flagged, `gallery.js` among them.

## Verification

`prototype-audit-check.sh` in headless Chrome (the fixture has a sign-in gate and an aside widget, 14 routes checked, 2 skipped; it fails with the old counting and with the old chrome rule), `prototype-fixround-tests.sh` (fails when the host-taking rule or the function-literal rule is removed), every other prototype suite, the Debug build and the three pull request checks. On scratchpad copies of the real prototypes: the old audit reports exactly the four screens of the report on vivaa, the new one none (also none once Tailwind is added); on strikedesk both report workspace (loading), trade (blank) and the placeholder chart; the loader check flags only `trade.js` of 82 real screens. 5.13.1 (Latest until 5.13.2) has the false positives of the loader check; 5.13.2 removes them. Release v5.13.2 is signed and notarized.

Not covered: a live fix round with a real assistant on the vivaa prototype.
