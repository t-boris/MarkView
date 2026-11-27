---
type: bug
id: BUG-128
title: Copilot offers only retry after a failed prerequisite and clips the step route
status: done
severity: high
reporter: Boris Tsekinovsky
created: 2026-11-25
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: После остановки вы открывали экран плана и пробовали изменить текущий шаг?
    why: "Это поможет понять, где искать проблему: в переходе с экрана ошибки или в применении правки к приостановленному запуску."
    options:
      - label: План не открывал
        text: Остался на экране запуска с кнопкой Retry prerequisite.
      - label: Открыл, изменить не смог
        text: На экране плана не удалось отправить или применить правку.
      - label: Правку удалось применить
        text: Удалось утвердить изменения для того же запуска.
    status: answered
    answer: Открыл, изменить не смог. На экране плана не удалось отправить или применить правку.
  - id: BQ-2
    text: Что было сказано в исходном задании про вход и создание тестового аккаунта на продакшене?
    why: Это покажет, мог ли агент выбрать разрешённый способ продолжить проверку или ему действительно не хватало указаний.
    status: answered
    answer: Ничего он сам так решил
  - id: BQ-3
    text: Удалось ли прокрутить последовательность вправо и увидеть шаг 9?
    why: Это поможет отличить незаметную прокрутку от проблемы с доступом к последнему шагу.
    options:
      - label: Шаг 9 виден после прокрутки
        text: Горизонтальная прокрутка показала последний шаг.
      - label: Шаг 9 остался обрезан
        text: Попытка прокрутить последовательность не показала последний шаг.
      - label: Не пробовал
        text: Видел только обрезанный край последовательности.
    status: answered
    answer: Шаг 9 остался обрезан. Попытка прокрутить последовательность не показала последний шаг.
  - id: BQ-4
    text: На каком этапе в Plan вы остановились? Если на экране было сообщение, укажите его текст.
    why: "Это поможет определить, где искать причину: в редактировании, в проверках перед утверждением или в применении уже утверждённой правки."
    options:
      - label: Отправка правки
        text: Не удалось отправить текст правки или сохранить изменение шага.
      - label: Просмотр изменений
        text: Правку внёс, но кнопка просмотра и утверждения была недоступна или отсутствовала.
      - label: После утверждения
        text: Утвердил изменения, но они не применились или появилась ошибка.
    status: answered
    answer: Отправка правки. Не удалось отправить текст правки или сохранить изменение шага.
  - id: BQ-5
    text: Чем и каким жестом вы пытались прокрутить маршрут вправо?
    why: Устройство и жест помогут воспроизвести ситуацию, в которой последний шаг остался недоступен.
    status: answered
    answer: There is  no tools for scrolling
  - id: BQ-6
    text: Что именно произошло в Plan, когда вы попытались отправить правку?
    why: "Это поможет проверить нужный путь в коде: доступность кнопки, ответ планировщика или сохранение прямой правки шага."
    options:
      - label: Кнопка недоступна
        text: Текст был введён, но «Revise plan» нельзя было нажать.
      - label: Нажатие без результата
        text: «Revise plan» нажалась, но я не увидел ни изменений, ни ошибки.
      - label: Появилась ошибка
        text: После нажатия появилось сообщение. Если помните, укажите его текст.
      - label: Правил сам шаг
        text: Я редактировал шаг напрямую. Изменение не сохранилось или я не нашёл, как его сохранить.
    status: answered
    answer: Кнопка недоступна. Текст был введён, но «Revise plan» нельзя было нажать.
  - id: BQ-7
    text: Когда текст уже был введён, а «Revise plan» оставалась недоступной, был ли на экране Plan индикатор работы или кнопка «Stop» рядом с кнопкой построения плана?
    why: Это поможет проверить, блокировало ли кнопку состояние планирования, и понять, нужно ли в первую очередь проверять, как поле передаёт введённый текст.
    options:
      - label: Да
        text: Был виден индикатор работы или кнопка «Stop».
      - label: Нет
        text: Ни индикатора работы, ни кнопки «Stop» не было.
      - label: Не помню
        text: Не могу уверенно сказать.
    status: answered
    answer: Не помню. Не могу уверенно сказать.
issue: "#440"
schema: 1
---

# Copilot offers only retry after a failed prerequisite and clips the step route

## Summary

A failed Cockpit prerequisite leaves retry as the failure banner’s only action, while an accepted same-run revision can bypass the unresolved prerequisite and launch a dependent step. The nine-step route clips its final waypoint without a visible overflow cue. The reported disabled refinement and unsuccessful direct edit still need controlled reproduction.

## Steps to reproduce

1. Start a nine-step Cockpit QA run in a signed-out session. Use a controlled chat fixture that redirects to sign-in on submission and has no test account. Make the first step a prerequisite that requires a chat response, and leave sign-in and account creation unspecified in the task.
2. Submit a chat message, let the prerequisite fail, and inspect the pause reason and the failure banner’s available actions.
3. Open Plan, expand “Ask the Copilot to revise this plan,” and type nonblank text. Record whether “Revise plan” enables and whether planner progress or Stop is visible.
4. Separately edit the first step’s title. Check whether the draft updates immediately, then reopen Plan and check whether the change persists and is eligible for review on the same run.
5. On a controlled paused run, approve an otherwise eligible changed plan with “Start from” set to a later dependent step. Check whether it dispatches before a passing prerequisite result and whether earlier result entries retain their original fingerprints.
6. Narrow the route until waypoint 9 is clipped. Check for a visible overflow cue and try to reveal and select waypoint 9. Record the route width, input device, and gesture.

## Expected

When a prerequisite fails, the banner should state the specific input or decision needed and let the user respond or open Plan directly. If the approved plan authorizes a bounded recovery attempt, Cockpit should attempt it and rerun the prerequisite. If the blocker persists, Cockpit should request the required input and keep dependent steps paused until the prerequisite passes. REQ-003 and DEC-014 establish the pass requirement. DEC-016 permits an arbitrary starting step but leaves its interaction with a known failure during same-run revision unspecified. A nonblank refinement should be submittable while planning is idle, and any blocker should be visible. Direct edits should update the draft immediately, survive reopening Plan, and be reviewable on the same paused run when eligible. Earlier results should keep their original plan fingerprints. An overflowing route should visibly indicate additional waypoints and let the user reach and select each one.

## Actual

The screenshot shows step 1 of 9 paused with “Needs you.” The failure banner says the chat submission redirected to sign-in, no production test account was known, and the supervisor advised against account creation and Google OAuth. “Retry prerequisite” is the banner’s only action. The reporter confirmed that the original task gave no instructions about sign-in or account creation. In Plan, the reporter entered text and found “Revise plan” disabled. They could not recall whether planner progress or “Stop” was visible. They also reported being unable to apply a direct edit, with the field and persistence outcome unknown. Source review confirms that an accepted revision can clear the pause and dispatch a later dependent step before the prerequisite passes. Existing result entries retain their original plan fingerprints. The screenshot shows waypoint 9 clipped without a visible overflow cue, and the reporter found no visible scrolling controls.

## Environment

MarkView for macOS, Copilot Cockpit, nine-step production QA run for vivaa.ai. The screenshot identifies the step agent as Codex with gpt-6-luna. Reviewed the attached screenshot, requirements, decisions, and source at local HEAD and origin/main, both at bbc1e0ee. Installed MarkView and macOS versions are unknown. No live reproduction was performed.

## Suspected code

- `MarkView/Views/Cockpit/CockpitRunScreen.swift` — The failed-step banner displays diagnostic text and exposes only Retry prerequisite for a live paused prerequisite.
- `tools/cockpit-temporal/workflow.go` — The failed-step loop applies a pending revision by changing the current index and clearing the pause. It does not recheck the failed prerequisite before dispatch.
- `MarkView/Views/Cockpit/CockpitPlanScreen.swift` — The refinement editor binds to session.refinement. Submission depends on planner busy state and trimmed text, while review and approval have separate eligibility checks.
- `MarkView/Views/Cockpit/CockpitStepCard.swift` — Direct field changes call session.editPlan and are independent of refinement submission.
- `MarkView/Models/Cockpit/CockpitSession.swift` — Owns the planner state, updates directly edited drafts in memory, and schedules draft persistence.
- `MarkView/Views/Cockpit/CockpitFlightPath.swift` — Renders fixed-width selectable waypoints inside a horizontal scroll view with hidden indicators and no overflow cue.

## Likely causes

- The failure banner renders the agent’s diagnostic as text and offers retry. The workflow has no structured response or bounded recovery path for a failed prerequisite.
- The revision acceptance checks validate the plan and selected index. The failed-step loop then applies the revision and clears the pause without checking whether the selected step depends on the failed prerequisite.
- The refinement button is disabled while planning is busy or the bound text trims to empty. The report establishes that the user entered text, but the runtime binding and planner state are unknown. Direct edits use a separate path.
- Nine 116-point cells require 1,044 points of horizontal space. The route hides scroll indicators and provides no other visible overflow cue.

## Missing information

- A controlled Plan reproduction capturing the bound refinement text, planner busy state, and progress or Stop visibility at the same time.
- The direct-edit field and whether the value appeared immediately, survived reopening Plan, and reached same-run review.
- Installed MarkView and macOS versions, the route viewport width, and which input device and gesture were used. The clarification establishes that no controls were visible.
- The generated prerequisite assignment and supervisor exchange, if the source of the authentication decision needs to be traced beyond the banner’s account.

## Validity check

**Outcome:** Still present on main (checked 2026-11-25).

**Verified against:** `origin/main` @ `bbc1e0eed4` (2026-11-24) — docs(BUG-128): record the Copilot prerequisite retry and clipped step route report

**Reason:** In the supplied bbc1e0eed4 snapshot, CockpitRunScreen.swift:103 and 135–138 still give the failed-prerequisite banner only “Retry prerequisite.” Plan navigation and Radio notes are available separately. In workflow.go:197–200 and 249–283, the failure loop has no structured request for the missing input or bounded recovery branch. An eligible revision can clear the pause and dispatch a later dependent step before the failed prerequisite passes. Earlier results retain their original plan fingerprints. CockpitFlightPath.swift:35–45 and 67–90 lays out nine 116-point waypoints in a horizontal scroll view with hidden indicators, so a narrow viewport can clip waypoint 9 without an overflow cue. CockpitPlanScreen.swift enables refinement when planning is idle and the bound text is nonblank, and shows progress and Stop in the Planner row while busy. Direct title edits update the session plan immediately, and eligible changes can be reviewed on the same paused run. Source inspection did not establish why the reporter’s refinement button was disabled, whether the reported edit survived reopening Plan, or whether their scroll attempt could reveal and select waypoint 9. Those observations require a controlled app reproduction.

## Attachments

![assets/BUG-128-pasted-image-9C0A50F3-ABF8-4401-A00E-A7AF4A9867C2.png](assets/BUG-128-pasted-image-9C0A50F3-ABF8-4401-A00E-A7AF4A9867C2.png)

## Clarifications

**BQ-1** После остановки вы открывали экран плана и пробовали изменить текущий шаг?
→ Открыл, изменить не смог. На экране плана не удалось отправить или применить правку.

**BQ-3** Удалось ли прокрутить последовательность вправо и увидеть шаг 9?
→ Шаг 9 остался обрезан. Попытка прокрутить последовательность не показала последний шаг.

**BQ-4** На каком этапе в Plan вы остановились? Если на экране было сообщение, укажите его текст.
→ Отправка правки. Не удалось отправить текст правки или сохранить изменение шага.

**BQ-6** Что именно произошло в Plan, когда вы попытались отправить правку?
→ Кнопка недоступна. Текст был введён, но «Revise plan» нельзя было нажать.

**BQ-7** Когда текст уже был введён, а «Revise plan» оставалась недоступной, был ли на экране Plan индикатор работы или кнопка «Stop» рядом с кнопкой построения плана?
→ Не помню. Не могу уверенно сказать.

**BQ-2** Что было сказано в исходном задании про вход и создание тестового аккаунта на продакшене?
→ Ничего он сам так решил

**BQ-5** Чем и каким жестом вы пытались прокрутить маршрут вправо?
→ There is  no tools for scrolling

## Original description

Капайлот, в принципе, не функционален, поскольку после остановки я могу только перезапустить его. Я не могу его изменить, сказать что-то там подправить и так далее. Он совершенно не функционален. И самое главное, понимаешь, он, капайлот, идея его в том, что он сам многие вещи делает. То есть, что он сам не смог догадаться, он остановился на том, что нужно залогиниться и не смог понять, что нужно создать аккаунт. То есть, это как-то странно. Мне кажется, капайлот подумай насчет имплементации этого капайлота, как оно сделано. Как зациклить некоторые вещи. То есть, есть ли что делать, если он падает. Он должен что? Фиксить это все, повторить заново, перейти на другой шаг сразу. Или ветка какая-то там должна быть. То есть, это должно быть более автоматизировано. Так что, это конкретный баг. Ну и, конечно, посмотри на UI баг, который я тебе скинул. Там последовательность не влазит по ширине.
