# Discussion — Issues panel: status filters, sorting, status display and resizable width

### Answer to Q-003 · 2026-09-27

Как показать элементы управления фильтром и сортировкой в узкой панели?

AI: Вариант A с доработкой: рядом с полем Filter поставить две компактные меню-кнопки, воронку и сортировку. Когда фильтр не стандартный, воронка подсвечивается, а над списком появляется одна строка с текущим фильтром и кнопкой сброса.

### Answer to Q-004 · 2026-09-27

Какие значения статуса фичи считать Implemented, Open и Closed?

A. Implemented — это implemented/done. Closed — это implemented, rejected и cancelled. Open — всё остальное.

### Answer to Q-005 · 2026-09-27

Откуда брать дату и приоритет для сортировки, и куда ставить элементы без них?

B. Дата — updated (или время изменения файла); приоритет как в A; пустые — в конце.

### Answer to Q-006 · 2026-09-27

Должны ли выбранные фильтр и сортировка сохраняться после перезапуска приложения?

A. Да, для каждого проекта отдельно, между перезапусками (как features.active.<hash>).

### Answer to Q-002 · 2026-09-27

Откуда брать дату и приоритет для сортировки?

A. Поля front matter (created/updated/priority); если их нет, брать mtime файла

### Answer to Q-001 · 2026-09-27

Что значит «Implemented» для фичи: какие значения feature.status относятся к implemented, а какие к open и closed?

A. Один общий набор: Open = всё незавершённое, Closed = implemented/done для фич и closed/fixed для багов
