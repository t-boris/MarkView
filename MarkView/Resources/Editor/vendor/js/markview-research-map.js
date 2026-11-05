// Research map view (DEC-009). A Markdown document whose front matter says `type: research-map` is shown as a mind map
// inside the editor tab. Swift owns the file: it parses and writes the format, applies every rule, and answers each
// operation with a full snapshot through window.mvResearchMapSet(documentId, snapshot). This file only draws the
// snapshot, keeps view state (selection, pan, zoom, panel width) and sends operations as
// sendToSwift('researchMap', {action, ...}). Positions come from markview-research-map-layout.js.
//
// Like the other overlay views (data, code, architecture, canvas) it takes over the editor area, and it wraps
// setContent / setStructuredContent / setCodeContent / setDataContent / showArchitecture / switchToSource /
// switchToPreview / the mode toggles, so the map and the Source view alternate and every other document leaves it.
(function () {
    'use strict';

    const Layout = window.MVResearchMapLayout;
    const host = document.querySelector('.editor-content');
    if (!Layout || !host || typeof DOM === 'undefined' || typeof state === 'undefined') return;

    const NS = 'http://www.w3.org/2000/svg';
    // [border, tint] per top-level branch: the prototype's palette.
    const PALETTE = [['#548d9a', '#eaf5f6'], ['#b08168', '#fbf1eb'], ['#8584ad', '#f0eff9'], ['#83a074', '#eef7eb'], ['#b27787', '#faeef1'], ['#b19a59', '#faf6e8']];
    const MIN_SCALE = 0.4, MAX_SCALE = 2;
    const PANEL_MIN = 240, PANEL_MAX = 600, PANEL_DEFAULT = 320;
    const MAX_TITLE = 120;
    const ICONS = {
        plus: 'M12 5v14M5 12h14',
        minus: 'M5 12h14',
        sparkle: 'M12 3l2.2 6.8L21 12l-6.8 2.2L12 21l-2.2-6.8L3 12l6.8-2.2z',
        link: 'M3 12h18M7 8l-4 4 4 4M17 8l4 4-4 4',
        edit: 'M4 20l1-4L16 5l3 3L8 19zM14 7l3 3',
        move: 'M5 4v8a4 4 0 0 0 4 4h9M14 12l4 4-4 4',
        grid: 'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z',
        trash: 'M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6',
        source: 'M8 7l-5 5 5 5M16 7l5 5-5 5M14 5l-4 14',
        centre: 'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM12 2v3M12 19v3M2 12h3M19 12h3',
        search: 'M10 4a6 6 0 1 0 0 12 6 6 0 0 0 0-12zM15 15l5 5',
        stop: 'M7 7h10v10H7z',
        play: 'M8 5l11 7-11 7z',
        close: 'M6 6l12 12M18 6L6 18',
        open: 'M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5'
    };

    // ---- small helpers -----------------------------------------------------------------------------------------------
    function append(parent, child) {
        if (child == null || child === false) return;
        if (Array.isArray(child)) { child.forEach(function (c) { append(parent, c); }); return; }
        parent.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    function h(tag, attrs) {
        const node = document.createElement(tag);
        if (attrs) {
            Object.keys(attrs).forEach(function (key) {
                const value = attrs[key];
                if (value == null || value === false) return;
                if (key === 'class') node.className = value;
                else if (key === 'text') node.textContent = value;
                else if (key.indexOf('on') === 0 && typeof value === 'function') node.addEventListener(key.slice(2).toLowerCase(), value);
                else if (key === 'value' || key === 'disabled' || key === 'hidden') node[key] = value;
                else node.setAttribute(key, value === true ? '' : value);
            });
        }
        for (let i = 2; i < arguments.length; i++) append(node, arguments[i]);
        return node;
    }
    function icon(name) {
        const svg = document.createElementNS(NS, 'svg');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('stroke-width', '2');
        svg.setAttribute('stroke-linecap', 'round');
        svg.setAttribute('stroke-linejoin', 'round');
        svg.setAttribute('aria-hidden', 'true');
        const path = document.createElementNS(NS, 'path');
        path.setAttribute('d', ICONS[name] || '');
        svg.appendChild(path);
        return svg;
    }
    function clamp(value, low, high) { return Math.max(low, Math.min(high, value)); }
    function now() { return (typeof performance !== 'undefined' && performance.now) ? performance.now() : Date.now(); }
    function reportError(where, error) {
        try { if (typeof sendToSwift === 'function') sendToSwift('jsError', { where: 'research-map ' + where, message: String(error && error.message || error), source: 'markview-research-map.js', lineno: 0, colno: 0, stack: String(error && error.stack || '') }); } catch (_) { /* never throw from the reporter */ }
    }

    /** `---` front matter with `type: research-map`. */
    function isResearchMapText(text) {
        if (typeof text !== 'string') return false;
        const match = /^﻿?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/.exec(text);
        return !!match && /^type[ \t]*:[ \t]*["']?research-map["']?[ \t]*(?:#.*)?$/m.test(match[1]);
    }

    function hexToRgb(hex) {
        const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex || '');
        return m ? [parseInt(m[1], 16), parseInt(m[2], 16), parseInt(m[3], 16)] : null;
    }
    function mix(hex, base, amount) {
        const a = hexToRgb(hex), b = hexToRgb(base);
        if (!a || !b) return base;
        const c = a.map(function (v, i) { return Math.round(v * amount + b[i] * (1 - amount)); });
        return '#' + c.map(function (v) { return v.toString(16).padStart(2, '0'); }).join('');
    }
    function readableOn(hex) {
        const c = hexToRgb(hex);
        if (!c) return '#fff';
        return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) > 160 ? '#1c1c24' : '#fff';
    }

    // ---- view state ---------------------------------------------------------------------------------------------------
    const rm = {
        active: false,
        docId: null,
        snap: null,
        mapKey: '',
        sourceBase: null,     // the Source text as of the last sync with Swift (see applySnapshot)
        selected: null,       // null until the first snapshot picks one; '' is "nothing selected"
        fallbackSelect: '',   // what to select when the selected node disappears (the parent of a deleted node)
        view: { x: 0, y: 0, scale: 1 },
        viewReady: false,
        panelWidth: PANEL_DEFAULT,
        positions: {},
        sizes: {},
        moves: {},            // moves not yet confirmed by a snapshot: id -> {x, y, sent}
        moveQueue: {},        // keyboard moves waiting to be sent: id -> {doc, x, y, timer}
        drag: null,           // {id, x, y} while a node is being dragged
        pending: {},          // property edits waiting to be sent: id -> {doc, fields, timer}
        els: new Map(),
        panelFor: null,
        menu: null,
        dialog: null,
        lastDragEnd: 0,
        saveTimer: 0,
        toastTimer: 0,
        ticker: 0,
        queriesOpen: false
    };

    // ---- operations to Swift -------------------------------------------------------------------------------------------
    function sendAs(doc, action, fields) {
        if (typeof sendToSwift !== 'function') return;
        const payload = Object.assign({ action: action }, fields || {});
        const current = window.mvDocumentId;
        if (doc !== undefined && doc !== (current || '')) {
            // The edit belongs to the document that was shown when it was made, not the one shown now.
            window.mvDocumentId = doc;
            try { sendToSwift('researchMap', payload); } finally { window.mvDocumentId = current; }
        } else sendToSwift('researchMap', payload);
    }
    function send(action, fields) { sendAs(undefined, action, fields); }

    function queueUpdate(id, patch, immediately) {
        let entry = rm.pending[id];
        if (!entry) entry = rm.pending[id] = { doc: window.mvDocumentId || '', fields: {}, timer: 0 };
        Object.assign(entry.fields, patch);
        clearTimeout(entry.timer);
        if (immediately) flushUpdate(id);
        else entry.timer = setTimeout(function () { flushUpdate(id); }, 300);
    }
    function flushUpdate(id) {
        const entry = rm.pending[id];
        if (!entry) return;
        clearTimeout(entry.timer);
        delete rm.pending[id];
        if (Object.keys(entry.fields).length) sendAs(entry.doc, 'update', Object.assign({ id: id }, entry.fields));
    }
    function queueMove(id, x, y) {
        let entry = rm.moveQueue[id];
        if (!entry) entry = rm.moveQueue[id] = { doc: window.mvDocumentId || '', x: x, y: y, timer: 0 };
        entry.x = x;
        entry.y = y;
        clearTimeout(entry.timer);
        entry.timer = setTimeout(function () { flushMove(id); }, 250);
    }
    function flushMove(id) {
        const entry = rm.moveQueue[id];
        if (!entry) return;
        clearTimeout(entry.timer);
        delete rm.moveQueue[id];
        if (rm.moves[id]) rm.moves[id].sent = true;
        sendAs(entry.doc, 'moveVisual', { id: id, x: entry.x, y: entry.y });
    }
    function flushAll() {
        Object.keys(rm.pending).forEach(flushUpdate);
        Object.keys(rm.moveQueue).forEach(flushMove);
    }

    // ---- persistence of the view (per map) -----------------------------------------------------------------------------
    function loadSaved() {
        try { const raw = localStorage.getItem(rm.mapKey); return raw ? JSON.parse(raw) : null; } catch (e) { return null; }
    }
    function saveNow() {
        if (!rm.mapKey) return;
        try {
            localStorage.setItem(rm.mapKey, JSON.stringify({ x: rm.view.x, y: rm.view.y, scale: rm.view.scale, panel: rm.panelWidth, selected: rm.selected == null ? '' : rm.selected }));
        } catch (e) { /* storage may be unavailable */ }
    }
    function saveSoon() {
        clearTimeout(rm.saveTimer);
        rm.saveTimer = setTimeout(saveNow, 120);
    }

    // ---- styles --------------------------------------------------------------------------------------------------------
    const css = `
    .rm-root { display: none; flex: 1; min-width: 0; min-height: 0; flex-direction: column; position: relative; overflow: hidden; background: var(--rm-page); color: var(--rm-ink); font-family: var(--font-sans); font-size: calc(14px * var(--ui-scale, 1)); line-height: 1.5;
        --rm-page: #17171e; --rm-bar: #24232d; --rm-line: #41404d; --rm-ink: #eeeef5; --rm-muted: #b0afbf; --rm-vp: #1d1c25; --rm-dots: #484354;
        --rm-tool-bg: #31483d; --rm-tool-fg: #e1f2e8; --rm-tool-hover: #426253; --rm-node-bg: #302e3a; --rm-node-ink: #eeeef5; --rm-root-bg: #59499c; --rm-root-ink: #fff;
        --rm-icon-bg: #302e3a; --rm-icon-fg: #eeeef5; --rm-icon-hover: #403b50; --rm-actions-bg: #302e3a; --rm-panel: #24232d; --rm-input: #1d1c25;
        --rm-tag-bg: #40395a; --rm-tag-fg: #ded6ff; --rm-error: #ff9da5; --rm-divider: #393743; --rm-handle: #9eb4b1; --rm-hint-bg: #302e3aeb; --rm-hint-fg: #d4d1df;
        --rm-ring: #9e8cf2; --rm-primary: #7563cb; --rm-danger: #a6384a; --rm-focus: #71bdaa; --rm-warn-bg: #4a3a1c; --rm-warn-fg: #f0d9a5; --rm-status-bg: #2f3a36;
        --rm-shadow: 0 5px 0 #302b3a0d, 0 12px 26px #302b3a12; --rm-root-shadow: 0 8px 0 #3e3178, 0 16px 32px #51419636; --rm-pop: 0 10px 24px #00000066; }
    html[data-theme="light"] .rm-root {
        --rm-page: #f3f1ed; --rm-bar: #fffefa; --rm-line: #e9e5e0; --rm-ink: #242b39; --rm-muted: #6e7481; --rm-vp: #f5f3ef; --rm-dots: #d9d3e1;
        --rm-tool-bg: #fff; --rm-tool-fg: #245c55; --rm-tool-hover: #d7ebe3; --rm-node-bg: #fff; --rm-node-ink: #263c40; --rm-root-bg: #514196;
        --rm-icon-bg: #f6f3fc; --rm-icon-fg: #514196; --rm-icon-hover: #eae4fa; --rm-actions-bg: #fffefa; --rm-panel: #fffefa; --rm-input: #eff5f1;
        --rm-tag-bg: #e4f0e9; --rm-tag-fg: #315b50; --rm-error: #b33d48; --rm-divider: #ede9e5; --rm-hint-bg: #fffefae8; --rm-hint-fg: #777184;
        --rm-primary: #6654bb; --rm-danger: #ad4754; --rm-warn-bg: #fbf0d6; --rm-warn-fg: #6a4a10; --rm-status-bg: #e4f0e9;
        --rm-shadow: 0 5px 0 #302b3a0d, 0 12px 26px #302b3a12; --rm-root-shadow: 0 8px 0 #3e3178, 0 16px 32px #51419636; --rm-pop: 0 10px 24px #302b3a30; }
    .rm-root.visible { display: flex; }
    .rm-root [hidden] { display: none !important; }
    .rm-root button { font: inherit; }
    .rm-toolbar { position: relative; display: flex; align-items: center; gap: 6px; padding: 6px 10px; min-height: calc(40px * var(--ui-scale, 1)); background: var(--rm-bar); border-bottom: 1px solid var(--rm-line); }
    .rm-tool { position: relative; display: inline-grid; place-items: center; flex: none; width: calc(28px * var(--ui-scale, 1)); height: calc(28px * var(--ui-scale, 1)); padding: 0; border: 0; border-radius: 9px; background: var(--rm-tool-bg); color: var(--rm-tool-fg); box-shadow: 0 2px 8px #1f514b18; cursor: pointer; }
    .rm-tool:hover:not(:disabled) { background: var(--rm-tool-hover); }
    .rm-tool svg { width: 16px; height: 16px; }
    .rm-tool .rm-count { position: absolute; top: -5px; right: -5px; min-width: 15px; height: 15px; padding: 0 3px; border-radius: 8px; background: var(--rm-primary); color: #fff; font-size: 10px; line-height: 15px; text-align: center; }
    .rm-heading { display: flex; flex-direction: column; flex: 1; min-width: 0; margin-left: 4px; line-height: 1.25; }
    .rm-heading strong { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 1.05em; }
    .rm-heading span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--rm-muted); font-size: .86em; }
    .rm-heading span:empty { display: none; }
    .rm-zoom { min-width: 3.2em; text-align: center; color: var(--rm-muted); font-variant-numeric: tabular-nums; }
    .rm-status { display: inline-flex; align-items: center; gap: 8px; min-width: 0; max-width: 46%; padding: 3px 4px 3px 10px; border-radius: 999px; background: var(--rm-status-bg); font-size: .92em; }
    .rm-status.warn { background: var(--rm-warn-bg); color: var(--rm-warn-fg); }
    .rm-status[hidden] { display: none; }
    .rm-status-text { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .rm-spin { flex: none; width: 12px; height: 12px; border: 2px solid currentColor; border-right-color: transparent; border-radius: 50%; animation: rm-spin .9s linear infinite; }
    @keyframes rm-spin { to { transform: rotate(360deg); } }
    .rm-chip-btn { flex: none; display: inline-flex; align-items: center; gap: 4px; padding: 2px 10px; border: 0; border-radius: 999px; background: var(--rm-tool-bg); color: var(--rm-tool-fg); cursor: pointer; }
    .rm-chip-btn:hover { background: var(--rm-tool-hover); }
    .rm-chip-btn svg { width: 11px; height: 11px; }
    .rm-popover { position: absolute; z-index: 20; top: calc(100% + 4px); right: 10px; width: min(420px, 80%); max-height: 50vh; overflow: auto; padding: 8px 12px; border: 1px solid var(--rm-line); border-radius: 12px; background: var(--rm-bar); box-shadow: var(--rm-pop); }
    .rm-popover h3 { margin: 0 0 4px; font-size: .9em; color: var(--rm-muted); font-weight: 700; }
    .rm-popover ol { margin: 0; padding-left: 20px; }
    .rm-popover li { margin: 3px 0; overflow-wrap: anywhere; }
    .rm-workspace { display: flex; flex: 1; min-height: 0; --rm-panel-width: ${PANEL_DEFAULT}px; }
    .rm-left { position: relative; display: flex; flex: 1; min-width: 0; flex-direction: column; }
    .rm-viewport { position: relative; flex: 1; overflow: hidden; touch-action: none; cursor: grab; background-color: var(--rm-vp); background-image: radial-gradient(var(--rm-dots) 1px, transparent 1px); background-size: 24px 24px; outline: none; }
    .rm-viewport.is-panning { cursor: grabbing; }
    .rm-world { position: absolute; left: 0; top: 0; width: 1px; height: 1px; transform-origin: 0 0; }
    .rm-lines { position: absolute; left: 0; top: 0; overflow: visible; pointer-events: none; }
    .rm-loading { position: absolute; inset: 0; display: grid; place-items: center; color: var(--rm-muted); pointer-events: none; }
    .rm-loading:empty { display: none; }
    .rm-hint { position: absolute; left: 14px; bottom: 12px; padding: 5px 10px; border-radius: 10px; background: var(--rm-hint-bg); color: var(--rm-hint-fg); font-size: .86em; pointer-events: none; }
    .rm-readout { position: absolute; right: 14px; bottom: 12px; padding: 5px 10px; border-radius: 10px; background: var(--rm-hint-bg); color: var(--rm-hint-fg); font-size: .86em; font-variant-numeric: tabular-nums; pointer-events: none; }
    .rm-readout[hidden] { display: none; }
    .rm-node-wrap { position: absolute; transform: translate(-50%, -50%); z-index: 1; width: max-content; max-width: 220px; }
    .rm-node-wrap.menu-open { z-index: 4; }
    .rm-node { position: relative; display: block; min-width: 110px; max-width: 220px; margin: 0; padding: 11px 28px 11px 17px; border: 2px solid var(--branch, #548d9a); border-radius: 15px; background: var(--rm-node-bg); color: var(--rm-node-ink);
        box-shadow: var(--rm-shadow); text-align: center; white-space: normal; overflow-wrap: anywhere; line-height: 1.3; font-weight: 650; cursor: grab; touch-action: none; -webkit-user-select: none; user-select: none; }
    .rm-node:active { cursor: grabbing; }
    .rm-node.root { min-width: 170px; padding: 18px 28px 18px 24px; border: 0; border-radius: 20px; background: var(--rm-root-bg); color: var(--rm-root-ink); font-size: calc(16px * var(--ui-scale, 1)); box-shadow: var(--rm-root-shadow); }
    .rm-node.has-color { background: var(--tint-dark); }
    html[data-theme="light"] .rm-node.branch, html[data-theme="light"] .rm-node.has-color { background: var(--tint); }
    .rm-node.root.has-color { background: var(--branch); color: var(--root-ink, #fff); }
    html[data-theme="light"] .rm-node.root.has-color { background: var(--branch); }
    .rm-node[aria-pressed="true"] { outline: 3px solid var(--rm-ring); outline-offset: 3px; }
    .rm-tri { position: absolute; top: 4px; right: 5px; z-index: 2; display: grid; place-items: center; width: 18px; height: 18px; padding: 0; border: 0; border-radius: 50%; background: transparent; color: var(--rm-node-ink); opacity: .5; cursor: pointer; font-size: 11px; line-height: 1; }
    .rm-node-wrap.is-root .rm-tri { color: var(--rm-root-ink); }
    .rm-tri:hover, .rm-node-wrap.menu-open .rm-tri { opacity: 1; }
    .rm-actions { position: absolute; right: 5px; top: 24px; z-index: 5; display: flex; gap: 4px; padding: 5px; border-radius: 12px; background: var(--rm-actions-bg); box-shadow: var(--rm-pop); cursor: default; }
    .rm-icon { display: inline-grid; place-items: center; flex: none; width: 26px; height: 26px; padding: 0; border: 0; border-radius: 8px; background: var(--rm-icon-bg); color: var(--rm-icon-fg); cursor: pointer; }
    .rm-icon svg { width: 15px; height: 15px; }
    .rm-icon:hover:not(:disabled) { background: var(--rm-icon-hover); }
    .rm-icon:disabled { opacity: .35; cursor: not-allowed; }
    .rm-layouts { position: absolute; right: 0; top: calc(100% + 6px); display: flex; flex-direction: column; min-width: 150px; padding: 4px; border-radius: 10px; background: var(--rm-actions-bg); box-shadow: var(--rm-pop); }
    .rm-layouts button { display: flex; align-items: center; gap: 6px; padding: 5px 8px; border: 0; border-radius: 6px; background: transparent; color: var(--rm-ink); text-align: left; white-space: nowrap; cursor: pointer; }
    .rm-layouts button:hover { background: var(--rm-icon-hover); }
    .rm-layouts button[aria-checked="true"] { font-weight: 700; }
    .rm-layouts .rm-check { width: 1em; color: var(--rm-ring); }
    .rm-divider { position: relative; flex: none; width: 9px; background: var(--rm-divider); cursor: col-resize; touch-action: none; }
    .rm-divider::after { content: ''; position: absolute; top: 45%; bottom: 45%; left: 3px; width: 3px; border-radius: 3px; background: var(--rm-handle); }
    .rm-panel { display: flex; flex-direction: column; gap: 12px; flex: none; width: var(--rm-panel-width); min-width: ${PANEL_MIN}px; max-width: 60%; padding: 20px; overflow: auto; background: var(--rm-panel); color: var(--rm-ink); box-shadow: -12px 0 36px #302b3a0b; }
    .rm-panel[hidden] { display: none; }
    .rm-panel-body { display: flex; flex: 1; flex-direction: column; gap: 12px; min-height: 0; }
    .rm-panel-body[hidden], .rm-empty[hidden], .rm-section[hidden] { display: none; }
    .rm-empty { margin: 0; color: var(--rm-muted); }
    .rm-panel input, .rm-panel textarea, .rm-dialog input, .rm-dialog select { font: inherit; color: var(--rm-ink); }
    .rm-panel .rm-title-input { width: 100%; min-height: 44px; padding: 5px 0; border: 0; border-bottom: 2px solid transparent; border-radius: 0; background: transparent; font-size: calc(21px * var(--ui-scale, 1)); font-weight: 700; outline: none; }
    .rm-panel .rm-title-input:focus { border-bottom-color: var(--rm-focus); }
    .rm-error { margin: -6px 0 0; color: var(--rm-error); font-size: .9em; }
    .rm-error:empty { display: none; }
    .rm-tags { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; }
    .rm-tag { display: inline-flex; align-items: center; gap: 5px; padding: 4px 8px; border-radius: 9px; background: var(--rm-tag-bg); color: var(--rm-tag-fg); font-size: .86em; }
    .rm-tag button { padding: 0; border: 0; background: transparent; color: inherit; font-size: 15px; line-height: 1; cursor: pointer; }
    .rm-tag-input { flex: 1; min-width: 90px; padding: 4px 2px; border: 0; background: transparent; outline: none; }
    .rm-tag-input::placeholder, .rm-desc::placeholder { color: var(--rm-muted); }
    .rm-color-row { display: flex; align-items: center; gap: 8px; color: var(--rm-muted); font-size: .86em; }
    .rm-color-row input[type=color] { width: 34px; height: 30px; padding: 2px; border: 0; border-radius: 10px; background: var(--rm-tag-bg); cursor: pointer; }
    .rm-panel h3 { margin: 4px 0 0; font-size: 1em; color: var(--rm-ink); }
    .rm-format { display: flex; flex-wrap: wrap; gap: 6px; }
    .rm-format .rm-icon { background: var(--rm-icon-bg); font-size: .9em; font-weight: 700; }
    .rm-desc { flex: 1 1 180px; width: 100%; min-height: 140px; padding: 12px; border: 0; border-radius: 12px; background: var(--rm-input); line-height: 1.6; resize: vertical; outline: none; }
    .rm-desc:focus-visible, .rm-tool:focus-visible, .rm-icon:focus-visible, .rm-node:focus-visible, .rm-chip-btn:focus-visible { outline: 3px solid var(--rm-focus); outline-offset: 2px; }
    .rm-section { display: flex; flex: none; flex-direction: column; gap: 6px; }
    .rm-list { margin: 0; padding: 0; list-style: none; display: flex; flex-direction: column; gap: 8px; }
    .rm-ev-row { display: flex; flex-direction: column; gap: 3px; padding: 8px 10px; border-radius: 10px; background: var(--rm-input); }
    .rm-ev-chip { align-self: flex-start; padding: 1px 8px; border-radius: 999px; background: #3b3b4a; color: #e2e2ee; font-size: .76em; font-weight: 700; letter-spacing: .02em; white-space: nowrap; }
    .rm-ev-chip[data-label="Project fact"] { background: #1f4b44; color: #8fe3d0; }
    .rm-ev-chip[data-label="External fact"] { background: #1f3a5c; color: #9cc6f5; }
    .rm-ev-chip[data-label="AI inference"] { background: #40395a; color: #ded6ff; }
    .rm-ev-chip[data-label="Open assumption"] { background: #5a4519; color: #f0d08a; }
    html[data-theme="light"] .rm-ev-chip { background: #e6e6ee; color: #3a3a4a; }
    html[data-theme="light"] .rm-ev-chip[data-label="Project fact"] { background: #d6f0ea; color: #17695a; }
    html[data-theme="light"] .rm-ev-chip[data-label="External fact"] { background: #dbe8f8; color: #1d4f86; }
    html[data-theme="light"] .rm-ev-chip[data-label="AI inference"] { background: #e8e3f8; color: #4a3a98; }
    html[data-theme="light"] .rm-ev-chip[data-label="Open assumption"] { background: #f8ebc9; color: #6a4a10; }
    .rm-ev-text { overflow-wrap: anywhere; }
    .rm-ev-source { align-self: flex-start; max-width: 100%; padding: 0; border: 0; background: transparent; color: var(--rm-tag-fg); font-size: .86em; text-align: left; text-decoration: underline; overflow-wrap: anywhere; cursor: pointer; }
    .rm-conn-row { display: flex; align-items: center; gap: 6px; padding: 4px 4px 4px 10px; border-radius: 10px; background: var(--rm-input); }
    .rm-conn-name { flex: 1; min-width: 0; padding: 0; border: 0; background: transparent; color: var(--rm-ink); text-align: left; overflow-wrap: anywhere; cursor: pointer; }
    .rm-x { display: inline-grid; place-items: center; flex: none; width: 22px; height: 22px; padding: 0; border: 0; border-radius: 6px; background: transparent; color: var(--rm-muted); cursor: pointer; }
    .rm-x:hover { background: var(--rm-icon-hover); color: var(--rm-ink); }
    .rm-x svg { width: 12px; height: 12px; }
    .rm-modal { position: absolute; inset: 0; z-index: 50; display: flex; align-items: center; justify-content: center; padding: 16px; background: #10101880; }
    .rm-dialog { width: 100%; max-width: 420px; max-height: 90%; overflow: auto; border: 1px solid var(--rm-line); border-radius: 16px; background: var(--rm-bar); color: var(--rm-ink); box-shadow: 0 24px 70px #10202b66; }
    .rm-dialog h2 { margin: 0; padding: 16px 20px 0; font-size: 1.15em; }
    .rm-dialog-body { display: flex; flex-direction: column; gap: 10px; padding: 12px 20px; }
    .rm-dialog-body p { margin: 0; overflow-wrap: anywhere; }
    .rm-dialog label { display: flex; flex-direction: column; gap: 4px; color: var(--rm-muted); font-size: .9em; }
    .rm-dialog input, .rm-dialog select { width: 100%; min-height: 32px; padding: 5px 9px; border: 1px solid var(--rm-line); border-radius: 9px; background: var(--rm-input); }
    .rm-dialog-actions { display: flex; justify-content: flex-end; gap: 8px; padding: 6px 20px 16px; }
    .rm-btn { min-height: 30px; padding: 4px 14px; border: 1px solid var(--rm-line); border-radius: 10px; background: var(--rm-icon-bg); color: var(--rm-ink); font-weight: 650; cursor: pointer; }
    .rm-btn:hover { background: var(--rm-icon-hover); }
    .rm-btn.primary { border-color: var(--rm-primary); background: var(--rm-primary); color: #fff; }
    .rm-btn.danger { border-color: var(--rm-danger); background: var(--rm-danger); color: #fff; }
    .rm-toast { position: absolute; left: 50%; bottom: 46px; z-index: 60; transform: translateX(-50%); max-width: 70%; padding: 8px 14px; border-radius: 10px; background: #444151; color: #fff; box-shadow: var(--rm-pop); pointer-events: none; }
    .rm-toast[hidden] { display: none; }
    .rm-problem { display: none; align-items: center; gap: 10px; padding: 4px 12px; background: var(--rm-warn-bg, #4a3a1c); color: var(--rm-warn-fg, #f0d9a5); font-size: calc(12px * var(--ui-scale, 1)); border-bottom: 1px solid #00000033; }
    .rm-problem.visible { display: flex; }
    .rm-problem span { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .rm-problem button { border: 0; background: transparent; color: inherit; cursor: pointer; font-size: 14px; }
    html[data-theme="light"] .rm-problem { --rm-warn-bg: #fbf0d6; --rm-warn-fg: #6a4a10; }
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
    function tool(act, label, content, handler) {
        return h('button', { class: 'rm-tool', type: 'button', 'data-act': act, title: label, 'aria-label': label, onClick: handler }, content);
    }
    el.sourceBtn = tool('source', 'Show the Markdown source (the Map toggle in the top bar brings the map back)', icon('source'), function () { goSource(); });
    el.title = h('strong');
    el.question = h('span');
    el.status = h('div', { class: 'rm-status', hidden: true, 'aria-live': 'polite' });
    el.queryCount = h('span', { class: 'rm-count' });
    el.queriesBtn = tool('queries', 'Web searches the research ran', [icon('search'), el.queryCount], function (e) { e.stopPropagation(); toggleQueries(); });
    el.queriesBtn.hidden = true;
    el.zoom = h('span', { class: 'rm-zoom', 'aria-live': 'polite' });
    el.popover = h('div', { class: 'rm-popover', hidden: true, role: 'dialog', 'aria-label': 'Web searches' });
    el.toolbar = h('div', { class: 'rm-toolbar' },
        el.sourceBtn,
        h('div', { class: 'rm-heading' }, el.title, el.question),
        el.status,
        el.queriesBtn,
        tool('zoom-out', 'Zoom out', icon('minus'), function () { zoomAtCentre(rm.view.scale / 1.2); }),
        el.zoom,
        tool('zoom-in', 'Zoom in', icon('plus'), function () { zoomAtCentre(rm.view.scale * 1.2); }),
        tool('centre', 'Centre the map on the root node at 100%', icon('centre'), function () { centreView(); }),
        el.popover);

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
    el.problem = h('div', { class: 'rm-problem', id: 'research-map-problem', role: 'alert' }, el.problemText, h('button', { type: 'button', 'aria-label': 'Dismiss', onClick: function () { hideProblem(); } }, '✕'));
    if (host.parentNode) host.parentNode.insertBefore(el.problem, host);

    // ---- the properties panel (built once, filled per node) ---------------------------------------------------------------
    function buildPanel() {
        el.empty = h('p', { class: 'rm-empty' }, 'Select a node on the map');
        el.titleInput = h('input', { class: 'rm-title-input', maxlength: String(MAX_TITLE), 'aria-label': 'Node name', spellcheck: 'false' });
        el.titleError = h('p', { class: 'rm-error', role: 'alert' });
        el.tagInput = h('input', { class: 'rm-tag-input', maxlength: String(MAX_TITLE), placeholder: 'Add tag', 'aria-label': 'Add tag' });
        el.tags = h('div', { class: 'rm-tags' }, el.tagInput);
        el.color = h('input', { class: 'rm-color-input', type: 'color', 'aria-label': 'Node color', title: 'Node color' });
        el.colorClear = h('button', { class: 'rm-x', type: 'button', title: 'Use the branch colour', 'aria-label': 'Use the branch colour' }, icon('close'));
        el.desc = h('textarea', { class: 'rm-desc', 'aria-label': 'Markdown description', placeholder: 'Add a Markdown description' });
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
        el.body = h('div', { class: 'rm-panel-body', hidden: true },
            el.titleInput, el.titleError, el.tags,
            h('div', { class: 'rm-color-row' }, h('span', null, 'Color'), el.color, el.colorClear),
            h('h3', null, 'Description'), el.format, el.desc,
            el.evSection, el.connSection);
        el.panel.appendChild(el.empty);
        el.panel.appendChild(el.body);

        el.titleInput.addEventListener('input', function () {
            const id = rm.selected;
            if (!id) return;
            const value = el.titleInput.value.trim();
            if (!value) { el.titleError.textContent = 'Enter a node name.'; return; }
            el.titleError.textContent = '';
            queueUpdate(id, { title: value });
            const entry = rm.els.get(id);
            if (entry) entry.btn.textContent = value;
        });
        el.titleInput.addEventListener('blur', function () {
            const id = rm.selected;
            if (!id) return;
            flushUpdate(id);
            const node = nodeById(id);
            if (!el.titleInput.value.trim()) { el.titleInput.value = node ? node.title : ''; el.titleError.textContent = ''; }
            else el.titleInput.value = el.titleInput.value.trim();
        });
        el.tagInput.addEventListener('keydown', function (event) {
            if (event.key !== 'Enter') return;
            event.preventDefault();
            const node = nodeById(rm.selected);
            const value = el.tagInput.value.trim().slice(0, MAX_TITLE);
            if (!node || !value) return;
            el.tagInput.value = '';
            if (node.tags.some(function (t) { return t.toLocaleLowerCase() === value.toLocaleLowerCase(); })) return;
            queueUpdate(node.id, { tags: node.tags.concat([value]) }, true);
        });
        el.color.addEventListener('input', function () { if (rm.selected) queueUpdate(rm.selected, { color: el.color.value.toLowerCase() }); });
        el.color.addEventListener('change', function () { if (rm.selected) queueUpdate(rm.selected, { color: el.color.value.toLowerCase() }, true); });
        el.colorClear.addEventListener('click', function () { if (rm.selected) queueUpdate(rm.selected, { color: '' }, true); });
        el.desc.addEventListener('input', function () { if (rm.selected) queueUpdate(rm.selected, { description: el.desc.value }); });
        el.desc.addEventListener('blur', function () { if (rm.selected) flushUpdate(rm.selected); });
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

    // ---- snapshot ----------------------------------------------------------------------------------------------------------
    function nodeById(id) {
        if (!rm.snap || !id) return null;
        return rm.snap.byId.get(id) || null;
    }
    function text(value) { return typeof value === 'string' ? value : (value == null ? '' : String(value)); }
    function normalise(raw) {
        const snap = { ok: true, problem: '' };
        if (!raw || typeof raw !== 'object') return { ok: false, problem: 'The map data is missing.' };
        if (raw.ok === false) return { ok: false, problem: text(raw.problem) || 'This file cannot be shown as a research map.' };
        const nodes = [];
        const seen = new Set();
        (Array.isArray(raw.nodes) ? raw.nodes : []).forEach(function (n) {
            if (!n || typeof n.id !== 'string' || !n.id || seen.has(n.id)) return;
            seen.add(n.id);
            nodes.push({
                id: n.id,
                parent: text(n.parent),
                title: text(n.title),
                tags: (Array.isArray(n.tags) ? n.tags : []).map(text).filter(Boolean),
                color: /^#[0-9a-f]{6}$/i.test(n.color || '') ? n.color.toLowerCase() : '',
                description: text(n.description),
                layout: text(n.layout),
                x: typeof n.x === 'number' && isFinite(n.x) ? n.x : null,
                y: typeof n.y === 'number' && isFinite(n.y) ? n.y : null,
                evidence: (Array.isArray(n.evidence) ? n.evidence : []).filter(Boolean).map(function (e) { return { label: text(e.label), text: text(e.text), source: text(e.source) }; })
            });
        });
        if (!nodes.length) return { ok: false, problem: 'The research map has no nodes.' };
        snap.id = text(raw.id);
        snap.title = text(raw.title);
        snap.question = text(raw.question);
        snap.status = text(raw.status);
        snap.incomplete = text(raw.incomplete);
        const job = raw.job && typeof raw.job === 'object' ? raw.job : null;
        snap.job = job ? { kind: text(job.kind), label: text(job.label), step: text(job.step), startedAt: typeof job.startedAt === 'number' ? job.startedAt : 0 } : null;
        snap.webQueries = (Array.isArray(raw.webQueries) ? raw.webQueries : []).map(text).filter(Boolean);
        snap.nodes = nodes;
        snap.byId = new Map(nodes.map(function (n) { return [n.id, n]; }));
        snap.links = (Array.isArray(raw.links) ? raw.links : []).filter(function (l) { return l && snap.byId.has(l.from) && snap.byId.has(l.to) && l.from !== l.to; }).map(function (l) { return { from: l.from, to: l.to }; });
        snap.layouts = (Array.isArray(raw.layouts) ? raw.layouts : []).filter(function (l) { return l && typeof l.id === 'string'; }).map(function (l) { return { id: l.id, name: text(l.name) || l.id }; });
        snap.created = text(raw.created);
        snap.notice = text(raw.notice);
        snap.markdown = typeof raw.markdown === 'string' ? raw.markdown : null;
        return snap;
    }

    /** Called by Swift: the whole state of the map, after a snapshot request, after every operation, and while an AI job adds nodes. */
    window.mvResearchMapSet = function (documentId, snapshot) {
        if (String(documentId == null ? '' : documentId) !== String(window.mvDocumentId || '')) return;
        try { applySnapshot(snapshot); } catch (e) { reportError('mvResearchMapSet', e); }
    };

    function applySnapshot(raw) {
        const snap = normalise(raw);
        if (!snap.ok) {
            rm.snap = null;
            showProblem(snap.problem);
            if (rm.active) { window.leaveResearchMap(); window.switchToSource(); }
            return;
        }
        hideProblem();
        const firstOfMap = !rm.snap || rm.snap.id !== snap.id || !rm.mapKey;
        rm.snap = snap;
        if (firstOfMap) {
            rm.mapKey = 'mvMap:' + (snap.id || ('doc-' + rm.docId));
            const saved = loadSaved();
            rm.view = { x: 0, y: 0, scale: 1 };
            rm.viewReady = false;
            rm.panelWidth = PANEL_DEFAULT;
            rm.selected = null;
            if (saved) {
                if (typeof saved.x === 'number' && typeof saved.y === 'number') { rm.view = { x: saved.x, y: saved.y, scale: clamp(Number(saved.scale) || 1, MIN_SCALE, MAX_SCALE) }; rm.viewReady = true; }
                if (typeof saved.panel === 'number') rm.panelWidth = clamp(saved.panel, PANEL_MIN, PANEL_MAX);
                if (typeof saved.selected === 'string') rm.selected = saved.selected;
            }
        }
        // A move the page has sent is shown at once; the next snapshot is Swift's answer (or its refusal) and replaces it.
        // A keyboard move that is still waiting to be sent stays.
        Object.keys(rm.moves).forEach(function (id) {
            if (!snap.byId.has(id) || rm.moves[id].sent) delete rm.moves[id];
        });
        if (rm.selected === null || (rm.selected !== '' && !snap.byId.has(rm.selected))) {
            rm.selected = snap.byId.has(rm.fallbackSelect) ? rm.fallbackSelect : snap.nodes[0].id;
        }
        rm.fallbackSelect = '';
        if (snap.markdown !== null) {
            // The Source view shows the text the map was just written to. In the Source view of the map document the
            // text follows the file (an AI job adds nodes, another editor saves) as long as the person has not typed
            // since the last sync; what they typed is already Swift's text, and the next snapshot carries it.
            if ((rm.active || DOM.editor.value === rm.sourceBase) && DOM.editor.value !== snap.markdown) {
                DOM.editor.value = snap.markdown;
                state.markdown = snap.markdown;
            }
            if (DOM.editor.value === snap.markdown) rm.sourceBase = snap.markdown;
        }
        if (rm.active) {
            render();
            if (snap.created && snap.byId.has(snap.created)) { select(snap.created); ensureVisible(snap.created); }
            if (snap.notice) toast(snap.notice);
        }
    }

    function showProblem(message) {
        el.problemText.textContent = message;
        el.problemText.title = message;
        el.problem.classList.add('visible');
    }
    function hideProblem() { el.problem.classList.remove('visible'); }

    function toast(message) {
        el.toast.textContent = message;
        el.toast.hidden = false;
        clearTimeout(rm.toastTimer);
        rm.toastTimer = setTimeout(function () { el.toast.hidden = true; }, 4200);
    }

    // ---- colours -------------------------------------------------------------------------------------------------------------
    /** Palette index per node: the position of its top-level branch among the root's children (the root takes the first). */
    function branchIndexes(nodes) {
        const index = new Map();
        const rootId = nodes[0].id;
        const tops = nodes.filter(function (n) { return n.parent === rootId; });
        tops.forEach(function (n, i) { index.set(n.id, i); });
        const byId = rm.snap.byId;
        nodes.forEach(function (n) {
            let cur = n, guard = 0;
            while (cur && cur.id !== rootId && !index.has(cur.id) && guard++ < 1000) cur = byId.get(cur.parent);
            index.set(n.id, cur && index.has(cur.id) ? index.get(cur.id) : 0);
        });
        index.set(rootId, 0);
        return index;
    }

    // ---- rendering -------------------------------------------------------------------------------------------------------------
    function render() {
        if (!rm.snap) return;
        const snap = rm.snap;
        el.loading.textContent = '';
        el.title.textContent = snap.title || snap.nodes[0].title;
        el.question.textContent = snap.question;
        el.title.title = snap.question || '';
        renderStatus();
        renderQueries();
        syncNodes();
        relayout();
        if (!rm.viewReady) initialView();
        applyView();
        applyPanelWidth();
        syncSelection();
        fillPanel();
    }

    function branchOf(id) { return PALETTE[(rm.branchIdx.get(id) || 0) % PALETTE.length]; }

    function syncNodes() {
        const snap = rm.snap;
        rm.branchIdx = branchIndexes(snap.nodes);
        const rootId = snap.nodes[0].id;
        const present = new Set();
        snap.nodes.forEach(function (n) {
            present.add(n.id);
            const entry = rm.els.get(n.id) || makeNode(n.id);
            const palette = branchOf(n.id);
            const isRoot = n.id === rootId, isBranch = n.parent === rootId;
            const own = n.color;
            entry.wrap.classList.toggle('is-root', isRoot);
            entry.btn.className = 'rm-node' + (isRoot ? ' root' : (isBranch ? ' branch' : '')) + (own ? ' has-color' : '');
            const title = (rm.pending[n.id] && rm.pending[n.id].fields.title) || n.title;
            if (entry.btn.textContent !== title) entry.btn.textContent = title;
            entry.btn.setAttribute('aria-label', title + '. Select node; arrow keys move the node');
            entry.tri.setAttribute('aria-label', 'Actions for node “' + title + '”');
            entry.btn.style.setProperty('--branch', own || palette[0]);
            entry.btn.style.setProperty('--tint', own ? mix(own, '#ffffff', 0.14) : palette[1]);
            entry.btn.style.setProperty('--tint-dark', own ? mix(own, '#302e3a', 0.22) : '');
            entry.btn.style.setProperty('--root-ink', own ? readableOn(own) : '');
            entry.tri.hidden = false;
        });
        rm.els.forEach(function (entry, id) {
            if (present.has(id)) return;
            if (rm.menu === id) closeMenu();
            entry.wrap.remove();
            rm.els.delete(id);
        });
        // Measure after the labels are in: the layout needs the real sizes.
        rm.sizes = {};
        rm.els.forEach(function (entry, id) {
            const w = entry.btn.offsetWidth, hgt = entry.btn.offsetHeight;
            if (w > 0 && hgt > 0) rm.sizes[id] = { w: w, h: hgt };
        });
    }

    function makeNode(id) {
        const btn = h('button', { class: 'rm-node', type: 'button', 'aria-pressed': 'false' });
        const tri = h('button', { class: 'rm-tri', type: 'button', title: 'Node actions', 'aria-haspopup': 'true', 'aria-expanded': 'false' }, '▼');
        const wrap = h('div', { class: 'rm-node-wrap', 'data-id': id }, btn, tri);
        const entry = { wrap: wrap, btn: btn, tri: tri };
        btn.addEventListener('click', function () {
            if (now() - rm.lastDragEnd < 60) return;
            select(id);
        });
        tri.addEventListener('click', function (event) {
            event.stopPropagation();
            if (rm.menu === id) closeMenu(); else openMenu(id);
        });
        el.world.appendChild(wrap);
        rm.els.set(id, entry);
        return entry;
    }

    function layoutNodes() {
        return rm.snap.nodes.map(function (n) {
            const move = rm.drag && rm.drag.id === n.id ? rm.drag : rm.moves[n.id];
            return move ? Object.assign({}, n, { x: move.x, y: move.y }) : n;
        });
    }
    function relayout() {
        if (!rm.snap) return;
        const result = Layout.compute({
            nodes: layoutNodes(),
            layouts: rm.snap.layouts,
            size: function (node) { return rm.sizes[node.id] || Layout.estimateSize(node, node.id === rm.snap.nodes[0].id); }
        });
        rm.positions = result.positions;
        rm.els.forEach(function (entry, id) {
            const p = rm.positions[id];
            if (!p) return;
            entry.wrap.style.left = p.x + 'px';
            entry.wrap.style.top = p.y + 'px';
        });
        drawLines();
    }

    function curve(a, b) {
        const dx = b.x - a.x, dy = b.y - a.y;
        if (Math.abs(dx) >= Math.abs(dy)) {
            const mid = (a.x + b.x) / 2;
            return 'M ' + a.x + ' ' + a.y + ' C ' + mid + ' ' + a.y + ', ' + mid + ' ' + b.y + ', ' + b.x + ' ' + b.y;
        }
        const mid = (a.y + b.y) / 2;
        return 'M ' + a.x + ' ' + a.y + ' C ' + a.x + ' ' + mid + ', ' + b.x + ' ' + mid + ', ' + b.x + ' ' + b.y;
    }
    function addPath(d, color, dashed, kind) {
        const path = document.createElementNS(NS, 'path');
        path.setAttribute('d', d);
        path.setAttribute('fill', 'none');
        path.setAttribute('stroke', color);
        path.setAttribute('stroke-width', dashed ? '2' : '3');
        path.setAttribute('stroke-linecap', 'round');
        path.setAttribute('data-line', kind);
        if (dashed) path.setAttribute('stroke-dasharray', '6 6');
        el.svg.appendChild(path);
    }
    function drawLines() {
        while (el.svg.firstChild) el.svg.removeChild(el.svg.firstChild);
        const snap = rm.snap;
        snap.nodes.forEach(function (n) {
            const a = rm.positions[n.parent], b = rm.positions[n.id];
            if (a && b) addPath(curve(a, b), n.color || branchOf(n.id)[0], false, 'tree');
        });
        snap.links.forEach(function (l) {
            const a = rm.positions[l.from], b = rm.positions[l.to];
            if (a && b) addPath(curve(a, b), '#849395', true, 'link');
        });
    }

    // ---- toolbar status ------------------------------------------------------------------------------------------------------
    function elapsedText(job) {
        if (!job || !job.startedAt) return '';
        const total = Math.max(0, Math.floor(Date.now() / 1000 - job.startedAt));
        return Math.floor(total / 60) + ':' + String(total % 60).padStart(2, '0');
    }
    function renderStatus() {
        const snap = rm.snap, box = el.status;
        box.textContent = '';
        box.classList.remove('warn');
        el.elapsed = null;
        if (snap.job || snap.status === 'researching') {
            const job = snap.job;
            const parts = job ? [job.label || 'Researching', job.step].filter(Boolean).join(' · ') : 'Researching…';
            el.elapsed = h('span', { class: 'rm-elapsed' }, job ? elapsedText(job) : '');
            box.appendChild(h('span', { class: 'rm-spin', 'aria-hidden': 'true' }));
            box.appendChild(h('span', { class: 'rm-status-text', title: parts }, parts));
            box.appendChild(el.elapsed);
            box.appendChild(h('button', { class: 'rm-chip-btn', type: 'button', 'data-act': 'stop', title: 'Stop the research' }, icon('stop'), 'Stop'));
            box.lastChild.addEventListener('click', function () { send('cancel'); });
            box.hidden = false;
            box.setAttribute('data-state', 'researching');
            startTicker();
            return;
        }
        stopTicker();
        if (snap.status === 'incomplete') {
            const reason = snap.incomplete || 'The research stopped early.';
            box.classList.add('warn');
            box.appendChild(h('span', { class: 'rm-status-text', title: reason }, 'Incomplete · ' + reason));
            box.appendChild(h('button', { class: 'rm-chip-btn', type: 'button', 'data-act': 'continue', title: 'Continue the research' }, icon('play'), 'Continue'));
            box.lastChild.addEventListener('click', function () { send('continue'); });
            box.hidden = false;
            box.setAttribute('data-state', 'incomplete');
            return;
        }
        box.hidden = true;
        box.removeAttribute('data-state');
    }
    function startTicker() {
        if (rm.ticker) return;
        rm.ticker = setInterval(function () {
            if (!rm.active || !rm.snap || !rm.snap.job || !el.elapsed) return;
            el.elapsed.textContent = elapsedText(rm.snap.job);
        }, 1000);
    }
    function stopTicker() {
        if (rm.ticker) { clearInterval(rm.ticker); rm.ticker = 0; }
    }

    function renderQueries() {
        const queries = rm.snap.webQueries;
        el.queriesBtn.hidden = queries.length === 0;
        el.queryCount.textContent = String(queries.length);
        el.popover.textContent = '';
        el.popover.appendChild(h('h3', null, 'Web searches (' + queries.length + ')'));
        el.popover.appendChild(h('ol', null, queries.map(function (q) { return h('li', null, q); })));
        if (!queries.length) closeQueries();
    }
    function toggleQueries() { if (rm.queriesOpen) closeQueries(); else { rm.queriesOpen = true; el.popover.hidden = false; } }
    function closeQueries() { rm.queriesOpen = false; el.popover.hidden = true; }

    // ---- view: pan and zoom --------------------------------------------------------------------------------------------------
    function viewSize() { return { w: el.viewport.clientWidth || 800, h: el.viewport.clientHeight || 600 }; }
    function applyView() {
        el.world.style.transform = 'translate(' + rm.view.x + 'px,' + rm.view.y + 'px) scale(' + rm.view.scale + ')';
        el.zoom.textContent = Math.round(rm.view.scale * 100) + '%';
    }
    function initialView() {
        const size = viewSize(), root = rm.positions[rm.snap.nodes[0].id] || { x: 0, y: 0 };
        rm.view = { x: size.w / 2 - root.x, y: size.h / 2 - root.y, scale: 1 };
        rm.viewReady = true;
    }
    function centreView() {
        const size = viewSize(), root = rm.positions[rm.snap.nodes[0].id] || { x: 0, y: 0 };
        rm.view = { x: size.w / 2 - root.x, y: size.h / 2 - root.y, scale: 1 };
        applyView();
        saveSoon();
    }
    function zoomAt(next, cx, cy) {
        const old = rm.view.scale, scale = clamp(next, MIN_SCALE, MAX_SCALE);
        rm.view = { x: cx - (cx - rm.view.x) * scale / old, y: cy - (cy - rm.view.y) * scale / old, scale: scale };
        applyView();
        saveSoon();
    }
    function zoomAtCentre(next) { const s = viewSize(); zoomAt(next, s.w / 2, s.h / 2); }
    function ensureVisible(id) {
        const p = rm.positions[id];
        if (!p) return;
        const size = viewSize(), sx = p.x * rm.view.scale + rm.view.x, sy = p.y * rm.view.scale + rm.view.y, margin = 80;
        if (sx > margin && sx < size.w - margin && sy > margin && sy < size.h - margin) return;
        rm.view.x = size.w / 2 - p.x * rm.view.scale;
        rm.view.y = size.h / 2 - p.y * rm.view.scale;
        applyView();
        saveSoon();
    }

    el.viewport.addEventListener('wheel', function (event) {
        // The plain mouse wheel zooms around the pointer. It never pans.
        event.preventDefault();
        let delta = event.deltaY || event.deltaX;
        if (event.deltaMode === 1) delta *= 16; else if (event.deltaMode === 2) delta *= 100;
        if (!delta) return;
        const rect = el.viewport.getBoundingClientRect();
        zoomAt(rm.view.scale * Math.pow(1.1, clamp(-delta / 12, -1, 1)), event.clientX - rect.left, event.clientY - rect.top);
    }, { passive: false });

    el.viewport.addEventListener('pointerdown', function (event) {
        if (event.button !== 0) return;
        if (event.target.closest('.rm-tri, .rm-actions')) return;
        const nodeEl = event.target.closest('.rm-node');
        if (nodeEl) startNodeDrag(event, nodeEl.parentNode.getAttribute('data-id'));
        else startPan(event);
    });

    function listen(move, end) {
        window.addEventListener('pointermove', move);
        window.addEventListener('pointerup', end);
        window.addEventListener('pointercancel', end);
        return function stop() {
            window.removeEventListener('pointermove', move);
            window.removeEventListener('pointerup', end);
            window.removeEventListener('pointercancel', end);
        };
    }

    function startPan(event) {
        const start = { x: event.clientX, y: event.clientY, vx: rm.view.x, vy: rm.view.y };
        let moved = false;
        try { el.viewport.setPointerCapture(event.pointerId); } catch (e) { /* a synthetic pointer has no capture */ }
        const stop = listen(function (e) {
            const dx = e.clientX - start.x, dy = e.clientY - start.y;
            if (!moved && Math.hypot(dx, dy) <= 3) return;
            moved = true;
            el.viewport.classList.add('is-panning');
            rm.view.x = start.vx + dx;
            rm.view.y = start.vy + dy;
            applyView();
        }, function () {
            stop();
            el.viewport.classList.remove('is-panning');
            if (moved) saveSoon();
            else { closeMenu(); closeQueries(); select(''); }
        });
    }

    function startNodeDrag(event, id) {
        const origin = rm.positions[id];
        if (!origin) return;
        const start = { x: event.clientX, y: event.clientY };
        let dragging = false;
        try { event.target.setPointerCapture(event.pointerId); } catch (e) { /* a synthetic pointer has no capture */ }
        const stop = listen(function (e) {
            const dx = e.clientX - start.x, dy = e.clientY - start.y;
            if (!dragging) {
                if (Math.hypot(dx, dy) <= 3) return;
                dragging = true;
                closeMenu();
            }
            rm.drag = { id: id, x: origin.x + dx / rm.view.scale, y: origin.y + dy / rm.view.scale };
            relayout();
            el.readout.hidden = false;
            el.readout.textContent = 'x ' + Math.round(rm.drag.x) + ' · y ' + Math.round(rm.drag.y);
        }, function (e) {
            stop();
            el.readout.hidden = true;
            if (!dragging) return;
            rm.lastDragEnd = now();
            const drag = rm.drag;
            rm.drag = null;
            if (e.type === 'pointercancel' || !drag) { relayout(); return; }
            commitMove(id, Math.round(drag.x), Math.round(drag.y));
        });
    }
    function commitMove(id, x, y) {
        rm.moves[id] = { x: x, y: y, sent: true };
        relayout();
        send('moveVisual', { id: id, x: x, y: y });
    }
    /** Arrow keys move the selected node (a click does not focus a button in WebKit, so this listens on the document). */
    document.addEventListener('keydown', function (event) {
        if (!rm.active || rm.dialog || !rm.selected || event.metaKey || event.ctrlKey || event.altKey || event.defaultPrevented) return;
        if (event.key.indexOf('Arrow') !== 0) return;
        const target = event.target;
        if (target && target.closest && target.closest('input, textarea, select, [contenteditable], .rm-divider, .rm-popover, .rm-layouts, .rm-modal')) return;
        onNodeKey(event, rm.selected);
    });
    function onNodeKey(event, id) {
        const step = event.shiftKey ? 40 : 10;
        const dx = event.key === 'ArrowLeft' ? -step : event.key === 'ArrowRight' ? step : 0;
        const dy = event.key === 'ArrowUp' ? -step : event.key === 'ArrowDown' ? step : 0;
        if (!dx && !dy) return;
        event.preventDefault();
        const p = rm.positions[id];
        if (!p) return;
        const x = Math.round(p.x + dx), y = Math.round(p.y + dy);
        rm.moves[id] = { x: x, y: y, sent: false };
        relayout();
        queueMove(id, x, y);
    }

    // ---- divider ------------------------------------------------------------------------------------------------------------
    function maxPanel() { return Math.min(PANEL_MAX, Math.max(PANEL_MIN, el.workspace.clientWidth * 0.6)); }
    function setPanelWidth(value) {
        rm.panelWidth = clamp(value, PANEL_MIN, maxPanel());
        applyPanelWidth();
        saveSoon();
    }
    function applyPanelWidth() {
        const width = clamp(rm.panelWidth, PANEL_MIN, maxPanel());
        el.workspace.style.setProperty('--rm-panel-width', width + 'px');
        el.divider.setAttribute('aria-valuenow', String(Math.round(width)));
    }
    el.divider.addEventListener('keydown', function (event) {
        if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return;
        event.preventDefault();
        setPanelWidth(rm.panelWidth + (event.key === 'ArrowLeft' ? 20 : -20));
    });
    el.divider.addEventListener('pointerdown', function (event) {
        if (event.button !== 0) return;
        const start = event.clientX, initial = rm.panelWidth;
        try { el.divider.setPointerCapture(event.pointerId); } catch (e) { /* a synthetic pointer has no capture */ }
        const stop = listen(function (e) { setPanelWidth(initial + start - e.clientX); }, function () { stop(); });
    });
    window.addEventListener('resize', function () { if (rm.active) applyPanelWidth(); });

    // ---- selection and panel ---------------------------------------------------------------------------------------------------
    function select(id) {
        if (rm.selected === id) return;
        flushAll();
        closeMenu();
        rm.selected = id;
        syncSelection();
        fillPanel();
        saveSoon();
    }
    function syncSelection() {
        rm.els.forEach(function (entry, id) { entry.btn.setAttribute('aria-pressed', id === rm.selected ? 'true' : 'false'); });
    }

    function setField(field, value, id, key) {
        if (field.value === value) return;
        // Never overwrite what the person is typing, or an edit that has not been sent yet.
        if (document.activeElement === field) return;
        if (rm.pending[id] && Object.prototype.hasOwnProperty.call(rm.pending[id].fields, key)) return;
        field.value = value;
    }
    function fillPanel() {
        const node = nodeById(rm.selected);
        el.empty.hidden = !!node;
        el.body.hidden = !node;
        if (!node) { rm.panelFor = null; return; }
        const fresh = rm.panelFor !== node.id;
        rm.panelFor = node.id;
        if (fresh) {
            el.titleInput.value = node.title;
            el.titleError.textContent = '';
            el.desc.value = node.description;
            el.tagInput.value = '';
        } else {
            if (!el.titleError.textContent) setField(el.titleInput, node.title, node.id, 'title');
            setField(el.desc, node.description, node.id, 'description');
        }
        const shownColor = node.color || branchOf(node.id)[0];
        if (document.activeElement !== el.color) el.color.value = shownColor;
        el.colorClear.hidden = !node.color;
        // Tags: chips before the input, which keeps its focus and caret.
        Array.prototype.slice.call(el.tags.querySelectorAll('.rm-tag')).forEach(function (chip) { chip.remove(); });
        node.tags.forEach(function (tag) {
            const chip = h('span', { class: 'rm-tag', 'data-tag': tag }, tag, h('button', { type: 'button', 'aria-label': 'Remove tag “' + tag + '”', onClick: function () {
                queueUpdate(node.id, { tags: node.tags.filter(function (t) { return t !== tag; }) }, true);
            } }, '×'));
            el.tags.insertBefore(chip, el.tagInput);
        });
        // Evidence.
        el.evList.textContent = '';
        node.evidence.forEach(function (ev) {
            const row = h('li', { class: 'rm-ev-row' },
                h('span', { class: 'rm-ev-chip', 'data-label': ev.label }, ev.label || 'Finding'),
                h('span', { class: 'rm-ev-text' }, ev.text));
            if (ev.source) {
                row.appendChild(h('button', { class: 'rm-ev-source', type: 'button', title: 'Open ' + ev.source, 'data-source': ev.source, onClick: function (event) {
                    event.preventDefault();
                    event.stopPropagation();
                    send('open', { source: ev.source });
                } }, ev.source));
            }
            el.evList.appendChild(row);
        });
        el.evHeading.textContent = 'Evidence (' + node.evidence.length + ')';
        el.evSection.hidden = node.evidence.length === 0;
        // Logical connections of this node, each removable.
        el.connList.textContent = '';
        const mine = rm.snap.links.filter(function (l) { return l.from === node.id || l.to === node.id; });
        mine.forEach(function (l) {
            const otherId = l.from === node.id ? l.to : l.from, other = nodeById(otherId);
            const name = other ? other.title : otherId;
            el.connList.appendChild(h('li', { class: 'rm-conn-row', 'data-from': l.from, 'data-to': l.to },
                h('button', { class: 'rm-conn-name', type: 'button', title: 'Select this node', onClick: function () { select(otherId); ensureVisible(otherId); } }, '↔ ' + name),
                h('button', { class: 'rm-x', type: 'button', title: 'Remove this connection', 'aria-label': 'Remove the connection to “' + name + '”', onClick: function () { send('unlink', { from: l.from, to: l.to }); } }, icon('close'))));
        });
        el.connHeading.textContent = 'Connections (' + mine.length + ')';
        el.connSection.hidden = mine.length === 0;
    }

    // ---- node menu -----------------------------------------------------------------------------------------------------------------
    function descendantIds(id) {
        const ids = [id];
        for (let i = 0; i < ids.length; i++) rm.snap.nodes.forEach(function (n) { if (n.parent === ids[i] && ids.indexOf(n.id) < 0) ids.push(n.id); });
        return ids;
    }
    function closeMenu() {
        if (rm.menu == null) return;
        const entry = rm.els.get(rm.menu);
        if (entry) {
            entry.wrap.classList.remove('menu-open');
            entry.tri.setAttribute('aria-expanded', 'false');
            const bar = entry.wrap.querySelector('.rm-actions');
            if (bar) bar.remove();
        }
        rm.menu = null;
    }
    function openMenu(id) {
        closeMenu();
        const entry = rm.els.get(id), node = nodeById(id);
        if (!entry || !node) return;
        const snap = rm.snap, isRoot = id === snap.nodes[0].id;
        const moveTargets = moveCandidates(node);
        const items = [
            { act: 'add', label: 'Add child node', icon: 'plus', run: function () { addChildDialog(node); } },
            { act: 'develop', label: 'Develop with AI', icon: 'sparkle', run: function () { developDialog(node); } },
            { act: 'link', label: 'Add logical connection', icon: 'link', off: snap.nodes.length < 2, run: function () { linkDialog(node); } },
            { act: 'edit', label: 'Edit node title', icon: 'edit', run: function () { editDialog(node); } },
            { act: 'move', label: 'Move to another branch', icon: 'move', off: isRoot || !moveTargets.length, run: function () { moveDialog(node, moveTargets); } },
            { act: 'arrange', label: 'Arrange branch', icon: 'grid', run: null },
            { act: 'delete', label: 'Delete node', icon: 'trash', off: isRoot, run: function () { deleteDialog(node); } }
        ];
        const bar = h('div', { class: 'rm-actions', role: 'menu', 'aria-label': 'Actions for node “' + node.title + '”' });
        items.forEach(function (item) {
            const button = h('button', { class: 'rm-icon', type: 'button', 'data-act': item.act, title: item.label, 'aria-label': item.label, disabled: !!item.off }, icon(item.icon));
            button.addEventListener('click', function (event) {
                event.stopPropagation();
                if (item.act === 'arrange') { toggleLayouts(bar, node); return; }
                closeMenu();
                item.run();
            });
            bar.appendChild(button);
        });
        entry.wrap.appendChild(bar);
        entry.wrap.classList.add('menu-open');
        entry.tri.setAttribute('aria-expanded', 'true');
        rm.menu = id;
    }
    function toggleLayouts(bar, node) {
        const existing = bar.querySelector('.rm-layouts');
        if (existing) { existing.remove(); return; }
        const layouts = rm.snap.layouts.length ? rm.snap.layouts : Layout.PRESETS.map(function (id) { return { id: id, name: id.charAt(0).toUpperCase() + id.slice(1) }; });
        const current = Layout.effectiveLayout(rm.snap.nodes, node.id, rm.snap.layouts);
        const list = h('div', { class: 'rm-layouts', role: 'menu', 'aria-label': 'Arrange branch' });
        layouts.forEach(function (layout) {
            const on = layout.id === current;
            const button = h('button', { type: 'button', role: 'menuitemradio', 'aria-checked': on ? 'true' : 'false', 'data-layout': layout.id }, h('span', { class: 'rm-check' }, on ? '✓' : ''), layout.name);
            button.addEventListener('click', function (event) {
                event.stopPropagation();
                closeMenu();
                send('layout', { id: node.id, layout: layout.id });
            });
            list.appendChild(button);
        });
        bar.appendChild(list);
    }
    function moveCandidates(node) {
        const blocked = new Set(descendantIds(node.id));
        return rm.snap.nodes.filter(function (n) { return !blocked.has(n.id) && n.id !== node.parent; });
    }

    // ---- dialogs (the web view blocks alert, confirm and prompt, so these are in the page) ------------------------------------------
    function closeDialog() {
        if (!rm.dialog) return;
        rm.dialog.remove();
        rm.dialog = null;
    }
    function dialog(title, body, actions, label) {
        closeDialog();
        closeMenu();
        const buttons = actions.map(function (action) {
            return h('button', { class: 'rm-btn' + (action.kind ? ' ' + action.kind : ''), type: 'button', 'data-kind': action.kind || 'ghost', onClick: function () {
                if (action.run && action.run() === false) return;
                closeDialog();
            } }, action.label);
        });
        const card = h('div', { class: 'rm-dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': label || title }, h('h2', null, title), h('div', { class: 'rm-dialog-body' }, body), h('div', { class: 'rm-dialog-actions' }, buttons));
        const overlay = h('div', { class: 'rm-modal', onPointerdown: function (event) { if (event.target === overlay) closeDialog(); } }, card);
        el.root.appendChild(overlay);
        rm.dialog = overlay;
        const primary = buttons.filter(function (b) { return b.classList.contains('primary') || b.classList.contains('danger'); })[0];
        card.addEventListener('keydown', function (event) {
            if (event.key === 'Enter' && event.target.tagName === 'INPUT' && primary) { event.preventDefault(); primary.click(); }
        });
        const first = card.querySelector('input, select') || primary || buttons[0];
        if (first) first.focus();
        return overlay;
    }
    function textDialog(title, intro, labelText, initial, maxLength, okLabel, onOk, emptyMessage) {
        const input = h('input', { type: 'text', maxlength: String(maxLength), 'aria-label': labelText, value: initial || '', spellcheck: 'false' });
        const error = h('p', { class: 'rm-error', role: 'alert' });
        dialog(title, [intro ? h('p', null, intro) : null, h('label', null, labelText, input), error], [
            { label: 'Cancel', kind: 'ghost' },
            { label: okLabel, kind: 'primary', run: function () {
                const value = input.value.trim();
                if (!value) { error.textContent = emptyMessage; input.focus(); return false; }
                onOk(value);
            } }
        ]);
        input.select();
    }
    function addChildDialog(parent) {
        textDialog('Add child node', 'Parent node: ' + parent.title, 'Child node name', '', MAX_TITLE, 'Add', function (title) { send('addChild', { parent: parent.id, title: title }); }, 'Enter a node name.');
    }
    function editDialog(node) {
        textDialog('Edit node', '', 'Node name', node.title, MAX_TITLE, 'Save', function (title) { send('update', { id: node.id, title: title }); }, 'Enter a node name.');
    }
    function developDialog(node) {
        textDialog('Develop with AI', 'Enter a direction for node “' + node.title + '”.', 'Direction for developing the topic', '', 500, 'Develop', function (direction) { send('develop', { id: node.id, direction: direction }); }, 'Enter a direction.');
    }
    function nodeOptions(nodes) {
        const depth = function (n) { let d = 0, cur = n, guard = 0; while (cur && cur.parent && guard++ < 100) { d++; cur = rm.snap.byId.get(cur.parent); } return d; };
        return nodes.map(function (n) { return h('option', { value: n.id }, ' '.repeat(Math.min(depth(n), 6)) + n.title); });
    }
    function linkDialog(node) {
        const nodes = rm.snap.nodes;
        const from = h('select', { 'aria-label': 'First node' }, nodeOptions(nodes));
        const to = h('select', { 'aria-label': 'Second node' }, nodeOptions(nodes));
        from.value = node.id;
        const other = nodes.filter(function (n) { return n.id !== node.id; })[0];
        if (other) to.value = other.id;
        const error = h('p', { class: 'rm-error', role: 'alert' });
        dialog('Add logical connection', [h('label', null, 'First node', from), h('label', null, 'Second node', to), error], [
            { label: 'Cancel', kind: 'ghost' },
            { label: 'Add', kind: 'primary', run: function () {
                if (from.value === to.value) { error.textContent = 'Select two different nodes.'; return false; }
                if (rm.snap.links.some(function (l) { return (l.from === from.value && l.to === to.value) || (l.from === to.value && l.to === from.value); })) { error.textContent = 'This connection already exists.'; return false; }
                send('link', { from: from.value, to: to.value });
            } }
        ]);
    }
    function moveDialog(node, targets) {
        const parentSelect = h('select', { 'aria-label': 'New parent node' }, nodeOptions(targets));
        dialog('Move to another branch', [h('p', null, 'Move “' + node.title + '” with everything under it to:'), h('label', null, 'New parent node', parentSelect)], [
            { label: 'Cancel', kind: 'ghost' },
            { label: 'Move', kind: 'primary', run: function () { send('reparent', { id: node.id, parent: parentSelect.value }); } }
        ]);
    }
    function deleteDialog(node) {
        const below = descendantIds(node.id).length - 1;
        const message = 'Delete node “' + node.title + '”' + (below > 0 ? ' and its child nodes (' + below + ')' : '') + '? Its logical connections will also be deleted.';
        dialog('Delete node', h('p', null, message), [
            { label: 'Cancel', kind: 'ghost' },
            { label: 'Delete', kind: 'danger', run: function () { rm.fallbackSelect = node.parent; send('delete', { id: node.id }); } }
        ]);
    }

    // ---- global listeners that only matter while the map is shown ---------------------------------------------------------------------
    document.addEventListener('pointerdown', function (event) {
        if (!rm.active) return;
        if (rm.menu != null && !event.target.closest('.rm-node-wrap.menu-open')) closeMenu();
        if (rm.queriesOpen && !event.target.closest('.rm-popover, [data-act="queries"]')) closeQueries();
    }, true);
    el.root.addEventListener('keydown', function (event) {
        if (event.key !== 'Escape') return;
        if (rm.dialog) { closeDialog(); event.stopPropagation(); }
        else if (rm.menu != null) { closeMenu(); event.stopPropagation(); }
        else if (rm.queriesOpen) { closeQueries(); event.stopPropagation(); }
    });

    // ---- entering and leaving ------------------------------------------------------------------------------------------------------------
    function resetForDocument(docId) {
        flushAll();
        clearTimeout(rm.saveTimer);
        saveNow();
        closeMenu();
        closeDialog();
        closeQueries();
        rm.els.forEach(function (entry) { entry.wrap.remove(); });
        rm.els.clear();
        while (el.svg.firstChild) el.svg.removeChild(el.svg.firstChild);
        rm.docId = docId;
        rm.snap = null;
        rm.mapKey = '';
        rm.selected = null;
        rm.panelFor = null;
        rm.positions = {};
        rm.moves = {};
        rm.drag = null;
        rm.viewReady = false;
        el.status.hidden = true;
        el.queriesBtn.hidden = true;
        el.title.textContent = '';
        el.question.textContent = '';
        el.loading.textContent = 'Loading the research map…';
        el.empty.hidden = false;
        el.body.hidden = true;
    }

    function enterMap() {
        const docId = window.mvDocumentId || '';
        if (rm.docId !== docId) resetForDocument(docId);
        if (typeof window.leaveCodeView === 'function') window.leaveCodeView();
        if (typeof window.leaveArchitectureView === 'function') window.leaveArchitectureView();
        if (typeof window.leaveCanvasView === 'function') window.leaveCanvasView();
        if (typeof window.leaveDataView === 'function') window.leaveDataView();
        if (typeof leaveInsightView === 'function') leaveInsightView();
        state.mode = 'research-map';
        DOM.editorPane.style.display = 'none';
        DOM.previewPane.style.display = 'none';
        const bar = document.getElementById('wysiwyg-toolbar');
        if (bar) bar.style.display = 'none';
        if (DOM.statusMode) DOM.statusMode.textContent = 'MAP';
        document.body.classList.add('research-map-mode');
        el.root.classList.add('visible');
        rm.active = true;
        hideProblem();
        if (rm.snap) render();
        send('snapshot');
    }

    window.leaveResearchMap = function () {
        flushAll();
        closeMenu();
        closeDialog();
        closeQueries();
        stopTicker();
        saveNow();
        rm.active = false;
        if (!el.root.classList.contains('visible')) return;
        el.root.classList.remove('visible');
        document.body.classList.remove('research-map-mode');
        const bar = document.getElementById('wysiwyg-toolbar');
        if (bar) bar.style.display = '';
    };

    function goSource() {
        window.leaveResearchMap();
        window.switchToSource();
    }

    /** From the Source view the top-bar toggle goes back to the map. */
    function returnToMap() {
        if (rm.active || state.mode !== 'source' || !isResearchMapText(DOM.editor.value)) return false;
        enterMap();
        return true;
    }
    function labelToggle() {
        const toggle = document.getElementById('mode-toggle');
        if (toggle && state.mode === 'source' && isResearchMapText(DOM.editor.value)) toggle.textContent = 'Map ↗';
    }

    // ---- wrapping the page's entry points ---------------------------------------------------------------------------------------------------
    const originalSetContent = window.setContent;
    window.setContent = function (markdown) {
        const result = typeof originalSetContent === 'function' ? originalSetContent.apply(this, arguments) : undefined;
        try {
            if (isResearchMapText(markdown)) { rm.sourceBase = markdown; enterMap(); }
            else { hideProblem(); window.leaveResearchMap(); }
        } catch (e) { reportError('setContent', e); }
        return result;
    };

    // Other content takes over the editor area.
    ['setStructuredContent', 'setCodeContent', 'setDataContent', 'showArchitecture', 'loadInsightSkeleton'].forEach(function (name) {
        const original = window[name];
        if (typeof original !== 'function') return;
        window[name] = function () {
            hideProblem();
            window.leaveResearchMap();
            return original.apply(this, arguments);
        };
    });
    ['switchToSource', 'switchToPreview'].forEach(function (name) {
        const original = window[name];
        if (typeof original !== 'function') return;
        window[name] = function () {
            window.leaveResearchMap();
            const result = original.apply(this, arguments);
            labelToggle();
            return result;
        };
    });
    ['toggleModeWrapper', 'toggleMode', 'toggleSourceMode'].forEach(function (name) {
        const original = window[name];
        if (typeof original !== 'function') return;
        window[name] = function () {
            if (returnToMap()) return undefined;
            return original.apply(this, arguments);
        };
    });
    // Edits that wait for the debounce belong to the document that was shown when they were made: hand them over
    // before the page takes the next document's id.
    const originalSetDocument = window.mvSetDocument;
    if (typeof originalSetDocument === 'function') {
        window.mvSetDocument = function (id) {
            if (String(id || '') !== String(window.mvDocumentId || '')) { try { flushAll(); } catch (e) { reportError('mvSetDocument', e); } }
            return originalSetDocument.apply(this, arguments);
        };
    }

    window.MVResearchMap = {
        isResearchMapText: isResearchMapText,
        viewState: function () { return { active: rm.active, x: rm.view.x, y: rm.view.y, scale: rm.view.scale, panel: rm.panelWidth, selected: rm.selected, key: rm.mapKey }; }
    };
})();
