---
type: bug
id: BUG-014
title: X-Ray adds sparse levels inside module outlines
status: fixed
severity: medium
reporter: Boris Tsekinovsky
created: 2026-09-28
provenance: Created from the bug intake
questions:
  - id: BQ-1
    text: В каком проекте и файле вы видели уровни «Helpers» и «Functions»? Если помните, укажите и название родительского модуля.
    why: Конкретный файл позволит воспроизвести дерево и определить, какой путь построения outline сработал.
    status: open
issue: "#67"
---

# X-Ray adds sparse levels inside module outlines

## Summary

X-Ray file-content outlines can add unnecessary logical levels to small parts of a module, forcing extra clicks to see only a few items. The requested behavior is conditional grouping based on module and group size, with roughly four items per level as the user's example threshold.

## Steps to reproduce

1. Open a code project in MarkView and let X-Ray analysis finish.
2. In X-Ray Logical view, expand a module, then drill into a code file whose outline contains a small number of declarations.
3. Inspect the part and type-group levels, especially groups named “Helpers” and “Functions”.
4. Check whether opening either group reveals fewer than approximately four items. The exact affected file is still needed for reliable reproduction.

## Expected

Add a logical part or group only when it helps navigate a sufficiently large module. As an approximate rule, avoid an extra level whose categories each contain fewer than four items; show those items directly under the useful parent. Preserve access to every outlined item.

## Actual

In X-Ray Logical view, drilling into a module can reveal extra levels containing only a few items, such as separate “Helpers” and “Functions” groups. This is the user's reported observation; no specific file or saved outline was provided.

## Reproduction and root cause

A standalone check against the original `XRayContent.nodes` reproduced both paths. A three-function Swift file produced `File → Declarations → Functions → items`. An AI-shaped outline with two parts, each holding a two-item “Helpers” or “Functions” group, produced `File → Part → Group → items`. The reported project's exact file is still unknown; these are deterministic reproductions of the same sparse hierarchy.

The node builder always emitted every collection and every named group. Its sole flattening rule covered one unnamed group, and the long-code prompt required 3–12 parts without a minimum size. Cached outlines use the same node builder, so changing the prompt alone would leave existing outlines unchanged.

## Resolution

X-Ray now shows a part only when there are multiple parts and it has at least four items. It shows a type group only when there are multiple groups in its part and that group has at least four items. Items from smaller or redundant levels attach to the next useful parent, keeping their IDs, line numbers, anchors, and file links. The long-code prompt asks for the same minimum when generating new outlines.

The standalone regression check covers local and AI-shaped outlines, mixed sparse and useful levels, and access to every item. The Debug app build also passes.

## Environment

MarkView native macOS app, X-Ray Logical view, file contents drill-down. Long code files (250 or more lines) use an AI-generated outline; shorter supported code files use a local declaration outline. App and macOS versions are unknown.

## Suspected code

- `MarkView/Models/XRayContent.swift` — Defines the 250-line AI threshold, prompts long-code outlines to create 3–12 parts and type groups, creates local “Functions” groups for shorter code, and converts outline collections and groups into diagram nodes without a sparse-group threshold.
- `MarkView/Models/ArchitectureStore.swift` — Selects the AI or local outline path, caches generated outlines, and inserts XRayContent nodes into the Logical view; relevant for locating which path produced an affected example.
- `docs/architecture/modules/architecture-and-xray.md` — Documents the X-Ray Logical view and content-outline flow; it does not describe a minimum group size.

## Likely causes

- The long-code outline prompt asks for 3–12 logical parts and then asks to group each part's elements by type. It suggests labels including “Helpers” but gives no minimum item count for creating a part or group.
- The outline parser and node builder preserve nonempty groups without collapsing sparse levels. These are code-based likely causes, not a confirmed reproduction.

## Remaining original-report detail

- A specific module or file showing the sparse “Helpers” and “Functions” groups.
- Whether that particular example came from an AI outline or a local outline. Both paths are covered by the fix.

## Original description

Когда мы делаем логическое разбиение внутри определенного модуля, делай это только если он большой. Не делай ни в коем случае разбиения, я видел очень часто у тебя разбиение, там, два, например, helper и function, и все. Больше ничего нет, зачем мне это разбиение, а потом только ты открываешь и видишь какие helper и functions. Не делай лишних уровней, если количество элементов на каждом уровне меньше, скажем, четырех, примерно так.
