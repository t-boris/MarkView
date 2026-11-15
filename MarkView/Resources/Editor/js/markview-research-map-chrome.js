// Research map, part 2 of 6: the stylesheet, the toolbar and the map's elements, and the properties panel (built once, filled per node).
(function (A) {
    'use strict';
    if (!A.ready) return;   // the page has no editor area, or no layout engine (the first part returned early): nothing to set up
    const {
        AI_ACTIONS, LIMITS, MAX_NUMBER, MAX_TITLE, NS, PANEL_DEFAULT, PANEL_MAX, PANEL_MIN, SHAPE_IDS, SHAPE_PATHS,
        SIZE_PRESETS, VISUAL_KINDS, flushUpdate, h, host, icon, imageOf, queueUpdate, rm, withDiagram, withImage
    } = A;
    Object.assign(A, { fitTitle, modeSwitch });

    // ---- styles --------------------------------------------------------------------------------------------------------
    const css = `
    .rm-root { display: none; flex: 1; min-width: 0; min-height: 0; flex-direction: column; position: relative; overflow: hidden; background: var(--rm-page); color: var(--rm-ink); font-family: var(--font-sans); font-size: calc(12px * var(--ui-scale, 1)); line-height: 1.5;
        --rm-page: var(--bg-primary); --rm-bar: var(--bg-secondary); --rm-line: var(--border-color); --rm-ink: var(--text-primary); --rm-muted: var(--text-secondary);
        --rm-dots: var(--cv-grid-dot, rgba(255, 255, 255, 0.055)); --rm-chip: var(--bg-tertiary); --rm-field: var(--bg-primary);
        --rm-hover: var(--toolbar-hover-bg); --rm-icon-fg: var(--toolbar-text); --rm-active: var(--rm-active-bg); --rm-primary: var(--rm-primary-bg); --rm-primary-hover: var(--rm-primary-hover-bg); --rm-danger: var(--rm-danger-bg); --rm-focus: var(--accent-primary);
        --rm-warn-bg: rgba(206, 145, 120, 0.16); --rm-warn-fg: var(--accent-warning); --rm-error: var(--accent-danger); --rm-pop: var(--shadow-lg); --rm-badge-ink: #1e1e1e;
        --b0: #569cd6; --b1: #4ec9b0; --b2: #c586c0; --b3: #dcdcaa; --b4: #ce9178; --b5: #9cdcfe; }
    html[data-theme="light"] .rm-root {
        --rm-warn-bg: rgba(176, 136, 0, 0.14); --rm-pop: 0 4px 14px rgba(0, 0, 0, 0.18); --rm-badge-ink: #ffffff;
        --b0: #0366d6; --b1: #22863a; --b2: #8250df; --b3: #9a6700; --b4: #cf4a1a; --b5: #0a7ea4; }
    .rm-root.visible { display: flex; }
    .rm-root [hidden] { display: none !important; }
    .rm-root button { font: inherit; }
    .rm-toolbar { position: relative; display: flex; align-items: center; gap: 4px; padding: 3px 8px; min-height: calc(32px * var(--ui-scale, 1)); background: var(--rm-bar); border-bottom: 1px solid var(--rm-line); flex: none; }
    .rm-tool { position: relative; display: inline-grid; place-items: center; flex: none; width: calc(26px * var(--ui-scale, 1)); height: calc(26px * var(--ui-scale, 1)); padding: 0; border: 0; border-radius: 3px; background: transparent; color: var(--rm-icon-fg); cursor: pointer; transition: background .15s, color .15s; }
    .rm-tool:hover:not(:disabled) { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-tool svg { width: 15px; height: 15px; }
    .rm-tool .rm-count { position: absolute; top: -3px; right: -3px; min-width: 14px; height: 14px; padding: 0 3px; border-radius: 7px; background: var(--rm-primary); color: var(--on-rm-primary); font-size: 9px; line-height: 14px; text-align: center; }
    .rm-tbtn { flex: none; display: inline-flex; align-items: center; gap: 4px; height: calc(24px * var(--ui-scale, 1)); padding: 0 8px; border: 1px solid transparent; border-radius: 3px; background: transparent; color: var(--rm-icon-fg); font-size: calc(11px * var(--ui-scale, 1)); white-space: nowrap; cursor: pointer; transition: background .15s, color .15s; }
    .rm-tbtn:hover:not(:disabled) { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-tbtn[aria-expanded="true"] { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-tbtn svg { width: 12px; height: 12px; }
    .rm-tsep { flex: none; width: 1px; height: 14px; margin: 0 3px; background: var(--rm-line); }
    /* The Map | View | Source switch (REQ-010) sits in the map toolbar and in the top bar, so it uses the application's tokens only. */
    .mv-modes { display: inline-flex; flex: none; overflow: hidden; border: 1px solid var(--border-color); border-radius: 4px; background: var(--bg-primary); }
    .mv-modes[hidden] { display: none; }
    .mv-modes.mv-modes button { height: calc(22px * var(--ui-scale, 1)); width: auto; min-width: 0; padding: 0 10px; border: 0; border-left: 1px solid var(--border-color); border-radius: 0; background: transparent; color: var(--text-secondary); font: inherit; font-size: calc(11px * var(--ui-scale, 1)); cursor: pointer; }
    .mv-modes.mv-modes button:first-child { border-left: 0; }
    .mv-modes.mv-modes button:hover { background: var(--bg-tertiary); color: var(--text-primary); }
    .mv-modes.mv-modes button[aria-pressed="true"] { background: var(--accent-fill); color: var(--on-accent); }
    .mv-modes.mv-modes button:focus-visible { outline: 2px solid var(--accent-primary); outline-offset: -2px; }
    .wysiwyg-toolbar > .mv-modes { margin-right: 6px; }
    /* The View of a map is read only: the formatting buttons (all call fmt*) have nothing to act on. */
    body.rm-view-readonly .wysiwyg-toolbar > button[onclick^="fmt"], body.rm-view-readonly .wysiwyg-toolbar > .sep { display: none; }
    .rm-heading { display: flex; flex-direction: column; flex: 1; min-width: 0; margin-left: 4px; line-height: 1.25; }
    .rm-heading strong { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 1.05em; font-weight: 600; }
    .rm-heading span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--rm-muted); font-size: .9em; }
    .rm-heading span:empty { display: none; }
    .rm-zoom { min-width: 3.2em; text-align: center; color: var(--rm-muted); font-variant-numeric: tabular-nums; }
    .rm-status { display: inline-flex; align-items: center; gap: 8px; min-width: 0; max-width: 40%; padding: 2px 3px 2px 10px; border: 1px solid var(--rm-line); border-radius: 999px; background: var(--rm-chip); font-size: .95em; }
    .rm-status.warn { border-color: transparent; background: var(--rm-warn-bg); color: var(--rm-warn-fg); }
    .rm-status[hidden] { display: none; }
    .rm-status-text { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .rm-elapsed { color: var(--rm-muted); font-variant-numeric: tabular-nums; }
    .rm-spin { flex: none; width: 11px; height: 11px; border: 2px solid var(--accent-primary); border-right-color: transparent; border-radius: 50%; animation: rm-spin .9s linear infinite; }
    @keyframes rm-spin { to { transform: rotate(360deg); } }
    .rm-chip-btn { flex: none; display: inline-flex; align-items: center; gap: 4px; padding: 1px 9px; border: 0; border-radius: 999px; background: transparent; color: var(--rm-ink); cursor: pointer; }
    .rm-chip-btn:hover { background: var(--rm-hover); }
    .rm-chip-btn svg { width: 10px; height: 10px; }
    .rm-popover { position: absolute; z-index: 20; top: calc(100% + 4px); right: 8px; width: min(420px, 80%); max-height: 50vh; overflow: auto; padding: 8px 12px; border: 1px solid var(--rm-line); border-radius: 6px; background: var(--rm-bar); box-shadow: var(--rm-pop); }
    .rm-popover h3 { margin: 0 0 4px; font-size: .9em; color: var(--rm-muted); font-weight: 600; }
    .rm-popover ol { margin: 0; padding-left: 20px; }
    .rm-popover li { margin: 3px 0; overflow-wrap: anywhere; }
    .rm-exportmenu { position: absolute; z-index: 20; top: calc(100% + 2px); right: 8px; display: flex; flex-direction: column; min-width: 190px; padding: 4px; border: 1px solid var(--rm-line); border-radius: 6px; background: var(--rm-bar); box-shadow: var(--rm-pop); }
    .rm-workspace { display: flex; flex: 1; min-height: 0; --rm-panel-width: ${PANEL_DEFAULT}px; }
    .rm-left { position: relative; display: flex; flex: 1; min-width: 0; flex-direction: column; }
    .rm-viewport { position: relative; flex: 1; overflow: hidden; touch-action: none; cursor: grab; background-color: var(--rm-page); background-image: radial-gradient(var(--rm-dots) 1px, transparent 1px); background-size: 24px 24px; outline: none; }
    .rm-viewport.is-panning { cursor: grabbing; }
    .rm-world { position: absolute; left: 0; top: 0; width: 1px; height: 1px; transform-origin: 0 0; }
    .rm-lines { position: absolute; left: 0; top: 0; overflow: visible; pointer-events: none; }
    .rm-loading { position: absolute; inset: 0; display: grid; place-items: center; color: var(--rm-muted); pointer-events: none; }
    .rm-loading:empty { display: none; }
    .rm-hint { position: absolute; left: 10px; bottom: 8px; padding: 3px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-bar); color: var(--rm-muted); font-size: .92em; pointer-events: none; }
    .rm-readout { position: absolute; right: 10px; bottom: 8px; padding: 3px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-bar); color: var(--rm-muted); font-size: .92em; font-variant-numeric: tabular-nums; pointer-events: none; }
    .rm-readout[hidden] { display: none; }
    .rm-node-wrap { position: absolute; transform: translate(-50%, -50%); z-index: 1; width: max-content; max-width: 220px; }
    .rm-node-wrap.menu-open { z-index: 4; }
    .rm-node { position: relative; display: block; min-width: 96px; max-width: 220px; margin: 0; padding: 7px 26px 7px 11px; border: 1px solid var(--rm-line); border-left: 3px solid var(--branch, var(--b0)); border-radius: 6px; background: var(--rm-bar); color: var(--rm-ink);
        box-shadow: var(--shadow-sm); text-align: left; white-space: normal; overflow-wrap: anywhere; line-height: 1.35; font-size: calc(12px * var(--ui-scale, 1)); font-weight: 500; cursor: grab; touch-action: none; -webkit-user-select: none; user-select: none; }
    .rm-node:active { cursor: grabbing; }
    .rm-node.root { min-width: 150px; padding: 10px 26px 10px 13px; border-radius: 8px; background: var(--rm-chip); font-size: calc(14px * var(--ui-scale, 1)); font-weight: 600; box-shadow: var(--shadow-md); }
    .rm-lead { display: inline-flex; align-items: center; gap: 4px; margin-right: 6px; vertical-align: middle; }
    .rm-lead[hidden], .rm-badge[hidden], .rm-glyph[hidden] { display: none; }
    .rm-badge { display: inline-grid; place-items: center; min-width: 1.5em; height: 1.5em; padding: 0 .4em; border-radius: .75em; background: var(--branch, var(--b0)); color: var(--badge-ink, var(--rm-badge-ink)); font-size: .85em; font-weight: 700; font-variant-numeric: tabular-nums; line-height: 1; }
    .rm-glyph { display: inline-grid; place-items: center; width: 1.25em; height: 1.25em; color: var(--branch, var(--b0)); font-size: 1.05em; line-height: 1; }
    .rm-glyph svg { width: 100%; height: 100%; }
    /* The picture of a node (REQ-017): small, beside the icon, before the title. */
    .rm-thumb { display: block; width: 30px; height: 30px; object-fit: cover; border-radius: 5px; border: 1px solid var(--rm-line); background: var(--rm-page); }
    .rm-thumb[hidden] { display: none; }
    .rm-body { position: relative; z-index: 1; display: block; min-width: 0; }
    /* A given width: the wrap is exactly that wide and the title wraps in it. A given height or a shape: the card is a column that centres its title. */
    .rm-node-wrap.has-w { max-width: none; }
    .rm-node-wrap.has-w .rm-node { width: 100%; min-width: 0; max-width: none; }
    .rm-node.boxed { display: flex; flex-direction: column; justify-content: center; }
    .rm-node-wrap.visual { max-width: 320px; }
    .rm-node.is-visual, .rm-node.root.is-visual { min-width: 150px; max-width: 320px; padding: 6px 26px 6px 8px; }
    .rm-node.is-visual .rm-lead, .rm-node.is-visual .rm-label { display: none; }
    .rm-vis { display: block; line-height: 0; }
    .rm-vis[hidden] { display: none; }
    .rm-vis svg, .rm-vis img { display: block; max-width: 100%; }
    .rm-vis svg { height: auto; }
    .rm-vis-note { display: block; padding: 6px 4px; line-height: 1.4; font-size: .85em; color: var(--rm-muted); }
    .rm-vis.error .rm-vis-note { color: var(--rm-error); }
    /* Shapes (REQ-009, DEC-012). The rounded rectangle is the default look and has no class; the rectangle keeps the branch stripe. */
    .rm-node-wrap.shape-rectangle .rm-node { border-radius: 0; }
    .rm-node-wrap.shape-pill .rm-node, .rm-node-wrap.shape-ellipse .rm-node { border: 1.5px solid var(--branch, var(--b0)); }
    .rm-node-wrap.shape-pill .rm-node { border-radius: 999px; padding: 7px 30px 7px 18px; }
    .rm-node-wrap.shape-pill .rm-node.root { padding: 10px 32px 10px 22px; }
    .rm-node-wrap.shape-ellipse .rm-node { border-radius: 50%; align-items: center; padding: 0 6px; text-align: center; }
    .rm-node-wrap.shape-diamond .rm-node { align-items: center; padding: 0 6px; border: 0; background: transparent !important; box-shadow: none !important; text-align: center; }
    .rm-node-wrap.shape-pill .rm-node[aria-pressed="true"], .rm-node-wrap.shape-ellipse .rm-node[aria-pressed="true"] { border-color: var(--accent-primary); }
    .rm-shape { position: absolute; left: 0; top: 0; width: 100%; height: 100%; overflow: visible; pointer-events: none; filter: drop-shadow(0 1px 2px rgba(0, 0, 0, .35)); }
    .rm-shape polygon { fill: var(--rm-bar); stroke: var(--branch, var(--b0)); stroke-width: 2; stroke-linejoin: round; vector-effect: non-scaling-stroke; }
    .rm-node.root .rm-shape polygon { fill: var(--rm-chip); }
    .rm-node.has-color .rm-shape polygon { fill: var(--tint-dark); }
    html[data-theme="light"] .rm-node.has-color .rm-shape polygon { fill: var(--tint); }
    .rm-node[aria-pressed="true"] .rm-shape polygon { stroke: var(--accent-primary); stroke-width: 3; }
    .rm-node-wrap.shape-pill .rm-tri { top: 50%; right: 8px; transform: translateY(-50%); }
    .rm-node-wrap.shape-ellipse .rm-tri { top: 11%; right: 13%; }
    .rm-node-wrap.shape-diamond .rm-tri { top: calc(25% - 9px); right: calc(25% - 10px); }
    /* Resize handles of the selected node: knobs on the corners, invisible bars along the edges (so the fold toggle keeps the middle of the bottom edge). They keep their size on screen at any zoom. */
    .rm-handle { position: absolute; z-index: 3; touch-action: none; }
    .rm-handle[hidden] { display: none; }
    /* The arrow on the outer edge of a node: drag it onto another node to make that node a child of this one (REQ-015). It keeps its size on screen at any zoom. */
    .rm-arrow { position: absolute; top: 50%; right: calc(-25px * var(--rm-inv, 1)); z-index: 3; display: grid; place-items: center; width: calc(18px * var(--rm-inv, 1)); height: calc(18px * var(--rm-inv, 1)); margin-top: calc(-9px * var(--rm-inv, 1)); padding: 0; border: 1px solid var(--rm-line); border-radius: 50%; background: var(--rm-bar); color: var(--rm-muted); font-size: calc(11px * var(--rm-inv, 1)); line-height: 1; cursor: crosshair; opacity: 0; transition: opacity .12s, color .12s, border-color .12s; touch-action: none; }
    .rm-arrow::before { content: ''; position: absolute; top: 0; bottom: 0; left: calc(-8px * var(--rm-inv, 1)); width: calc(8px * var(--rm-inv, 1)); } /* bridges the gap to the node, so the hover is not lost on the way */
    .rm-node-wrap.arrow-left .rm-arrow { right: auto; left: calc(-25px * var(--rm-inv, 1)); transform: scaleX(-1); }
    .rm-node-wrap:hover .rm-arrow, .rm-node-wrap.selected .rm-arrow, .rm-node-wrap.connect-from .rm-arrow { opacity: 1; }
    .rm-arrow:hover, .rm-node-wrap.connect-from .rm-arrow { color: var(--accent-primary); border-color: var(--accent-primary); }
    .rm-node-wrap.connect-ok .rm-node { outline: 2px solid var(--accent-primary); outline-offset: 2px; }
    .rm-node-wrap.connect-no { opacity: .45; }
    .rm-viewport.is-connecting, .rm-viewport.is-connecting .rm-node { cursor: crosshair; }
    .rm-lines path[data-line="link-hit"] { fill: none; stroke: transparent; stroke-width: 14px; vector-effect: non-scaling-stroke; pointer-events: stroke; cursor: pointer; }
    .rm-lines path[data-line="connect"] { stroke: var(--accent-primary); stroke-dasharray: 3 5; }
    .rm-linkx { position: absolute; z-index: 4; transform: translate(-50%, -50%); display: grid; place-items: center; width: calc(20px * var(--rm-inv, 1)); height: calc(20px * var(--rm-inv, 1)); padding: 0; border: 1px solid var(--accent-primary); border-radius: 50%; background: var(--rm-bar); color: var(--rm-ink); cursor: pointer; box-shadow: var(--rm-pop); }
    .rm-linkx:hover { background: var(--rm-hover); }
    .rm-linkx svg { width: calc(10px * var(--rm-inv, 1)); height: calc(10px * var(--rm-inv, 1)); }
    .rm-handle[data-h="n"], .rm-handle[data-h="s"] { left: calc(10px * var(--rm-inv, 1)); right: calc(10px * var(--rm-inv, 1)); height: calc(8px * var(--rm-inv, 1)); cursor: ns-resize; }
    .rm-handle[data-h="n"] { top: calc(-4px * var(--rm-inv, 1)); }
    .rm-handle[data-h="s"] { bottom: calc(-4px * var(--rm-inv, 1)); }
    .rm-handle[data-h="e"], .rm-handle[data-h="w"] { top: calc(10px * var(--rm-inv, 1)); bottom: calc(10px * var(--rm-inv, 1)); width: calc(8px * var(--rm-inv, 1)); cursor: ew-resize; }
    .rm-handle[data-h="e"] { right: calc(-4px * var(--rm-inv, 1)); }
    .rm-handle[data-h="w"] { left: calc(-4px * var(--rm-inv, 1)); }
    .rm-handle[data-h="nw"], .rm-handle[data-h="ne"], .rm-handle[data-h="se"], .rm-handle[data-h="sw"] { box-sizing: border-box; width: calc(10px * var(--rm-inv, 1)); height: calc(10px * var(--rm-inv, 1)); border: 1.5px solid var(--accent-primary); border-radius: 2px; background: var(--rm-bar); }
    .rm-handle[data-h="nw"] { top: calc(-5px * var(--rm-inv, 1)); left: calc(-5px * var(--rm-inv, 1)); cursor: nwse-resize; }
    .rm-handle[data-h="ne"] { top: calc(-5px * var(--rm-inv, 1)); right: calc(-5px * var(--rm-inv, 1)); cursor: nesw-resize; }
    .rm-handle[data-h="sw"] { bottom: calc(-5px * var(--rm-inv, 1)); left: calc(-5px * var(--rm-inv, 1)); cursor: nesw-resize; }
    .rm-handle[data-h="se"] { bottom: calc(-5px * var(--rm-inv, 1)); right: calc(-5px * var(--rm-inv, 1)); cursor: nwse-resize; }
    /* An ellipse and a diamond do not fill their box: a thin frame ties the handles to the selected shape. */
    .rm-node-wrap.selected.shape-ellipse::before, .rm-node-wrap.selected.shape-diamond::before { content: ''; position: absolute; left: 0; top: 0; right: 0; bottom: 0; border: 1px dashed var(--accent-primary); opacity: .55; pointer-events: none; }
    .rm-handle[data-h="n"]:hover::after, .rm-handle[data-h="s"]:hover::after { content: ''; position: absolute; left: 0; right: 0; top: 50%; height: 2px; margin-top: -1px; background: var(--accent-primary); }
    .rm-handle[data-h="e"]:hover::after, .rm-handle[data-h="w"]:hover::after { content: ''; position: absolute; top: 0; bottom: 0; left: 50%; width: 2px; margin-left: -1px; background: var(--accent-primary); }
    .rm-node.has-color { background: var(--tint-dark); }
    html[data-theme="light"] .rm-node.has-color { background: var(--tint); }
    .rm-node[aria-pressed="true"] { border-color: var(--accent-primary); border-left-color: var(--branch, var(--b0)); box-shadow: 0 0 0 1px var(--accent-primary); }
    .rm-tri { position: absolute; top: 3px; right: 3px; z-index: 2; display: grid; place-items: center; width: 20px; height: 18px; padding: 0; border: 0; border-radius: 3px; background: transparent; color: var(--rm-ink); opacity: .55; cursor: pointer; font-size: 14px; line-height: 1; letter-spacing: -1px; }
    .rm-tri:hover, .rm-node-wrap.menu-open .rm-tri { opacity: 1; background: var(--rm-hover); }
    .rm-fold { position: absolute; left: 50%; bottom: -9px; z-index: 2; transform: translateX(-50%); display: inline-flex; align-items: center; justify-content: center; gap: 2px; min-width: 18px; height: 18px; padding: 0 5px; border: 1px solid var(--rm-line); border-radius: 9px; background: var(--rm-bar); color: var(--rm-muted); font-size: 10px; line-height: 1; cursor: pointer; }
    .rm-fold:hover { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-fold.folded { border-color: var(--branch, var(--b0)); color: var(--rm-ink); }
    .rm-fold svg { width: 9px; height: 9px; }
    .rm-actions { position: absolute; z-index: 30; display: flex; flex-direction: column; min-width: 210px; max-height: calc(100% - 12px); overflow: auto; padding: 4px; border: 1px solid var(--rm-line); border-radius: 6px; background: var(--rm-bar); box-shadow: var(--rm-pop); cursor: default; }
    .rm-item { display: flex; align-items: center; gap: 8px; width: 100%; padding: 5px 9px; border: 0; border-radius: 3px; background: transparent; color: var(--rm-ink); text-align: left; white-space: nowrap; cursor: pointer; }
    .rm-item svg { flex: none; width: 14px; height: 14px; color: var(--rm-icon-fg); }
    .rm-item.ai svg { color: var(--accent-primary); }
    .rm-item:hover:not(:disabled) { background: var(--rm-hover); }
    .rm-item.danger { color: var(--accent-danger); }
    .rm-item.danger svg { color: var(--accent-danger); }
    .rm-item:disabled { opacity: .4; cursor: not-allowed; }
    .rm-item .rm-more { margin-left: auto; color: var(--rm-muted); }
    .rm-sep { height: 1px; margin: 4px 2px; background: var(--rm-line); }
    .rm-icon { display: inline-grid; place-items: center; flex: none; width: calc(26px * var(--ui-scale, 1)); height: calc(26px * var(--ui-scale, 1)); padding: 0; border: 0; border-radius: 3px; background: transparent; color: var(--rm-icon-fg); cursor: pointer; transition: background .15s, color .15s; }
    .rm-icon svg { width: 14px; height: 14px; }
    .rm-icon:hover:not(:disabled) { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-layouts { display: flex; flex-direction: column; margin: 2px 0 2px 22px; padding: 2px 0 2px 6px; border-left: 1px solid var(--rm-line); }
    .rm-layouts button { display: flex; align-items: center; gap: 6px; padding: 4px 8px; border: 0; border-radius: 3px; background: transparent; color: var(--rm-ink); text-align: left; white-space: nowrap; cursor: pointer; }
    .rm-layouts button:hover { background: var(--rm-hover); }
    .rm-layouts button[aria-checked="true"] { font-weight: 600; }
    .rm-layouts .rm-check { width: 1em; color: var(--accent-primary); }
    .rm-divider { position: relative; flex: none; width: 5px; margin-left: -2px; border-left: 1px solid var(--rm-line); cursor: col-resize; touch-action: none; }
    .rm-divider:hover, .rm-divider:focus-visible { border-left-color: var(--accent-primary); background: var(--rm-hover); outline: none; }
    .rm-panel { display: flex; flex-direction: column; gap: 10px; flex: none; width: var(--rm-panel-width); min-width: ${PANEL_MIN}px; max-width: 60%; padding: 14px 12px; overflow: auto; background: var(--rm-bar); color: var(--rm-ink); }
    .rm-panel[hidden] { display: none; }
    .rm-panel-body { display: flex; flex: 1; flex-direction: column; gap: 10px; min-height: 0; }
    .rm-panel-body[hidden], .rm-empty[hidden], .rm-section[hidden] { display: none; }
    .rm-empty { margin: 0; color: var(--rm-muted); }
    .rm-panel input, .rm-panel textarea, .rm-dialog input, .rm-dialog textarea, .rm-dialog select { font: inherit; color: var(--rm-ink); }
    .rm-panel .rm-title-input { display: block; flex: none; width: 100%; min-height: 30px; padding: 4px 6px; border: 1px solid transparent; border-radius: 4px; background: transparent; font-size: calc(15px * var(--ui-scale, 1)); font-weight: 600; line-height: 1.3; resize: none; overflow: hidden; outline: none; }
    .rm-panel .rm-title-input:hover { border-color: var(--rm-line); }
    .rm-panel .rm-title-input:focus { border-color: var(--rm-focus); background: var(--rm-field); }
    .rm-error { margin: -4px 0 0; color: var(--rm-error); font-size: .95em; }
    .rm-error:empty { display: none; }
    .rm-ai { display: grid; grid-template-columns: 1fr 1fr; gap: 4px; }
    .rm-ai-btn { display: flex; align-items: center; gap: 5px; min-width: 0; padding: 4px 6px; border: 1px solid var(--rm-line); border-radius: 4px; background: transparent; color: var(--rm-ink); font-size: calc(11px * var(--ui-scale, 1)); text-align: left; white-space: nowrap; cursor: pointer; transition: background .15s; }
    .rm-ai-btn svg { flex: none; width: 13px; height: 13px; color: var(--accent-primary); }
    .rm-ai-label { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
    .rm-ai-btn:hover:not(:disabled) { background: var(--rm-hover); }
    .rm-ai-btn:disabled { opacity: .45; cursor: not-allowed; }
    .rm-ai-note { margin: -4px 0 0; color: var(--rm-muted); font-size: .92em; }
    .rm-ai-note:empty { display: none; }
    .rm-tags { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; }
    .rm-tag { display: inline-flex; align-items: center; gap: 4px; padding: 1px 7px; border: 1px solid var(--rm-line); border-radius: 10px; background: var(--rm-chip); color: var(--rm-ink); font-size: .92em; }
    .rm-tag button { padding: 0; border: 0; background: transparent; color: var(--rm-muted); font-size: 14px; line-height: 1; cursor: pointer; }
    .rm-tag button:hover { color: var(--rm-ink); }
    .rm-tag-input { flex: 1; min-width: 90px; padding: 3px 2px; border: 0; background: transparent; outline: none; }
    .rm-tag-input::placeholder, .rm-desc::placeholder { color: var(--rm-muted); }
    .rm-color-row, .rm-badge-row { display: flex; align-items: center; gap: 8px; color: var(--rm-muted); font-size: .95em; }
    .rm-badge-row { flex-wrap: wrap; gap: 8px 14px; }
    .rm-badge-row .rm-field { display: inline-flex; align-items: center; gap: 6px; }
    .rm-icon-pick, .rm-picture-pick { display: inline-flex; align-items: center; gap: 6px; min-width: 56px; height: 26px; padding: 0 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); color: var(--rm-ink); cursor: pointer; }
    .rm-icon-pick:hover, .rm-picture-pick:hover { background: var(--rm-hover); }
    .rm-picture-pick span { max-width: 130px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .rm-picture-thumb { display: block; width: 20px; height: 20px; object-fit: cover; border-radius: 3px; border: 1px solid var(--rm-line); }
    .rm-picture-thumb[hidden] { display: none; }
    .rm-dropzone { display: flex; flex-direction: column; align-items: center; gap: 10px; padding: 16px; border: 1px dashed var(--rm-line); border-radius: 6px; color: var(--rm-muted); text-align: center; outline: none; }
    .rm-dropzone:focus, .rm-dropzone.over { border-color: var(--accent-primary); }
    .rm-picture-preview { max-width: 100%; max-height: 160px; border-radius: 4px; border: 1px solid var(--rm-line); object-fit: contain; }
    .rm-picture-preview[hidden] { display: none; }
    .rm-node-wrap.picture-drop .rm-node { outline: 2px solid var(--accent-primary); outline-offset: 2px; }
    .rm-icon-pick .rm-glyph { color: var(--rm-ink); }
    .rm-number-input { width: 64px; height: 26px; padding: 2px 6px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); font: inherit; color: var(--rm-ink); outline: none; }
    .rm-number-input:focus { border-color: var(--rm-focus); }
    .rm-look-row { display: flex; align-items: center; flex-wrap: wrap; gap: 6px 8px; color: var(--rm-muted); font-size: .95em; }
    .rm-look-row > span:first-child { flex: none; min-width: 3.4em; }
    .rm-seg { display: inline-flex; border: 1px solid var(--rm-line); border-radius: 4px; overflow: hidden; background: var(--rm-field); }
    .rm-seg button { display: inline-grid; place-items: center; min-width: 30px; height: 26px; padding: 0 8px; border: 0; border-left: 1px solid var(--rm-line); background: transparent; color: var(--rm-ink); font: inherit; cursor: pointer; }
    .rm-seg button:first-child { border-left: 0; }
    .rm-seg button:hover { background: var(--rm-hover); }
    .rm-seg button[aria-pressed="true"] { background: var(--accent-fill); color: var(--on-accent); }
    .rm-seg button svg { width: 16px; height: 16px; }
    .rm-dim { display: inline-flex; align-items: center; gap: 4px; }
    .rm-dim input { width: 62px; height: 26px; padding: 2px 6px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); font: inherit; color: var(--rm-ink); outline: none; }
    .rm-dim input:focus { border-color: var(--rm-focus); }
    .rm-dim input::placeholder { color: var(--rm-muted); }
    .rm-icongrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(34px, 1fr)); gap: 4px; }
    .rm-icongrid button { display: grid; place-items: center; height: 34px; padding: 0; border: 1px solid transparent; border-radius: 4px; background: transparent; color: var(--rm-ink); cursor: pointer; }
    .rm-icongrid button:hover { background: var(--rm-hover); }
    .rm-icongrid button[aria-pressed="true"] { border-color: var(--accent-primary); background: var(--rm-active); }
    .rm-icongrid svg { width: 18px; height: 18px; }
    .rm-color-row input[type=color] { width: 30px; height: 24px; padding: 1px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); cursor: pointer; }
    .rm-panel h3 { margin: 6px 0 0; font-size: .82em; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--rm-muted); }
    .rm-format { display: flex; flex-wrap: wrap; gap: 2px; }
    .rm-format .rm-icon { font-size: .95em; font-weight: 700; }
    .rm-desc { flex: none; width: 100%; height: 180px; min-height: 80px; box-sizing: border-box; padding: 8px 10px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); line-height: 1.55; resize: vertical; outline: none; }
    .rm-desc:focus { border-color: var(--rm-focus); }
    .rm-visual-pane { display: flex; flex-direction: column; gap: 8px; }
    .rm-visual-pane[hidden], .rm-visual-pane [hidden] { display: none; }
    .rm-vis-panel { padding: 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); overflow: auto; max-height: 340px; }
    .rm-vis-panel img { margin: 0 auto; }
    .rm-visual-pane .rm-chip-btn { align-self: flex-start; border: 1px solid var(--rm-line); }
    .rm-visual-pane .rm-vis-source { flex: none; width: 100%; height: 120px; min-height: 60px; box-sizing: border-box; padding: 8px 10px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em; line-height: 1.45; resize: vertical; outline: none; }
    .rm-visual-pane .rm-vis-source:focus { border-color: var(--rm-focus); }
    .rm-visual-pane .rm-image-input { width: 100%; box-sizing: border-box; padding: 6px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); outline: none; }
    .rm-visual-pane .rm-image-input:focus { border-color: var(--rm-focus); }
    .rm-draw-list { display: flex; flex-direction: column; gap: 2px; padding: 4px; border: 1px solid var(--rm-line); border-radius: 4px; }
    .rm-draw-list[hidden] { display: none; }
    .rm-draw-list button { padding: 4px 8px; border: 0; border-radius: 3px; background: transparent; color: var(--rm-ink); text-align: left; cursor: pointer; }
    .rm-draw-list button:hover { background: var(--rm-hover); }
    .rm-icongrid button:focus-visible, .rm-icon-pick:focus-visible, .rm-tool:focus-visible, .rm-icon:focus-visible, .rm-tbtn:focus-visible, .rm-item:focus-visible, .rm-ai-btn:focus-visible, .rm-chip-btn:focus-visible, .rm-fold:focus-visible, .rm-tri:focus-visible, .rm-node:focus-visible { outline: 2px solid var(--rm-focus); outline-offset: 1px; }
    .rm-section { display: flex; flex: none; flex-direction: column; gap: 6px; }
    .rm-list { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 6px; }
    .rm-ev-row { display: flex; flex-direction: column; gap: 3px; padding: 6px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); }
    .rm-ev-chip { align-self: flex-start; padding: 0 7px; border-radius: 999px; background: var(--rm-chip); color: var(--rm-ink); font-size: .8em; font-weight: 600; white-space: nowrap; }
    .rm-ev-chip[data-label="Project fact"] { background: rgba(78, 201, 176, .18); color: #4ec9b0; }
    .rm-ev-chip[data-label="External fact"] { background: rgba(86, 156, 214, .20); color: #7cb7e8; }
    .rm-ev-chip[data-label="AI inference"] { background: rgba(197, 134, 192, .20); color: #d7a0d2; }
    .rm-ev-chip[data-label="Open assumption"] { background: rgba(206, 145, 120, .20); color: #e0a98f; }
    html[data-theme="light"] .rm-ev-chip[data-label="Project fact"] { background: rgba(34, 134, 58, .14); color: #1a6e30; }
    html[data-theme="light"] .rm-ev-chip[data-label="External fact"] { background: rgba(3, 102, 214, .12); color: #0550ae; }
    html[data-theme="light"] .rm-ev-chip[data-label="AI inference"] { background: rgba(130, 80, 223, .14); color: #6a3fc0; }
    html[data-theme="light"] .rm-ev-chip[data-label="Open assumption"] { background: rgba(176, 136, 0, .16); color: #7a5f00; }
    .rm-ev-text { overflow-wrap: anywhere; }
    .rm-ev-source { align-self: flex-start; max-width: 100%; padding: 0; border: 0; background: transparent; color: var(--accent-primary); font-size: .92em; text-align: left; text-decoration: underline; overflow-wrap: anywhere; cursor: pointer; }
    .rm-conn-row { display: flex; align-items: center; gap: 6px; padding: 2px 3px 2px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); }
    .rm-conn-name { flex: 1; min-width: 0; padding: 0; border: 0; background: transparent; color: var(--rm-ink); text-align: left; overflow-wrap: anywhere; cursor: pointer; }
    .rm-x { display: inline-grid; place-items: center; flex: none; width: 20px; height: 20px; padding: 0; border: 0; border-radius: 3px; background: transparent; color: var(--rm-muted); cursor: pointer; }
    .rm-x:hover { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-x svg { width: 11px; height: 11px; }
    .rm-modal { position: absolute; inset: 0; z-index: 50; display: flex; align-items: center; justify-content: center; padding: 16px; background: rgba(0, 0, 0, 0.45); }
    .rm-dialog { width: 100%; max-width: 440px; max-height: 90%; overflow: auto; border: 1px solid var(--rm-line); border-radius: 8px; background: var(--rm-bar); color: var(--rm-ink); box-shadow: var(--shadow-lg); }
    .rm-dialog h2 { margin: 0; padding: 14px 18px 0; font-size: 1.15em; font-weight: 600; }
    .rm-dialog-body { display: flex; flex-direction: column; gap: 10px; padding: 10px 18px; }
    .rm-dialog-body p { margin: 0; overflow-wrap: anywhere; }
    .rm-dialog label { display: flex; flex-direction: column; gap: 4px; color: var(--rm-muted); font-size: .95em; }
    .rm-dialog input, .rm-dialog textarea, .rm-dialog select { width: 100%; min-height: 28px; padding: 4px 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); outline: none; }
    .rm-dialog textarea { min-height: 84px; line-height: 1.5; resize: vertical; }
    .rm-dialog input:focus, .rm-dialog textarea:focus, .rm-dialog select:focus { border-color: var(--rm-focus); }
    .rm-dialog-actions { display: flex; justify-content: flex-end; gap: 8px; padding: 6px 18px 14px; }
    .rm-btn { min-height: 26px; padding: 3px 14px; border: 1px solid var(--rm-line); border-radius: 4px; background: transparent; color: var(--rm-ink); cursor: pointer; }
    .rm-btn:hover { background: var(--rm-hover); }
    .rm-btn.primary { border-color: var(--rm-primary); background: var(--rm-primary); color: var(--on-rm-primary); }
    .rm-btn.primary:hover { background: var(--rm-primary-hover); }
    .rm-btn.danger { border-color: var(--rm-danger); background: var(--rm-danger); color: var(--on-rm-danger); }
    .rm-toast { position: absolute; left: 50%; bottom: 40px; z-index: 60; transform: translateX(-50%); max-width: 70%; padding: 6px 12px; border: 1px solid var(--rm-line); border-radius: 6px; background: var(--rm-chip); color: var(--rm-ink); box-shadow: var(--rm-pop); pointer-events: none; }
    .rm-toast[hidden] { display: none; }
    .rm-problem { display: none; align-items: center; gap: 10px; padding: 4px 12px; background: var(--rm-warn-bg, rgba(206, 145, 120, 0.16)); color: var(--rm-warn-fg, var(--accent-warning)); font-size: calc(12px * var(--ui-scale, 1)); border-bottom: 1px solid var(--border-color); }
    .rm-problem.visible { display: flex; }
    .rm-problem span { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .rm-problem button { border: 0; background: transparent; color: inherit; cursor: pointer; font-size: 14px; }
    @media (max-width: 760px) {
        .rm-workspace { flex-direction: column; }
        .rm-left { flex: none; height: 58vh; min-height: 300px; }
        .rm-divider { display: none; }
        .rm-panel { width: 100%; max-width: none; min-width: 0; min-height: 240px; border-top: 1px solid var(--rm-line); }
    }
    `;
    const styleEl = document.createElement('style');
    styleEl.id = 'research-map-style';
    styleEl.textContent = css;
    document.head.appendChild(styleEl);

    // ---- the page structure ---------------------------------------------------------------------------------------------
    const el = {};
    A.el = el;
    function tool(act, label, content, handler) {
        return h('button', { class: 'rm-tool', type: 'button', 'data-act': act, title: label, 'aria-label': label, onClick: handler }, content);
    }
    const VIEWS = [['map', 'Map', 'The mind map'], ['view', 'View', 'The file as ordinary Markdown'], ['source', 'Source', 'The Markdown source']];
    /** One Map | View | Source switch; there are two of them (map toolbar, top bar) and both follow the current view. */
    function modeSwitch() {
        return h('div', { class: 'mv-modes', role: 'group', 'aria-label': 'View of this map' }, VIEWS.map(function (v) {
            return h('button', { type: 'button', 'data-view': v[0], 'aria-pressed': 'false', title: v[2], onClick: function () { A.showView(v[0]); } }, v[1]);
        }));
    }
    el.modes = modeSwitch();
    el.title = h('strong');
    el.question = h('span');
    el.status = h('div', { class: 'rm-status', hidden: true, 'aria-live': 'polite' });
    el.queryCount = h('span', { class: 'rm-count' });
    el.queriesBtn = tool('queries', 'Web searches the research ran', [icon('search'), el.queryCount], function (e) { e.stopPropagation(); A.toggleQueries(); });
    el.queriesBtn.hidden = true;
    el.zoom = h('span', { class: 'rm-zoom', 'aria-live': 'polite' });
    el.popover = h('div', { class: 'rm-popover', hidden: true, role: 'dialog', 'aria-label': 'Web searches' });
    function tbtn(act, label, title, handler, extra) {
        return h('button', { class: 'rm-tbtn', type: 'button', 'data-act': act, title: title, onClick: handler }, extra || null, label);
    }
    el.exportBtn = tbtn('export', 'Export', 'Export the map as a Markdown report or a PDF', function (e) { e.stopPropagation(); A.toggleExport(); }, icon('download'));
    el.exportBtn.setAttribute('aria-haspopup', 'true');
    el.exportBtn.setAttribute('aria-expanded', 'false');
    el.exportBtn.appendChild(icon('chevron'));
    el.exportMenu = h('div', { class: 'rm-exportmenu', role: 'menu', 'aria-label': 'Export', hidden: true },
        h('button', { class: 'rm-item', type: 'button', role: 'menuitem', 'data-act': 'export-markdown', title: 'The AI writes a report of the whole map as a document you can share, saved as Markdown', onClick: function (e) { e.stopPropagation(); A.closeExport(); A.exportDialog('markdown'); } }, icon('text'), h('span', null, 'Markdown report…')),
        h('button', { class: 'rm-item', type: 'button', role: 'menuitem', 'data-act': 'export-pdf', title: 'The same report as a PDF', onClick: function (e) { e.stopPropagation(); A.closeExport(); A.exportDialog('pdf'); } }, icon('download'), h('span', null, 'PDF…')),
        h('div', { class: 'rm-sep', role: 'separator' }),
        h('button', { class: 'rm-item', type: 'button', role: 'menuitem', 'data-act': 'translate', title: 'The AI translates this map into another language', onClick: function (e) { e.stopPropagation(); A.closeExport(); A.translateDialog(); } }, icon('text'), h('span', null, 'Translate map…')));
    el.collapseBtn = tbtn('collapse-all', 'Collapse all', 'Fold every branch so that only the root and its main branches show', function () { A.collapseAll(); });
    el.expandBtn = tbtn('expand-all', 'Expand all', 'Show every node', function () { A.expandAll(); });
    el.toolbar = h('div', { class: 'rm-toolbar' },
        el.modes,
        h('div', { class: 'rm-heading' }, el.title, el.question),
        el.status,
        el.queriesBtn,
        el.collapseBtn,
        el.expandBtn,
        el.exportBtn,
        h('span', { class: 'rm-tsep', 'aria-hidden': 'true' }),
        tool('zoom-out', 'Zoom out', icon('minus'), function () { A.zoomAtCentre(rm.view.scale / 1.2); }),
        el.zoom,
        tool('zoom-in', 'Zoom in', icon('plus'), function () { A.zoomAtCentre(rm.view.scale * 1.2); }),
        tool('centre', 'Centre the map on the root node at 100%', icon('centre'), function () { A.centreView(); }),
        el.popover,
        el.exportMenu);

    el.svg = document.createElementNS(NS, 'svg');
    el.svg.setAttribute('class', 'rm-lines');
    el.svg.setAttribute('aria-hidden', 'true');
    el.world = h('div', { class: 'rm-world' }, el.svg);
    el.loading = h('div', { class: 'rm-loading' }, 'Loading the research map…');
    el.viewport = h('div', { class: 'rm-viewport', tabindex: '0', role: 'region', 'aria-label': 'Research map. Drag the background to move the map and drag nodes to change their positions.' }, el.world, el.loading);
    el.hint = h('div', { class: 'rm-hint' }, 'Drag the map and nodes · the mouse wheel zooms');
    el.readout = h('div', { class: 'rm-readout', hidden: true });
    el.left = h('section', { class: 'rm-left', 'aria-label': 'Research map' }, el.viewport, el.hint, el.readout);

    el.divider = h('div', { class: 'rm-divider', role: 'separator', tabindex: '0', 'aria-label': 'Resize properties panel', 'aria-orientation': 'vertical', 'aria-valuemin': String(PANEL_MIN), 'aria-valuemax': String(PANEL_MAX) });
    el.panel = h('aside', { class: 'rm-panel', 'aria-label': 'Node properties' });
    el.workspace = h('div', { class: 'rm-workspace' }, el.left, el.divider, el.panel);
    el.toast = h('div', { class: 'rm-toast', hidden: true, role: 'status' });
    el.root = h('div', { class: 'rm-root', id: 'research-map-container' }, el.toolbar, el.workspace, el.toast);
    host.appendChild(el.root);

    // A one-line notice outside the map: shown above the editor when the file cannot be shown as a map.
    el.problemText = h('span');
    el.problem = h('div', { class: 'rm-problem', id: 'research-map-problem', role: 'alert' }, el.problemText, h('button', { type: 'button', 'aria-label': 'Dismiss', onClick: function () { A.hideProblem(); } }, '✕'));
    if (host.parentNode) host.parentNode.insertBefore(el.problem, host);

    // ---- the properties panel (built once, filled per node) ---------------------------------------------------------------
    function buildPanel() {
        el.empty = h('p', { class: 'rm-empty' }, 'Select a node on the map');
        el.titleInput = h('textarea', { class: 'rm-title-input', rows: '1', maxlength: String(MAX_TITLE), 'aria-label': 'Node name', spellcheck: 'false' });
        el.titleError = h('p', { class: 'rm-error', role: 'alert' });
        el.tagInput = h('input', { class: 'rm-tag-input', maxlength: String(MAX_TITLE), placeholder: 'Add tag', 'aria-label': 'Add tag' });
        el.tags = h('div', { class: 'rm-tags' }, el.tagInput);
        el.color = h('input', { class: 'rm-color-input', type: 'color', 'aria-label': 'Node color', title: 'Node color' });
        el.colorClear = h('button', { class: 'rm-x', type: 'button', title: 'Use the branch colour', 'aria-label': 'Use the branch colour' }, icon('close'));
        el.iconPick = h('button', { class: 'rm-icon-pick', type: 'button', 'data-act': 'icon', title: 'Choose an icon for this node', onClick: function () { A.iconDialog(A.nodeById(rm.selected)); } });
        el.iconGlyph = h('span', { class: 'rm-glyph', 'aria-hidden': 'true' });
        el.iconText = h('span', null, 'None');
        el.iconPick.appendChild(el.iconGlyph);
        el.iconPick.appendChild(el.iconText);
        el.iconClear = h('button', { class: 'rm-x', type: 'button', 'data-act': 'icon-clear', title: 'Remove the icon', 'aria-label': 'Remove the icon' }, icon('close'));
        el.imageThumb = h('img', { class: 'rm-picture-thumb', alt: '', hidden: true });
        el.imageText = h('span', null, 'None');
        el.imagePick = h('button', { class: 'rm-picture-pick', type: 'button', 'data-act': 'image', title: 'Choose a picture for this node, shown beside its icon', onClick: function () { A.pictureDialog(A.nodeById(rm.selected)); } }, el.imageThumb, el.imageText);
        el.imageClear = h('button', { class: 'rm-x', type: 'button', 'data-act': 'image-clear', title: 'Remove the picture', 'aria-label': 'Remove the picture' }, icon('close'));
        el.numberInput = h('input', { class: 'rm-number-input', type: 'number', min: '1', max: String(MAX_NUMBER), step: '1', inputmode: 'numeric', 'aria-label': 'Number badge', title: 'A number shown before the title (1 to ' + MAX_NUMBER + '); leave it empty for none', placeholder: '—' });
        // Shape and size of the node (REQ-009): a shape picker, Auto/S/M/L and the exact width and height.
        el.shapeBtns = {};
        SHAPE_IDS.forEach(function (id) {
            el.shapeBtns[id] = h('button', { type: 'button', 'data-shape': id, 'aria-pressed': 'false', onClick: function () {
                if (rm.selected) queueUpdate(rm.selected, { shape: id === 'rounded' ? '' : id }, true);
            } }, icon(id, SHAPE_PATHS));
        });
        el.shapeSeg = h('div', { class: 'rm-seg', role: 'group', 'aria-label': 'Node shape' }, SHAPE_IDS.map(function (id) { return el.shapeBtns[id]; }));
        el.sizeBtns = {};
        const sizeButton = function (id, label, title, patch) {
            el.sizeBtns[id] = h('button', { type: 'button', 'data-size': id, 'aria-pressed': 'false', title: title, onClick: function () {
                if (rm.selected) queueUpdate(rm.selected, patch, true);
            } }, label);
            return el.sizeBtns[id];
        };
        el.sizeSeg = h('div', { class: 'rm-seg', role: 'group', 'aria-label': 'Node size' },
            sizeButton('auto', 'Auto', 'Fit the size to the title', { width: null, height: null }),
            SIZE_PRESETS.map(function (p) { return sizeButton(p.id, p.label, 'Width ' + p.w + ', height ' + p.h, { width: p.w, height: p.h }); }));
        el.widthInput = h('input', { type: 'number', step: '1', inputmode: 'numeric', 'data-dim': 'width', 'aria-label': 'Node width', placeholder: 'Auto' });
        el.heightInput = h('input', { type: 'number', step: '1', inputmode: 'numeric', 'data-dim': 'height', 'aria-label': 'Node height', placeholder: 'Auto' });
        el.desc = h('textarea', { class: 'rm-desc', 'aria-label': 'Markdown description', placeholder: 'Add a Markdown description' });
        // What the node shows: its title (Text), the first Mermaid block of the description (Diagram) or its first picture (Image).
        el.visualBtns = {};
        VISUAL_KINDS.forEach(function (kind) {
            el.visualBtns[kind[0]] = h('button', { type: 'button', 'data-visual': kind[0], 'aria-pressed': 'false', onClick: function () {
                if (rm.selected) queueUpdate(rm.selected, { visual: kind[0] === 'text' ? '' : kind[0] }, true);
            } }, kind[1]);
        });
        el.visualSeg = h('div', { class: 'rm-seg', role: 'group', 'aria-label': 'What the node shows' }, VISUAL_KINDS.map(function (kind) { return el.visualBtns[kind[0]]; }));
        el.visualPreview = h('div', { class: 'rm-vis rm-vis-panel' });
        el.visualExpand = h('button', { class: 'rm-chip-btn', type: 'button', title: 'Open full screen: wheel to zoom, drag to move, Esc to close', onClick: function () { A.expandVisual(rm.selected); } }, icon('open'), 'Expand');
        el.visualSource = h('textarea', { class: 'rm-vis-source', 'aria-label': 'Mermaid source', placeholder: 'Paste or type Mermaid, for example: sequenceDiagram', spellcheck: 'false' });
        el.imageInput = h('input', { type: 'text', class: 'rm-image-input', 'aria-label': 'Image address or project path', placeholder: 'images/screen.png or https://…', spellcheck: 'false' });
        el.visualPane = h('div', { class: 'rm-visual-pane', hidden: true }, el.visualPreview, el.visualExpand, el.visualSource, el.imageInput);
        el.shapeRow = h('div', { class: 'rm-look-row' }, h('span', null, 'Shape'), el.shapeSeg);
        el.drawBtn = h('button', { class: 'rm-ai-btn', type: 'button', 'data-act': 'draw', 'aria-expanded': 'false', title: 'The AI draws a diagram of this node as a child node', onClick: function () { A.toggleDrawList(); } },
            icon('diagram'), h('span', { class: 'rm-ai-label' }, 'Draw'), h('span', { class: 'rm-more', 'aria-hidden': 'true' }, '▾'));
        el.drawList = h('div', { class: 'rm-draw-list', role: 'menu', 'aria-label': 'Diagram types', hidden: true });
        const fmt = function (label, text, before, after, placeholder) {
            return h('button', { class: 'rm-icon', type: 'button', title: label, 'aria-label': label, 'data-fmt': label.toLowerCase(), onClick: function () { insertMarkdown(before, after, placeholder); } }, text);
        };
        el.format = h('div', { class: 'rm-format', 'aria-label': 'Markdown formatting', role: 'group' },
            fmt('Bold', 'B', '**', '**', 'text'), fmt('Italic', 'I', '*', '*', 'text'), fmt('Link', '↗', '[', '](url)', 'text'),
            fmt('Image', '▧', '![', '](image url)', 'description'), fmt('List', '☷', '- ', '', 'item'));
        el.evHeading = h('h3', null, 'Evidence');
        el.evList = h('ul', { class: 'rm-list' });
        el.evSection = h('div', { class: 'rm-section', hidden: true }, el.evHeading, el.evList);
        el.connHeading = h('h3', null, 'Connections');
        el.connList = h('ul', { class: 'rm-list' });
        el.connSection = h('div', { class: 'rm-section', hidden: true }, el.connHeading, el.connList);
        el.aiButtons = AI_ACTIONS.map(function (action) {
            return h('button', { class: 'rm-ai-btn', type: 'button', 'data-act': action.act, title: action.hint, onClick: function () { A.runAI(action.act, A.nodeById(rm.selected)); } }, icon(action.icon), h('span', { class: 'rm-ai-label' }, action.label));
        });
        el.aiButtons.push(el.drawBtn);
        el.aiNote = h('p', { class: 'rm-ai-note' });
        el.body = h('div', { class: 'rm-panel-body', hidden: true },
            el.titleInput, el.titleError,
            h('h3', null, 'AI'), h('div', { class: 'rm-ai', role: 'group', 'aria-label': 'AI actions on this node' }, el.aiButtons), el.drawList, el.aiNote,
            el.tags,
            h('div', { class: 'rm-color-row' }, h('span', null, 'Color'), el.color, el.colorClear),
            h('div', { class: 'rm-badge-row' },
                h('div', { class: 'rm-field' }, h('span', null, 'Icon'), el.iconPick, el.iconClear),
                h('div', { class: 'rm-field' }, h('span', null, 'Number'), el.numberInput)),
            h('div', { class: 'rm-badge-row' }, h('div', { class: 'rm-field' }, h('span', null, 'Picture'), el.imagePick, el.imageClear)),
            el.shapeRow,
            h('div', { class: 'rm-look-row' }, h('span', null, 'Size'), el.sizeSeg),
            h('div', { class: 'rm-look-row' }, h('span', null),
                h('label', { class: 'rm-dim', title: 'Width in pixels; empty is automatic. The title wraps inside it.' }, 'W', el.widthInput),
                h('label', { class: 'rm-dim', title: 'Height in pixels; empty is automatic. The node never gets lower than its title.' }, 'H', el.heightInput)),
            h('div', { class: 'rm-look-row' }, h('span', null, 'Content'), el.visualSeg), el.visualPane,
            h('h3', null, 'Description'), el.format, el.desc,
            el.evSection, el.connSection);
        el.panel.appendChild(el.empty);
        el.panel.appendChild(el.body);

        if (window.ResizeObserver) {
            let lastWidth = 0;
            new ResizeObserver(function () {
                const width = el.titleInput.offsetWidth;
                if (width !== lastWidth) { lastWidth = width; fitTitle(); }
            }).observe(el.titleInput);
        }
        el.titleInput.addEventListener('keydown', function (event) {
            // A title is one line: Enter confirms it instead of adding a line.
            if (event.key === 'Enter') { event.preventDefault(); el.titleInput.blur(); }
        });
        el.titleInput.addEventListener('input', function () {
            fitTitle();
            const id = rm.selected;
            if (!id) return;
            const value = el.titleInput.value.trim().replace(/\s*\n\s*/g, ' ');
            if (!value) { el.titleError.textContent = 'Enter a node name.'; return; }
            el.titleError.textContent = '';
            queueUpdate(id, { title: value });
            // Only the title text: the badge and the icon of the node card stay.
            const entry = rm.els.get(id);
            if (entry) entry.label.textContent = value;
        });
        el.titleInput.addEventListener('blur', function () {
            const id = rm.selected;
            if (!id) return;
            flushUpdate(id);
            const node = A.nodeById(id);
            if (!el.titleInput.value.trim()) { el.titleInput.value = node ? node.title : ''; el.titleError.textContent = ''; }
            else el.titleInput.value = el.titleInput.value.trim();
        });
        el.tagInput.addEventListener('keydown', function (event) {
            if (event.key !== 'Enter') return;
            event.preventDefault();
            const node = A.nodeById(rm.selected);
            const value = el.tagInput.value.trim().slice(0, MAX_TITLE);
            if (!node || !value) return;
            el.tagInput.value = '';
            if (node.tags.some(function (t) { return t.toLocaleLowerCase() === value.toLocaleLowerCase(); })) return;
            queueUpdate(node.id, { tags: node.tags.concat([value]) }, true);
        });
        el.color.addEventListener('input', function () { if (rm.selected) queueUpdate(rm.selected, { color: el.color.value.toLowerCase() }); });
        el.color.addEventListener('change', function () { if (rm.selected) queueUpdate(rm.selected, { color: el.color.value.toLowerCase() }, true); });
        el.colorClear.addEventListener('click', function () { if (rm.selected) queueUpdate(rm.selected, { color: '' }, true); });
        el.iconClear.addEventListener('click', function () { if (rm.selected) queueUpdate(rm.selected, { icon: '' }, true); });
        el.imageClear.addEventListener('click', function () { if (rm.selected) queueUpdate(rm.selected, { image: '' }, true); });
        // The number is confirmed on Enter or when the field is left; an empty field removes it.
        const sendNumber = function () {
            if (!rm.selected) return;
            const raw = el.numberInput.value.trim();
            const value = raw === '' ? null : Math.floor(Number(raw));
            if (value !== null && !(value >= 1 && value <= MAX_NUMBER)) { A.toast('A number is between 1 and ' + MAX_NUMBER + '.'); A.fillPanel(true); return; }
            const node = A.nodeById(rm.selected);
            if (node && (node.number == null ? null : node.number) === value) return;
            queueUpdate(rm.selected, { number: value }, true);
        };
        el.numberInput.addEventListener('change', sendNumber);
        el.numberInput.addEventListener('keydown', function (event) { if (event.key === 'Enter') { event.preventDefault(); sendNumber(); el.numberInput.blur(); } });
        // The width and the height are confirmed the same way; an empty field makes that value automatic.
        const sendSize = function (key, input) {
            if (!rm.selected) return;
            const range = LIMITS[key], raw = input.value.trim();
            const value = raw === '' ? null : Math.round(Number(raw));
            if (value !== null && !(value >= range[0] && value <= range[1])) { A.toast('A ' + key + ' is between ' + range[0] + ' and ' + range[1] + '.'); A.fillPanel(true); return; }
            const node = A.nodeById(rm.selected);
            if (node && A.boxOf(node)[key] === value) return;
            queueUpdate(rm.selected, key === 'width' ? { width: value } : { height: value }, true);
        };
        [el.widthInput, el.heightInput].forEach(function (input) {
            const key = input.getAttribute('data-dim');
            input.addEventListener('change', function () { sendSize(key, input); });
            input.addEventListener('keydown', function (event) { if (event.key === 'Enter') { event.preventDefault(); sendSize(key, input); input.blur(); } });
        });
        el.desc.addEventListener('input', function () { if (rm.selected) queueUpdate(rm.selected, { description: el.desc.value }); });
        el.desc.addEventListener('blur', function () { if (rm.selected) flushUpdate(rm.selected); });
        // The Mermaid source and the picture address edit the description's first fence or image (the description stays the one place).
        el.visualSource.addEventListener('input', function () { if (rm.selected) queueUpdate(rm.selected, { description: withDiagram(A.currentDescription(rm.selected), el.visualSource.value) }); });
        el.visualSource.addEventListener('blur', function () { if (rm.selected) flushUpdate(rm.selected); });
        el.imageInput.addEventListener('input', function () {
            const node = A.nodeById(rm.selected);
            if (node) queueUpdate(node.id, { description: withImage(A.currentDescription(node.id), (imageOf(A.currentDescription(node.id)) || {}).alt || node.title, el.imageInput.value) });
        });
        el.imageInput.addEventListener('blur', function () { if (rm.selected) flushUpdate(rm.selected); });
    }
    /** The title field grows with its text, so a long title is never cut off. */
    function fitTitle() {
        const box = el.titleInput;
        if (!box.offsetParent) return; // the panel is hidden: nothing to measure
        box.style.height = 'auto';
        // scrollHeight leaves out the border, and the box is border-box.
        box.style.height = (box.scrollHeight + box.offsetHeight - box.clientHeight) + 'px';
    }
    function insertMarkdown(before, after, placeholder) {
        const area = el.desc, start = area.selectionStart, end = area.selectionEnd, value = area.value;
        const chosen = value.slice(start, end) || placeholder;
        area.value = value.slice(0, start) + before + chosen + after + value.slice(end);
        area.dispatchEvent(new Event('input', { bubbles: true }));
        area.focus();
        area.setSelectionRange(start + before.length, start + before.length + chosen.length);
    }
    buildPanel();
})(window.MVResearchMapView);
