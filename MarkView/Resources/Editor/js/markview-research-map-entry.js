// Research map, part 6 of 6: entering and leaving the map, the Source/Map switch, the wrappers around the page's own functions and the public window.MVResearchMap API.
(function (A) {
    'use strict';
    if (!A.ready) return;   // the page has no editor area, or no layout engine (the first part returned early): nothing to set up
    const {
        LIMITS, NODE_ICON_IDS, SHAPE_IDS, closeDialog, closeExport, closeMenu, closeQueries, diagramSourceOf, el,
        fillPanel, flushAll, hideProblem, imageOf, isResearchMapText, modeSwitch, render, reportError, rm, saveNow,
        send, stopTicker, syncVisual, toast, withDiagram, withImage
    } = A;
    Object.assign(A, { showView });

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
        rm.resize = null;
        rm.boxes = {};
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
        syncModes();
        watchTheme();
        if (rm.snap) render();
        send('snapshot');
    }
    /** A diagram is drawn in the colours of the theme: when the theme changes the cards and the panel draw it again. */
    function watchTheme() {
        if (rm.themeWatch || typeof MutationObserver === 'undefined') return;
        rm.themeWatch = new MutationObserver(function () {
            if (!rm.active || !rm.snap) return;
            rm.snap.nodes.forEach(function (n) {
                const entry = rm.els.get(n.id);
                if (entry) syncVisual(entry, n, n.title);
            });
            fillPanel();
        });
        rm.themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'data-preset', 'data-accent'] });
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
        syncModes();
    };

    function goSource() {
        window.leaveResearchMap();
        window.switchToSource();
    }

    // ---- Map | View | Source (REQ-010) ---------------------------------------------------------------------------------------------------
    /** The view of a map document that is shown now: 'map', 'view' (ordinary Markdown) or 'source'; null for any other document. */
    function currentView() {
        if (rm.active) return 'map';
        if (!isResearchMapText(DOM.editor.value)) return null;
        if (state.mode === 'preview') return 'view';
        if (state.mode === 'source') return 'source';
        return null;
    }
    const topBar = document.getElementById('wysiwyg-toolbar'), topLabel = document.getElementById('mode-toggle');
    el.topModes = modeSwitch();
    el.topModes.hidden = true;
    if (topBar && topLabel && topLabel.parentNode === topBar) topBar.insertBefore(el.topModes, topLabel);
    let viewLocked = false;
    /** Marks the current view on both switches; a map document has the switch instead of the single mode label in the top bar. */
    function syncModes() {
        const view = currentView();
        [el.modes, el.topModes].forEach(function (group) {
            Array.prototype.forEach.call(group.querySelectorAll('button'), function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-view') === view ? 'true' : 'false'); });
        });
        el.topModes.hidden = view === null;
        if (topLabel) topLabel.style.display = view === null ? '' : 'none';
        // The View of a map shows the file as Markdown but is not edited: the page's converter cannot write a map file back (REQ-010).
        const lock = view === 'view';
        document.body.classList.toggle('rm-view-readonly', lock);
        if (lock && DOM.rendered) { DOM.rendered.contentEditable = 'false'; viewLocked = true; }
        else if (viewLocked && DOM.rendered) { DOM.rendered.contentEditable = 'true'; viewLocked = false; }
    }
    function showView(view) {
        const now = currentView();
        if (now === null || view === now) return;
        if (view === 'map') enterMap();
        else if (view === 'view') { window.leaveResearchMap(); window.switchToPreview(); }
        else goSource();
        syncModes();
    }
    /** The top-bar shortcut for a map document: Map, View, Source, Map. False for any other document. */
    function cycleView() {
        const view = currentView();
        if (view === null) return false;
        showView(view === 'map' ? 'view' : view === 'view' ? 'source' : 'map');
        return true;
    }

    // ---- wrapping the page's entry points ---------------------------------------------------------------------------------------------------
    const originalSetContent = window.setContent;
    window.setContent = function (markdown) {
        const result = typeof originalSetContent === 'function' ? originalSetContent.apply(this, arguments) : undefined;
        try {
            if (isResearchMapText(markdown)) { rm.sourceBase = markdown; enterMap(); }
            else { hideProblem(); window.leaveResearchMap(); }
            syncModes();
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
            const result = original.apply(this, arguments);
            syncModes();
            return result;
        };
    });
    ['switchToSource', 'switchToPreview'].forEach(function (name) {
        const original = window[name];
        if (typeof original !== 'function') return;
        window[name] = function () {
            window.leaveResearchMap();
            const result = original.apply(this, arguments);
            syncModes();
            return result;
        };
    });
    ['toggleModeWrapper', 'toggleMode', 'toggleSourceMode'].forEach(function (name) {
        const original = window[name];
        if (typeof original !== 'function') return;
        window[name] = function () {
            if (cycleView()) return undefined;
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
        iconIDs: function () { return NODE_ICON_IDS.slice(); },
        shapeIDs: function () { return SHAPE_IDS.slice(); },
        sizeLimits: function () { return { width: LIMITS.width.slice(), height: LIMITS.height.slice() }; },
        notice: function (message) { toast(String(message)); },
        collapsed: function () { return Array.from(rm.collapsed); },
        isResearchMapText: isResearchMapText,
        visual: { diagramSourceOf: diagramSourceOf, imageOf: imageOf, withDiagram: withDiagram, withImage: withImage },
        viewState: function () { return { active: rm.active, x: rm.view.x, y: rm.view.y, scale: rm.view.scale, panel: rm.panelWidth, selected: rm.selected, key: rm.mapKey }; }
    };
})(window.MVResearchMapView);
