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
