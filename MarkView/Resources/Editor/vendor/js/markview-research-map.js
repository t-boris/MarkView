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
    // Six branch colours: the application's own accent family (--b0..--b5 in the styles below, one set per theme).
    const BRANCH_COLOURS = 6;
    const MIN_SCALE = 0.4, MAX_SCALE = 2;
    const PANEL_MIN = 240, PANEL_MAX = 600, PANEL_DEFAULT = 320;
    const MAX_TITLE = 120;
    // The four AI actions on one node (REQ-006): what each does is said in its tooltip.
    const AI_ACTIONS = [
        { act: 'describe', label: 'Expand description', icon: 'text', hint: 'The AI rewrites and extends this node’s description' },
        { act: 'develop', label: 'Expand topic', icon: 'fork', hint: 'The AI adds child nodes under this node' },
        { act: 'correct', label: 'Correct', icon: 'edit', hint: 'Say what is wrong; the AI fixes this node' },
        { act: 'investigate', label: 'Research', icon: 'search', hint: 'The AI looks for facts about this node in the project and on the web' }
    ];
    const ICONS = {
        plus: 'M12 5v14M5 12h14',
        minus: 'M5 12h14',
        sparkle: 'M12 3l2.2 6.8L21 12l-6.8 2.2L12 21l-2.2-6.8L3 12l6.8-2.2z',
        link: 'M3 12h18M7 8l-4 4 4 4M17 8l4 4-4 4',
        edit: 'M4 20l1-4L16 5l3 3L8 19zM14 7l3 3',
        text: 'M4 6h16M4 11h16M4 16h10',
        fork: 'M4 12h7M11 5v14M11 5h9M11 12h9M11 19h9',
        chevron: 'M6 9l6 6 6-6',
        download: 'M12 4v11M7 11l5 5 5-5M5 20h14',
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

    // The icons a node can carry (REQ-008). The ids are ResearchMap.iconIDs in Swift; a web test keeps both lists equal.
    const NODE_ICONS = {
        check: 'M5 12l5 5L20 7',
        warning: 'M12 4l9 16H3zM12 10v4M12 17v.5',
        error: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9 9l6 6M15 9l-6 6',
        info: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v6M12 7.5v.5',
        question: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.4-1 .9-1 1.7M12 17v.5',
        bug: 'M9 7a3 3 0 0 1 6 0M8 9h8v5a4 4 0 0 1-8 0zM4 10l4 1M20 10l-4 1M4 17l4-2M20 17l-4-2M12 9v9',
        lock: 'M7 11V8a5 5 0 0 1 10 0v3M5 11h14v9H5zM12 15v2',
        key: 'M8 11a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zM10.5 13.5L20 4M16 8l3 3M13 11l2 2',
        database: 'M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3zM4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3',
        server: 'M4 4h16v6H4zM4 14h16v6H4zM8 7h.5M8 17h.5',
        cloud: 'M7 18a4 4 0 0 1-.5-8A6 6 0 0 1 18 9a4.5 4.5 0 0 1 0 9z',
        user: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0',
        users: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2 20a7 7 0 0 1 14 0M16 5a3.5 3.5 0 0 1 0 6M18 14a6 6 0 0 1 4 6',
        clock: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3 2',
        calendar: 'M4 6h16v14H4zM4 10h16M8 3v4M16 3v4',
        flag: 'M5 21V4M5 4h11l-2 4 2 4H5',
        star: 'M12 3l2.8 5.7 6.2.9-4.5 4.4 1 6.2L12 17.3 6.5 20.2l1-6.2L3 9.6l6.2-.9z',
        heart: 'M12 20s-8-5-8-11a4.5 4.5 0 0 1 8-2.5A4.5 4.5 0 0 1 20 9c0 6-8 11-8 11z',
        bulb: 'M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z',
        target: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8zM12 12v.01',
        rocket: 'M12 2c3 2.5 4.5 6 4.5 10v3h-9v-3C7.5 8 9 4.5 12 2zM12 8.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zM7.5 13L5 16v3l3-1.5M16.5 13l2.5 3v3l-3-1.5M10.5 18v3M13.5 18v3',
        book: 'M4 5a2 2 0 0 1 2-2h13v16H6a2 2 0 0 0-2 2zM4 19a2 2 0 0 1 2-2h13',
        file: 'M6 3h8l4 4v14H6zM14 3v4h4M9 12h6M9 16h6',
        folder: 'M3 6a1 1 0 0 1 1-1h5l2 2h8a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z',
        code: 'M8 7l-5 5 5 5M16 7l5 5-5 5M14 4l-4 16',
        terminal: 'M4 5h16v14H4zM7 9l3 3-3 3M12 15h5',
        gear: 'M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M18.4 5.6l-2.1 2.1M7.7 16.3l-2.1 2.1',
        shield: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z',
        globe: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18',
        chain: 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
        mail: 'M3 5h18v14H3zM3 7l9 7 9-7',
        chat: 'M4 5h16v11H9l-5 4z',
        money: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM14.5 9.5c-.5-1-1.5-1.5-2.5-1.5-1.4 0-2.5.8-2.5 2s1 1.7 2.5 2 2.5.8 2.5 2-1.1 2-2.5 2c-1 0-2-.5-2.5-1.5M12 6.5V8M12 16v1.5',
        chart: 'M4 20h16M7 17v-6M12 17V6M17 17v-9',
        trend: 'M3 17l6-6 4 4 8-8M15 7h6v6',
        bolt: 'M13 3L5 14h6l-1 7 8-11h-6z',
        pin: 'M12 21v-6M8 4h8l-1 6 3 3H6l3-3z',
        tag: 'M3 12V4h8l10 10-8 8zM7.5 8.5v.01',
        bell: 'M6 16v-5a6 6 0 0 1 12 0v5l2 2H4zM10 21h4',
        eye: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z',
        package: 'M12 3l8 4v10l-8 4-8-4V7zM4 7l8 4 8-4M12 11v10'
    };
    const NODE_ICON_IDS = Object.keys(NODE_ICONS);
    const MAX_NUMBER = 999;

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
    function icon(name, table) {
        const svg = document.createElementNS(NS, 'svg');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('stroke-width', '2');
        svg.setAttribute('stroke-linecap', 'round');
        svg.setAttribute('stroke-linejoin', 'round');
        svg.setAttribute('aria-hidden', 'true');
        const path = document.createElementNS(NS, 'path');
        path.setAttribute('d', (table || ICONS)[name] || '');
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
    /** The text colour (dark or white) that reads on a custom node colour. */
    function readableOn(hex) {
        const r = parseInt(hex.slice(1, 3), 16), g = parseInt(hex.slice(3, 5), 16), b = parseInt(hex.slice(5, 7), 16);
        return (0.299 * r + 0.587 * g + 0.114 * b) > 150 ? '#1e1e1e' : '#ffffff';
    }
    /** Draws a node icon into a glyph element: a built-in drawing by id, or an emoji as text. Rebuilt only when it changes. */
    function setGlyph(glyph, value) {
        if (glyph.getAttribute('data-icon') === value) return;
        glyph.setAttribute('data-icon', value);
        glyph.textContent = '';
        glyph.hidden = !value;
        if (!value) return;
        if (NODE_ICONS[value]) glyph.appendChild(icon(value, NODE_ICONS));
        else glyph.appendChild(document.createTextNode(value));
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
        collapsed: new Set(), // ids of nodes whose children are folded away (view state, DEC-010)
        panelFor: null,
        menu: null,
        menuEl: null,
        exportOpen: false,
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
            localStorage.setItem(rm.mapKey, JSON.stringify({ x: rm.view.x, y: rm.view.y, scale: rm.view.scale, panel: rm.panelWidth, selected: rm.selected == null ? '' : rm.selected, collapsed: Array.from(rm.collapsed) }));
        } catch (e) { /* storage may be unavailable */ }
    }
    function saveSoon() {
        clearTimeout(rm.saveTimer);
        rm.saveTimer = setTimeout(saveNow, 120);
    }

    // ---- styles --------------------------------------------------------------------------------------------------------
    const css = `
    .rm-root { display: none; flex: 1; min-width: 0; min-height: 0; flex-direction: column; position: relative; overflow: hidden; background: var(--rm-page); color: var(--rm-ink); font-family: var(--font-sans); font-size: calc(12px * var(--ui-scale, 1)); line-height: 1.5;
        --rm-page: var(--bg-primary); --rm-bar: var(--bg-secondary); --rm-line: var(--border-color); --rm-ink: var(--text-primary); --rm-muted: var(--text-secondary);
        --rm-dots: var(--cv-grid-dot, rgba(255, 255, 255, 0.055)); --rm-chip: var(--bg-tertiary); --rm-field: var(--bg-primary);
        --rm-hover: #37373d; --rm-icon-fg: #b0b0b0; --rm-active: #264f78; --rm-primary: #0e639c; --rm-primary-hover: #1177bb; --rm-danger: #a1260d; --rm-focus: var(--accent-primary);
        --rm-warn-bg: rgba(206, 145, 120, 0.16); --rm-warn-fg: var(--accent-warning); --rm-error: var(--accent-danger); --rm-pop: var(--shadow-lg); --rm-badge-ink: #1e1e1e;
        --b0: #569cd6; --b1: #4ec9b0; --b2: #c586c0; --b3: #dcdcaa; --b4: #ce9178; --b5: #9cdcfe; }
    html[data-theme="light"] .rm-root {
        --rm-hover: #e0e0e0; --rm-icon-fg: #505050; --rm-active: #cfe4f7; --rm-primary: #0366d6; --rm-primary-hover: #0550ae; --rm-danger: #cb2431;
        --rm-warn-bg: rgba(176, 136, 0, 0.14); --rm-pop: 0 4px 14px rgba(0, 0, 0, 0.18); --rm-badge-ink: #ffffff;
        --b0: #0366d6; --b1: #22863a; --b2: #8250df; --b3: #9a6700; --b4: #cf4a1a; --b5: #0a7ea4; }
    .rm-root.visible { display: flex; }
    .rm-root [hidden] { display: none !important; }
    .rm-root button { font: inherit; }
    .rm-toolbar { position: relative; display: flex; align-items: center; gap: 4px; padding: 3px 8px; min-height: calc(32px * var(--ui-scale, 1)); background: var(--rm-bar); border-bottom: 1px solid var(--rm-line); flex: none; }
    .rm-tool { position: relative; display: inline-grid; place-items: center; flex: none; width: calc(26px * var(--ui-scale, 1)); height: calc(26px * var(--ui-scale, 1)); padding: 0; border: 0; border-radius: 3px; background: transparent; color: var(--rm-icon-fg); cursor: pointer; transition: background .15s, color .15s; }
    .rm-tool:hover:not(:disabled) { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-tool svg { width: 15px; height: 15px; }
    .rm-tool .rm-count { position: absolute; top: -3px; right: -3px; min-width: 14px; height: 14px; padding: 0 3px; border-radius: 7px; background: var(--rm-primary); color: #fff; font-size: 9px; line-height: 14px; text-align: center; }
    .rm-tbtn { flex: none; display: inline-flex; align-items: center; gap: 4px; height: calc(24px * var(--ui-scale, 1)); padding: 0 8px; border: 1px solid transparent; border-radius: 3px; background: transparent; color: var(--rm-icon-fg); font-size: calc(11px * var(--ui-scale, 1)); white-space: nowrap; cursor: pointer; transition: background .15s, color .15s; }
    .rm-tbtn:hover:not(:disabled) { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-tbtn[aria-expanded="true"] { background: var(--rm-hover); color: var(--rm-ink); }
    .rm-tbtn svg { width: 12px; height: 12px; }
    .rm-tsep { flex: none; width: 1px; height: 14px; margin: 0 3px; background: var(--rm-line); }
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
    .rm-icon-pick { display: inline-flex; align-items: center; gap: 6px; min-width: 56px; height: 26px; padding: 0 8px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); color: var(--rm-ink); cursor: pointer; }
    .rm-icon-pick:hover { background: var(--rm-hover); }
    .rm-icon-pick .rm-glyph { color: var(--rm-ink); }
    .rm-number-input { width: 64px; height: 26px; padding: 2px 6px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); font: inherit; color: var(--rm-ink); outline: none; }
    .rm-number-input:focus { border-color: var(--rm-focus); }
    .rm-icongrid { display: grid; grid-template-columns: repeat(auto-fill, minmax(34px, 1fr)); gap: 4px; }
    .rm-icongrid button { display: grid; place-items: center; height: 34px; padding: 0; border: 1px solid transparent; border-radius: 4px; background: transparent; color: var(--rm-ink); cursor: pointer; }
    .rm-icongrid button:hover { background: var(--rm-hover); }
    .rm-icongrid button[aria-pressed="true"] { border-color: var(--accent-primary); background: var(--rm-active); }
    .rm-icongrid svg { width: 18px; height: 18px; }
    .rm-color-row input[type=color] { width: 30px; height: 24px; padding: 1px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); cursor: pointer; }
    .rm-panel h3 { margin: 6px 0 0; font-size: .82em; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--rm-muted); }
    .rm-format { display: flex; flex-wrap: wrap; gap: 2px; }
    .rm-format .rm-icon { font-size: .95em; font-weight: 700; }
    .rm-desc { flex: 1 1 180px; width: 100%; min-height: 140px; padding: 8px 10px; border: 1px solid var(--rm-line); border-radius: 4px; background: var(--rm-field); line-height: 1.55; resize: vertical; outline: none; }
    .rm-desc:focus { border-color: var(--rm-focus); }
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
    .rm-btn.primary { border-color: var(--rm-primary); background: var(--rm-primary); color: #fff; }
    .rm-btn.primary:hover { background: var(--rm-primary-hover); }
    .rm-btn.danger { border-color: var(--rm-danger); background: var(--rm-danger); color: #fff; }
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
    function tbtn(act, label, title, handler, extra) {
        return h('button', { class: 'rm-tbtn', type: 'button', 'data-act': act, title: title, onClick: handler }, extra || null, label);
    }
    el.exportBtn = tbtn('export', 'Export', 'Export the map as a Markdown report or a PDF', function (e) { e.stopPropagation(); toggleExport(); }, icon('download'));
    el.exportBtn.setAttribute('aria-haspopup', 'true');
    el.exportBtn.setAttribute('aria-expanded', 'false');
    el.exportBtn.appendChild(icon('chevron'));
    el.exportMenu = h('div', { class: 'rm-exportmenu', role: 'menu', 'aria-label': 'Export', hidden: true },
        h('button', { class: 'rm-item', type: 'button', role: 'menuitem', 'data-act': 'export-markdown', onClick: function (e) { e.stopPropagation(); closeExport(); send('export', { kind: 'markdown' }); } }, icon('text'), h('span', null, 'Markdown report')),
        h('button', { class: 'rm-item', type: 'button', role: 'menuitem', 'data-act': 'export-pdf', onClick: function (e) { e.stopPropagation(); closeExport(); send('export', { kind: 'pdf' }); } }, icon('download'), h('span', null, 'PDF…')));
    el.collapseBtn = tbtn('collapse-all', 'Collapse all', 'Fold every branch so that only the root and its main branches show', function () { collapseAll(); });
    el.expandBtn = tbtn('expand-all', 'Expand all', 'Show every node', function () { expandAll(); });
    el.toolbar = h('div', { class: 'rm-toolbar' },
        el.sourceBtn,
        h('div', { class: 'rm-heading' }, el.title, el.question),
        el.status,
        el.queriesBtn,
        el.collapseBtn,
        el.expandBtn,
        el.exportBtn,
        h('span', { class: 'rm-tsep', 'aria-hidden': 'true' }),
        tool('zoom-out', 'Zoom out', icon('minus'), function () { zoomAtCentre(rm.view.scale / 1.2); }),
        el.zoom,
        tool('zoom-in', 'Zoom in', icon('plus'), function () { zoomAtCentre(rm.view.scale * 1.2); }),
        tool('centre', 'Centre the map on the root node at 100%', icon('centre'), function () { centreView(); }),
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
    el.problem = h('div', { class: 'rm-problem', id: 'research-map-problem', role: 'alert' }, el.problemText, h('button', { type: 'button', 'aria-label': 'Dismiss', onClick: function () { hideProblem(); } }, '✕'));
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
        el.iconPick = h('button', { class: 'rm-icon-pick', type: 'button', 'data-act': 'icon', title: 'Choose an icon for this node', onClick: function () { iconDialog(nodeById(rm.selected)); } });
        el.iconGlyph = h('span', { class: 'rm-glyph', 'aria-hidden': 'true' });
        el.iconText = h('span', null, 'None');
        el.iconPick.appendChild(el.iconGlyph);
        el.iconPick.appendChild(el.iconText);
        el.iconClear = h('button', { class: 'rm-x', type: 'button', 'data-act': 'icon-clear', title: 'Remove the icon', 'aria-label': 'Remove the icon' }, icon('close'));
        el.numberInput = h('input', { class: 'rm-number-input', type: 'number', min: '1', max: String(MAX_NUMBER), step: '1', inputmode: 'numeric', 'aria-label': 'Number badge', title: 'A number shown before the title (1 to ' + MAX_NUMBER + '); leave it empty for none', placeholder: '—' });
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
        el.aiButtons = AI_ACTIONS.map(function (action) {
            return h('button', { class: 'rm-ai-btn', type: 'button', 'data-act': action.act, title: action.hint, onClick: function () { runAI(action.act, nodeById(rm.selected)); } }, icon(action.icon), h('span', { class: 'rm-ai-label' }, action.label));
        });
        el.aiNote = h('p', { class: 'rm-ai-note' });
        el.body = h('div', { class: 'rm-panel-body', hidden: true },
            el.titleInput, el.titleError,
            h('h3', null, 'AI'), h('div', { class: 'rm-ai', role: 'group', 'aria-label': 'AI actions on this node' }, el.aiButtons), el.aiNote,
            el.tags,
            h('div', { class: 'rm-color-row' }, h('span', null, 'Color'), el.color, el.colorClear),
            h('div', { class: 'rm-badge-row' },
                h('div', { class: 'rm-field' }, h('span', null, 'Icon'), el.iconPick, el.iconClear),
                h('div', { class: 'rm-field' }, h('span', null, 'Number'), el.numberInput)),
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
        el.iconClear.addEventListener('click', function () { if (rm.selected) queueUpdate(rm.selected, { icon: '' }, true); });
        // The number is confirmed on Enter or when the field is left; an empty field removes it.
        const sendNumber = function () {
            if (!rm.selected) return;
            const raw = el.numberInput.value.trim();
            const value = raw === '' ? null : Math.floor(Number(raw));
            if (value !== null && !(value >= 1 && value <= MAX_NUMBER)) { toast('A number is between 1 and ' + MAX_NUMBER + '.'); fillPanel(true); return; }
            const node = nodeById(rm.selected);
            if (node && (node.number == null ? null : node.number) === value) return;
            queueUpdate(rm.selected, { number: value }, true);
        };
        el.numberInput.addEventListener('change', sendNumber);
        el.numberInput.addEventListener('keydown', function (event) { if (event.key === 'Enter') { event.preventDefault(); sendNumber(); el.numberInput.blur(); } });
        el.desc.addEventListener('input', function () { if (rm.selected) queueUpdate(rm.selected, { description: el.desc.value }); });
        el.desc.addEventListener('blur', function () { if (rm.selected) flushUpdate(rm.selected); });
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
                icon: text(n.icon),
                number: typeof n.number === 'number' && isFinite(n.number) && n.number >= 1 && n.number <= MAX_NUMBER && Math.floor(n.number) === n.number ? n.number : null,
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
            rm.collapsed = new Set();
            if (saved) {
                if (Array.isArray(saved.collapsed)) saved.collapsed.forEach(function (id) { if (typeof id === 'string') rm.collapsed.add(id); });
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
            if (snap.created && snap.byId.has(snap.created)) { reveal(snap.created); select(snap.created); ensureVisible(snap.created); }
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
        renderAI();
        fillPanel();
    }

    /** The CSS colour of a node's branch: a variable, so the theme can change without a redraw. */
    function branchOf(id) { return 'var(--b' + ((rm.branchIdx.get(id) || 0) % BRANCH_COLOURS) + ')'; }
    /** The same colour as #rrggbb, for the colour input. */
    function branchHex(id) {
        const raw = getComputedStyle(el.root).getPropertyValue('--b' + ((rm.branchIdx.get(id) || 0) % BRANCH_COLOURS)).trim();
        return /^#[0-9a-f]{6}$/i.test(raw) ? raw.toLowerCase() : '#569cd6';
    }

    // ---- folding (DEC-010): the children of a folded node are hidden; the state is view state, not part of the file ------------------
    function childrenIndex() {
        const kids = new Map();
        rm.snap.nodes.forEach(function (n) {
            if (!n.parent) return;
            if (!kids.has(n.parent)) kids.set(n.parent, []);
            kids.get(n.parent).push(n.id);
        });
        return kids;
    }
    /** Ids hidden by folded ancestors; the root is never hidden and never folded. */
    function hiddenIds() {
        const hidden = new Set();
        if (!rm.snap || !rm.collapsed.size) return hidden;
        const kids = childrenIndex(), rootId = rm.snap.nodes[0].id;
        rm.collapsed.forEach(function (id) {
            if (id === rootId || !rm.snap.byId.has(id)) return;
            const stack = (kids.get(id) || []).slice();
            while (stack.length) {
                const cur = stack.pop();
                if (hidden.has(cur)) continue;
                hidden.add(cur);
                (kids.get(cur) || []).forEach(function (k) { stack.push(k); });
            }
        });
        return hidden;
    }
    /** Number of descendants per node id, from one pass over the tree. */
    function descendantCounts() {
        const kids = childrenIndex(), counts = new Map();
        const count = function (id, depth) {
            if (counts.has(id)) return counts.get(id);
            let total = 0;
            if (depth < 1000) (kids.get(id) || []).forEach(function (k) { total += 1 + count(k, depth + 1); });
            counts.set(id, total);
            return total;
        };
        rm.snap.nodes.forEach(function (n) { count(n.id, 0); });
        return counts;
    }
    function toggleFold(id) {
        if (!rm.snap || !rm.snap.byId.has(id)) return;
        if (rm.collapsed.has(id)) rm.collapsed.delete(id); else rm.collapsed.add(id);
        closeMenu();
        const hidden = hiddenIds();
        if (rm.selected && hidden.has(rm.selected)) { rm.selected = id; fillPanel(); }
        refreshTree();
        saveSoon();
    }
    function collapseAll() {
        if (!rm.snap) return;
        const kids = childrenIndex(), rootId = rm.snap.nodes[0].id;
        rm.collapsed = new Set();
        rm.snap.nodes.forEach(function (n) { if (n.id !== rootId && kids.has(n.id)) rm.collapsed.add(n.id); });
        closeMenu();
        if (rm.selected && hiddenIds().has(rm.selected)) {
            let cur = nodeById(rm.selected);
            while (cur && hiddenIds().has(cur.id)) cur = nodeById(cur.parent);
            rm.selected = cur ? cur.id : rootId;
            fillPanel();
        }
        refreshTree();
        saveSoon();
    }
    function expandAll() {
        if (!rm.collapsed.size) return;
        rm.collapsed = new Set();
        closeMenu();
        refreshTree();
        saveSoon();
    }
    /** Unfolds the ancestors of a node so that it is shown; true when something changed. */
    function reveal(id) {
        let changed = false, cur = nodeById(id), guard = 0;
        while (cur && cur.parent && guard++ < 1000) {
            if (rm.collapsed.has(cur.parent)) { rm.collapsed.delete(cur.parent); changed = true; }
            cur = nodeById(cur.parent);
        }
        if (changed) refreshTree();
        return changed;
    }
    function refreshTree() {
        syncNodes();
        relayout();
        syncSelection();
    }

    function syncNodes() {
        const snap = rm.snap;
        rm.branchIdx = branchIndexes(snap.nodes);
        const rootId = snap.nodes[0].id;
        const present = new Set();
        const counts = descendantCounts();
        snap.nodes.forEach(function (n) {
            present.add(n.id);
            const entry = rm.els.get(n.id) || makeNode(n.id);
            const colour = branchOf(n.id);
            const isRoot = n.id === rootId, isBranch = n.parent === rootId;
            const own = n.color;
            entry.wrap.classList.toggle('is-root', isRoot);
            entry.btn.className = 'rm-node' + (isRoot ? ' root' : (isBranch ? ' branch' : '')) + (own ? ' has-color' : '');
            const title = (rm.pending[n.id] && rm.pending[n.id].fields.title) || n.title;
            if (entry.label.textContent !== title) entry.label.textContent = title;
            // Icon and number badge before the title (REQ-008).
            entry.badge.hidden = n.number == null;
            entry.badge.textContent = n.number == null ? '' : String(n.number);
            setGlyph(entry.glyph, n.icon);
            entry.lead.hidden = n.number == null && !n.icon;
            const spoken = (n.number == null ? '' : 'Number ' + n.number + '. ') + (n.icon && NODE_ICONS[n.icon] ? n.icon + ' icon. ' : '');
            entry.btn.setAttribute('aria-label', spoken + title + '. Select node; arrow keys move the node');
            entry.tri.setAttribute('aria-label', 'Actions for node “' + title + '”');
            // The wrap carries the colour: the node and its fold toggle both use it.
            entry.wrap.style.setProperty('--branch', own || colour);
            entry.btn.style.setProperty('--tint', own ? mix(own, '#ffffff', 0.14) : '');
            entry.btn.style.setProperty('--tint-dark', own ? mix(own, '#252526', 0.22) : '');
            // The badge text reads on the node's own colour, and on the theme's branch colour otherwise.
            entry.btn.style.setProperty('--badge-ink', own ? readableOn(own) : '');
            entry.tri.hidden = false;
            // Fold toggle: only a node with children has one; a folded node says how many nodes it hides.
            const below = counts.get(n.id) || 0;
            const folded = below > 0 && !isRoot && rm.collapsed.has(n.id);
            entry.fold.hidden = below === 0 || isRoot;
            entry.fold.classList.toggle('folded', folded);
            entry.fold.setAttribute('aria-expanded', folded ? 'false' : 'true');
            entry.fold.title = folded ? 'Show ' + below + ' hidden ' + (below === 1 ? 'node' : 'nodes') : 'Fold the ' + (below === 1 ? 'child node' : 'child nodes') + ' of this node';
            entry.fold.setAttribute('aria-label', (folded ? 'Expand “' : 'Collapse “') + title + '”');
            entry.fold.textContent = '';
            if (folded) entry.fold.appendChild(document.createTextNode('+' + below));
            else entry.fold.appendChild(icon('chevron'));
        });
        // Hidden nodes are not laid out and not measured.
        const hidden = hiddenIds();
        rm.els.forEach(function (entry, id) { entry.wrap.hidden = hidden.has(id); });
        rm.els.forEach(function (entry, id) {
            if (present.has(id)) return;
            if (rm.menu === id) closeMenu();
            entry.wrap.remove();
            rm.els.delete(id);
        });
        // Measure after the labels are in: the layout needs the real sizes.
        rm.sizes = {};
        rm.els.forEach(function (entry, id) {
            if (hidden.has(id)) return;
            const w = entry.btn.offsetWidth, hgt = entry.btn.offsetHeight;
            if (w > 0 && hgt > 0) rm.sizes[id] = { w: w, h: hgt };
        });
    }

    function makeNode(id) {
        const badge = h('span', { class: 'rm-badge', hidden: true });
        const glyph = h('span', { class: 'rm-glyph', hidden: true, 'aria-hidden': 'true' });
        const lead = h('span', { class: 'rm-lead', hidden: true }, badge, glyph);
        const label = h('span', { class: 'rm-label' });
        const btn = h('button', { class: 'rm-node', type: 'button', 'aria-pressed': 'false' }, lead, label);
        const tri = h('button', { class: 'rm-tri', type: 'button', title: 'Node menu: AI actions, add, connect, arrange, delete', 'aria-haspopup': 'true', 'aria-expanded': 'false' }, '⋯');
        const fold = h('button', { class: 'rm-fold', type: 'button', hidden: true, 'aria-expanded': 'true' });
        const wrap = h('div', { class: 'rm-node-wrap', 'data-id': id }, btn, tri, fold);
        const entry = { wrap: wrap, btn: btn, tri: tri, fold: fold, lead: lead, badge: badge, glyph: glyph, label: label };
        fold.addEventListener('click', function (event) {
            event.stopPropagation();
            toggleFold(id);
        });
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
        const hidden = hiddenIds();
        return rm.snap.nodes.filter(function (n) { return !hidden.has(n.id); }).map(function (n) {
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
        path.style.stroke = color;
        path.setAttribute('stroke-width', dashed ? '1.5' : '2');
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
            if (a && b) addPath(curve(a, b), n.color || branchOf(n.id), false, 'tree');
        });
        snap.links.forEach(function (l) {
            const a = rm.positions[l.from], b = rm.positions[l.to];
            if (a && b) addPath(curve(a, b), 'var(--rm-muted)', true, 'link');
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
    function toggleQueries() { if (rm.queriesOpen) closeQueries(); else { closeExport(); rm.queriesOpen = true; el.popover.hidden = false; } }
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
        closeMenu();
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
        if (event.target.closest('.rm-tri, .rm-fold, .rm-actions')) return;
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
            closeMenu();
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
    function fillPanel(forceNumber) {
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
        const shownColor = node.color || branchHex(node.id);
        if (document.activeElement !== el.color) el.color.value = shownColor;
        el.colorClear.hidden = !node.color;
        setGlyph(el.iconGlyph, node.icon);
        el.iconText.textContent = node.icon ? (NODE_ICONS[node.icon] ? node.icon.charAt(0).toUpperCase() + node.icon.slice(1) : 'Emoji') : 'None';
        el.iconClear.hidden = !node.icon;
        if (forceNumber === true || document.activeElement !== el.numberInput) el.numberInput.value = node.number == null ? '' : String(node.number);
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
        renderAI();
        el.evHeading.textContent = 'Evidence (' + node.evidence.length + ')';
        el.evSection.hidden = node.evidence.length === 0;
        // Logical connections of this node, each removable.
        el.connList.textContent = '';
        const mine = rm.snap.links.filter(function (l) { return l.from === node.id || l.to === node.id; });
        mine.forEach(function (l) {
            const otherId = l.from === node.id ? l.to : l.from, other = nodeById(otherId);
            const name = other ? other.title : otherId;
            el.connList.appendChild(h('li', { class: 'rm-conn-row', 'data-from': l.from, 'data-to': l.to },
                h('button', { class: 'rm-conn-name', type: 'button', title: 'Select this node', onClick: function () { reveal(otherId); select(otherId); ensureVisible(otherId); } }, '↔ ' + name),
                h('button', { class: 'rm-x', type: 'button', title: 'Remove this connection', 'aria-label': 'Remove the connection to “' + name + '”', onClick: function () { send('unlink', { from: l.from, to: l.to }); } }, icon('close'))));
        });
        el.connHeading.textContent = 'Connections (' + mine.length + ')';
        el.connSection.hidden = mine.length === 0;
        // Last, when the panel has its final content: a scrollbar that appears now narrows the title field. The second pass
        // measures at the final width (a taller title can itself bring the scrollbar).
        fitTitle();
        fitTitle();
    }

    // ---- node menu -----------------------------------------------------------------------------------------------------------------
    function descendantIds(id) {
        const ids = [id];
        for (let i = 0; i < ids.length; i++) rm.snap.nodes.forEach(function (n) { if (n.parent === ids[i] && ids.indexOf(n.id) < 0) ids.push(n.id); });
        return ids;
    }
    function closeMenu() {
        if (rm.menu == null && !rm.menuEl) return;
        const entry = rm.els.get(rm.menu);
        if (entry) {
            entry.wrap.classList.remove('menu-open');
            entry.tri.setAttribute('aria-expanded', 'false');
        }
        if (rm.menuEl) { rm.menuEl.remove(); rm.menuEl = null; }
        rm.menu = null;
    }
    /** Under the node's menu button, at screen size (the menu is not part of the zoomed map), kept inside the map area. */
    function placeMenu(bar, entry) {
        const host = el.left.getBoundingClientRect(), anchor = entry.tri.getBoundingClientRect();
        const width = bar.offsetWidth, height = bar.offsetHeight;
        let left = anchor.right - host.left - width, top = anchor.bottom - host.top + 4;
        left = clamp(left, 4, Math.max(4, host.width - width - 4));
        if (top + height > host.height - 4) top = Math.max(4, host.height - height - 4);
        bar.style.left = left + 'px';
        bar.style.top = top + 'px';
    }
    function aiBusy() { return !!(rm.snap && (rm.snap.job || rm.snap.status === 'researching')); }
    const BUSY_HINT = 'An AI job is already working on this map; stop it or wait for it first.';
    function openMenu(id) {
        closeMenu();
        closeExport();
        const entry = rm.els.get(id), node = nodeById(id);
        if (!entry || !node) return;
        const snap = rm.snap, isRoot = id === snap.nodes[0].id, busy = aiBusy();
        const dialogs = { develop: true, correct: true };
        const bar = h('div', { class: 'rm-actions', role: 'menu', 'aria-label': 'Actions for node “' + node.title + '”' });
        const addItem = function (item) {
            const button = h('button', { class: 'rm-item' + (item.ai ? ' ai' : '') + (item.danger ? ' danger' : ''), type: 'button', role: 'menuitem', 'data-act': item.act,
                title: item.off && item.offHint ? item.offHint : (item.hint || item.label), 'aria-label': item.label, disabled: !!item.off }, icon(item.icon), h('span', null, item.label));
            if (item.more) button.appendChild(h('span', { class: 'rm-more', 'aria-hidden': 'true' }, '▾'));
            button.addEventListener('click', function (event) {
                event.stopPropagation();
                if (item.act === 'arrange') { toggleLayouts(bar, node, button, entry); return; }
                closeMenu();
                item.run();
            });
            bar.appendChild(button);
        };
        AI_ACTIONS.forEach(function (action) {
            addItem({ act: action.act, label: action.label + (dialogs[action.act] ? '…' : ''), icon: action.icon, ai: true, hint: action.hint, off: busy, offHint: BUSY_HINT,
                run: function () { runAI(action.act, node); } });
        });
        bar.appendChild(h('div', { class: 'rm-sep', role: 'separator' }));
        addItem({ act: 'add', label: 'Add child node…', icon: 'plus', run: function () { addChildDialog(node); } });
        addItem({ act: 'link', label: 'Add logical connection…', icon: 'link', off: snap.nodes.length < 2, run: function () { linkDialog(node); } });
        addItem({ act: 'edit', label: 'Edit title…', icon: 'edit', run: function () { editDialog(node); } });
        addItem({ act: 'icon', label: 'Icon…', icon: 'tag', hint: 'Choose an icon or an emoji for this node', run: function () { select(id); iconDialog(node); } });
        const kids = snap.nodes.filter(function (n) { return n.parent === id; });
        const numbered = kids.length > 0 && kids.every(function (n, i) { return n.number === i + 1; });
        addItem({ act: 'number-children', label: numbered ? 'Remove numbers from children' : 'Number children 1, 2, 3…', icon: 'text',
            hint: numbered ? 'Take the number badges off the child nodes' : 'Give the child nodes the number badges 1, 2, 3 in map order',
            off: kids.length === 0, offHint: 'This node has no children', run: function () { send('numberChildren', { id: id, clear: numbered }); } });
        addItem({ act: 'arrange', label: 'Arrange branch', icon: 'grid', more: true, hint: 'Choose how this branch lays out its nodes', run: null });
        bar.appendChild(h('div', { class: 'rm-sep', role: 'separator' }));
        addItem({ act: 'delete', label: 'Delete node…', icon: 'trash', danger: true, off: isRoot, offHint: 'The root node cannot be deleted', run: function () { deleteDialog(node); } });
        el.left.appendChild(bar);
        placeMenu(bar, entry);
        entry.wrap.classList.add('menu-open');
        entry.tri.setAttribute('aria-expanded', 'true');
        rm.menu = id;
        rm.menuEl = bar;
    }
    function toggleLayouts(bar, node, anchorButton, entry) {
        const existing = bar.querySelector('.rm-layouts');
        if (existing) { existing.remove(); placeMenu(bar, entry); return; }
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
        anchorButton.insertAdjacentElement('afterend', list);
        placeMenu(bar, entry);
    }

    // ---- AI actions on a node (REQ-006) ----------------------------------------------------------------------------------------------
    function runAI(act, node) {
        if (!node) return;
        if (aiBusy()) { toast(BUSY_HINT); return; }
        if (act === 'describe') send('describe', { id: node.id });
        else if (act === 'investigate') send('investigate', { id: node.id });
        else if (act === 'develop') developDialog(node);
        else if (act === 'correct') correctDialog(node);
    }
    function renderAI() {
        const busy = aiBusy();
        el.aiButtons.forEach(function (button) { button.disabled = busy; });
        el.aiNote.textContent = busy ? BUSY_HINT : '';
    }

    // ---- export menu -----------------------------------------------------------------------------------------------------------------
    function toggleExport() {
        if (rm.exportOpen) { closeExport(); return; }
        closeMenu();
        closeQueries();
        rm.exportOpen = true;
        el.exportMenu.hidden = false;
        el.exportBtn.setAttribute('aria-expanded', 'true');
    }
    function closeExport() {
        rm.exportOpen = false;
        el.exportMenu.hidden = true;
        el.exportBtn.setAttribute('aria-expanded', 'false');
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
            if (event.key === 'Enter' && primary && (event.target.tagName === 'INPUT' || ((event.metaKey || event.ctrlKey) && event.target.tagName === 'TEXTAREA'))) { event.preventDefault(); primary.click(); }
        });
        const first = card.querySelector('input, textarea, select') || primary || buttons[0];
        if (first) first.focus();
        return overlay;
    }
    function textDialog(title, intro, labelText, initial, maxLength, okLabel, onOk, emptyMessage, options) {
        options = options || {};
        const input = options.multiline
            ? h('textarea', { maxlength: String(maxLength), 'aria-label': labelText, spellcheck: 'false', placeholder: options.placeholder || '' })
            : h('input', { type: 'text', maxlength: String(maxLength), 'aria-label': labelText, value: initial || '', spellcheck: 'false', placeholder: options.placeholder || '' });
        if (options.multiline) input.value = initial || '';
        const error = h('p', { class: 'rm-error', role: 'alert' });
        dialog(title, [intro ? h('p', null, intro) : null, h('label', null, labelText, input), error], [
            { label: 'Cancel', kind: 'ghost' },
            { label: okLabel, kind: 'primary', run: function () {
                const value = input.value.trim();
                if (!value && emptyMessage) { error.textContent = emptyMessage; input.focus(); return false; }
                onOk(value);
            } }
        ]);
        input.select();
    }
    /** One emoji: a single grapheme that is a pictograph. Swift decides in the end; this only saves a round trip. */
    function isEmojiText(value) {
        if (!value) return false;
        const parts = typeof Intl !== 'undefined' && Intl.Segmenter ? Array.from(new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(value)) : [value];
        return parts.length === 1 && /\p{Extended_Pictographic}|\p{Regional_Indicator}|\uFE0F/u.test(value);
    }
    function iconDialog(node) {
        if (!node) return;
        const grid = h('div', { class: 'rm-icongrid', role: 'group', 'aria-label': 'Built-in icons' });
        NODE_ICON_IDS.forEach(function (id) {
            const name = id.charAt(0).toUpperCase() + id.slice(1);
            grid.appendChild(h('button', { type: 'button', 'data-icon': id, title: name, 'aria-label': name, 'aria-pressed': node.icon === id ? 'true' : 'false', onClick: function () {
                queueUpdate(node.id, { icon: id }, true);
                closeDialog();
            } }, icon(id, NODE_ICONS)));
        });
        const input = h('input', { type: 'text', 'aria-label': 'Emoji', maxlength: '16', spellcheck: 'false', placeholder: 'Paste or type one emoji', value: node.icon && !NODE_ICONS[node.icon] ? node.icon : '' });
        const error = h('p', { class: 'rm-error', role: 'alert' });
        const actions = [{ label: 'Cancel', kind: 'ghost' }];
        if (node.icon) actions.push({ label: 'Remove icon', kind: 'ghost', run: function () { queueUpdate(node.id, { icon: '' }, true); } });
        actions.push({ label: 'Use emoji', kind: 'primary', run: function () {
            const value = input.value.trim();
            if (!isEmojiText(value)) { error.textContent = 'Paste one emoji (macOS: Control-Command-Space).'; input.focus(); return false; }
            queueUpdate(node.id, { icon: value }, true);
        } });
        dialog('Icon for “' + node.title + '”', [grid, h('label', null, 'Or any emoji', input), error], actions, 'Choose an icon');
    }
    function addChildDialog(parent) {
        textDialog('Add child node', 'Parent node: ' + parent.title, 'Child node name', '', MAX_TITLE, 'Add', function (title) { send('addChild', { parent: parent.id, title: title }); }, 'Enter a node name.');
    }
    function editDialog(node) {
        textDialog('Edit node', '', 'Node name', node.title, MAX_TITLE, 'Save', function (title) { send('update', { id: node.id, title: title }); }, 'Enter a node name.');
    }
    function developDialog(node) {
        textDialog('Expand topic', 'The AI adds child nodes under “' + node.title + '”.', 'Direction (optional)', '', 500, 'Expand', function (direction) { send('develop', { id: node.id, direction: direction }); }, '',
            { placeholder: 'e.g. compare the options, or focus on the costs' });
    }
    function correctDialog(node) {
        textDialog('Correct node', 'The AI checks “' + node.title + '” against the project and the web and fixes only this node.', 'What is wrong with it?', '', 2000, 'Correct', function (note) { send('correct', { id: node.id, note: note }); }, 'Say what is wrong with this node.',
            { multiline: true, placeholder: 'e.g. the cache is not LRU, it evicts by size' });
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
        if (rm.menu != null && !event.target.closest('.rm-node-wrap.menu-open, .rm-actions')) closeMenu();
        if (rm.queriesOpen && !event.target.closest('.rm-popover, [data-act="queries"]')) closeQueries();
        if (rm.exportOpen && !event.target.closest('.rm-exportmenu, [data-act="export"]')) closeExport();
    }, true);
    el.root.addEventListener('keydown', function (event) {
        if (event.key !== 'Escape') return;
        if (rm.dialog) { closeDialog(); event.stopPropagation(); }
        else if (rm.menu != null) { closeMenu(); event.stopPropagation(); }
        else if (rm.queriesOpen) { closeQueries(); event.stopPropagation(); }
        else if (rm.exportOpen) { closeExport(); event.stopPropagation(); }
    });

    // ---- entering and leaving ------------------------------------------------------------------------------------------------------------
    function resetForDocument(docId) {
        flushAll();
        clearTimeout(rm.saveTimer);
        saveNow();
        closeMenu();
        closeDialog();
        closeQueries();
        closeExport();
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
        rm.collapsed = new Set();
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
        closeExport();
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

    /** The report of a map as HTML for the PDF pipeline. A separate renderer that never passes raw HTML through: the text is AI-written. */
    let reportRenderer = null;
    function reportHTML(markdown) {
        try {
            if (!reportRenderer && window.markdownit) reportRenderer = window.markdownit({ html: false, breaks: true, linkify: true, typographer: true });
            return reportRenderer ? reportRenderer.render(String(markdown == null ? '' : markdown)) : '';
        } catch (e) { reportError('reportHTML', e); return ''; }
    }

    window.MVResearchMap = {
        reportHTML: reportHTML,
        iconIDs: function () { return NODE_ICON_IDS.slice(); },
        notice: function (message) { toast(String(message)); },
        collapsed: function () { return Array.from(rm.collapsed); },
        isResearchMapText: isResearchMapText,
        viewState: function () { return { active: rm.active, x: rm.view.x, y: rm.view.y, scale: rm.view.scale, panel: rm.panelWidth, selected: rm.selected, key: rm.mapKey }; }
    };
})();
