---
type: feature
id: i-need-to-understand-a-real-answer-not
title: "I Need to Understand: a real answer, not only X-Ray highlights"
status: implemented
owner: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the feature intake
understanding:
  Problem: known
  Target Users: known
  Primary Workflow: known
  Permissions: n/a
  Failure Scenarios: known
  Data Model: known
  Notifications: n/a
  Security: known
  Analytics: n/a
  Dependencies: known
  Acceptance Criteria: known
issue: "#26"
understanding_notes:
  Problem: Все три возможные причины (нет ответа, он незаметен, он только про «где») закрываются вместе.
  Target Users: Пользователь MarkView, которому нужно разобраться в какой-то части проекта.
  Primary Workflow: Вопрос → X-Ray с раскрытым ответом справа → ссылки-доказательства → при желании сохранить как RES.
  Permissions: Локальное приложение, ролей нет.
  Failure Scenarios: Ошибка или пустой ответ показываются явно, с повтором; если источник происхождения не найден, это сказано в ответе.
  Data Model: Ответ со ссылками на источники; существующий формат RES-nnn.
  Notifications: Не требуются.
  Security: Используются только уже доступные git-история, PR и документы; новых секретов нет.
  Analytics: Не входит в объём.
  Dependencies: XRaySearch, WorkspaceManager.understandInXRay, git и PR, docs/research.
  Acceptance Criteria: Критерии заданы для REQ-001…004 и для нового требования о явной ошибке.
questions_left: 0
---

# I Need to Understand: a real answer, not only X-Ray highlights

## Idea

"I Need to Understand" should give the user an explained answer to the question they asked: what the thing is, why it exists, where it came from (docs, decisions, history) and how it works. X-Ray highlights stay as supporting evidence of where it lives, but the answer itself is the main result.

## Problem

Today (project fact: WorkspaceManager.understandInXRay, Done 21 in tasks/todo.md) the question is turned into a temporary X-Ray ⚡ filter and the architecture view opens with highlighted parts. The user reports getting only the visual 'where' and no answer to 'what is it / why is it here / where did it come from in the documentation'. XRaySearch's schema already asks for an `answer` field that is shown in the details panel. So the gap is one of these, and which one is not yet known (inference): the answer is not visible or noticeable enough, its content is about location instead of meaning and origin, or it is missing or failing for this kind of question.

## Scope

IN: the I Need to Understand flow (intake sheet and 'from document' entry) end to end; making an explanatory answer (what, why, origin/provenance in docs/decisions/requirements, how it works) the primary output; linking the answer to X-Ray places as evidence; saving the answer (existing docs/research RES-nnn). OUT: unrelated changes to New Feature / New Bug flows; X-Ray topic filters and edge explanations; new speech services; the X-Ray scanning and indexing pipeline, except where the answer needs it.

## Implemented in 2.23.0

The answer is shown first in X-Ray, with typed evidence, read-only history, explicit failures and Retry, and opt-in RES saves. User follow-ups on 2026-09-27 also authorize visible Dictate buttons in Understand and New Research, image paste in creation forms, and research from a folder including nested documents. See [verification](implementation/verification.md).
