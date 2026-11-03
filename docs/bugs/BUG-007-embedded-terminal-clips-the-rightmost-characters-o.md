---
type: bug
id: BUG-007
title: Embedded terminal clips the rightmost characters of lines (Claude Code, Codex)
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-27
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: Сколько обрезается справа и меняется ли это при изменении ширины панели?
    why: Постоянно ~1 символ указывает на скроллбар/округление; если после ресайза исправляется — на неверные метрики шрифта при старте.
    options:
      - label: Всегда ~1 символ
        text: Обрезается примерно один символ независимо от ширины
      - label: Исправляется ресайзом
        text: После изменения размера панели/окна текст помещается
      - label: Больше/по-разному
        text: Обрезается несколько символов, зависит от ширины
    status: answered
    answer: Всегда ~1 символ. Обрезается примерно один символ независимо от ширины
  - id: BQ-2
    text: Обрезается ли и обычный вывод shell (например, длинная строка `printf '%*s\n' $COLUMNS | tr ' ' =`), или только в Claude/Codex?
    why: Отличает проблему расчёта колонок от поведения конкретных TUI.
    options:
      - label: Да, тоже
        text: Обычный вывод тоже обрезается
      - label: Только TUI
        text: Только в Claude/Codex
    status: skipped
    answer: The user does not know.
  - id: BQ-3
    text: На каком экране это видно?
    why: Дробное масштабирование и внешние мониторы влияют на округление ширины ячейки.
    options:
      - label: Встроенный Retina
        text: Экран MacBook
      - label: Внешний монитор
        text: Внешний дисплей
      - label: Оба
        text: Везде
    status: answered
    answer: Внешний монитор. Внешний дисплей
  - id: BQ-4
    text: Воспроизводится ли обрезка на встроенном экране MacBook (Retina), если перенести окно туда?
    why: "Так станет понятно, в чём причина: в округлении при нестандартном devicePixelRatio внешнего монитора или в скроллбаре и вёрстке, которые не зависят от экрана."
    options:
      - label: Да, тоже обрезается
        text: Скорее всего, дело в скроллбаре или вёрстке
      - label: Нет, там всё видно
        text: Скорее всего, дело в DPR и округлении
      - label: Не могу проверить
        text: Встроенного экрана нет
    status: answered
    answer: Не могу проверить. Встроенного экрана нет
  - id: BQ-5
    text: Какое разрешение и режим масштабирования у внешнего монитора (Системные настройки → Дисплеи)?
    why: При DPR 1 или в масштабированном режиме ошибка округления в расчёте колонок становится вероятнее; от этого зависит, какую причину проверять первой.
    options:
      - label: Нативное, без масштабирования (например, 1920×1080)
        text: DPR 1
      - label: Масштабированный режим ("Looks like …")
        text: Дробный или HiDPI-режим
      - label: Не знаю
        text: Не проверял
    status: answered
    answer: 3440x1440
  - id: BQ-6
    text: Когда текст обрезан, видна ли справа от последнего символа полоса прокрутки или хотя бы узкий фон (отступ ~4px), или символ обрезан прямо по краю панели?
    why: Если символ пропадает под полосой прокрутки, виноват скроллбар xterm. Если он уходит за край панели, значит, веб-вью шире видимой области.
    options:
      - label: Под полосой прокрутки
        text: Символ скрыт за полосой прокрутки или она его перекрывает
      - label: Прямо по краю
        text: Обрезано ровно по краю панели, отступа справа нет
      - label: Не знаю
        text: Не могу определить
    status: answered
    answer: Прямо по краю. Обрезано ровно по краю панели, отступа справа нет
  - id: BQ-7
    text: Выполните в терминале MarkView `printf '%*s\n' $COLUMNS | tr ' ' =` и сравните с `tput cols`. Последний символ «=» обрезан так же, как в Claude/Codex?
    why: Это покажет, проблема в подгонке терминала под ширину (обрезается всё) или в том, как Claude/Codex рисуют строки.
    options:
      - label: Да, обрезан
        text: Последний «=» обрезан так же
      - label: Нет, виден целиком
        text: Строка видна полностью, с отступом справа
    status: answered
    answer: Сам выполни
  - id: BQ-8
    text: Слева в терминале между краем панели и первым символом виден обычный отступ (около 8px), или текст тоже прижат к левому краю или частично срезан?
    why: Так можно отличить веб-вью, сдвинутый вправо, от веб-вью, который шире панели или неправильно рассчитывает количество колонок.
    options:
      - label: Отступ слева есть
        text: Слева виден нормальный небольшой отступ
      - label: Прижат к краю
        text: Текст начинается прямо у левого края, отступа нет
      - label: Срезан и слева
        text: Первый символ тоже частично обрезан
      - label: Не уверен
        text: Не могу сказать
    status: answered
    answer: Отступ слева есть. Слева виден нормальный небольшой отступ
issue: "#33"
---

# Embedded terminal clips the rightmost characters of lines (Claude Code, Codex)

## Summary

The embedded terminal (xterm.js + FitAddon in WKWebView) clips about one character at the right edge of full-width lines in Claude Code and Codex. The clip is flush with the panel edge and the 4px right padding is not visible, while the 8px left padding is. The loss stays at about 1 column at any panel width. Seen on a single 3440x1440 external display.

## Steps to reproduce

1. Use a 3440x1440 external monitor as the only display and open MarkView on it
2. Open the embedded terminal panel
3. Run `claude` or `codex` and produce full-width output (optionally also run `printf '%*s\n' $COLUMNS | tr ' ' =` and compare with `tput cols`)
4. Look at the right and left edges of the terminal panel
5. Resize the panel and repeat

## Expected

All term.cols columns are fully visible inside #term, with the 8px left padding and the 4px right padding both visible.

## Actual

About 1 character of each full-width line is clipped exactly at the panel's right edge, with no visible right padding. The 8px left padding looks normal. The amount of clipping stays the same at any panel width.

## Environment

MarkView macOS app (WKWebView, xterm.js with FitAddon, fontFamily "SF Mono", Menlo, Monaco, monospace, fontSize 12, lineHeight 1.15; html/body overflow:hidden; #term position:absolute, inset 6px 4px 4px 8px; refit() calls fit.fit() and posts cols/rows to the PTY). macOS Darwin 27, a single 3440x1440 external display and no built-in screen, so Retina cannot be compared. The scaling mode and devicePixelRatio are unknown; DPR 1 is inferred, not confirmed. Reproduced with the Claude Code and Codex CLIs. Screenshots: docs/bugs/assets/BUG-007-*.png.

## Suspected code

- `MarkView/Models/TerminalSession.swift` — Owns the host WKWebView. The left padding is visible, so the web view is not shifted. The likelier cause is a frame that is a constant few points wider than the visible panel, or a container that clips on the right. Either would hide the 4px padding and about 1 column.
- `MarkView/Resources/Editor/terminal.html` — refit() calls fit.fit() (line 129), and #term uses inset 6px 4px 4px 8px under body overflow:hidden. If FitAddon gets one column too many (cell-width rounding, or it reserves no width for the viewport scrollbar), the last column spills past the padding and is clipped at the page edge.
- `MarkView (the SwiftUI/AppKit view hosting the terminal panel)` — The layout that places the terminal panel next to other panes may give the WKWebView bounds larger than its visible area, for example an overlapping split divider or a safe-area inset.

## Likely causes

- The host WKWebView is a constant amount wider than the visible panel, or its right edge is covered or clipped by the container or a divider. This hides the page's right edge (4px padding plus about 1 column). A visible left padding with a constant right-side loss fits this best.
- FitAddon computes one extra column (cell-width rounding at DPR 1, or the scrollbar width is not reserved), and overflow:hidden clips the excess. This fits less well, because the 4px padding would usually still show.
- Cell metrics are measured before SF Mono loads. This is unlikely, because the error would grow with width rather than stay constant.

## Missing information

- Whether plain shell output (the printf test compared with tput cols) is also clipped. This needs a live app run, which the user declined to do.
- The macOS scaling mode and the actual devicePixelRatio
- While the bug is visible: term.cols, and the widths of #term, .xterm-screen, .xterm-viewport and window.innerWidth, compared with the WKWebView frame and the visible panel bounds

## Attachments

![assets/BUG-007-Screenshot at Sep 27 11-42-15.png](assets/BUG-007-Screenshot%20at%20Sep%2027%2011-42-15.png)
![assets/BUG-007-Screenshot at Sep 27 11-35-29.png](assets/BUG-007-Screenshot%20at%20Sep%2027%2011-35-29.png)

## Clarifications

**BQ-1** Сколько обрезается справа и меняется ли это при изменении ширины панели?
→ Всегда ~1 символ. Обрезается примерно один символ независимо от ширины

**BQ-3** На каком экране это видно?
→ Внешний монитор. Внешний дисплей

**BQ-4** Воспроизводится ли обрезка на встроенном экране MacBook (Retina), если перенести окно туда?
→ Не могу проверить. Встроенного экрана нет

**BQ-2** Обрезается ли и обычный вывод shell (например, длинная строка `printf '%*s\n' $COLUMNS | tr ' ' =`), или только в Claude/Codex?
→ The user does not know.

**BQ-5** Какое разрешение и режим масштабирования у внешнего монитора (Системные настройки → Дисплеи)?
→ 3440x1440

**BQ-6** Когда текст обрезан, видна ли справа от последнего символа полоса прокрутки или хотя бы узкий фон (отступ ~4px), или символ обрезан прямо по краю панели?
→ Прямо по краю. Обрезано ровно по краю панели, отступа справа нет

**BQ-7** Выполните в терминале MarkView `printf '%*s\n' $COLUMNS | tr ' ' =` и сравните с `tput cols`. Последний символ «=» обрезан так же, как в Claude/Codex?
→ Сам выполни

**BQ-8** Слева в терминале между краем панели и первым символом виден обычный отступ (около 8px), или текст тоже прижат к левому краю или частично срезан?
→ Отступ слева есть. Слева виден нормальный небольшой отступ

## Original description

В терминале, не важно, что я использую, например, кодекс или клод, он обрезает немножко с правой стороны текст. То есть такое ощущение, как будто бы этот элемент терминальный чуть-чуть вправо уходит от границы.

## Resolution

Fixed in MarkView 2.23.1 by [PR #39](https://github.com/t-boris/MarkView/pull/39), merged into main on 2026-09-27.

WebKit paints fractional glyph advances beyond xterm's rounded DOM row width, where the row's overflow:hidden clips the final glyph. The fix gives rows 8px of paint room in the existing right gutter without changing terminal columns or the PTY size.

Verification: native WebKit at DPR 1, seven widths from 300 to 3440px, normal and alternate buffers, styled/wide glyphs and scrolling. The original page fails 14 final-cell checks; the fixed page passes all 46. Terminal link checks (82) and editor line checks (9) pass. Debug and signed Release builds pass.
