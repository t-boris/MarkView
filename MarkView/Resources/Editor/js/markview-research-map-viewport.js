// Research map, part 4 of 6: pan and zoom, keyboard and pointer interaction, connecting and moving nodes, the panel divider.
(function (A) {
    'use strict';
    if (!A.ready) return;   // the page has no editor area, or no layout engine (the first part returned early): nothing to set up
    const {
        MAX_SCALE, MIN_SCALE, PANEL_MAX, PANEL_MIN, clamp, clearLink, closeQueries, drawLines, el, nodeById, now,
        queueMove, relayout, removeSelectedLink, rm, saveSoon, selectLink, send, startResize, toast
    } = A;
    Object.assign(A, {
        applyPanelWidth, applyView, centreView, ensureVisible, initialView, listen, viewSize, zoomAtCentre
    });

    // ---- view: pan and zoom --------------------------------------------------------------------------------------------------
    function viewSize() { return { w: el.viewport.clientWidth || 800, h: el.viewport.clientHeight || 600 }; }
    function applyView() {
        el.world.style.transform = 'translate(' + rm.view.x + 'px,' + rm.view.y + 'px) scale(' + rm.view.scale + ')';
        // The resize handles keep their size on the screen at any zoom.
        el.world.style.setProperty('--rm-inv', String(Math.round(100 / rm.view.scale) / 100));
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
        A.closeMenu();
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
        const handle = event.target.closest('.rm-handle');
        if (handle) { startResize(event, handle.parentNode.getAttribute('data-id'), handle.getAttribute('data-h')); return; }
        const arrow = event.target.closest('.rm-arrow');
        if (arrow) { startConnect(event, arrow.parentNode.getAttribute('data-id')); return; }
        const hit = event.target.closest('[data-line="link-hit"]');
        if (hit) { event.preventDefault(); selectLink(hit.getAttribute('data-from'), hit.getAttribute('data-to')); return; }
        if (event.target.closest('.rm-tri, .rm-fold, .rm-actions, .rm-linkx')) return;
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
            A.closeMenu();
            el.viewport.classList.add('is-panning');
            rm.view.x = start.vx + dx;
            rm.view.y = start.vy + dy;
            applyView();
        }, function () {
            stop();
            el.viewport.classList.remove('is-panning');
            if (moved) saveSoon();
            else { A.closeMenu(); closeQueries(); A.select(''); clearLink(); }
        });
    }

    /** Why `from` cannot take `to` as a child (the same rules as `ResearchMap.move`), or '' when it can. */
    function connectProblem(from, to) {
        if (!rm.snap || !nodeById(from) || !nodeById(to)) return 'That node no longer exists.';
        if (to === rm.snap.nodes[0].id) return 'The root node cannot be moved.';
        if (to === from) return 'A node cannot become its own child.';
        for (let cur = nodeById(from), guard = 0; cur && guard < 10000; cur = cur.parent ? nodeById(cur.parent) : null, guard++) {
            if (cur.id === to) return 'A node cannot be moved under one of its own descendants.';
        }
        if (nodeById(to).parent === from) return '\u201c' + nodeById(from).title + '\u201d is already the parent of this node.';
        return '';
    }
    /** Drags a line from the arrow of node `from`; releasing on node B makes B the last child of `from` (REQ-015, DEC-016). */
    function startConnect(event, from) {
        if (!rm.positions[from]) return;
        event.preventDefault();
        A.closeMenu();
        const rect = el.viewport.getBoundingClientRect();
        const world = function (e) { return { x: (e.clientX - rect.left - rm.view.x) / rm.view.scale, y: (e.clientY - rect.top - rm.view.y) / rm.view.scale }; };
        const start = { x: event.clientX, y: event.clientY };
        let active = false, target = '';
        const mark = function (id) {
            if (id === target) return;
            const old = target && rm.els.get(target);
            if (old) old.wrap.classList.remove('connect-ok', 'connect-no');
            target = id;
            const entry = id && rm.els.get(id);
            if (entry) entry.wrap.classList.add(connectProblem(from, id) ? 'connect-no' : 'connect-ok');
        };
        const finish = function () {
            stop();
            window.removeEventListener('keydown', onEsc, true);
            mark('');
            const entry = rm.els.get(from);
            if (entry) entry.wrap.classList.remove('connect-from');
            el.viewport.classList.remove('is-connecting');
            rm.connect = null;
            rm.lastDragEnd = now();
            drawLines();
        };
        const onEsc = function (e) { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(); } };
        window.addEventListener('keydown', onEsc, true);
        const stop = listen(function (e) {
            if (!active) {
                if (Math.hypot(e.clientX - start.x, e.clientY - start.y) <= 3) return;
                active = true;
                el.viewport.classList.add('is-connecting');
                const entry = rm.els.get(from);
                if (entry) entry.wrap.classList.add('connect-from');
            }
            const at = world(e);
            rm.connect = { from: from, x: at.x, y: at.y };
            // The node under the pointer (a touch pointer keeps its first target, so the event target alone is not enough).
            const under = document.elementFromPoint(e.clientX, e.clientY) || e.target;
            const over = under && under.closest ? under.closest('.rm-node-wrap') : null;
            mark(over ? over.getAttribute('data-id') : '');
            drawLines();
        }, function (e) {
            const chosen = e.type === 'pointercancel' ? '' : target;
            const wasActive = active;
            finish();
            if (!wasActive || !chosen) return;
            const problem = connectProblem(from, chosen);
            if (problem) { toast(problem); return; }
            // A folded parent would hide the moved node: show the children.
            rm.collapsed.delete(from);
            saveSoon();
            A.select(chosen);
            send('move', { id: chosen, parent: from });
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
                A.closeMenu();
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
    /** Delete or Backspace removes the selected logical connection, Escape deselects it (REQ-015). */
    document.addEventListener('keydown', function (event) {
        if (!rm.active || rm.dialog || !rm.selLink || event.metaKey || event.ctrlKey || event.altKey || event.defaultPrevented) return;
        const target = event.target;
        if (target && target.closest && target.closest('input, textarea, select, [contenteditable], .rm-divider, .rm-popover, .rm-layouts, .rm-modal')) return;
        if (event.key === 'Delete' || event.key === 'Backspace') { event.preventDefault(); removeSelectedLink(); }
        else if (event.key === 'Escape') { event.preventDefault(); clearLink(); }
    });
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
})(window.MVResearchMapView);
