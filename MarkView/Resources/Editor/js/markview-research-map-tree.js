// Research map, part 3 of 6: the snapshot, the tree (branches, folding), node cards, layout, links, status and web searches.
(function (A) {
    'use strict';
    if (!A.ready) return;   // the page has no editor area, or no layout engine (the first part returned early): nothing to set up
    const {
        BRANCH_COLOURS, CARD_BOX, HANDLES, LIMITS, Layout, MAX_NUMBER, MAX_SCALE, MIN_SCALE, NODE_ICONS, NS,
        PANEL_DEFAULT, PANEL_MAX, PANEL_MIN, SHAPE_FIT, SHAPE_IDS, SHAPE_NAMES, clamp, el, fillVisual, h, icon,
        loadSaved, mix, now, readableOn, reportError, rm, saveSoon, send, setGlyph, setThumb, visualOf
    } = A;
    Object.assign(A, {
        boxOf, branchHex, clearLink, closeQueries, collapseAll, drawLines, expandAll, expandVisual, focusNode,
        hideProblem, nodeById, relayout, remeasure, removeSelectedLink, render, reveal, selectLink, startResize,
        stopTicker, syncVisual, toast, toggleQueries
    });

    // ---- snapshot ----------------------------------------------------------------------------------------------------------
    function nodeById(id) {
        if (!rm.snap || !id) return null;
        return rm.snap.byId.get(id) || null;
    }
    function text(value) { return typeof value === 'string' ? value : (value == null ? '' : String(value)); }
    /** An integer inside [low, high], or null (automatic). */
    function limited(value, range) {
        return typeof value === 'number' && isFinite(value) && Math.floor(value) === value && value >= range[0] && value <= range[1] ? value : null;
    }
    /** Swift's limits for a given width and height replace the page's defaults. */
    function adoptLimits(raw) {
        const pair = function (value, fallback) {
            return Array.isArray(value) && value.length === 2 && value.every(Number.isInteger) && value[0] > 0 && value[0] <= value[1] ? value.slice() : fallback;
        };
        const given = raw && typeof raw === 'object' ? raw : {};
        LIMITS.width = pair(given.width, LIMITS.width);
        LIMITS.height = pair(given.height, LIMITS.height);
    }
    function normalise(raw) {
        const snap = { ok: true, problem: '' };
        if (!raw || typeof raw !== 'object') return { ok: false, problem: 'The map data is missing.' };
        if (raw.ok === false) return { ok: false, problem: text(raw.problem) || 'This file cannot be shown as a research map.' };
        adoptLimits(raw.sizeLimits);
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
                image: text(n.image),
                number: typeof n.number === 'number' && isFinite(n.number) && n.number >= 1 && n.number <= MAX_NUMBER && Math.floor(n.number) === n.number ? n.number : null,
                shape: SHAPE_IDS.indexOf(text(n.shape)) > 0 ? n.shape : '',
                visual: text(n.visual) === 'diagram' || text(n.visual) === 'image' ? n.visual : '',
                width: limited(n.width, LIMITS.width),
                height: limited(n.height, LIMITS.height),
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
        snap.drawKinds = (Array.isArray(raw.drawKinds) ? raw.drawKinds : []).filter(function (k) { return k && typeof k.id === 'string' && k.id; })
            .map(function (k) { return { id: k.id, name: text(k.name) || k.id, hint: text(k.hint) }; });
        snap.languages = (Array.isArray(raw.languages) ? raw.languages : []).filter(function (l) { return l && typeof l.code === 'string' && l.code; })
            .map(function (l) { return { code: l.code, name: text(l.name) || l.code }; });
        snap.shapeNames = {};
        (Array.isArray(raw.shapes) ? raw.shapes : []).forEach(function (s) { if (s && SHAPE_IDS.indexOf(s.id) >= 0) snap.shapeNames[s.id] = text(s.name) || SHAPE_NAMES[s.id]; });
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
        // The same for a size the page has sent (the resize that is still being dragged stays).
        rm.boxes = {};
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
            if (snap.created && snap.byId.has(snap.created)) { reveal(snap.created); A.select(snap.created); A.ensureVisible(snap.created); }
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
        if (!rm.viewReady) A.initialView();
        A.applyView();
        A.applyPanelWidth();
        A.syncSelection();
        A.renderAI();
        A.fillPanel();
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
        A.closeMenu();
        const hidden = hiddenIds();
        if (rm.selected && hidden.has(rm.selected)) { rm.selected = id; A.fillPanel(); }
        refreshTree();
        saveSoon();
    }
    function collapseAll() {
        if (!rm.snap) return;
        const kids = childrenIndex(), rootId = rm.snap.nodes[0].id;
        rm.collapsed = new Set();
        rm.snap.nodes.forEach(function (n) { if (n.id !== rootId && kids.has(n.id)) rm.collapsed.add(n.id); });
        A.closeMenu();
        if (rm.selected && hiddenIds().has(rm.selected)) {
            let cur = nodeById(rm.selected);
            while (cur && hiddenIds().has(cur.id)) cur = nodeById(cur.parent);
            rm.selected = cur ? cur.id : rootId;
            A.fillPanel();
        }
        refreshTree();
        saveSoon();
    }
    function expandAll() {
        if (!rm.collapsed.size) return;
        rm.collapsed = new Set();
        A.closeMenu();
        refreshTree();
        saveSoon();
    }
    /** Focus (REQ-011): the path from the root to the node and the node itself are unfolded, every other node that has children is
     *  folded. So the node's children show one level deep, the siblings along the path stay on the map, and nothing is hidden except
     *  by folding. View state only: the file is not touched. */
    function focusNode(id) {
        if (!rm.snap || !rm.snap.byId.has(id)) return;
        const kids = childrenIndex(), rootId = rm.snap.nodes[0].id, open = new Set();
        for (let cur = nodeById(id), guard = 0; cur && guard++ < 1000; cur = cur.parent ? nodeById(cur.parent) : null) open.add(cur.id);
        rm.collapsed = new Set();
        rm.snap.nodes.forEach(function (n) { if (n.id !== rootId && kids.has(n.id) && !open.has(n.id)) rm.collapsed.add(n.id); });
        A.closeMenu();
        A.select(id);
        refreshTree();
        const p = rm.positions[id];
        if (p) {
            const size = A.viewSize();
            rm.view.x = size.w / 2 - p.x * rm.view.scale;
            rm.view.y = size.h / 2 - p.y * rm.view.scale;
            A.applyView();
        }
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
        A.syncSelection();
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
            syncVisual(entry, n, title);
            // Icon and number badge before the title (REQ-008).
            entry.badge.hidden = n.number == null;
            entry.badge.textContent = n.number == null ? '' : String(n.number);
            setGlyph(entry.glyph, n.icon);
            setThumb(entry, n.id, n.image);
            entry.lead.hidden = n.number == null && !n.icon && entry.thumb.hidden;
            const spoken = (n.number == null ? '' : 'Number ' + n.number + '. ') + (n.icon && NODE_ICONS[n.icon] ? n.icon + ' icon. ' : '') + (n.image ? 'With a picture. ' : '');
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
            if (rm.menu === id) A.closeMenu();
            entry.wrap.remove();
            rm.els.delete(id);
        });
        // Shapes and given sizes, then measure: the layout needs the real sizes, and the labels are in by now.
        rm.sizes = {};
        rm.els.forEach(function (entry, id) {
            if (hidden.has(id)) return;
            const node = nodeById(id);
            if (node) applyBox(entry, node, boxOf(node));
            const w = entry.btn.offsetWidth, hgt = entry.btn.offsetHeight;
            if (w > 0 && hgt > 0) rm.sizes[id] = { w: w, h: hgt };
        });
    }

    // ---- diagram and image nodes on the card ----------------------------------------------------------------------------------------
    function syncVisual(entry, node, title) {
        const v = visualOf(node);
        entry.btn.classList.toggle('is-visual', !!v);
        entry.wrap.classList.toggle('visual', !!v);
        if (!v) {
            entry.vis.hidden = true;
            if (entry.vis._vk) { entry.vis.textContent = ''; entry.vis._vk = ''; }
            entry.btn.removeAttribute('title');
            return;
        }
        entry.vis.hidden = false;
        entry.btn.title = title;
        fillVisual(entry.vis, v, CARD_BOX, title, function () { remeasure(node.id); });
    }
    /** Opens the diagram or picture of a node in the full-screen viewer of the Markdown preview (wheel zoom, drag, Fit, 100%, Esc). */
    function expandVisual(id) {
        const entry = rm.els.get(id), node = nodeById(id), v = visualOf(node);
        if (!entry || !v) return;
        if (typeof openDiagramViewer !== 'function') { toast('The full-screen viewer is not available.'); return; }
        const holder = entry.vis;
        if (v.kind === 'diagram') {
            const svg = holder.querySelector('svg');
            if (svg) openDiagramViewer(svg);
            else toast(holder.classList.contains('error') ? 'This diagram could not be drawn.' : 'The diagram is still being drawn.');
            return;
        }
        const img = holder.querySelector('img');
        if (!img || !img.naturalWidth) { toast('The image is not loaded.'); return; }
        // The viewer shows an SVG: the picture goes into one at its natural size.
        const svg = document.createElementNS(NS, 'svg');
        svg.setAttribute('viewBox', '0 0 ' + img.naturalWidth + ' ' + img.naturalHeight);
        const image = document.createElementNS(NS, 'image');
        image.setAttribute('href', img.currentSrc || img.src);
        image.setAttribute('width', String(img.naturalWidth));
        image.setAttribute('height', String(img.naturalHeight));
        svg.appendChild(image);
        openDiagramViewer(svg);
    }

    // ---- shape and size of a node (REQ-009, DEC-012) ------------------------------------------------------------------------------
    /** The width and height that count now: the resize being dragged, else a size sent and not yet confirmed, else the stored one (null is automatic). */
    function boxOf(node) {
        const live = rm.resize && rm.resize.id === node.id ? rm.resize : rm.boxes[node.id];
        return live ? { width: live.width, height: live.height } : { width: node.width, height: node.height };
    }

    /**
     * Gives a node card its shape and size. A width is exact (the title wraps inside it); a height is a floor (the card
     * is never lower than its title). Ellipse and diamond keep the title in the rectangle inscribed in the shape, so their
     * size is worked out here from the measured title. Sets entry.autoH, the height the card would have with no height given.
     */
    function applyBox(entry, node, box) {
        const wrap = entry.wrap, btn = entry.btn, body = entry.body;
        // A card that shows a diagram or picture is always the rounded rectangle.
        const shape = visualOf(node) ? '' : node.shape, fit = SHAPE_FIT[shape];
        SHAPE_IDS.forEach(function (id) { wrap.classList.toggle('shape-' + id, id !== 'rounded' && id === shape); });
        if (shape === 'diamond' && !entry.shapeSvg) {
            const svg = document.createElementNS(NS, 'svg');
            svg.setAttribute('class', 'rm-shape');
            svg.setAttribute('viewBox', '0 0 100 100');
            svg.setAttribute('preserveAspectRatio', 'none');
            svg.setAttribute('aria-hidden', 'true');
            const polygon = document.createElementNS(NS, 'polygon');
            polygon.setAttribute('points', '50,1 99,50 50,99 1,50');
            svg.appendChild(polygon);
            btn.insertBefore(svg, btn.firstChild);
            entry.shapeSvg = svg;
        } else if (shape !== 'diamond' && entry.shapeSvg) {
            entry.shapeSvg.remove();
            entry.shapeSvg = null;
        }
        const width = box.width, height = box.height;
        wrap.style.width = '';
        btn.style.minHeight = '';
        body.style.maxWidth = '';
        wrap.classList.toggle('has-w', width != null || !!fit);
        btn.classList.toggle('boxed', height != null || !!fit);
        entry.autoH = 0;
        if (!fit) {
            if (width != null) wrap.style.width = width + 'px';
            if (height != null) {
                entry.autoH = btn.offsetHeight;
                btn.style.minHeight = height + 'px';
            }
            return;
        }
        // Ellipse and diamond: measure the title where it wraps (at its own maximum, or inside the given width), then size the shape around it.
        const textMax = width != null ? Math.max(24, Math.round(width * fit.k) - 2 * fit.padX) : fit.maxText;
        wrap.style.width = 'max-content';
        body.style.maxWidth = textMax + 'px';
        const tw = body.offsetWidth, th = body.offsetHeight;
        if (!tw || !th) { wrap.style.width = ''; return; } // not on screen: nothing to measure; the layout estimates
        const autoW = Math.max(fit.minW, Math.ceil(tw / fit.k) + 2 * fit.padX);
        entry.autoH = Math.max(fit.minH, Math.ceil(th / fit.k) + 2 * fit.padY);
        wrap.style.width = (width != null ? width : autoW) + 'px';
        btn.style.minHeight = Math.max(entry.autoH, height || 0) + 'px';
    }

    /** Applies a size that is changing (a drag, a double click) to one node, then lays the map out again. */
    function remeasure(id) {
        const entry = rm.els.get(id), node = nodeById(id);
        if (!entry || !node) return;
        applyBox(entry, node, boxOf(node));
        const w = entry.btn.offsetWidth, hgt = entry.btn.offsetHeight;
        if (w > 0 && hgt > 0) rm.sizes[id] = { w: w, h: hgt };
        relayout();
    }

    /** Dragging a handle resizes the node around its centre (the layout decides where the centre is). One update is sent on release. */
    function startResize(event, id, dir) {
        const entry = rm.els.get(id), node = nodeById(id);
        if (!entry || !node) return;
        event.preventDefault();
        const rect = entry.btn.getBoundingClientRect(), scale = rm.view.scale;
        const start = { x: event.clientX, y: event.clientY, w: rect.width / scale, h: rect.height / scale };
        const before = boxOf(node);
        const horizontal = dir.indexOf('e') >= 0 || dir.indexOf('w') >= 0, vertical = dir.indexOf('n') >= 0 || dir.indexOf('s') >= 0;
        const sx = dir.indexOf('w') >= 0 ? -1 : 1, sy = dir.indexOf('n') >= 0 ? -1 : 1;
        let active = false, cancelled = false;
        try { event.target.setPointerCapture(event.pointerId); } catch (e) { /* a synthetic pointer has no capture */ }
        const onKey = function (e) {
            if (e.key !== 'Escape' || !active) return;
            cancelled = true;
            e.preventDefault();
            finish(null);
        };
        const stop = A.listen(function (e) {
            const dx = e.clientX - start.x, dy = e.clientY - start.y;
            if (!active) {
                if (Math.hypot(dx, dy) <= 3) return;
                active = true;
                A.closeMenu();
            }
            rm.resize = {
                id: id,
                width: horizontal ? clamp(Math.round(start.w + 2 * sx * dx / scale), LIMITS.width[0], LIMITS.width[1]) : before.width,
                height: vertical ? clamp(Math.round(start.h + 2 * sy * dy / scale), LIMITS.height[0], LIMITS.height[1]) : before.height
            };
            remeasure(id);
            const size = rm.sizes[id];
            el.readout.hidden = false;
            el.readout.textContent = size ? 'w ' + Math.round(size.w) + ' · h ' + Math.round(size.h) : '';
        }, function (e) { finish(e); });
        window.addEventListener('keydown', onKey, true);
        function finish(e) {
            stop();
            window.removeEventListener('keydown', onKey, true);
            el.readout.hidden = true;
            if (!active) return;
            rm.lastDragEnd = now();
            const live = rm.resize;
            rm.resize = null;
            if (cancelled || !live || (e && e.type === 'pointercancel')) { remeasure(id); return; }
            const fields = {};
            if (horizontal) fields.width = live.width;
            // A height at or below the height of the title is no height at all.
            if (vertical) fields.height = entry.autoH && live.height <= entry.autoH ? null : live.height;
            rm.boxes[id] = {
                width: horizontal ? fields.width : before.width,
                height: vertical ? fields.height : before.height
            };
            remeasure(id);
            send('update', Object.assign({ id: id }, fields));
        }
    }

    function makeNode(id) {
        const badge = h('span', { class: 'rm-badge', hidden: true });
        const glyph = h('span', { class: 'rm-glyph', hidden: true, 'aria-hidden': 'true' });
        const thumb = h('img', { class: 'rm-thumb', alt: '', hidden: true, draggable: 'false' });
        const lead = h('span', { class: 'rm-lead', hidden: true }, badge, glyph, thumb);
        const label = h('span', { class: 'rm-label' });
        const visual = h('span', { class: 'rm-vis', hidden: true });
        const body = h('span', { class: 'rm-body' }, lead, label, visual);
        const btn = h('button', { class: 'rm-node', type: 'button', 'aria-pressed': 'false' }, body);
        const tri = h('button', { class: 'rm-tri', type: 'button', title: 'Node menu: AI actions, add, connect, arrange, delete', 'aria-haspopup': 'true', 'aria-expanded': 'false' }, '⋯');
        const fold = h('button', { class: 'rm-fold', type: 'button', hidden: true, 'aria-expanded': 'true' });
        // The arrow on the outer edge: dragged onto another node it makes that node a child of this one (REQ-015, DEC-016).
        const arrow = h('button', { class: 'rm-arrow', type: 'button', tabindex: '-1', title: 'Drag onto another node to make it a child of this node', 'aria-label': 'Drag onto another node to make it a child of this node' }, '→');
        // Eight resize handles, shown on the selected node only (REQ-009). A double click on any of them makes the size automatic.
        const handles = HANDLES.map(function (dir) {
            const handle = h('span', { class: 'rm-handle', 'data-h': dir, 'aria-hidden': 'true', hidden: true });
            handle.addEventListener('dblclick', function (event) {
                event.stopPropagation();
                const node = nodeById(id);
                if (!node) return;
                const current = boxOf(node);
                if (current.width == null && current.height == null) return;
                rm.boxes[id] = { width: null, height: null };
                remeasure(id);
                send('update', { id: id, width: null, height: null });
            });
            return handle;
        });
        const wrap = h('div', { class: 'rm-node-wrap', 'data-id': id }, btn, tri, fold, arrow, handles);
        const entry = { wrap: wrap, btn: btn, body: body, tri: tri, fold: fold, arrow: arrow, lead: lead, badge: badge, glyph: glyph, thumb: thumb, label: label, vis: visual, handles: handles, shapeSvg: null, autoH: 0 };
        // A double click on a diagram or picture opens it full screen (REQ-012).
        btn.addEventListener('dblclick', function () {
            const node = nodeById(id);
            if (node && visualOf(node)) expandVisual(id);
        });
        fold.addEventListener('click', function (event) {
            event.stopPropagation();
            toggleFold(id);
        });
        btn.addEventListener('click', function () {
            if (now() - rm.lastDragEnd < 60) return;
            A.select(id);
        });
        tri.addEventListener('click', function (event) {
            event.stopPropagation();
            if (rm.menu === id) A.closeMenu(); else A.openMenu(id);
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
            // The arrow sits on the outer edge: the left one for a node that lies to the left of its parent.
            const own = nodeById(id), parentAt = own && own.parent ? rm.positions[own.parent] : null;
            entry.wrap.classList.toggle('arrow-left', !!parentAt && p.x < parentAt.x - 1);
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
        return path;
    }
    function drawLines() {
        while (el.svg.firstChild) el.svg.removeChild(el.svg.firstChild);
        if (el.linkX && el.linkX.parentNode) el.linkX.parentNode.removeChild(el.linkX);
        const snap = rm.snap;
        snap.nodes.forEach(function (n) {
            const a = rm.positions[n.parent], b = rm.positions[n.id];
            if (a && b) addPath(curve(a, b), n.color || branchOf(n.id), false, 'tree');
        });
        let chosen = null;
        snap.links.forEach(function (l) {
            const a = rm.positions[l.from], b = rm.positions[l.to];
            if (!a || !b) return;
            const picked = rm.selLink === l.from + '|' + l.to;
            const line = addPath(curve(a, b), picked ? 'var(--accent-primary)' : 'var(--rm-muted)', true, 'link');
            if (picked) { line.setAttribute('stroke-width', '2.5'); chosen = { l: l, a: a, b: b }; }
            // A wide invisible line over it, so that a connection is easy to hit with the pointer (REQ-015).
            const hit = addPath(curve(a, b), 'transparent', false, 'link-hit');
            hit.setAttribute('data-from', l.from);
            hit.setAttribute('data-to', l.to);
        });
        if (rm.selLink && !chosen) rm.selLink = '';
        if (chosen) {
            el.linkX = h('button', { class: 'rm-linkx', type: 'button', title: 'Remove this connection', 'aria-label': 'Remove this connection', 'data-from': chosen.l.from, 'data-to': chosen.l.to,
                style: 'left:' + (chosen.a.x + chosen.b.x) / 2 + 'px;top:' + (chosen.a.y + chosen.b.y) / 2 + 'px;',
                onClick: function (event) { event.stopPropagation(); removeSelectedLink(); } }, icon('close'));
            el.world.appendChild(el.linkX);
        }
        if (rm.connect) {
            const from = rm.positions[rm.connect.from];
            if (from) addPath('M ' + from.x + ' ' + from.y + ' L ' + rm.connect.x + ' ' + rm.connect.y, 'var(--accent-primary)', true, 'connect');
        }
    }
    /** Selects a logical connection (REQ-015): the line is highlighted and shows a cross in the middle. */
    function selectLink(from, to) {
        if (rm.selected) A.select('');
        rm.selLink = from + '|' + to;
        A.closeMenu();
        drawLines();
    }
    function clearLink() {
        if (!rm.selLink) return;
        rm.selLink = '';
        drawLines();
    }
    function removeSelectedLink() {
        const parts = rm.selLink.split('|');
        if (parts.length !== 2) return;
        rm.selLink = '';
        send('unlink', { from: parts[0], to: parts[1] });
        drawLines();
    }
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
    function toggleQueries() { if (rm.queriesOpen) closeQueries(); else { A.closeExport(); rm.queriesOpen = true; el.popover.hidden = false; } }
    function closeQueries() { rm.queriesOpen = false; el.popover.hidden = true; }
})(window.MVResearchMapView);
