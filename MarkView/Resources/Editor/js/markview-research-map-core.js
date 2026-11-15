// Research map view (DEC-009). A Markdown document whose front matter says `type: research-map` is shown as a mind map
// inside the editor tab. Swift owns the file: it parses and writes the format, applies every rule, and answers each
// operation with a full snapshot through window.mvResearchMapSet(documentId, snapshot). This file only draws the
// snapshot, keeps view state (selection, pan, zoom, panel width) and sends operations as
// sendToSwift('researchMap', {action, ...}). Positions come from markview-research-map-layout.js.
//
// Like the other overlay views (data, code, architecture, canvas) it takes over the editor area, and it wraps
// setContent / setStructuredContent / setCodeContent / setDataContent / showArchitecture / switchToSource /
// switchToPreview / the mode toggles, so the map and the Source view alternate and every other document leaves it.

// Research map, part 1 of 6: constants, icons and shapes, DOM helpers, visuals (diagrams and pictures), colour helpers, view state and saving.
(function (A) {
    'use strict';
    Object.assign(A, {
        clamp, diagramSourceOf, fillVisual, flushAll, flushUpdate, h, icon, imageOf, imageURL, isResearchMapText,
        loadSaved, mix, now, queueMove, queueUpdate, readableOn, reportError, saveNow, saveSoon, send, setGlyph,
        setThumb, visualOf, withDiagram, withImage
    });

    const Layout = window.MVResearchMapLayout;
    A.Layout = Layout;
    const host = document.querySelector('.editor-content');
    A.host = host;
    if (!Layout || !host || typeof DOM === 'undefined' || typeof state === 'undefined') return;
    A.ready = true;

    const NS = 'http://www.w3.org/2000/svg';
    A.NS = NS;
    // Six branch colours: the application's own accent family (--b0..--b5 in the styles below, one set per theme).
    const BRANCH_COLOURS = 6;
    A.BRANCH_COLOURS = BRANCH_COLOURS;
    const MIN_SCALE = 0.4, MAX_SCALE = 2;
    A.MAX_SCALE = MAX_SCALE;
    A.MIN_SCALE = MIN_SCALE;
    const PANEL_MIN = 240, PANEL_MAX = 600, PANEL_DEFAULT = 320;
    A.PANEL_DEFAULT = PANEL_DEFAULT;
    A.PANEL_MAX = PANEL_MAX;
    A.PANEL_MIN = PANEL_MIN;
    const MAX_TITLE = 120;
    A.MAX_TITLE = MAX_TITLE;
    // The four AI actions on one node (REQ-006): what each does is said in its tooltip.
    const AI_ACTIONS = [
        { act: 'describe', label: 'Expand description', icon: 'text', hint: 'The AI rewrites and extends this node’s description' },
        { act: 'develop', label: 'Expand topic', icon: 'fork', hint: 'The AI adds child nodes under this node' },
        { act: 'correct', label: 'Correct', icon: 'edit', hint: 'Say what is wrong; the AI fixes this node' },
        { act: 'investigate', label: 'Research', icon: 'search', hint: 'The AI looks for facts about this node in the project and on the web' }
    ];
    A.AI_ACTIONS = AI_ACTIONS;
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
        open: 'M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5',
        diagram: 'M4 4h7v5H4zM13 15h7v5h-7zM7.5 9v3.5h9V15',
        photo: 'M4 5h16v14H4zM4 16l5-5 4 4 3-3 4 4M9 9a.8.8 0 1 0 0 .01'
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
    A.NODE_ICONS = NODE_ICONS;
    const NODE_ICON_IDS = Object.keys(NODE_ICONS);
    A.NODE_ICON_IDS = NODE_ICON_IDS;
    const MAX_NUMBER = 999;
    A.MAX_NUMBER = MAX_NUMBER;

    // Node shapes and sizes (REQ-009, DEC-012). Swift owns the list of ids and the limits (they arrive in every snapshot);
    // the page owns the drawings. `rounded` is the default look and is never stored. A check in research-map-web-tests.sh
    // keeps SHAPE_IDS equal to ResearchMap.shapes.
    const SHAPE_IDS = ['rounded', 'rectangle', 'pill', 'ellipse', 'diamond'];
    A.SHAPE_IDS = SHAPE_IDS;
    const SHAPE_PATHS = {
        rounded: 'M6 7h12a3 3 0 0 1 3 3v4a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3v-4a3 3 0 0 1 3-3z',
        rectangle: 'M3 7h18v10H3z',
        pill: 'M9 7h6a5 5 0 0 1 0 10H9A5 5 0 0 1 9 7z',
        ellipse: 'M3 12a9 6 0 1 0 18 0 9 6 0 1 0-18 0z',
        diamond: 'M12 4l9 8-9 8-9-8z'
    };
    A.SHAPE_PATHS = SHAPE_PATHS;
    const SHAPE_NAMES = { rounded: 'Rounded', rectangle: 'Rectangle', pill: 'Pill', ellipse: 'Ellipse', diamond: 'Diamond' };
    A.SHAPE_NAMES = SHAPE_NAMES;
    // The limits of a given width and height, replaced by the snapshot's `sizeLimits` (Swift's ResearchMap.widthRange/heightRange).
    const LIMITS = { width: [60, 800], height: [28, 600] };
    A.LIMITS = LIMITS;
    const SIZE_PRESETS = [{ id: 's', label: 'S', w: 140, h: 44 }, { id: 'm', label: 'M', w: 220, h: 64 }, { id: 'l', label: 'L', w: 320, h: 96 }];
    A.SIZE_PRESETS = SIZE_PRESETS;
    // Ellipse and diamond keep the title in the rectangle inscribed in the shape: k is its share of the width and of the
    // height (the corners of the text just touch the outline), the pads are extra room, maxText is where an automatic
    // node wraps its title, minW/minH keep a short title from making a tiny shape.
    const SHAPE_FIT = {
        ellipse: { k: Math.SQRT1_2, padX: 12, padY: 7, maxText: 170, minW: 88, minH: 46 },
        diamond: { k: 0.5, padX: 8, padY: 5, maxText: 130, minW: 112, minH: 68 }
    };
    A.SHAPE_FIT = SHAPE_FIT;
    const HANDLES = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'];
    A.HANDLES = HANDLES;

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

    // ---- diagram and image nodes (REQ-012, DEC-013) --------------------------------------------------------------------------------
    // A node with `visual` "diagram" or "image" shows the first ```mermaid fence or the first Markdown image of its description
    // instead of its title. The content stays in the description (Markdown), so View, Source and the report show it too.
    // diagramSourceOf / imageOf mirror ResearchMap.diagramSource / imageSource in Swift; a web test feeds both the same text.
    const CARD_BOX = { w: 280, h: 190 }, PANEL_BOX = { w: 460, h: 300 };
    A.PANEL_BOX = PANEL_BOX;
    A.CARD_BOX = CARD_BOX;
    const VISUAL_KINDS = [['text', 'Text'], ['diagram', 'Diagram'], ['image', 'Image']];
    A.VISUAL_KINDS = VISUAL_KINDS;
    const vis = { cache: new Map(), queue: Promise.resolve(), counter: 0 };

    function fenceOf(text) {
        const lines = String(text || '').split('\n');
        for (let i = 0; i < lines.length; i++) {
            const t = lines[i].trim();
            if (t.indexOf('```') !== 0 || t.slice(3).trim().toLowerCase() !== 'mermaid') continue;
            for (let j = i + 1; j < lines.length; j++) {
                if (lines[j].trim().indexOf('```') === 0) return { from: i, to: j, lines: lines, source: lines.slice(i + 1, j).join('\n').trim() };
            }
            return null;
        }
        return null;
    }
    function diagramSourceOf(text) { const f = fenceOf(text); return f && f.source ? f.source : null; }
    function imageOf(text) {
        const s = String(text || '');
        const open = s.indexOf('![');
        if (open < 0) return null;
        const mid = s.indexOf('](', open + 2);
        if (mid < 0) return null;
        const close = s.indexOf(')', mid + 2);
        if (close < 0) return null;
        const alt = s.slice(open + 2, mid);
        let src = s.slice(mid + 2, close).trim();
        const space = src.indexOf(' ');
        if (space >= 0) src = src.slice(0, space);
        if (alt.indexOf('\n') >= 0 || !src) return null;
        return { alt: alt, src: src, from: open, to: close + 1 };
    }
    /** `text` with its first Mermaid fence replaced by `source` (an empty source removes the fence); with no fence, the new one goes first. */
    function withDiagram(text, source) {
        const body = String(source || '').split('\n').filter(function (line) { return line.trim().indexOf('```') !== 0; }).join('\n').replace(/\s+$/, '');
        const fence = body ? ['```mermaid'].concat(body.split('\n'), ['```']) : [];
        const f = fenceOf(text);
        if (f) {
            const lines = f.lines.slice();
            lines.splice.apply(lines, [f.from, f.to - f.from + 1].concat(fence));
            return lines.join('\n');
        }
        if (!fence.length) return String(text || '');
        return fence.join('\n') + (String(text || '').trim() ? '\n\n' + text : '');
    }
    /** `text` with its first Markdown image replaced by one for `src` (an empty address removes it); with none, the new one goes first. */
    function withImage(text, alt, src) {
        const s = String(text || '');
        const address = String(src || '').trim().replace(/ /g, '%20').replace(/\)/g, '%29');
        const markdown = address ? '![' + String(alt || '').replace(/[\[\]\n]/g, ' ').trim() + '](' + address + ')' : '';
        const found = imageOf(s);
        if (found) return s.slice(0, found.from) + markdown + s.slice(found.to);
        if (!markdown) return s;
        return markdown + (s.trim() ? '\n\n' + s : '');
    }
    /** What a node shows in place of its title, or null (a text node, or a visual with nothing to show yet). */
    function visualOf(node) {
        if (!node || !node.visual) return null;
        if (node.visual === 'diagram') {
            const source = diagramSourceOf(node.description);
            return source ? { kind: 'diagram', source: source } : null;
        }
        if (node.visual === 'image') {
            const image = imageOf(node.description);
            return image ? { kind: 'image', alt: image.alt, src: image.src } : null;
        }
        return null;
    }
    /** The address the page can load for a picture: web and data addresses as written, a project path through the document files. */
    function imageURL(src) {
        const written = String(src || '').trim();
        if (!written) return null;
        if (/^(https?:|data:image\/)/i.test(written)) return written;
        if (/^[a-z][a-z0-9+.-]*:/i.test(written)) return null;
        const base = typeof state !== 'undefined' ? state.documentBaseURL : null;
        return (window.MarkViewDocumentFiles && base && window.MarkViewDocumentFiles.pictureURL(written, base)) || null;
    }
    /** Draws Mermaid source to { svg, w, h } or { error }. Draws run one after another and are remembered per source and theme. */
    function drawDiagram(key, source, forcedTheme) {
        if (vis.cache.has(key)) return Promise.resolve(vis.cache.get(key));
        const remember = function (result) {
            vis.cache.set(key, result);
            if (vis.cache.size > 80) vis.cache.delete(vis.cache.keys().next().value);
            return result;
        };
        const run = function () {
            if (typeof mermaid === 'undefined') return remember({ error: 'Mermaid is not available.' });
            const id = 'rmv' + (++vis.counter);
            try { mermaid.initialize(Object.assign({ startOnLoad: false, securityLevel: 'strict' }, forcedTheme ? { theme: forcedTheme } : MarkViewThemes.mermaid())); } catch (e) { /* keep the current setup */ }
            return Promise.resolve().then(function () { return mermaid.render(id, source); }).then(function (drawn) {
                const doc = new DOMParser().parseFromString(drawn.svg, 'image/svg+xml').documentElement;
                const box = (doc.getAttribute('viewBox') || '').trim().split(/[\s,]+/).map(Number);
                const w = box.length === 4 && box[2] > 0 ? box[2] : 300, hgt = box.length === 4 && box[3] > 0 ? box[3] : 150;
                return remember({ svg: drawn.svg, w: w, h: hgt });
            }).catch(function (error) {
                const junk = document.getElementById('d' + id);
                if (junk) junk.remove();
                return remember({ error: String((error && error.message) || error || 'The diagram could not be drawn.').slice(0, 300) });
            });
        };
        const next = vis.queue.then(run, run);
        vis.queue = next.then(function () {}, function () {});
        return next;
    }
    function placeDiagram(box, result, limits) {
        box.textContent = '';
        box.classList.toggle('error', !!result.error);
        if (result.error) {
            box.appendChild(h('span', { class: 'rm-vis-note', title: result.error }, 'This diagram could not be drawn'));
            return;
        }
        const holder = document.createElement('span');
        holder.innerHTML = window.mvKit.sanitizeMermaidSvg(result.svg);
        const svg = holder.querySelector('svg');
        if (!svg) return;
        const k = Math.min(1, limits.w / result.w, limits.h / result.h);
        svg.setAttribute('width', String(Math.max(40, Math.round(result.w * k))));
        svg.setAttribute('height', String(Math.max(24, Math.round(result.h * k))));
        svg.style.maxWidth = '100%';
        svg.style.height = 'auto';
        box.appendChild(svg);
    }
    /**
     * Shows a visual in `box` (the card or the panel preview). `done` runs when a drawing or a picture arrives later than this call
     * (the card then measures itself again). The same visual in the same theme is not drawn twice.
     */
    function fillVisual(box, v, limits, label, done) {
        const key = v.kind + '\n' + (v.kind === 'diagram' ? v.source : v.src) + '\n' + MarkViewThemes.signature();
        if (box._vk === key) return;
        box._vk = key;
        box.setAttribute('role', 'img');
        box.setAttribute('aria-label', label);
        box.classList.remove('error');
        if (v.kind === 'diagram') {
            if (vis.cache.has(key)) { placeDiagram(box, vis.cache.get(key), limits); return; }
            box.textContent = '';
            box.appendChild(h('span', { class: 'rm-vis-note' }, 'Drawing…'));
            drawDiagram(key, v.source).then(function (result) {
                if (box._vk !== key) return;
                placeDiagram(box, result, limits);
                if (done) done();
            });
            return;
        }
        const url = imageURL(v.src);
        box.textContent = '';
        if (!url) {
            box.classList.add('error');
            box.appendChild(h('span', { class: 'rm-vis-note' }, 'This image address is not supported'));
            return;
        }
        const img = h('img', { alt: v.alt || label, draggable: 'false' });
        img.style.maxWidth = limits.w + 'px';
        img.style.maxHeight = limits.h + 'px';
        img.addEventListener('load', function () { if (box._vk === key && done) done(); });
        img.addEventListener('error', function () {
            if (box._vk !== key) return;
            box.classList.add('error');
            box.textContent = '';
            box.appendChild(h('span', { class: 'rm-vis-note', title: v.src }, 'This image could not be loaded'));
            if (done) done();
        });
        box.appendChild(img);
        img.src = url;
    }
    function reportError(where, error) {
        try { if (typeof sendToSwift === 'function') sendToSwift('jsError', { where: 'research-map ' + where, message: String(error && error.message || error), source: 'markview-research-map-core.js', lineno: 0, colno: 0, stack: String(error && error.stack || '') }); } catch (_) { /* never throw from the reporter */ }
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

    /** Shows the picture of a node (REQ-017) in the thumbnail of its card; a picture that cannot be loaded leaves no gap. */
    function setThumb(entry, id, address) {
        const url = address ? imageURL(address) : null;
        const key = url || '';
        if (entry.thumb._key === key) return;
        entry.thumb._key = key;
        if (!url) {
            entry.thumb.hidden = true;
            entry.thumb.removeAttribute('src');
            return;
        }
        entry.thumb.hidden = false;
        entry.thumb.onload = function () { A.remeasure(id); };
        entry.thumb.onerror = function () {
            entry.thumb.hidden = true;
            const node = A.nodeById(id);
            entry.lead.hidden = !node || (node.number == null && !node.icon);
            A.remeasure(id);
        };
        entry.thumb.src = url;
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
        resize: null,         // {id, width, height} while a node is being resized with its handles (null is automatic)
        boxes: {},            // sizes sent and not yet confirmed by a snapshot: id -> {width, height}
        pending: {},          // property edits waiting to be sent: id -> {doc, fields, timer}
        els: new Map(),
        collapsed: new Set(), // ids of nodes whose children are folded away (view state, DEC-010)
        selLink: '',          // "from|to" of the selected logical connection (REQ-015), '' for none
        connect: null,        // {from, x, y, target} while an arrow is dragged (REQ-015)
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
    A.rm = rm;

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
})(window.MVResearchMapView = {});
