---
type: bug
id: BUG-064
title: Preview check reports working screens as broken (sign-in gates, loader check), so the fix round rewrites screens that work
status: open
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
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
