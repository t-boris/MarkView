---
type: bug
id: BUG-085
title: "Opening a part in the Code X-Ray breaks the layered diagram: layers end up side by side"
status: fixing
severity: medium
reporter: Boris Tsekinovsky
created: 2026-11-04
provenance: Created by an AI agent through MarkView
---

# Opening a part in the Code X-Ray breaks the layered diagram: layers end up side by side

## Summary

The Code X-Ray overview is a layered diagram (Users above, Presentation, Application, Domain and Data stacked top to bottom, cross-cutting layers as columns, External below). As soon as any part is opened, the view falls back to the generic graph layout: layers are placed beside each other in a mosaic, the Users caption disappears, and the layers no longer read as layers. Opening a part must only unfold that part inside its own layer and leave the relation of the layers to each other untouched.

## Steps to reproduce

1. Open a project with a code model in MarkView and open X-Ray, Code view (overview, nothing opened)
2. Double-click any part (for example a component in Presentation) to open it

## Expected

Presentation stays on top, Application below it, then Domain and Data, with the Users caption above and External below. The opened part unfolds inside its layer, which grows taller; every other part and layer keeps its place relative to the others.

## Actual

The layers are re-laid out by the generic graph algorithm: Application sits to the right of Presentation, Domain and Data stand side by side below, and the Users caption is gone. Measured on a 4-layer sample, the layers' vertical order is lost after opening one part.

## Environment

MarkView 5.26.1, macOS. Layered placement (`layeredBands`) runs only while nothing is opened (`codeOverview()`); `layout()` and the Users caption are tied to it.
