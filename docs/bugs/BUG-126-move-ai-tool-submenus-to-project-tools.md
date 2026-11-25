---
type: bug
id: BUG-126
title: Move AI tool submenus to project tools
status: done
severity: low
reporter: Boris Tsekinovsky
created: 2026-11-20
provenance: Created from the bug intake
issue: "#431"
schema: 1
---

# Move AI tool submenus to project tools

## Summary

Project tool submenus are grouped under the AI model-selection menu instead of More project tools.

## Steps to reproduce

1. Open a project in MarkView.
2. Open the toolbar menu for selecting the assistant and its model.
3. Observe the Diagrams, Prototype, and Analysis submenus below the X-Ray model selector.
4. Open the ellipsis menu labeled More project tools and observe Project Cycle Time and DDE Settings.

## Expected

Move the complete Diagrams, Prototype, and Analysis submenus into More project tools alongside Project Cycle Time and DDE Settings. Preserve their actions and existing availability conditions. Keep the assistant, assistant model, and X-Ray model selectors in the AI toolbar menu.

## Actual

The AI toolbar menu contains the Diagrams, Prototype, and Analysis submenus below the X-Ray model selector. The More project tools menu contains Project Cycle Time and DDE Settings, but none of those three submenus.

## Environment

Source inspected on local main and origin/main at d27e73bb3882029ca61812360b5110784a1a3dd1. The project specifies MarkView 7.3.0 and a macOS 13.0 deployment target. The installed app and macOS versions on which the issue was observed are unknown. The application was not run for this investigation.

## Suspected code

- `MarkView/Views/AI/AIToolbarMenu.swift` — AIToolbarMenu inserts AIToolsMenuItems after the X-Ray model selector. AIToolsMenuItems defines all three submenus, their actions, and availability conditions. The menu help text also says it holds AI tools.
- `MarkView/Views/Workspace/ContentView.swift` — The workspace header hosts both menus. Its projectMenu defines the ellipsis menu labeled More project tools and currently contains Project Cycle Time and DDE Settings.

## Likely causes

- AIToolbarMenu explicitly inserts AIToolsMenuItems after the X-Ray model selector.
- The separately defined projectMenu does not include AIToolsMenuItems.

## Missing information

- The installed MarkView and macOS versions used when the issue was observed are unknown, but the source identifies the menu placement and is sufficient to begin a fix.

## Validity check

**Outcome:** Still present on main (checked 2026-11-20).

**Verified against:** `origin/main` @ `d27e73bb38` (2026-11-18) — docs(mcp): record feature status as done after release v7.3.0

**Reason:** In MarkView/Views/AI/AIToolbarMenu.swift, the assistant and model selectors are followed by the X-Ray model submenu and AIToolsMenuItems, which defines the Diagrams, Prototype, and Analysis submenus and their existing actions and availability conditions. MarkView/Views/Workspace/ContentView.swift places both menus in the workspace header, but its ellipsis menu labeled More project tools contains only Project Cycle Time and DDE Settings. The three submenus have not been moved.

## Original description

У нас в меню наверху есть несколько вещей. Там, где мы, например, выбираем модель для ассистента и для X-Ray, у нас есть диаграммы, прототайп, есть аналисис. Это все нужно вынести в TrayTorch, где мы делаем все эти виды. Мы должны вынести это сюда, где Project Cycle Time, где DE Settings. В это место надо вынести все три вот эти вещи, а выбор модели оставить как есть.
