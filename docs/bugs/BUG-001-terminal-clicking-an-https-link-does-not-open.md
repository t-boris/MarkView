---
type: bug
id: BUG-001
title: "Terminal: clicking an https link does not open the browser; file paths are not clickable at all"
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-26
provenance: Created from the bug intake
issue: "#11"
questions:
  - id: BQ-1
    text: Подчёркивается ли ссылка при наведении мыши, и как вы кликали?
    why: Если подчёркивания нет, ссылку не распознаёт аддон. Если оно есть, но ничего не открывается, сообщение теряется по пути в Swift.
    options:
      - label: Подчёркивается, обычный клик
        text: Ссылка подчёркнута, кликал без модификаторов
      - label: Подчёркивается, Cmd+клик
        text: Ссылка подчёркнута, кликал с Cmd
      - label: Не подчёркивается
        text: При наведении ссылка никак не выделяется
    status: answered
    answer: Подчёркивается, Cmd+клик. Ссылка подчёркнута, кликал с Cmd
  - id: BQ-2
    text: "Откуда была ссылка: вы сами её напечатали (echo) или её вывела программа (например, gh, Claude Code, ls --hyperlink)?"
    why: Программы часто выводят ссылки в формате OSC 8. Такие ссылки в терминале сейчас вообще не обрабатываются, а обычный текстовый URL проходит через другой путь.
    options:
      - label: Обычный текст
        text: URL виден в выводе целиком как текст
      - label: Вывод программы
        text: Ссылку вывела утилита или ассистент, текст мог отличаться от адреса
      - label: Не знаю
        text: Не уверен
    status: answered
    answer: Вывод программы. Ссылку вывела утилита или ассистент, текст мог отличаться от адреса
  - id: BQ-3
    text: Как должен открываться файл по клику на путь?
    why: Это решение о поведении, без него нельзя реализовать ссылки на файлы.
    options:
      - label: Вкладка MarkView
        text: Поддерживаемые файлы открываются во вкладке MarkView (со строкой), остальные — в приложении по умолчанию
      - label: Всегда приложение по умолчанию
        text: Открывать через системное приложение
    status: answered
    answer: Вкладка MarkView. Поддерживаемые файлы открываются во вкладке MarkView (со строкой), остальные — в приложении по умолчанию
  - id: BQ-4
    text: Попробуйте выполнить в терминале MarkView `echo https://github.com` и кликнуть по ссылке с Cmd. Открывается ли браузер?
    why: "Так станет ясно, какой путь сломан: обычные URL, которые находит WebLinksAddon, или OSC 8 гиперссылки, которые выводят программы. Исправления для них разные."
    options:
      - label: Открывается
        text: С echo работает, не открываются только ссылки из программ
      - label: Не открывается
        text: Даже ссылка из echo не открывается
      - label: Не проверял
        text: Нет возможности проверить
    status: answered
    answer: Не проверял. Нет возможности проверить
  - id: BQ-5
    text: Какая именно программа вывела ссылку?
    why: Если это полноэкранная программа вроде Claude Code, она может сама перехватывать клики мыши. Тогда причина другая, чем при обычном выводе утилиты (например, gh).
    options:
      - label: Claude Code
        text: Ссылку вывел Claude Code (полноэкранный интерфейс)
      - label: CLI-утилита
        text: "Обычная утилита: gh, git, ls --hyperlink и т. п."
      - label: Другое
        text: Другая программа
    status: answered
    answer: Claude Code. Ссылку вывел Claude Code (полноэкранный интерфейс)
---

# Terminal: clicking an https link does not open the browser; file paths are not clickable at all

## Summary

In MarkView's built-in terminal (xterm.js in WKWebView), Cmd+clicking an OSC 8 hyperlink printed by Claude Code (full-screen TUI) did not open the browser, and file paths were not clickable. The problem was reproduced in a native WKWebView harness. Root cause: terminal.html configured no xterm `linkHandler`, so activating an OSC 8 link fell back to confirm()/window.open. WKWebView (no WKUIDelegate) ignored that fallback. Under mouse tracking, Cmd+click also leaked mouse reports to the TUI. Plain URLs worked through WebLinksAddon. File-path links did not exist. Fixed in 2.17.0.

## Steps to reproduce

1. Open a folder in MarkView and choose 'Open Terminal Here'.
2. Run `printf '\e]8;;https://github.com\e\\link\e]8;;\e\\\n'`, hover 'link' (underlined) and Cmd+click it: no browser opens (confirm() fallback, no `link` message reaches Swift).
3. Enable mouse tracking (e.g. run `claude` full-screen, or modes 1000/1002/1003) and Cmd+click an OSC 8 link: no browser opens, and mouse-down/up reports are sent to the TUI.
4. Control: `echo https://github.com` + Cmd+click sends one `link` message (works, verified in the harness).
5. Run `grep -n foo *.md` or print `README.md:42:3` and click the path: it is not a link.

## Expected

Cmd+click on any http/https link (regex-detected or OSC 8, including inside mouse-tracking TUIs) opens it in the default browser, and the TUI receives no mouse report. Clicking an existing file path (absolute or relative to the shell cwd, optionally with :line[:col]) opens openable files in a MarkView tab at that line, and other files in the default app.

## Actual

OSC 8 links are underlined on hover, but Cmd+click triggers xterm's default confirm()/window.open, which WKWebView drops, so nothing opens. With mouse tracking on, the click is also forwarded to the TUI. File paths are never recognised as links.

## Environment

MarkView macOS app (SwiftUI + WKWebView), macOS Darwin 27.0.0. Terminal: xterm.js + @xterm/addon-web-links (vendor/js/xterm.bundle.js). Link source: Claude Code in full-screen mode (OSC 8). Reproduced before 2.17.0; fixed in 2.17.0.

## Suspected code

- `MarkView/Resources/Editor/terminal.html` — No `linkHandler` for OSC 8 links. Cmd+click is not intercepted before mouse reporting. No file-path link provider.
- `MarkView/Models/TerminalSession.swift` — The 'link' handler accepted only http(s) URLs. There was no cwd-aware file resolution or file-open route.
- `MarkView/Views/EditorView.swift` — Reference open-file-at-line behaviour. Markdown and structured views needed line reveal.

## Likely causes

- Confirmed: the missing xterm `linkHandler` made OSC 8 activation fall back to confirm()/window.open, which WKWebView ignores without a WKUIDelegate.
- Confirmed: under VT200/SGR mouse tracking, Cmd+click was also delivered as mouse reports to the TUI.
- Confirmed: file-path links were not implemented (feature gap).
- Ruled out as the primary cause: plain regex URLs worked through WebLinksAddon.

## Missing information

- None. On 2026-09-26 the reporter confirmed that Cmd+click on Claude Code links now works in the installed 2.17.0 app, with a physical mouse.

## Clarifications

**BQ-1** Подчёркивается ли ссылка при наведении мыши, и как вы кликали?
→ Подчёркивается, Cmd+клик. Ссылка подчёркнута, кликал с Cmd

**BQ-2** Откуда была ссылка: вы сами её напечатали (echo) или её вывела программа (например, gh, Claude Code, ls --hyperlink)?
→ Вывод программы. Ссылку вывела утилита или ассистент, текст мог отличаться от адреса

**BQ-3** Как должен открываться файл по клику на путь?
→ Вкладка MarkView. Поддерживаемые файлы открываются во вкладке MarkView (со строкой), остальные — в приложении по умолчанию

**BQ-4** Попробуйте выполнить в терминале MarkView `echo https://github.com` и кликнуть по ссылке с Cmd. Открывается ли браузер?
→ Не проверял. Нет возможности проверить

**BQ-5** Какая именно программа вывела ссылку?
→ Claude Code. Ссылку вывел Claude Code (полноэкранный интерфейс)

## Original description

В терминале, если есть там ссылка какая-то, у меня не получается открыть ссылку. То есть он не открывает браузер, например, если это HTTPS-ссылка. Ну и вообще ссылки на файлы он должен тоже открывать соответствующий файл сразу.


## Resolution (2026-09-26, 2.17.0)

Reproduced in a separate native WKWebView using the shipping terminal page and xterm bundle,
before changing the app:

- Plain `https://github.com` sent one `link` message to Swift.
- The OSC 8 `link` label invoked browser `confirm()` and sent no `link` message. With no
  WKUIDelegate, that fallback did not open a browser.
- With VT200/SGR mouse tracking enabled, the same Cmd+click also emitted mouse-down and
  mouse-up PTY reports to the TUI.
- `README.md:42:3` produced no link message.

The root cause was the missing OSC 8 `linkHandler`, as described in the
[xterm option documentation](https://xtermjs.org/docs/api/terminal/interfaces/iterminaloptions/#optional-linkhandler).
The WebLinksAddon handled only plain URLs. File paths had no link provider or native route.

The fix configures both URL providers to send targets through the native bridge, shows the
actual target on hover, and reserves Cmd+click for link activation before mouse events reach
the TUI. Ordinary TUI clicks and mouse modes remain active. A file provider asks Swift to
validate existing files off the main thread; it supports absolute/relative paths, quoted
paths, `:line[:column]`, grep output and OSC 8 file URLs. Native resolution uses the
foreground process/shell cwd, including after `cd`. Supported files open through the
workspace's existing tab API, others through NSWorkspace. Markdown and structured documents
now reveal the requested line too, alongside the existing code viewer. Unsafe schemes,
missing files and directories receive no native action.

Verification:

- `tools/tests/terminal-link-tests.sh`: **71 terminal checks + 9 editor checks passed** in
  real WKWebView using the shipping assets and TerminalSession handler. Includes OSC 8
  labels, plain URLs, alternate-screen TUIs with modes 1000/1002/1003, no mouse reports on
  Cmd+click, normal TUI clicks, file routing, wide/combining characters, wrapped paths,
  right-click handling, and relative links after a real shell `cd`.
- `tools/tests/terminal-link-tests.sh --open-browser`: the extra actual OSC 8 Cmd+click
  returned success from `NSWorkspace.open`; the system default handler was Google Chrome.
- Editor checks confirm Markdown front-matter line offsets and visible preview scrolling,
  source selection/scrolling for Markdown and JSON, and queued code-viewer line navigation.
- Debug and Release builds succeeded; the signed Release app passed strict codesign verification.
  The fix adds no vendor dependency and uses the existing bundle.

The tests use deterministic OSC 8 and TUI mouse-mode output; they do not make a Claude API
request. Reproduction and verification do not require a particular assistant response.

## Re-verification (2026-09-26)

- Reproduced again before the fix: the shipping harness was run against the pre-fix `terminal.html`
  (`85b6f8d^`) and failed 34 of 71 checks. OSC 8 Cmd+click sent no `link` message, and mouse modes
  1000/1002/1003 leaked `<0;2;1M` reports to the TUI.
- Added Claude Code-shaped cases to `tools/tests/TerminalLinkTests.swift`. They use the
  Ink/ansi-escapes BEL terminator, `id=` params and a bold mid-line label, in an alternate screen
  with SGR modes 1002/1003. The pre-fix page fails all 9 (no `link`, 2–4 PTY mouse reports). The
  fixed page passes all 9.
- `tools/tests/terminal-link-tests.sh`: **80 terminal + 9 editor checks, 0 failures**.
- The installed `/Applications/MarkView.app` (2.17.0) bundles the same `terminal.html` as `HEAD`.
- Live Claude Code check, outside the repo, run once: real `claude` 2.1.283 (`"tui": "fullscreen"`, Haiku)
  ran in the real `TerminalSession` PTY with the shipping `terminal.html`, in a WKWebView window.
  It was asked to print `Docs at https://github.com/anthropics/claude-code and file README.md`.
  Its raw output contains `ESC]8;id=…;https://…BEL` and enables modes 1049/1000/1002/1003/1006/1004.
  The hover was sent as DOM `mousemove` events, since synthesized AppKit mouseMoved events do not reach
  WebKit. The click was a real AppKit Cmd+`leftMouseDown`/`leftMouseUp` pair.
  - Pre-fix page (`85b6f8d^`): the link was underlined, but Cmd+click sent no `link` message and
    `README.md` was not a link. This is the reported behaviour.
  - 2.17.0 page: the tooltip showed the target. Cmd+click sent exactly one `link` message, and the URL
    reached `openExternalURL`. Claude Code received 0 mouse reports. Cmd+click on `README.md` opened
    `<repo>/README.md` through `openFile`.

### Known limitation (decision 2026-09-26)

A long OSC 8 link that a TUI breaks across rows with cursor moves opens the full target from
either row (regression check "OSC 8 link hard-wrapped by TUI"). A plain-text URL (not OSC 8)
broken the same way opens truncated, because the terminal has no signal that the rows belong
together. Other terminals behave the same way. The reporter chose to leave this as is and not add
a row-continuation heuristic. Suite: **82 terminal + 9 editor checks, 0 failures**.
