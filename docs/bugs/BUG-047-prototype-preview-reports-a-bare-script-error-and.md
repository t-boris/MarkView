---
type: bug
id: BUG-047
title: Prototype preview reports a bare "Script error." and the last stage fixes it blind
status: fixed
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-03
provenance: Created by an AI agent through MarkView
---

# Prototype preview reports a bare "Script error." and the last stage fixes it blind

## Summary

When a prototype is generated, the last stage ("Fixing errors found in the preview") starts with the message "The preview reported 1 error; fixing: • Script error." The preview loads site/index.html through file://, where WebKit treats every file as its own origin and hides the message, file and line of any error thrown in app.js, data.js or screens/*.js. The assistant is asked to fix an error it cannot see.

## Steps to reproduce

1. Generate a prototype in Prototype Studio.
2. Wait for the build to finish; the final stage reports the preview's JavaScript errors.
3. The conversation shows 'Script error.' with no message, file or line.

## Expected

The preview reports the real error text with the file and line (for example "ReferenceError: Can't find variable: x (broken.js:2)"), so the automatic fix round and the reviewer can act on it.

## Actual

The error arrives as "Script error." Reproduced with a standalone WKWebView harness that loads a site with a throwing screens/broken.js through loadFileURL and the same window 'error' listener as PrototypeStudioView: it reports "Script error."; serving the same files through a custom URL scheme reports "ReferenceError: Can't find variable: undefinedFunction (broken.js:2)".

## Environment

Prototype Studio preview (PrototypeStudioView.PrototypePreview, WKWebView.loadFileURL), macOS 13+.

## Cause

`loadFileURL` gives every `file:` URL its own origin. WebKit hides the message, file and line of an error thrown by a script from another origin and delivers only "Script error." to the `error` listener. `index.html` loads `data.js`, `app.js` and `screens/*.js` as siblings, so every fault in them reached the fix round as a bare "Script error.". The fault in the user's own prototype is not known; the fix lets the next run name it.

## Resolution

The preview serves the `site/` folder through its own URL scheme, `mvproto://site/<path>` (`PrototypeSchemeHandler`), so all files share one origin and the real error arrives with its text and `path:line`. The handler serves files only inside `site/` (`..`, encoded `..`, NUL and symbolic links out of the folder are refused with 403), maps a directory to `index.html`, sends no-store headers, and never answers a stopped task. The private `allowFileAccessFromFileURLs` key is not used. The reload keeps the screen's `#hash`; "Open in browser" still opens the file itself. Old prototypes need no migration; a generated script's `localStorage` starts empty once because the origin changes.

## Verification

- `tools/tests/prototype-scheme-tests.sh`: 28 checks, including a real WKWebView run that takes the error listener from `PrototypeStudioView.swift`: through `mvproto://` it reports `ReferenceError: Can't find variable: undefinedFunction (screens/broken.js:2)`, through `file://` only "Script error." (the baseline).
- The other prototype harnesses and the Debug build pass.
- A live check in a scratch copy of the Debug build with a fixture prototype that has one throwing screen was done before the session restart (see `tasks/todo.md`): the preview showed the page and the error badge named the file and line.
- Not verified: a full generation against a real assistant.
