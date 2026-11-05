# Discussion — Issue Lifecycle Management

### Answer to Q-001 · 2026-11-05

Какие события должны определять начало и завершение реализации issue?

C. Считать реализацию завершённой только после merge, проверок и необходимого выпуска; проверку приёмки отмечать отдельно.

### Answer to Q-002 · 2026-11-05

Какие полномочия должны быть у человека и AI при смене статуса?

B. Разрешить человеку принудительный переход с обязательной причиной; AI действует только по правилам.

### Answer to Q-003 · 2026-11-05

Как поступать, когда после завершения обнаружена регрессия или нужна дополнительная работа?

A. Повторно открывать исходный issue при регрессии; для новой самостоятельной работы создавать связанный issue.

### Answer to Q-004 · 2026-11-05

Какую силу имеют ручные закрытие и повторное открытие GitHub issue для связанных записей MarkView?

A. MarkView определяет локальные статусы; изменения GitHub учитываются как свидетельства и расхождения для проверки.

### Answer to Q-005 · 2026-11-05

Какие AI-сессии первая версия обязана охватывать?

A. Гарантировать контекст и автоматизацию для поддерживаемых сессий MarkView; внешние сессии подключать явно.

### Answer to Q-006 · 2026-11-05

Должна ли функция автоматически закрывать и повторно открывать связанные GitHub issues?

A. Автоматически закрывать и повторно открывать GitHub issue по проверенному состоянию всех связанных работ.

### Answer to Q-007 · 2026-11-05

Who may record acceptance verification of a feature (implemented → verified)?

B. A human, or AI when it supplies verification evidence and every acceptance criterion of the active requirements is ticked. (Boris, 2026-11-05, in the goal session: "Человек или AI с доказательствами".)

### Answer to Q-008 · 2026-11-05

What is a confirmed regression, and who may reopen the original issue for it?

A. A human in the UI (with a reason), or AI when a linked bug report names the original in regression_of and is not closed as invalid or duplicate. A failing check alone only shows as a discrepancy. (Boris, 2026-11-05: "Человек в UI или AI по связанному багу".) Destinations chosen by the implementation: feature → implementing, bug → open.

### Answer to Q-009 · 2026-11-05

What does "verified completion" mean for automatic closure of a GitHub issue?

A. Implementation completed through evidence (merge, checks, required release) is verified completion: feature implemented or verified, bug fixed or closed after a fix. Overrides, archived without implementation, duplicate or invalid bugs and unknown status do not qualify. (Boris, 2026-11-05: "Реализация с доказательствами".)

### Boris · 2026-11-05

Answers to Q-007, Q-008 and Q-009 (goal session, 2026-11-05).

Q-007 Who may record acceptance verification? — B. A human, or AI with evidence (DEC-008).

Q-008 What is a confirmed regression and who reopens? — A. A human in the UI, or AI by a linked bug report (DEC-009).

Q-009 What is verified completion for GitHub closure? — A. Implementation with evidence (DEC-010).

Working-tree rule: documentation changes always go to main; when I see docs changes I may pick them up from any place and any branch.

### Claude · 2026-11-05

Implementation (5.36.0, goal session 2026-11-05). All of REQ-001..006 is built; every criterion is ticked where a standalone check, the Debug build or the code proves it. Recorded answers applied without asking again: Q-001..006, Q-007 B (DEC-008), Q-008 A (DEC-009), Q-009 A (DEC-010), and the rule that documentation always goes to main (BUG-065).

An independent review of the app-side glue found 13 problems; the real ones are fixed: (1) the hand-off prompts promised that MarkView completes implemented / fixed, but nothing did, so MarkView now completes work under way itself when the evidence is complete (DEC-016); (2) evidence is no longer cut off silently: documentation-only commits are dropped first, only work since the last start or reopening counts, and an unreadable window makes the verdict unknown; (3) features are found by a `Feature: <slug>` trailer as well as by docs/features/<slug> and linked issue numbers (DEC-012); (4) Sync asks GitHub first, reads evidence only for items linked to an open issue, and re-reads links just before each write; (5) the validity check's "already fixed" finding closes the bug as a cancellation and is no verified completion, because a model's finding is not delivery evidence (DEC-013 amended); (6) the Lifecycle section keeps no state of another issue; (7) a status that was written but whose record failed counts as reached; (8) restart refuses a move the rules would refuse before trashing files; (9) a single-bug hand-off refuses a bug that cannot start; (10) baseline and external-edit records are written only when the file shows that status; (11) the journal and the session links append with one O_APPEND write. Independent new work is created with `related` (REQ-002 criterion 5).

Known limits, not fixed: the release check compares a pull request's head, so a squash-merged pull request is not recognised as released (this repository merges with --merge; the result is unknown, never complete); "handed over" means the prompt was queued in the terminal, not that the agent read it; the journal is parsed whole on every request (fine for hundreds of records); the SwiftUI Lifecycle section and the menus are compiled and their logic is checked, but no automated UI test renders them.

Still `proposed`: DEC-011, DEC-012, DEC-013, DEC-014, DEC-015, DEC-016. They were implemented as written (DEC-012, DEC-013 amended as above) and wait for Boris to accept or change them.

### Boris · 2026-11-05

Asked to accept or change the still-proposed DEC-011, DEC-012, DEC-013, DEC-014, DEC-015 and DEC-016 (DEC-012 and DEC-013 as amended in the implementation), Boris answered "меняй, убедись что все в main" (2026-11-05): all six are accepted as written, and everything is to be in main. Recorded by setting the six decisions to accepted.
