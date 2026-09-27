---
type: bug
id: BUG-004
title: Switching a panel tab in one MarkView window switches the same tab in all other open windows
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Какой именно таб переключается во втором окне?
    why: В коде несколько глобально синхронизируемых состояний; от ответа зависит, какой файл чинить в первую очередь.
    options:
      - label: Вкладки документов
        text: Верхняя панель вкладок с открытыми файлами
      - label: Левая панель
        text: Режим левой панели (Files / Features / Issues)
      - label: Оглавление (TOC)
        text: Вкладки боковой панели оглавления
      - label: Git
        text: Раздел панели Git
    status: answered
    answer: Оглавление (TOC). Вкладки боковой панели оглавления
  - id: BQ-2
    text: В двух окнах был открыт один и тот же проект или разные?
    why: Если проекты разные, значит состояние общее для всего приложения (UserDefaults), а не для одного проекта.
    options:
      - label: Один проект
        text: Одна и та же папка или воркспейс
      - label: Разные проекты
        text: Разные папки
    status: answered
    answer: Settled by the clarifications.
issue: "#27"
---

# Switching a panel tab in one MarkView window switches the same tab in all other open windows

## Summary

With two or more MarkView windows open, switching the TOC (outline) sidebar tab in one window switches the same tab in every other window. TOCView stores its selected tab with @AppStorage("layout.navigatorTab"). That value lives in the app-wide UserDefaults, so every window observes the same key.

## Steps to reproduce

1. Launch MarkView and open window A.
2. Open a second window B (File > New Window or open another workspace).
3. In window A, switch the TOC/outline sidebar tab (e.g. Contents → another tab).
4. Look at window B's TOC sidebar.

## Expected

Each window keeps its own TOC sidebar tab. Changing it in window A has no effect on window B. Restoring the selection on relaunch or for new windows may still happen, per window.

## Actual

Window B's TOC sidebar immediately switches to the tab selected in window A.

## Environment

MarkView macOS app (SwiftUI), macOS Darwin 27.0.0, multiple windows open at once. Build/commit not specified.

## Suspected code

- `MarkView/Views/TOCView.swift` — Line 6: `@AppStorage(Tab.storageKey) private var selectedTab` with storageKey "layout.navigatorTab" (line 15). The value is app-global in UserDefaults, so it syncs live across all windows. Confirmed as the reported tab.
- `MarkView/Views/FeatureNavigatorView.swift` — Lines 16/18: @AppStorage for left-panel mode and open feature slug. Same pattern, so it likely has the same cross-window sync (not the reported symptom).
- `MarkView/Views/GitView.swift` — Line 12: @AppStorage("layout.gitSection"). Same pattern.
- `MarkView/Views/TerminalView.swift` — Line 106: @AppStorage("layout.terminalPromptsExpanded"). Same pattern.

## Likely causes

- Confirmed from code: the TOC tab selection is persisted with @AppStorage. That is backed by the single app-wide UserDefaults, which pushes every change to all views in all windows that observe the key.
- Fix direction (inference): use @SceneStorage or state owned by the per-window workspace model. Optionally write the last choice to UserDefaults only as the initial default for new windows. Apply the same fix to the other @AppStorage layout keys.

## Missing information

- App build/commit version (not needed to fix, since the cause is visible in code).

## Clarifications

**BQ-1** Какой именно таб переключается во втором окне?
→ Оглавление (TOC). Вкладки боковой панели оглавления

## Original description

Нашел критический прэм баг. Если мы меняем тэб в одном окошке MarkView в другом окне MarkView, тэб точно также меняется. Это вообще такой косяк, который надо исправить как можно срочно.

## Resolution (2026-09-27, 2.19.1)

**Reproduced** in a Debug copy with its own bundle ID (`com.markview.bug004`, separate defaults),
driven through Accessibility by process ID. With six windows open, all on Git, pressing "Search" in
window 0 switched all six windows to Search.

**Root cause.** `TOCView` bound the tab to `@AppStorage("layout.navigatorTab")`. That is one value in
the app-wide UserDefaults, and every window's `TOCView` observes it, so a change in one window
re-renders all of them. `WorkspaceManager.showAIConsole`, `intakeFinished` and `runFeatureAction`
also wrote the key directly, which switched every window too. Four other panel states used the same
pattern and had the same defect: the left panel Files/Issues mode (`layout.leftPanel`), the feature
open in the Issues list (`layout.issuesFeature`), the Git section (`layout.gitSection`) and the
feature stage (`feature.stage`).

**Fix.** The new `Models/PanelLayout.swift` is a per-window `ObservableObject`, owned by each window's
`WorkspaceManager` (`layout`). It holds all five states. It reads the existing keys once when the
window opens, and writes each change back only as the starting value for the next window and for
relaunch (the same rule as `showTOC`). `TOCView`, the left panel, `GitView` and `FeaturePanelView`
observe the window's `PanelLayout`. The `WorkspaceManager` actions and "Go to Review" set that
window's layout. The stored keys and their values are unchanged.

**Verified** in the same copy after the fix:
- TOC tab: pressing "Search" in one of eight windows changed only that window.
- New window: File > New Window opened on the last choice. Switching that window to Git left the
  older Search window alone.
- Relaunch: every restored window came back on the last choice.
- Left panel: two folders with `docs/bugs` open side by side. "Issues" in one window showed its
  Issues list, and the other window stayed on Files.

The View > Terminal (⌘3) action path was not driven. It acts on the focused window, which needs the
test copy to be the active app. It now writes only to that window's `layout`, the object the checks
above covered.
