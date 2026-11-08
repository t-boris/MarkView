# Discussion — X-Ray Comparison by Date

### Answer to Q-001 · 2026-11-08

Какие коммиты должен показывать выбор даты?

A. Показывать коммиты, сделанные именно в выбранный календарный день.

### Answer to Q-002 · 2026-11-08

Что считать текущим кодом для сравнения?

A. Сравнивать выбранный коммит с рабочей копией, включая незакоммиченные изменения и новые файлы.

### Answer to Q-003 · 2026-11-08

Из какой истории выбирать коммиты?

B. Показывать коммиты всех доступных локально веток.

### Answer to Q-004 · 2026-11-08

Как показывать архитектуру при сравнении с выбранным коммитом?

C. Предоставить оба режима: сфокусированный и полную карту с выделением.

### AI updated the requirements · 2026-11-08

DEC-005 written into REQ-001.

### AI updated the requirements · 2026-11-08

DEC-006 written into REQ-003.

### Agent · 2026-11-08

Implementation on branch feat/x-ray-comparison-by-date (version 5.42.0). I-1: the PR X-Ray toolbar has "Compare with a date..." (a date field starting on today, then the commits of that day, or "No commits were made on this day."); commits come from git log --branches, filtered in Swift by committer time in the user's calendar day (DEC-001, DEC-003, DEC-005). I-2: the new source at:<full sha> compares the working copy (commits, uncommitted edits, new files) with that commit itself, not its merge base (DEC-002). I-3: the PR tab has a Focused / Full map switch; removed files are marked nodes (cross, dashed red outline, "removed -N") on both maps, standing in the nearest surviving component or folder, with their diff one click away (DEC-004, DEC-006). I-4: the overlay menu works in the PR tab; changed parts keep a halo and their "+added -removed" count whatever overlay colours them. Three choices the specification left open were applied by default and are recorded as proposed: DEC-007 (local branches only, not remote-tracking refs), DEC-008 (the map switch and the overlay menu serve every PR X-Ray source, not only this one), DEC-009 (the picker lives in the PR X-Ray toolbar; a rename reads as a removed and an added file). Evidence: tools/tests/historical-baseline-tests.sh (real git, mutation-checked) and tools/tests/xray-comparison-web-tests.sh (WebKit, 91 checks; the old page fails 67 of the first 80; targeted mutations of the new code each fail the checks that guard them). An independent review found three page-state defects (a tap on an untouched file left the full map, the risk colour overrode another overlay, the full map shared its open parts with the project view); all fixed with checks. Acceptance criteria stay unticked until the installed app is checked by hand.

### Agent · 2026-11-08

Correction to the previous note: the WebKit suite tools/tests/xray-comparison-web-tests.sh has 86 passing checks (not 91); 67 of the first 80 failed on the old page.
