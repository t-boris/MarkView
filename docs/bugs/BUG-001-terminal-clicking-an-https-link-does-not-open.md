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

In MarkView's built-in terminal (xterm.js in WKWebView), Cmd+clicking an underlined https link printed by Claude Code (full-screen TUI) does nothing: no browser opens. File paths in terminal output are not clickable at all. Code review: terminal.html sets no `linkHandler`, so OSC 8 hyperlinks (which Claude Code emits, with link text that can differ from the URL) fall back to xterm's default confirm()/window.open. WKWebView ignores these because there is no WKUIDelegate. Only WebLinksAddon (regex-detected URLs) posts {type:'link'} to Swift. TerminalSession drops non-http(s) URLs and unparsable URLs silently. Claude Code's full-screen UI may also enable mouse tracking, which can route clicks to the app instead of xterm link activation. File-path links are not implemented.

## Steps to reproduce

1. Open a folder in MarkView and choose 'Open Terminal Here' in the file tree.
2. Run `printf '\e]8;;https://github.com\e\\link\e]8;;\e\\\n'`, hover 'link' (it is underlined) and Cmd+click it. No browser opens.
3. Run `claude` (Claude Code, full-screen UI), get it to print a link, hover it and Cmd+click it. No browser opens.
4. For comparison, run `echo https://github.com` and Cmd+click the URL (the WebLinksAddon path). This result has not been verified yet.
5. Run `ls -1` or `grep -n foo *.md` and try to click a file path. It is not a link.

## Expected

Cmd+clicking any http/https link opens it in the default browser. This applies to regex-detected links and OSC 8 links, including links inside mouse-tracking TUIs such as Claude Code. Clicking a file path (absolute, or relative to the terminal cwd, optionally with :line[:col]) opens the file in a MarkView tab and scrolls to the line when FileType.isOpenable is true. Other files open in the default app. This mirrors EditorView's link handling.

## Actual

A link printed by Claude Code is underlined on hover, but Cmd+click does nothing visible and no browser opens. File paths are not recognised as links.

## Environment

MarkView macOS app (SwiftUI + WKWebView) on macOS Darwin 27.0.0. The terminal is xterm.js with @xterm/addon-web-links bundled into vendor/js/xterm.bundle.js. The link source is Claude Code in full-screen mode. The build/commit is unknown.

## Suspected code

- `MarkView/Resources/Editor/terminal.html` — Only WebLinksAddon posts {type:'link'}. No `linkHandler` is set in the Terminal options, so OSC 8 links go to the default confirm()/window.open. There is no file-path link provider.
- `MarkView/Models/TerminalSession.swift` — The 'link' case silently drops non-http(s) URLs and strings that URL(string:) cannot parse, with no logging. There is no cwd-relative path resolution and no WKUIDelegate, so window.open is ignored.
- `MarkView/Views/EditorView.swift` — Reference link handling (openFile with a line, NSWorkspace for http) that the terminal should reuse.
- `tools/web-vendor/xterm-entry.js` — Defines what gets bundled. A stale xterm.bundle.js could change behaviour.

## Likely causes

- Fact (code): no `linkHandler` is configured. Claude Code emits OSC 8 hyperlinks, whose activation falls back to window.open/confirm, which WKWebView drops without a WKUIDelegate. This is the most likely cause.
- Inference: Claude Code's full-screen UI enables mouse tracking, so the click may go to the app instead of xterm link activation.
- Inference: a regex-detected URL fails URL(string:) (trailing punctuation or non-ASCII characters) and is dropped silently.
- Fact: file-path links are not implemented (a feature gap).

## Missing information

- Whether `echo https://github.com` + Cmd+click works.
- Web Inspector console output when clicking.
- The build/commit and whether xterm.bundle.js is up to date.

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
