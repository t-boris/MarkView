---
type: bug
id: BUG-068
title: UI Studio applies a change to an element other than the selected one
status: fixing
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
feature: markview-ui-studio
ready_to_fix: true
updated: 2026-11-04
---

# UI Studio applies a change to an element other than the selected one

## Summary

After the scenario is restored for a change request, UI Studio finds the selected element again by its positional selector. When the restored page has a different layout (here vivaa's consent banner came back), the path points at another element, and the assistant edits that element's sources.

## Steps to reproduce

1. Open UI Studio on vivaa-platform apps/client-web-app (Next.js 16), scenario Populated.
2. Accept the consent banner, then select the "Can't find the right package?" card (div.mx-auto.flex.w-full, component PlanningInvitation, Source: none).
3. Ask for a change, e.g. make this section more attractive, and press Change.

## Expected

The change is made to the selected card. If the selected element cannot be found again after the restore, the change stops and asks the person to select it again.

## Actual

The operation's selection is button.rounded-pill.bg-coral.px-sp6, a button in the consent banner. Its scope says "changes limited to the selected ConsentBanner section", and the assistant edited components/layout/consent-banner.tsx and consent-banner.module.css.

## Environment

MarkView 5.15.2; vivaa-platform apps/client-web-app, Next.js 16.2.1, React 19, Turbopack. Cause in code: selectorOf (markview-ui-studio.js) falls back to a tag:nth-of-type path; change() restores the scenario (storage cleared, page reloaded); StudioSelectionRevalidation.decide accepts any single element on that path when the element has no source node.
