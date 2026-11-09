---
type: bug
id: BUG-110
title: Date comparison is hard to find in X-Ray
status: done
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-08
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Где вы искали выбор даты?
    why: В текущем коде кнопка предусмотрена только в PR X-Ray; ответ поможет отличить проблему доступности от отсутствия кнопки в предусмотренном месте.
    options:
      - label: A
        text: В обычном X-Ray проекта.
      - label: B
        text: В PR X-Ray.
      - label: C
        text: Проверял оба представления.
      - label: D
        text: Не помню.
    status: answered
    answer: A. В обычном X-Ray проекта.
  - id: BQ-2
    text: Какая версия MarkView установлена?
    why: Реализация появилась в версии 5.42.0; версия поможет проверить, попала ли она в установленное приложение.
    status: answered
    answer: 5.43.0
issue: "#327"
branch: fix/xray-and-review-batch
updated: 2026-11-08
---

# Date comparison is hard to find in X-Ray

## Summary

Date-based comparison with a historical commit is not discoverable from ordinary project X-Ray because its existing picker is restricted to PR X-Ray.

## Steps to reproduce

1. Open a Git project in MarkView 5.43.0 and enter ordinary project X-Ray.
2. Look in the X-Ray toolbar for a control to compare the current working copy with a commit selected by date.
3. Observe that no date comparison control is visible.

## Expected

Ordinary project X-Ray provides a discoverable way to choose a date and a commit and compare that commit with the current working copy, without requiring a pull request or first opening a PR-labeled view.

## Actual

The user reports that no date-and-commit comparison control was visible in ordinary project X-Ray in MarkView 5.43.0. At the inspected local source revision, both the date button and history picker are restricted to PR X-Ray, whose entry point is labeled “Pull request.” The installed app has not been independently checked.

## Environment

User-reported MarkView 5.43.0 on macOS; macOS version and project are unknown. Source inspected read-only at local HEAD 27595564d8cfb59ae83c8b19c3f1f6038f469f31. The installed binary was not inspected.

## Suspected code

- `MarkView/Resources/Editor/vendor/js/markview-architecture.js:3118` — Toolbar rendering hides the date button unless the payload mode is PR; renderHistory at line 3178 also restricts the picker to PR mode.
- `MarkView/Resources/Editor/index.html:1443` — The entry point to the separate view is labeled “Pull request,” obscuring access to historical comparison.
- `MarkView/Models/WorkspaceManager.swift:1790` — Routes history and commit-selection messages to the architecture store; relevant when verifying the picker from ordinary X-Ray.
- `MarkView/Models/ArchitectureStore.swift:2764` — Loads commits for a selected day and handles comparison with the chosen commit; the existing path should be verified with the new entry point.
- `docs/features/x-ray-comparison-by-date/decisions/DEC-009.md:26` — Documents the existing placement in the PR X-Ray toolbar, which conflicts with the user's clarification that date comparison should not depend on PR.

## Likely causes

- Confirmed in source: toolbar rendering hides the date button outside PR mode, and history rendering separately requires PR mode.
- Likely discoverability cause: the route to the existing picker is labeled “Pull request,” although historical comparison does not require a pull request.

## Missing information

- The affected project, its Git history and the macOS version are unknown, but are not needed to begin fixing the confirmed visibility restriction.
- The reported experience and the eventual fix still need manual verification in the app.
- Whether the result remains in the current X-Ray or opens a separate comparison view has not been decided; this does not prevent investigation or a fix.

## Validity check

**Outcome:** Still present on main (checked 2026-11-08).

**Verified against:** `origin/main` @ `41b20d81f0` (2026-11-08) — docs: flexible-files-views-and-visible-agent-usage is implemented (PR #326, release v5.44.0)

**Reason:** In the snapshot, MarkView/Resources/Editor/vendor/js/markview-architecture.js hides the date comparison button unless the X-Ray payload mode is 'pr', and renderHistory also requires that mode. MarkView/Resources/Editor/index.html labels the entry to that separate view 'Pull request'. The history and commit-selection handlers exist, but ordinary project X-Ray still does not expose the requested date comparison entry point. The installed app was not independently checked.

## Clarifications

**BQ-1** Где вы искали выбор даты?
→ A. В обычном X-Ray проекта.

**BQ-2** Какая версия MarkView установлена?
→ 5.43.0

## Discussion

### Boris Tsekinovsky · 2026-11-08

Он не должен зависеть PR… Он сравнивает текущий код с датой (commit)

### AI · 2026-11-08

Теперь я понимаю проблему шире: сравнение с датой должно быть самостоятельной функцией X-Ray, доступной из обычного X-Ray проекта, без необходимости сначала открывать «Pull request» или иметь PR.

Проверка текущего исходного кода подтверждает ограничение: кнопка и список коммитов показываются только в режиме PR. При этом механизм выбора коммита и сравнения уже существует. В документации размещение в PR X-Ray было предложенным решением реализации, а не вашим требованием; ваше уточнение ему противоречит. Установленное приложение я не проверял. Изображений, прикреплённых к BUG-110, в репозитории не нашёл.

Для передачи в разработку предлагаю зафиксировать: в обычном X-Ray видна кнопка сравнения с датой; пользователь выбирает день и коммит, после чего видит различия между этим коммитом и текущей рабочей копией, включая несохранённые в Git изменения и новые файлы. Существующие правила выбора коммитов и отображения различий сохраняются.

Остался один вопрос о результате: сравнение должно отображаться прямо в текущем обычном X-Ray или допустимо после выбора коммита открыть отдельное представление сравнения, если вход и дальнейший интерфейс не требуют PR? Второй вариант позволит использовать существующее представление различий. После этого уточнения предложу подтвердить передачу в разработку; статус отчёта не менял.

## Original description

В X-Ray нет возможности выбрать сравнение текущего кода с какой-либо датой, вернее, коммита какой-то определенной даты. Мы это делали, но в UI это нигде не появилось.

## Resolution

Fixed in the batch branch fix/xray-and-review-batch (PR #331, 5.46.0). The project X-Ray toolbar now has the "Compare with a date…" button and its picker, not only the PR X-Ray. Choosing a commit opens the comparison view (the PR X-Ray tab, as a branch comparison does) with the working copy against that commit; no pull request is needed. Folder X-Rays have no comparison view and do not offer it. Decision on the open discussion question: the result opens in the existing comparison view, not in the current X-Ray, because that view already shows file diffs and the changed parts. Checked by tools/tests/xray-comparison-web-tests.sh (project X-Ray opens the picker, lists commits, asks to compare with exactly the chosen one; folder X-Ray hides it). Not checked by hand in the installed app.
