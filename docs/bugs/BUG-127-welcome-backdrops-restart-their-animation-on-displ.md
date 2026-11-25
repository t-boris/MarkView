---
type: bug
id: BUG-127
title: Welcome backdrops restart their animation on display changes that alter nothing they are built from
status: in-progress
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-25
provenance: Created by an AI agent through MarkView
related: agent-aware-implementation-runs
schema: 1
---

# Welcome backdrops restart their animation on display changes that alter nothing they are built from

## Summary

BackdropHostView rebuilt its layers, and so restarted every animation from the beginning, on every accessibilityDisplayOptionsDidChange notification (posted for contrast, transparency and colour options, not only Reduce Motion) and on every viewDidChangeBackingProperties callback (a colour space change calls it at the same scale). Each restart is a visible jump in every window, and in the hosted welcome-screen check (WelcomeScreenHostTests.testWelcomeScreen, CI shard hosted-tests (4)) a restart between the two measured frames failed main after PR #438 twice: "frames aurora: the composed picture changes in 1.5 seconds (0.0 % of the pixels)", then "frames bugs: every bug in motion faces the way it moves (0 of 0, 21 bugs)". The tree was identical to the PR head where the shard passed. Locally the same check measures 3.6 % for aurora (threshold 0.2 %), and posting the notification mid-measurement reproduces the aurora message exactly. One such notification took 0.57 s because the test process keeps about 180 closed windows alive, each with a live backdrop.

## Steps to reproduce

1. Open a welcome screen with an animated backdrop (Aurora or Bugs)
2. Change a display option other than Reduce Motion (Increase contrast, Reduce transparency), or move the window to a display with another colour profile at the same scale
3. Watch the backdrop: every animation jumps back to its start
4. On CI: run tools/tests/welcome-screen-tests.sh; a system display-change callback during animatedFrameChecks fails the frames check

## Expected

The backdrop rebuilds only when something it is built from changes: size, scale, Reduce Motion, kind, colours, seed or detail. Other callbacks leave the running animation alone, and the welcome-screen check measures one continuous animation.

## Actual

Every display-options notification and every backing-properties callback rebuilt all backdrops and restarted their animations; CI main run 45533888020 (77ff8e8a) failed twice in WelcomeScreenHostTests.

## Environment

MarkView 7.4.0; GitHub runner macos-26-arm64 20261117.0516.1; local macOS Darwin 27.2
