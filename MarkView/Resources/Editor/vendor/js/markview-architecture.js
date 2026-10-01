        // ============================================================================
        // Architecture tab — Cytoscape.js + ELK (vendor/js, loaded on first use).
        //
        // Swift pushes the whole state with showArchitecture(payload) (see
        // ArchitectureStore.payloadJSON). Views: modules | deployment | docs. Nodes nest
        // through `parent`; double-clicking a node expands it in place (drawn as a
        // container) and every file-level edge is lifted to the nearest node that is
        // currently drawn, so connections to the rest of the system stay visible.
        // Overlays colour the Modules view by documentation coverage or by a change
        // (branch, uncommitted work or GitHub PR) and its AI review.
        // ============================================================================
        (function() {
            const container = document.getElementById('arch-container');
            if (!container) return;

            const el = {
                graph: document.getElementById('arch-graph'),
                details: document.getElementById('arch-details'),
                crumbs: document.getElementById('arch-crumbs'),
                status: document.getElementById('arch-status'),
                legend: document.getElementById('arch-legend'),
                views: container.querySelectorAll('[data-arch-view]'),
                overlay: document.getElementById('arch-overlay'),
                flagged: document.getElementById('arch-flagged'),
                hide: document.getElementById('arch-hide'),
                prSource: document.getElementById('arch-pr-source'),
                prOpen: document.getElementById('arch-pr-open'),
                analyzePR: document.getElementById('arch-analyze-pr'),
                prNumber: document.getElementById('arch-pr-number'),
                review: document.getElementById('arch-review'),
                analyze: document.getElementById('arch-analyze'),
                rescan: document.getElementById('arch-rescan'),
                fit: document.getElementById('arch-fit'),
                progress: document.getElementById('arch-progress'),
                detailsResizer: document.getElementById('arch-details-resizer'),
                tempFilter: document.getElementById('arch-temp-filter'),
                detailsToggle: document.getElementById('arch-details-toggle'),
                stop: document.getElementById('arch-stop'),
                empty: document.getElementById('arch-empty'),
                deploy: document.getElementById('arch-deploy'),
                deployPicker: document.getElementById('arch-deploy-picker'),
            };

            const ui = {
                payload: null,
                view: 'logical',
                overlay: 'none',
                onlyFlagged: false,
                hidden: new Set(),
                ratingRequested: new Set(),   // parents whose children were sent for AI importance
                describeRequested: new Set(),
                expanded: { logical: new Set(), modules: new Set(), deployment: new Set(), docs: new Set(), pr: new Set() },
                focus: { logical: null, modules: null, deployment: null, docs: null, pr: null },
                prView: null,       // the PR X-Ray's own view, built from the X-Ray and the change
                selected: null,
                graphKey: null,     // view + snapshot version the canvas was built from
                viewChosen: false,  // the user picked a view (no automatic fallback to Structure)
                root: null,         // root folder of the X-Ray shown (project or one of its folders)
                progress: null,     // live analysis progress (setArchitectureProgress)
                operations: null,   // project-root operations only; folder X-Rays receive none
                operationQuery: '', operationsShowAll: false, operationSearchFocused: false,
            };
            let cy = null;
            let libs = null;

            function post(action, fields) {
                // A file opened while a change is shown opens on that change (viewer's "Pull request" lens).
                if (action === 'openFile' && ui.payload && ui.payload.pr && (ui.view === 'pr' || ui.overlay === 'pr')) {
                    fields = Object.assign({ fromPR: true }, fields || {});
                }
                try {
                    window.webkit.messageHandlers.bridge.postMessage({ type: 'arch', payload: Object.assign({ action: action }, fields || {}) });
                } catch (e) { console.log('[arch] post failed', action, e); }
            }

            function loadScript(src) {
                return new Promise(function(resolve, reject) {
                    const s = document.createElement('script');
                    s.src = src;
                    s.onload = resolve;
                    s.onerror = function() { reject(new Error(src + ' failed to load')); };
                    document.head.appendChild(s);
                });
            }

            function loadLibraries() {
                if (libs) return libs;
                libs = loadScript('vendor/js/cytoscape.min.js')
                    .then(function() { return loadScript('vendor/js/elk.bundled.js'); })
                    .then(function() { return loadScript('vendor/js/cytoscape-elk.js'); })
                    .then(function() { cytoscape.use(cytoscapeElk); })
                    .catch(function(error) { libs = null; throw error; });
                return libs;
            }

            const isDark = function() { return document.documentElement.getAttribute('data-theme') === 'dark'; };
            function palette() {
                return isDark()
                    ? { bg: '#17191c', node: '#23272c', box: '#7d97ff', boxAlpha: 0.07, boxLine: '#353b44', line: '#3a4049',
                        text: '#e3e6e9', mute: '#8d949e', accent: '#7d97ff', ok: '#4cc38a', warn: '#e2ab4a', bad: '#f07a73',
                        info: '#6cb6ff', dim: 0.28 }
                    : { bg: '#fbfbfa', node: '#ffffff', box: '#2b54d9', boxAlpha: 0.045, boxLine: '#d4d8de', line: '#c3c8cf',
                        text: '#1b1e23', mute: '#6b717b', accent: '#2b54d9', ok: '#23845a', warn: '#b77a12', bad: '#c2413b',
                        info: '#2f7fd1', dim: 0.3 };
            }
            // With no overlay, boxes are coloured by the role the AI gave them (legend below).
            const roleNames = { ui: 'UI', api: 'API', domain: 'Domain logic', data: 'Data', infra: 'Infrastructure',
                integration: 'Integration', tooling: 'Tooling', tests: 'Tests', docs: 'Docs', config: 'Config',
                shared: 'Shared', app: 'App' };
            const roleColor = { ui: '#6c8cff', api: '#b07cff', domain: '#2fa37a', data: '#d9822b', infra: '#8a94a6',
                integration: '#b98ad6', tooling: '#8a94a6', tests: '#a0a7b1', docs: '#4aa3c4', config: '#a0a7b1',
                shared: '#5bb3a8', app: '#6c8cff' };

            // ------------------------------------------------------------------ model

            function currentView() {
                const snap = ui.payload && ui.payload.snapshot;
                if (!snap) return null;
                if (ui.view === 'pr') return ui.prView;
                return snap.views.find(function(v) { return v.id === ui.view; }) || null;
            }

            /** Links the change adds or removes, as edges between the given view's file ids. */
            function prDependencyEdges(prefix) {
                const pr = ui.payload && ui.payload.pr;
                return ((pr && pr.dependencies) || []).map(function(d) {
                    return { source: prefix + d.source, target: prefix + d.target, kind: d.change, weight: 1, label: d.change === 'added' ? 'new' : 'removed' };
                });
            }

            /** The PR X-Ray: only the parts of the structure the change touches — its files
             *  inside their components and subsystems — with existing links between them and
             *  the links the change adds (green) or removes (red, dashed). A file is the leaf:
             *  what changed inside it is shown when it is opened (the viewer's Pull request lens). */
            function buildPRView(snap, pr) {
                if (!snap || !pr) return null;
                const logical = snap.views.find(function(v) { return v.id === 'logical'; });
                const base = logical || snap.views.find(function(v) { return v.id === 'modules'; });
                if (!base) return null;
                const prefix = logical ? 'l:f:' : 'm:';
                const byId = new Map(base.nodes.map(function(n) { return [n.id, n]; }));
                const keep = new Set();
                const changed = new Set(pr.files.map(function(f) { return prefix + f.path; }));
                (pr.dependencies || []).forEach(function(d) { changed.add(prefix + d.target); });
                changed.forEach(function(id) {
                    for (let n = byId.get(id); n && !keep.has(n.id); n = n.parent != null ? byId.get(n.parent) : null) keep.add(n.id);
                });
                // Files the change adds are not in the X-Ray yet: draw them in their folder's component.
                const extra = [];
                if (logical) {
                    const assigned = function(path) {
                        for (let folder = path.split('/').slice(0, -1).join('/'); ; folder = folder.split('/').slice(0, -1).join('/')) {
                            const a = (snap.overrides || {})[folder] || ((snap.assignments || {})[folder] || {}).component;
                            if (a) return a;
                            if (!folder) return null;
                        }
                    };
                    pr.files.forEach(function(f) {
                        const id = prefix + f.path;
                        if (byId.has(id)) return;
                        const comp = assigned(f.path);
                        const parent = comp && byId.has('l:c:' + comp) ? 'l:c:' + comp : 'l:';
                        extra.push({ id: id, parent: parent, kind: 'file', name: f.path.split('/').pop(), path: f.path,
                                     loc: f.deleted ? f.deletions : f.additions, files: 1,
                                     summary: f.deleted ? 'Removed in this change' : 'New in this change' });
                        for (let n = byId.get(parent); n && !keep.has(n.id); n = n.parent != null ? byId.get(n.parent) : null) keep.add(n.id);
                        keep.add(id);
                    });
                }
                const nodes = base.nodes.filter(function(n) { return keep.has(n.id); }).concat(extra);
                const edges = base.edges.filter(function(e) { return keep.has(e.source) && keep.has(e.target) && changed.has(e.source) && changed.has(e.target); })
                    .concat(prDependencyEdges(prefix).filter(function(e) { return keep.has(e.source) && keep.has(e.target); }));
                return { id: 'pr', nodes: nodes, edges: edges };
            }

            function indexView(view) {
                const byId = new Map(), children = new Map();
                view.nodes.forEach(function(n) { byId.set(n.id, n); });
                view.nodes.forEach(function(n) {
                    const p = n.parent;
                    if (p != null && byId.has(p)) {
                        if (!children.has(p)) children.set(p, []);
                        children.get(p).push(n.id);
                    }
                });
                return { byId: byId, children: children };
            }

            /** Roots of kind "root" are never drawn; their children form the top level. */
            function isTransparent(node) { return node && node.kind === 'root' && node.parent == null; }

            /** Drawn node that stands in for `id`: walk down from the top while expanded. */
            function representative(id, idx, expanded) {
                const path = [];
                let cur = idx.byId.get(id);
                while (cur) { path.unshift(cur); cur = cur.parent != null ? idx.byId.get(cur.parent) : null; }
                for (let i = 0; i < path.length; i++) {
                    const n = path[i];
                    if (isTransparent(n)) continue;
                    if (!expanded.has(n.id) || !(idx.children.get(n.id) || []).length) return n.id;
                }
                return path.length ? path[path.length - 1].id : null;
            }

            function drawnNodes(idx, expanded) {
                const drawn = [];
                function visit(id) {
                    const node = idx.byId.get(id);
                    const kids = idx.children.get(id) || [];
                    if (isTransparent(node)) { kids.forEach(visit); return; }
                    drawn.push(node);
                    if (expanded.has(id)) kids.forEach(visit);
                }
                idx.byId.forEach(function(n) { if (n.parent == null || !idx.byId.has(n.parent)) visit(n.id); });
                return drawn;
            }

            function descendantsFiles(id, idx, out) {
                const kids = idx.children.get(id) || [];
                // A file (or a Book chapter) is a leaf here: its contents and changes are drawn
                // under it but belong to it.
                const node = idx.byId.get(id);
                if (!kids.length || (node && (node.kind === 'file' || node.kind === 'doc'))) { out.push(id); return out; }
                kids.forEach(function(k) { descendantsFiles(k, idx, out); });
                return out;
            }

            // --------------------------------------------------------------- overlays

            /** Metrics, coverage and changes are keyed by the Structure-view id of a file. */
            function fileKey(node) { return node && node.path != null ? 'm:' + node.path : null; }
            const codeViews = { modules: 1, logical: 1, pr: 1 };
            /** The Book view: the documents as parts, chapters and sections. */
            function isBook() { return ui.view === 'docs'; }
            const bookKinds = { root: 'book', dir: 'part', doc: 'chapter', entity: 'item' };
            function kindLabel(node) {
                if (isBook() && bookKinds[node.kind]) return bookKinds[node.kind];
                return node.kind === 'moduleRef' ? 'module' : node.kind;
            }
            /** The first sentence of a summary, cut to `max` characters, for a node label. */
            function firstSentence(text, max) {
                const m = /^[\s\S]*?[.!?](?=\s|$)/.exec(text || '');
                let out = (m ? m[0] : text || '').replace(/\s+/g, ' ').trim();
                if (out.length > max) out = out.slice(0, max - 1).replace(/\s+\S*$/, '') + '…';
                return out;
            }
            /** Chapters the AI has not annotated yet (their texts are the documents' first paragraphs). */
            function undescribedChapters(view) {
                return view.nodes.filter(function(n) { return n.kind === 'doc' && !n.summarySignature; });
            }
            /** The Book's texts for documents drawn in other views: chapter by path, section by
             *  path and start line (the Logical view's local outline lists the same headings). */
            function bookIndex() {
                const snap = ui.payload && ui.payload.snapshot;
                if (!snap) return null;
                if (ui.bookIndexFor === snap) return ui.bookIndex;
                const book = snap.views.find(function(v) { return v.id === 'docs'; });
                const index = { chapters: new Map(), sections: new Map() };
                (book ? book.nodes : []).forEach(function(n) {
                    if (n.kind === 'doc' && n.path) index.chapters.set(n.path, n);
                    else if (n.kind === 'section' && n.path && n.line) index.sections.set(n.path + ':' + n.line, n);
                });
                ui.bookIndexFor = snap; ui.bookIndex = index;
                return index;
            }
            /** The text drawn under a node's name: its own description, else what the Book says
             *  about the document or section it stands for. Whole, so a box tells what the thing
             *  is; cut only when very long. */
            function nodeDescription(node) {
                if (!node || node.kind === 'change' || node.kind === 'changePart') return null;
                const book = bookText(node);
                const text = node.summary || (book && book.summary);
                if (!text) return null;
                let out = String(text).replace(/\s+/g, ' ').trim();
                if (out.length > 240) out = out.slice(0, 239).replace(/\s+\S*$/, '') + '…';
                return out || null;
            }
            /** What the Book says about a node of another view: a document's chapter, or the
             *  section an outline item stands for. */
            function bookText(node) {
                if (isBook() || !node || !node.path) return null;
                const index = bookIndex(); if (!index) return null;
                if (node.kind === 'file' || node.kind === 'doc') return index.chapters.get(node.path) || null;
                if (node.kind === 'entity' && node.line) return index.sections.get(node.path + ':' + node.line) || null;
                return null;
            }
            function overlayApplies() {
                if (ui.overlay === 'none') return false;
                // The ⚡ search also marks deployment nodes.
                if (ui.view === 'deployment') return isSearch(currentFilter());
                if (codeViews[ui.view]) return true;
                return ui.view === 'docs' && (isAIFilter() || ui.overlay === 'size' || ui.overlay === 'freshness');
            }

            // AI filters: Importance (built in) and the user's own criteria.
            const IMPORTANCE = { id: 'importance', name: 'Importance', levels: ['critical', 'high', 'normal', 'low'] };
            function aiFilters() { return [IMPORTANCE].concat((ui.payload && ui.payload.filters) || []); }
            function isAIFilter() { return ui.overlay.indexOf('ai:') === 0; }
            function currentFilter() {
                if (!isAIFilter()) return null;
                const id = ui.overlay.slice(3);
                return aiFilters().find(function(f) { return f.id === id; }) || null;
            }
            /** 0 = weakest … levels-1 = strongest. */
            function levelRank(filter, level) { const i = filter.levels.indexOf(level); return i < 0 ? -1 : filter.levels.length - 1 - i; }
            /** The ⚡ quick filter is a search: only what matters is marked, in red. */
            function isSearch(filter) { return !!filter && filter.id.indexOf('tmp-') === 0; }
            function levelColor(filter, rank, c) {
                if (rank < 0) return null;
                const top = filter.levels.length - 1;
                if (isSearch(filter)) return rank === top ? '#e5484d' : null;
                // Weakest → strongest along one ramp; the weakest relevance ("none") stays uncoloured.
                if (filter.id === 'importance') return [c.mute, c.info, c.warn, c.bad][rank];
                if (rank === 0) return null;
                // Relevance: cold → hot in distinct hues (cyan, amber, magenta), spread over the levels.
                const hot = ['#3fb8d0', '#e2a93b', '#e0457b'];
                return hot[Math.round((rank - 1) / Math.max(1, top - 1) * (hot.length - 1))];
            }

            // ------------------------------------------------------------ colour scales

            function rgb(hex) {
                const h = hex.replace('#', '');
                return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
            }
            /** Colour between `a` and `b` (hex) at `t` ∈ [0, 1]. */
            function mix(a, b, t) {
                const x = rgb(a), y = rgb(b);
                return '#' + x.map(function(v, i) {
                    return Math.round(v + (y[i] - v) * Math.max(0, Math.min(1, t))).toString(16).padStart(2, '0');
                }).join('');
            }

            /** Numeric overlays: colour runs smoothly through `stops` ([value, label, colour]). */
            function scales(c) {
                return {
                    complexity: { title: 'Most complex function (McCabe)', note: 'A folder shows its worst file',
                                  stops: [[1, '1', c.ok], [10, '10', c.ok], [15, '15', c.warn], [25, '25+', c.bad]] },
                    bugs: { title: 'Bug-fix commits in the worst file', note: 'From git history',
                            stops: [[0, '0', c.ok], [1, '1', c.ok], [3, '3', c.warn], [8, '8+', c.bad]] },
                    tests: { title: 'Tested share of source files', note: 'Line coverage when a report exists',
                             stops: [[0, '0%', c.bad], [35, '35%', c.warn], [70, '70%', c.ok], [100, '100%', c.ok]] },
                    coverage: { title: 'Documented share', note: 'Docs older than the code count half',
                                stops: [[0, '0%', c.bad], [35, '35%', c.warn], [70, '70%', c.ok], [100, '100%', c.ok]] },
                    freshness: { title: 'Last change', note: 'Newest file in a folder',
                                 stops: [[0, 'today', c.accent], [30, '1 mo', c.info], [180, '6 mo', c.ok], [730, '2 y', c.warn], [1460, '4 y+', c.mute]] },
                };
            }
            function scaleColor(scale, value) {
                const st = scale.stops;
                if (value <= st[0][0]) return st[0][2];
                for (let i = 0; i < st.length - 1; i++) {
                    if (value <= st[i + 1][0]) return mix(st[i][2], st[i + 1][2], (value - st[i][0]) / (st[i + 1][0] - st[i][0]));
                }
                return st[st.length - 1][2];
            }

            /** Effective tags of a node: its own, or the nearest ancestor's. */
            function tagsOf(node, idx) {
                let cur = node;
                while (cur) { if (cur.tags && cur.tags.length) return cur.tags; cur = cur.parent != null ? idx.byId.get(cur.parent) : null; }
                return [];
            }
            function isHidden(node, idx) {
                if (!ui.hidden.size || node.kind === 'root') return false;
                if (tagsOf(node, idx).some(function(t) { return ui.hidden.has(t); })) return true;
                // A container whose files are all hidden goes too (no empty "Tests" box).
                const kids = idx.children.get(node.id) || [];
                if (!kids.length) return false;
                const files = descendantsFiles(node.id, idx, []).map(function(id) { return idx.byId.get(id); })
                    .filter(function(n) { return n && (n.kind === 'file' || n.kind === 'doc'); });
                return files.length > 0 && files.every(function(f) { return tagsOf(f, idx).some(function(t) { return ui.hidden.has(t); }); });
            }

            // Importance is rated by the AI (ArchitectureStore.rateImportance) and stored
            // per path, component or document section.

            function importanceKey(node) {
                if (!node) return null;
                if (node.kind === 'component') return 'c:' + node.id.replace(/^l:c:/, '');
                if (node.kind === 'section') return node.id;
                // A file's contents are not rated on their own.
                if (['collection', 'group', 'entity', 'change', 'changePart'].indexOf(node.kind) >= 0) return null;
                if (node.path != null && node.kind !== 'root') return 'p:' + node.path;
                return null;
            }
            /** The Book with no overlay chosen is coloured by importance all the same: the AI's
             *  rating of a chapter or section (written while annotating), a container by the
             *  strongest rating inside it. Null when nothing below is rated. */
            function bookImportance(node, idx) {
                if (!isBook() || ui.overlay !== 'none' || !node) return null;
                const table = ((ui.payload.snapshot && ui.payload.snapshot.ratings) || {}).importance || {};
                function own(n) { const key = importanceKey(n); const r = key ? table[key] : null; return r ? levelRank(IMPORTANCE, r.level) : -1; }
                let best = own(node);
                if (best < 0) {
                    (function walk(id) {
                        (idx.children.get(id) || []).forEach(function(k) {
                            const r = own(idx.byId.get(k)); if (r > best) best = r;
                            if (best < IMPORTANCE.levels.length - 1) walk(k);
                        });
                    })(node.id);
                }
                return best < 0 ? null : best;
            }
            function bookColor(rank, c) { return rank == null ? null : [c.mute, c.info, c.warn, c.bad][rank]; }

            function ratingOf(node) {
                const filter = currentFilter(); if (!filter) return null;
                const all = (ui.payload.snapshot && ui.payload.snapshot.ratings) || {};
                const table = all[filter.id] || {};
                if (ui.view === 'deployment' && node) {
                    // A deployment node the AI named, or one running code that matters.
                    if (node.kind !== 'moduleRef') return table['dep:' + node.id.replace(/^p:/, '')] || null;
                    const base = node.path || '';
                    const hit = Object.keys(table).find(function(k) {
                        return k.indexOf('p:') === 0 && table[k].level === 'strong' && (k === 'p:' + base || k.indexOf('p:' + base + '/') === 0);
                    });
                    return hit ? { level: 'strong', reason: 'Runs ' + hit.slice(2), provisional: !!table[hit].provisional } : null;
                }
                const key = importanceKey(node);
                return key ? table[key] : null;
            }
            /** Ask the AI to rate the children of every drawn container that has none rated yet. */
            function requestRatings(idx, drawn) {
                const filter = currentFilter(); if (!filter) return;
                // Topic filters are searched over the whole project at once (keywords, then the
                // AI's check); only Importance is rated per container as you zoom in.
                if (filter.id !== 'importance') {
                    const all = (ui.payload.snapshot && ui.payload.snapshot.ratings) || {};
                    const key = 'search|' + filter.id;
                    if (!all[filter.id] && !ui.ratingRequested.has(key)) { ui.ratingRequested.add(key); post('filterSearch', { filter: filter.id }); }
                    return;
                }
                const parents = new Set();
                drawn.forEach(function(n) { if (n.parent != null) parents.add(n.parent); });
                parents.forEach(function(parentId) {
                    const key = filter.id + '|' + ui.view + '|' + parentId;
                    if (ui.ratingRequested.has(key)) return;
                    const kids = (idx.children.get(parentId) || []).map(function(id) { return idx.byId.get(id); })
                        .filter(function(n) { return n && importanceKey(n); });
                    if (!kids.length || kids.every(function(n) { return ratingOf(n); })) return;
                    ui.ratingRequested.add(key);
                    post('rateImportance', { view: ui.view, parent: parentId, filter: filter.id });
                });
            }

            function prByNode() {
                const pr = ui.payload && ui.payload.pr;
                const map = new Map();
                if (!pr) return map;
                pr.files.forEach(function(f) { map.set('m:' + f.path, f); });
                return map;
            }

            const verdictRank = { bug: 3, concern: 2, ok: 1 };

            // Absolute, explainable scales. A folder takes the colour of its worst file.
            const COMPLEXITY = { moderate: 11, complex: 21 };   // McCabe: 1–10 simple, 11–20 moderate, >20 complex
            const FIXES = { some: 2, many: 5 };                  // bug-fix commits touching a file

            /** Overlay facts for a drawn node (aggregated over its files). */
            function overlayInfo(node, idx) {
                if (!overlayApplies()) return null;
                // Contents and changes inside a file show the file's colour.
                if (['collection', 'group', 'entity', 'change', 'changePart'].indexOf(node.kind) >= 0) {
                    let file = node;
                    while (file && file.kind !== 'file' && file.kind !== 'doc') file = file.parent != null ? idx.byId.get(file.parent) : null;
                    if (file) node = file;
                }
                const filter = currentFilter();
                if (filter) {
                    // Own rating, else the strongest rating found below (containers show their strongest part).
                    const own = ratingOf(node);
                    if (own) return { kind: 'ai', filter: filter, level: levelRank(filter, own.level), label: own.level, reason: own.reason, provisional: !!own.provisional };
                    let best = -1, label = null, provisional = false;
                    (function walk(id) {
                        (idx.children.get(id) || []).forEach(function(k) {
                            const r = ratingOf(idx.byId.get(k));
                            if (r && levelRank(filter, r.level) > best) { best = levelRank(filter, r.level); label = r.level; provisional = !!r.provisional; }
                            walk(k);
                        });
                    })(node.id);
                    return { kind: 'ai', filter: filter, level: best, label: label, inherited: best >= 0, provisional: provisional };
                }
                // Metrics are keyed by file path ("m:<path>"): code files, and in the Docs
                // view documents (a section counts as its document).
                const leaves = descendantsFiles(node.id, idx, []).map(function(id) { return idx.byId.get(id); })
                    .filter(function(n) { return n && (n.kind === 'file' || n.kind === 'doc' || n.kind === 'section'); });
                const files = Array.from(new Set(leaves.map(fileKey)));
                // Complexity, tests and documentation coverage are about code, not notes.
                const codeFiles = Array.from(new Set(leaves.filter(function(n) { return n.kind === 'file' && n.language !== 'markdown'; }).map(fileKey)));
                if (ui.overlay === 'coverage') {
                    const cov = (ui.payload.snapshot && ui.payload.snapshot.coverage) || {};
                    let fresh = 0, stale = 0, none = 0;
                    codeFiles.forEach(function(id) {
                        const c = cov[id]; const s = c ? c.status : 'none';
                        if (s === 'fresh') fresh++; else if (s === 'stale') stale++; else none++;
                    });
                    const total = fresh + stale + none;
                    return { kind: 'coverage', fresh: fresh, stale: stale, none: none, total: total,
                             ratio: total ? (fresh + stale) / total : 0 };
                }
                if (ui.overlay === 'pr') {
                    const pr = prByNode();
                    let changed = 0, adds = 0, dels = 0, worst = 0, unreviewed = 0, findings = 0;
                    files.forEach(function(id) {
                        const f = pr.get(id); if (!f) return;
                        changed++; adds += f.additions; dels += f.deletions;
                        findings += (f.findings || []).length;
                        if (f.verdict) worst = Math.max(worst, verdictRank[f.verdict] || 0); else unreviewed++;
                    });
                    return { kind: 'pr', changed: changed, adds: adds, dels: dels, worst: worst, unreviewed: unreviewed, findings: findings };
                }
                const metrics = (ui.payload.snapshot && ui.payload.snapshot.metrics) || {};
                const list = files.map(function(id) { return metrics[id]; }).filter(Boolean);
                const codeList = codeFiles.map(function(id) { return metrics[id]; }).filter(Boolean);
                if (ui.overlay === 'tests') {
                    const sources = codeList.filter(function(m) { return !m.isTest; });
                    const tested = sources.filter(function(m) { return m.tested; }).length;
                    const withCoverage = sources.filter(function(m) { return m.lineCoverage != null; });
                    const lines = withCoverage.reduce(function(a, m) { return a + m.loc; }, 0);
                    const covered = withCoverage.reduce(function(a, m) { return a + m.loc * m.lineCoverage; }, 0);
                    return { kind: 'tests', sources: sources.length, tested: tested,
                             tests: codeList.length - sources.length,
                             lineCoverage: lines ? covered / lines : null,
                             ratio: sources.length ? tested / sources.length : 0 };
                }
                if (ui.overlay === 'bugs') {
                    const fixes = list.reduce(function(a, m) { return a + m.bugfixes; }, 0);
                    const commits = list.reduce(function(a, m) { return a + m.commits; }, 0);
                    let worst = 0, worstFile = null;
                    files.forEach(function(id) { const m = metrics[id]; if (m && m.bugfixes > worst) { worst = m.bugfixes; worstFile = id; } });
                    return { kind: 'bugs', fixes: fixes, commits: commits, files: list.length, worst: worst,
                             worstName: worstFile ? worstFile.split('/').pop() : null };
                }
                if (ui.overlay === 'freshness') {
                    const ages = list.map(function(m) { return m.lastChanged; }).filter(function(t) { return t > 0; })
                        .sort(function(a, b) { return a - b; });
                    if (!ages.length) return { kind: 'freshness', files: 0 };
                    const now = Date.now() / 1000, halfYear = 182 * 86400;
                    return { kind: 'freshness', files: ages.length,
                             newest: ages[ages.length - 1], median: ages[Math.floor(ages.length / 2)],
                             recentShare: ages.filter(function(t) { return now - t < halfYear; }).length / ages.length };
                }
                if (ui.overlay === 'complexity' || ui.overlay === 'size') {
                    let worst = 0, worstName = null, complexFns = 0, fns = 0;
                    const measured = ui.overlay === 'complexity' ? codeList : list;
                    measured.forEach(function(m) {
                        fns += m.functions || 0;
                        complexFns += m.complexFunctions || 0;
                        if ((m.maxFunctionComplexity || 0) > worst) { worst = m.maxFunctionComplexity; worstName = m.maxFunctionName; }
                    });
                    const loc = measured.reduce(function(a, m) { return a + m.loc; }, 0);
                    return { kind: ui.overlay, worst: worst, worstName: worstName, complexFns: complexFns,
                             functions: fns, loc: loc, files: measured.length };
                }
                return null;
            }

            /** The value a numeric overlay is coloured by, or null when it does not apply. */
            function overlayValue(info) {
                if (!info) return null;
                if (info.kind === 'tests') return info.sources ? 100 * (info.lineCoverage != null ? info.lineCoverage : info.ratio) : null;
                if (info.kind === 'bugs') return info.files ? info.worst : null;
                if (info.kind === 'complexity') return info.files ? info.worst : null;
                if (info.kind === 'freshness') return info.files ? (Date.now() / 1000 - info.newest) / 86400 : null;
                if (info.kind === 'coverage') return info.total ? 100 * (info.fresh + 0.5 * info.stale) / info.total : null;
                return null;
            }

            /** "Only flagged": what deserves attention under the current overlay. */
            function overlayFlag(info) {
                if (!info) return false;
                if (info.kind === 'ai') return isSearch(info.filter) ? info.level === info.filter.levels.length - 1
                                                                     : info.level >= info.filter.levels.length - 2;
                if (info.kind === 'pr') return info.worst >= 2;
                const v = overlayValue(info);
                if (v == null) return false;
                if (info.kind === 'complexity') return v >= COMPLEXITY.moderate;
                if (info.kind === 'bugs') return v >= FIXES.some;
                if (info.kind === 'freshness') return v >= 183;
                return v < 70;   // tests, documentation
            }

            function overlayColor(info, c) {
                if (!info) return null;
                if (info.kind === 'tests' && !info.sources) return info.tests ? c.info : null;
                if (info.kind === 'size') return null;
                if (info.kind === 'ai') return levelColor(info.filter, info.level, c);
                const scale = scales(c)[info.kind];
                if (scale) { const v = overlayValue(info); return v == null ? null : scaleColor(scale, v); }
                if (info.kind === 'pr') {
                    if (!info.changed) return null;
                    if (info.worst === 3) return c.bad;
                    if (info.worst === 2) return c.warn;
                    if (info.worst === 1 && !info.unreviewed) return c.ok;
                    return c.info;
                }
                return null;
            }

            // ----------------------------------------------------------------- render

            function ago(unix) {
                const days = Math.max(0, Math.round((Date.now() / 1000 - unix) / 86400));
                if (days < 1) return 'today';
                if (days < 45) return days + (days === 1 ? ' day ago' : ' days ago');
                if (days < 540) return Math.round(days / 30) + ' months ago';
                return (days / 365).toFixed(1).replace('.0', '') + ' years ago';
            }

            function formatCount(n) { return n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1) + 'k' : String(n); }

            /** Risk the PR analysis gave a component (PR X-Ray only). */
            function prImpact(node) {
                const a = ui.view === 'pr' && ui.payload.pr && ui.payload.pr.analysis;
                if (!a || node.kind !== 'component') return null;
                const id = node.id.replace(/^l:c:/, '');
                return a.impact.find(function(i) { return i.component === id; }) || null;
            }

            /** `isBox`: an opened container — its title sits above its children and stays short. */
            function nodeLabel(node, info, isBox) {
                // Long names (dated notes, generated files) are cut; the details panel has them whole.
                let label = node.name || node.id;
                if (label.length > 40) label = label.slice(0, 38) + '…';
                // Every described box says what it is, under its name: a component's purpose, a
                // folder's or file's AI description, a chapter's or section's annotation. Documents
                // and their sections drawn in other views borrow the Book's texts.
                const book = bookText(node);
                if (book && node.kind === 'file' && book.name && book.name !== node.name && book.name + '.md' !== node.name) {
                    label += '\n' + (book.name.length > 60 ? book.name.slice(0, 58) + '…' : book.name);
                }
                const described = isBox ? null : nodeDescription(node);
                if (described) label += '\n' + described;
                const impact = prImpact(node);
                if (impact) label += '\nrisk: ' + impact.risk;
                const meta = [];
                if (node.kind === 'change') {
                    meta.push((node.change ? node.change + ' · ' : '') + (node.endLine && node.endLine !== node.line
                        ? 'lines ' + node.line + '–' + node.endLine : 'line ' + node.line));
                } else if (node.kind === 'changePart') {
                    meta.push(node.files + (node.files === 1 ? ' change' : ' changes'));
                } else if (node.kind === 'collection' || node.kind === 'group') {
                    if (node.files) meta.push(formatCount(node.files) + (node.files === 1 ? ' item' : ' items'));
                } else if (node.kind !== 'file' && node.kind !== 'doc' && node.kind !== 'entity' && node.files) {
                    meta.push(formatCount(node.files) + (isBook() && node.kind !== 'section' ? ' chapters' : ' files'));
                }
                if (node.loc && !(isBook() && node.kind === 'section')) meta.push(formatCount(node.loc) + ' lines');
                if (node.tech) meta.push(node.tech);
                if (info && info.kind === 'coverage' && info.total > 1) {
                    meta.push(Math.round(info.ratio * 100) + '% documented' + (info.stale ? ' · ' + info.stale + ' outdated' : ''));
                }
                // Line counts are the file's; parts and changes inside it do not repeat them.
                const inside = ['collection', 'group', 'entity', 'change', 'changePart'].indexOf(node.kind) >= 0;
                if (info && info.kind === 'pr' && info.changed && !inside) meta.push('+' + info.adds + ' −' + info.dels);
                if (info && info.kind === 'tests' && info.sources) {
                    meta.push(info.lineCoverage != null ? Math.round(info.lineCoverage * 100) + '% lines covered'
                                                        : info.tested + '/' + info.sources + ' tested');
                }
                if (info && info.kind === 'bugs' && info.files) {
                    meta.push(node.kind === 'file' ? info.fixes + ' bug-fix commits of ' + info.commits
                        : info.fixes ? 'worst: ' + info.worstName + ' (' + info.worst + ' fixes)' : 'no bug fixes');
                }
                if (info && info.kind === 'freshness' && info.files) meta.push('changed ' + ago(info.newest));
                if (info && info.kind === 'ai' && info.label) meta.push((info.inherited ? 'contains ' : '') + info.label);
                if (info && info.kind === 'complexity' && info.files) {
                    meta.push('max ' + info.worst + (info.worstName ? ' in ' + info.worstName : '')
                        + (node.kind !== 'file' && info.complexFns ? ' · ' + info.complexFns + ' complex fns' : ''));
                }
                if (meta.length) label += '\n' + meta.join(' · ');
                return label;
            }

            /** Median lines of code among drawn nodes — the unit size for the Size overlay. */
            function sizeBase(drawn) {
                const locs = drawn.map(function(n) { return n.loc || 0; }).filter(function(v) { return v > 0; }).sort(function(a, b) { return a - b; });
                return locs.length ? locs[Math.floor(locs.length / 2)] : 1;
            }

            function buildElements() {
                const view = currentView();
                if (!view) return [];
                const idx = indexView(view);
                const expanded = ui.expanded[ui.view];
                const drawn = drawnNodes(idx, expanded).filter(function(n) { return !isHidden(n, idx); });
                requestRatings(idx, drawn);
                const drawnIds = new Set(drawn.map(function(n) { return n.id; }));
                const c = palette();
                const elements = [];
                drawn.forEach(function(node) {
                    const kids = idx.children.get(node.id) || [];
                    const isBox = expanded.has(node.id) && kids.length > 0;
                    const info = overlayInfo(node, idx);
                    const label = nodeLabel(node, info, isBox);
                    const longest = label.split('\n').reduce(function(m, l) { return Math.max(m, l.length); }, 0);
                    // Size overlay: area grows with lines of code.
                    const grow = ui.overlay === 'size' && overlayApplies() && node.loc
                        ? Math.min(3.2, Math.max(1, Math.sqrt(node.loc / Math.max(1, sizeBase(drawn))))) : 1;
                    const parent = node.parent != null && drawnIds.has(node.parent) && expanded.has(node.parent) ? node.parent : undefined;
                    // A described box is set in smaller type so its whole text fits: wider, and as
                    // tall as the wrapped lines.
                    const described = !isBox && !!nodeDescription(node);
                    const perChar = described ? 5.4 : 6.6;
                    const w = Math.min(described ? 340 : 260, Math.max(70, longest * perChar + 22)) * grow;
                    const rows = label.split('\n').reduce(function(a, l) { return a + Math.max(1, Math.ceil((l.length * perChar) / Math.max(40, w - 24))); }, 0);
                    elements.push({ group: 'nodes', data: {
                        id: node.id, parent: parent, label: label, kind: node.kind,
                        w: w, tw: Math.max(40, w - 14),
                        h: (rows > 2 ? 12 + (described ? 11 : 12) * rows : rows > 1 ? 38 : 26) * grow,
                        fill: (prImpact(node) ? { high: c.bad, medium: c.warn, low: c.ok }[prImpact(node).risk] : null)
                            || overlayColor(info, c) || bookColor(bookImportance(node, idx), c) || (node.role ? roleColor[node.role] : null) || '',
                        dimmed: ui.overlay === 'pr' && info && !info.changed ? 1 : 0,
                        // Keyword match not yet confirmed by the AI: drawn dashed.
                        provisional: info && info.kind === 'ai' && info.provisional && info.level > 0 ? 1 : 0,
                        // "Only flagged": the top two levels of an AI filter, else anything not green/neutral.
                        flag: overlayFlag(info) ? 1 : 0,
                        expandable: kids.length && !isBox ? 1 : 0,
                    }, classes: [node.kind, isBox ? 'box' : 'leaf', kids.length && !isBox ? 'expandable' : '', described ? 'described' : ''].join(' ') });
                });
                const agg = new Map();
                const prEdges = ui.view !== 'pr' && overlayApplies() && ui.overlay === 'pr'
                    ? prDependencyEdges(ui.view === 'logical' ? 'l:f:' : 'm:') : [];
                view.edges.concat(prEdges).forEach(function(e) {
                    if (!idx.byId.has(e.source) || !idx.byId.has(e.target)) return;
                    const s = representative(e.source, idx, expanded), t = representative(e.target, idx, expanded);
                    if (!s || !t || s === t || !drawnIds.has(s) || !drawnIds.has(t)) return;
                    const key = s + '→' + t + (e.kind === 'added' || e.kind === 'removed' ? '|' + e.kind : '');
                    const cur = agg.get(key);
                    if (cur) { cur.weight += e.weight || 1; }
                    else agg.set(key, { id: 'e:' + key, source: s, target: t, weight: e.weight || 1, label: e.label || '', kind: e.kind });
                });
                agg.forEach(function(e) { elements.push({ group: 'edges', data: e }); });
                if (ui.onlyFlagged && overlayApplies() && ui.overlay !== 'size') return keepFlagged(elements, c);
                return elements;
            }

            /** "Only flagged": drop leaves the overlay leaves neutral or green, then empty containers. */
            function keepFlagged(elements, c) {
                const nodes = elements.filter(function(e) { return e.group === 'nodes'; });
                const flagged = new Set(nodes.filter(function(e) {
                    return e.classes.indexOf('box') < 0 && e.data.flag === 1;
                }).map(function(e) { return e.data.id; }));
                const parentOf = new Map(nodes.map(function(e) { return [e.data.id, e.data.parent]; }));
                const keep = new Set(flagged);
                flagged.forEach(function(id) { let p = parentOf.get(id); while (p) { keep.add(p); p = parentOf.get(p); } });
                return elements.filter(function(e) {
                    return e.group === 'nodes' ? keep.has(e.data.id) : keep.has(e.data.source) && keep.has(e.data.target);
                });
            }

            function stylesheet() {
                const c = palette();
                return [
                    { selector: 'node', style: {
                        'shape': 'round-rectangle', 'width': 'data(w)', 'height': 'data(h)',
                        'background-color': c.node, 'border-width': 1, 'border-color': c.line,
                        'label': 'data(label)', 'color': c.text, 'font-size': 10.5,
                        'font-family': '-apple-system, "SF Pro Text", sans-serif',
                        'text-valign': 'center', 'text-halign': 'center', 'text-wrap': 'wrap', 'text-max-width': 'data(tw)',
                        'line-height': 1.3 } },
                    { selector: 'node[fill != ""]', style: { 'border-color': 'data(fill)', 'border-width': 2,
                        'background-color': 'data(fill)', 'background-opacity': 0.14 } },
                    { selector: 'node.expandable', style: { 'border-style': 'solid', 'border-width': 1.5 } },
                    { selector: 'node.file, node.doc', style: { 'font-size': 10, 'font-family': '"SF Mono", Menlo, monospace' } },
                    { selector: 'node.section', style: { 'font-size': 10, 'border-style': 'dotted' } },
                    // Contents of a file: collection → type → item.
                    { selector: 'node.collection', style: { 'font-weight': 600, 'border-style': 'double', 'border-width': 3 } },
                    { selector: 'node.group', style: { 'font-size': 10, 'border-style': 'solid' } },
                    { selector: 'node.entity', style: { 'font-size': 9.5, 'border-style': 'dotted', 'text-max-width': 200 } },
                    // Boxes that carry their description: smaller type, so the whole text is read in place.
                    { selector: 'node.described', style: { 'font-size': 8.5, 'line-height': 1.2, 'text-max-width': 'data(tw)' } },
                    // What changed inside a file (PR X-Ray).
                    { selector: 'node.changePart', style: { 'font-size': 10, 'border-style': 'solid' } },
                    { selector: 'node.change', style: { 'font-size': 9.5, 'border-color': '#d29922', 'border-width': 1.5, 'text-max-width': 220 } },
                    { selector: 'node.external, node.externalGroup', style: { 'border-style': 'dashed', 'color': c.mute } },
                    { selector: 'node.moduleRef', style: { 'border-style': 'dotted' } },
                    { selector: 'node.box', style: {
                        'shape': 'round-rectangle', 'background-color': c.box, 'background-opacity': c.boxAlpha,
                        'border-color': c.boxLine, 'border-width': 1, 'text-valign': 'top', 'text-halign': 'center',
                        'text-margin-y': -4, 'font-weight': 600, 'padding': 14, 'color': c.mute } },
                    // Containers keep a light fill; the overlay colour goes on the outline.
                    { selector: 'node.box[fill != ""]', style: { 'background-color': c.box, 'background-opacity': c.boxAlpha, 'border-color': 'data(fill)', 'border-width': 2 } },
                    { selector: 'node[dimmed = 1]', style: { 'opacity': c.dim } },
                    // Replace Cytoscape's default selection fill (solid blue) with an accent outline.
                    { selector: 'node:selected', style: { 'border-color': c.accent, 'border-width': 2.5, 'background-color': c.node, 'background-opacity': 1 } },
                    { selector: 'node.box:selected', style: { 'background-color': c.box, 'background-opacity': c.boxAlpha, 'border-color': c.accent } },
                    { selector: 'node[fill != ""]:selected', style: { 'background-color': 'data(fill)', 'background-opacity': 0.2 } },
                    { selector: 'node:active, edge:active', style: { 'overlay-opacity': 0 } },
                    { selector: 'edge', style: {
                        'width': 'mapData(weight, 1, 20, 1, 3.5)', 'line-color': c.line, 'target-arrow-color': c.line,
                        'target-arrow-shape': 'triangle', 'arrow-scale': 0.7, 'curve-style': 'bezier', 'opacity': 0.85 } },
                    { selector: 'edge[label != ""]', style: { 'label': 'data(label)', 'font-size': 9, 'color': c.mute,
                        'text-background-color': c.bg, 'text-background-opacity': 1, 'text-background-padding': 2 } },
                    { selector: 'edge.faded', style: { 'opacity': 0.12 } },
                    { selector: 'node.appearing', style: { 'opacity': 0 } },
                    // Links a pull request adds (green) or removes (red, dashed).
                    { selector: 'edge[kind = "added"]', style: { 'line-color': c.ok, 'target-arrow-color': c.ok, 'width': 2.5, 'opacity': 1 } },
                    { selector: 'edge[kind = "removed"]', style: { 'line-color': c.bad, 'target-arrow-color': c.bad, 'width': 2.5, 'line-style': 'dashed', 'opacity': 1 } },
                    { selector: 'node[provisional = 1]', style: { 'border-style': 'dashed' } },
                    // Related sections the AI found in the Book: dashed, muted, their reason in the panel.
                    { selector: 'edge[kind = "related"]', style: { 'line-style': 'dashed', 'line-color': c.mute, 'target-arrow-color': c.mute, 'label': '', 'opacity': 0.7 } },
                    { selector: 'edge.hot', style: { 'line-color': c.accent, 'target-arrow-color': c.accent, 'opacity': 1 } },
                ];
            }

            /** Lay the graph out; `fitTo` zooms to that node afterwards, `keepView` leaves pan and zoom alone. */
            function layout(fitTo, keepView) {
                if (!cy) return;
                const count = cy.nodes().length;
                // Every box is laid out on its own: children with few links between them (a
                // notes folder, a list of files) are packed into a rectangle instead of one tall
                // column; linked ones follow the flow of their links. The top level is packed to
                // the window's shape. More than `flowLimit` children are packed even when linked:
                // a flow of dozens of files that reference one another spreads them over a huge
                // area (BUG-012: MarkView/Models, 73 files, filled 2% of its box; packed, 61%).
                const flowLimit = 20;
                function sparse(children) {
                    if (children.length > flowLimit) return true;
                    const ids = new Set(children.map(function(n) { return n.id(); }));
                    const links = children.connectedEdges().filter(function(e) { return ids.has(e.source().id()) && ids.has(e.target().id()); }).length;
                    return links < 0.25 * children.length;
                }
                const topSparse = sparse(cy.nodes().orphans());
                const packed = function(ratio) {
                    return { 'elk.algorithm': 'rectpacking', 'elk.aspectRatio': String(ratio), 'elk.spacing.nodeNode': 14,
                             'elk.padding': '[top=30,left=14,bottom=14,right=14]' };
                };
                const layered = {
                    'elk.algorithm': 'layered', 'elk.direction': 'RIGHT',
                    'elk.layered.spacing.nodeNodeBetweenLayers': 46, 'elk.spacing.nodeNode': 18,
                    'elk.padding': '[top=30,left=14,bottom=14,right=14]',
                    'elk.layered.crossingMinimization.strategy': 'LAYER_SWEEP',
                    // Keep document order (sections, files) where edges allow it.
                    'elk.layered.considerModelOrder.strategy': 'NODES_AND_EDGES',
                };
                cy.layout({
                    name: 'elk', fit: !fitTo && !keepView, padding: 28, animate: count < 200, animationDuration: 420,
                    nodeDimensionsIncludeLabels: false,
                    elk: Object.assign({ 'elk.hierarchyHandling': 'SEPARATE_CHILDREN' },
                        topSparse ? packed(Math.max(0.5, cy.width() / Math.max(1, cy.height()))) : layered),
                    nodeLayoutOptions: function(node) {
                        if (!node.isParent()) return {};
                        return sparse(node.children()) ? packed(1.6) : layered;
                    },
                    stop: function() {
                        cy.nodes('.appearing').animate({ style: { opacity: 1 } }, { duration: 350, complete: function() {
                            cy.nodes('.appearing').removeClass('appearing').removeStyle('opacity');
                        } });
                        if (fitTo) {
                            const target = cy.getElementById(fitTo);
                            if (target.length) cy.animate({ fit: { eles: target.union(target.descendants()).union(target.neighborhood()), padding: 40 }, duration: 260 });
                        }
                    },
                }).run();
            }

            /** Message over the canvas when the chosen view does not exist yet. */
            function renderEmpty() {
                const snap = ui.payload && ui.payload.snapshot;
                if (ui.view === 'pr') {
                    el.empty.hidden = !!ui.prView;
                    el.empty.textContent = !snap ? 'The X-Ray is still being built…' : 'Choose a pull request, your branch or your uncommitted changes above.';
                    return;
                }
                const missing = snap && !snap.views.some(function(v) { return v.id === ui.view; });
                const bookView = isBook() && !missing && currentView();
                if (bookView && !bookView.nodes.some(function(n) { return n.kind === 'doc'; })) {
                    el.empty.hidden = false;
                    el.empty.textContent = 'No text documents in this folder.';
                    return;
                }
                el.empty.hidden = !missing;
                if (!missing) return;
                const step = { logical: 2, deployment: 3 }[ui.view];
                const name = { logical: 'Logical components', deployment: 'The deployment map', docs: 'The book' }[ui.view] || 'This view';
                const p = ui.progress;
                el.empty.textContent = p && step
                    ? name + ' will appear after step ' + step + ' of ' + p.steps + (p.step < step ? '.' : ' (running now).')
                        + ' Structure and the Book are available meanwhile.'
                    : step ? name + ' is built by the AI analysis. Press Analyze to create it.'
                    : name + ' is empty. Press Rescan.';
            }

            function render(fitTo) {
                renderEmpty();
                if (!cy) return;
                // Keep where boxes were, so a redraw moves them instead of starting over;
                // new boxes appear at their parent and fade in.
                const previous = {};
                cy.nodes().forEach(function(n) { if (!n.isParent()) previous[n.id()] = Object.assign({}, n.position()); });
                const hadNodes = Object.keys(previous).length > 0;
                cy.startBatch();
                cy.elements().remove();
                cy.add(buildElements());
                if (hadNodes) {
                    cy.nodes().forEach(function(n) {
                        if (n.isParent()) return;
                        let at = previous[n.id()];
                        for (let p = n.parent(); !at && p.length; p = p.parent()) at = previous[p.id()];
                        if (at) n.position(at);
                        if (!previous[n.id()]) n.addClass('appearing');
                    });
                }
                cy.style(stylesheet());
                cy.endBatch();
                if (ui.selected && cy.getElementById(ui.selected).length) cy.getElementById(ui.selected).select();
                layout(fitTo);
                renderCrumbs();
                renderLegend();
                renderDetails();
            }

            function restyle() {
                // Overlay, ratings or theme changed: update labels and colours. Positions are
                // kept unless a box changed size — then lay out again so nothing overlaps.
                if (!cy) return;
                const fresh = new Map(buildElements().filter(function(e) { return e.group === 'nodes'; })
                    .map(function(e) { return [e.data.id, e.data]; }));
                let resized = false;
                cy.batch(function() {
                    cy.nodes().forEach(function(n) {
                        const d = fresh.get(n.id());
                        if (!d) return;
                        if (n.data('w') !== d.w || n.data('h') !== d.h) resized = true;
                        n.data({ label: d.label, fill: d.fill, dimmed: d.dimmed, w: d.w, h: d.h });
                    });
                    cy.style(stylesheet());
                });
                if (resized) layout(null, true);
                renderLegend();
                renderDetails();
            }

            function ensureCy() {
                if (cy) return;
                cy = cytoscape({ container: el.graph, elements: [], style: stylesheet(), wheelSensitivity: 0.25,
                                 minZoom: 0.05, maxZoom: 3, boxSelectionEnabled: false });
                cy.on('tap', 'node', function(evt) {
                    ui.selectedEdge = null;
                    ui.selected = evt.target.id();
                    highlightNeighbourhood(evt.target);
                    renderDetails();
                    // In the PR X-Ray a click on a file opens it (on its change when it has one).
                    if (ui.view === 'pr') {
                        const node = ui.prView && ui.prView.nodes.find(function(n) { return n.id === evt.target.id(); });
                        if (node && node.path && (node.kind === 'file' || node.kind === 'doc')) openPRFile(node.path);
                    }
                });
                // An arrow: why the link exists (the AI reads the code behind it).
                cy.on('tap', 'edge', function(evt) {
                    const e = evt.target;
                    ui.selected = null;
                    ui.selectedEdge = { view: ui.view, source: e.data('source'), target: e.data('target'),
                                        kind: e.data('kind') || 'uses', label: e.data('label') || '' };
                    cy.edges().removeClass('faded hot'); cy.edges().not(e).addClass('faded'); e.addClass('hot');
                    renderDetails();
                    if (ui.selectedEdge.kind !== 'related') post('explainEdge', { view: ui.view, source: ui.selectedEdge.source, target: ui.selectedEdge.target,
                                          kind: ui.selectedEdge.kind, label: ui.selectedEdge.label || undefined });
                });
                cy.on('tap', function(evt) {
                    if (evt.target === cy) { ui.selected = null; ui.selectedEdge = null; highlightNeighbourhood(null); renderDetails(); }
                });
                cy.on('dbltap', 'node', function(evt) { activate(evt.target.id()); });
            }

            function highlightNeighbourhood(node) {
                cy.edges().removeClass('faded hot');
                if (!node) return;
                const connected = node.union(node.descendants()).connectedEdges();
                cy.edges().not(connected).addClass('faded');
                connected.addClass('hot');
            }

            /** Double-click: expand/collapse containers, open files and documents. */
            /** While the analysis builds the Logical view, open the subsystems that have parts,
             *  so the structure is seen growing — until the user opens or closes something. */
            function autoExpand(snap) {
                // The Book: every part open, so all chapter blurbs are on one screen (top-level
                // parts only for a big book); chapters stay closed until opened.
                if (isBook()) {
                    if (ui.userNavigated) return;
                    const book = snap.views.find(function(v) { return v.id === 'docs'; });
                    if (!book) return;
                    const chapters = book.nodes.filter(function(n) { return n.kind === 'doc'; }).length;
                    const parts = book.nodes.filter(function(n) { return n.kind === 'dir'; });
                    (chapters <= 60 ? parts : parts.filter(function(n) { return n.parent === 'd:'; }))
                        .forEach(function(n) { ui.expanded.docs.add(n.id); });
                    return;
                }
                if (!ui.progress || ui.progress.steps < 2 || ui.view !== 'logical' || ui.userNavigated) return;
                const view = snap.views.find(function(v) { return v.id === 'logical'; });
                if (!view) return;
                const idx = indexView(view);
                (snap.components || []).forEach(function(c) {
                    if (c.parent) return;
                    const kids = (idx.children.get('l:c:' + c.id) || []).map(function(k) { return idx.byId.get(k); });
                    const parts = kids.filter(function(k) { return k && k.kind === 'component'; }).length;
                    if (parts && kids.length - parts <= 40) ui.expanded.logical.add('l:c:' + c.id);
                });
            }

            function activate(id) {
                ui.userNavigated = true;
                const view = currentView(); if (!view) return;
                const idx = indexView(view);
                const node = idx.byId.get(id); if (!node) return;
                const kids = idx.children.get(id) || [];
                const expanded = ui.expanded[ui.view];
                if (kids.length) {
                    if (expanded.has(id)) collapse(id, idx); else { expanded.add(id); ui.focus[ui.view] = id; }
                    ui.selected = id;
                    render(expanded.has(id) ? id : null);
                } else if (node.kind === 'section') {
                    post('openFile', sectionTarget(node));
                } else if (node.kind === 'entity') {
                    post('openFile', entityTarget(node));
                } else if (node.path && (node.kind === 'file' || node.kind === 'doc' || node.kind === 'moduleRef')) {
                    post('openFile', { path: node.path });
                }
            }

            /** Open a file from the PR X-Ray: a changed one at its first change, in the change's
             *  own version (removed files as they were), any other one as it is. */
            function openPRFile(path) {
                const pr = ui.payload && ui.payload.pr;
                const f = pr && pr.files.find(function(x) { return x.path === path; });
                const first = f && !f.deleted && f.ranges && f.ranges[0];
                post('openFile', first ? { path: path, line: first[0], endLine: first[1] } : { path: path });
            }

            /** Where a Book section starts: its line, and its heading to find in a preview. */
            function sectionTarget(node) {
                const target = { path: node.path, find: node.anchor || node.name };
                if (node.line) target.line = node.line;
                return target;
            }

            /** Where an item of a file's contents is: its line (code) and its text (markdown). */
            function entityTarget(node) {
                const target = { path: node.path };
                if (node.line) target.line = node.line;
                if (node.anchor) target.find = node.anchor;
                return target;
            }

            function collapse(id, idx) {
                ui.userNavigated = true;
                const expanded = ui.expanded[ui.view];
                (function walk(n) { expanded.delete(n); (idx.children.get(n) || []).forEach(walk); })(id);
                const node = idx.byId.get(id);
                ui.focus[ui.view] = node && node.parent != null && expanded.has(node.parent) ? node.parent : null;
            }

            // ---------------------------------------------------------------- chrome

            function renderCrumbs() {
                const view = currentView();
                el.crumbs.textContent = '';
                if (!view) return;
                const idx = indexView(view);
                const chain = [];
                let cur = ui.focus[ui.view] ? idx.byId.get(ui.focus[ui.view]) : null;
                while (cur) { if (!isTransparent(cur)) chain.unshift(cur); cur = cur.parent != null ? idx.byId.get(cur.parent) : null; }
                const top = document.createElement('button');
                top.className = 'arch-crumb';
                top.textContent = ({ logical: 'Logical', modules: 'Modules', deployment: 'Deployment', docs: 'Book', pr: 'Pull request' })[ui.view];
                // The top level: the details panel goes back to the view's overview (the PR panel
                // in the PR X-Ray) — nothing stays selected.
                top.onclick = function() {
                    ui.expanded[ui.view].clear(); ui.focus[ui.view] = null;
                    ui.selected = null; ui.selectedEdge = null;
                    if (cy) { cy.elements().unselect(); highlightNeighbourhood(null); }
                    render();
                };
                el.crumbs.appendChild(top);
                chain.forEach(function(node) {
                    const sep = document.createElement('span'); sep.className = 'arch-sep'; sep.textContent = '›';
                    el.crumbs.appendChild(sep);
                    const b = document.createElement('button'); b.className = 'arch-crumb'; b.textContent = node.name;
                    b.onclick = function() {
                        // Keep this level expanded, collapse everything below it.
                        (idx.children.get(node.id) || []).forEach(function(k) { collapse(k, idx); });
                        ui.focus[ui.view] = node.id; ui.selected = node.id; ui.selectedEdge = null;
                        if (cy) cy.elements().unselect();
                        render(node.id);
                    };
                    el.crumbs.appendChild(b);
                });
            }

            /** A gradient scale in the legend: title, then value labels joined by colour ramps. */
            function scaleLegend(scale) {
                const wrap = document.createElement('span'); wrap.className = 'arch-scale';
                const title = document.createElement('b'); title.textContent = scale.title; wrap.appendChild(title);
                scale.stops.forEach(function(stop, i) {
                    const label = document.createElement('em'); label.textContent = stop[1]; wrap.appendChild(label);
                    const next = scale.stops[i + 1];
                    if (!next) return;
                    const seg = document.createElement('i'); seg.className = 'arch-scale-seg';
                    seg.style.background = 'linear-gradient(to right, ' + stop[2] + ', ' + next[2] + ')';
                    wrap.appendChild(seg);
                });
                return wrap;
            }

            function renderLegend() {
                const c = palette();
                el.legend.textContent = '';
                const scale = overlayApplies() && scales(c)[ui.overlay];
                const filter = overlayApplies() && currentFilter();
                if (scale) {
                    el.legend.appendChild(scaleLegend(scale));
                } else if (isSearch(filter)) {
                    // Search: one colour — what matters; everything else uncoloured.
                    const title = document.createElement('span'); title.innerHTML = '<b></b>';
                    title.firstChild.textContent = filter.name + ' — AI search';
                    el.legend.appendChild(title);
                    const found = document.createElement('span');
                    const dot = document.createElement('i'); dot.style.background = levelColor(filter, filter.levels.length - 1, c);
                    found.appendChild(dot); found.appendChild(document.createTextNode('Matters for it'));
                    el.legend.appendChild(found);
                    const summary = (ui.payload.searchSummaries || {})[filter.id];
                    if (summary) {
                        const s = document.createElement('span'); s.className = 'arch-search-summary';
                        s.textContent = summary; s.title = summary;
                        el.legend.appendChild(s);
                    }
                } else if (filter) {
                    // AI levels, weakest → strongest, on their ramp.
                    const ramp = filter.levels.slice().reverse().map(function(level) {
                        return [levelRank(filter, level), level, levelColor(filter, levelRank(filter, level), c) || c.line];
                    });
                    el.legend.appendChild(scaleLegend({ title: filter.id === 'importance' ? 'Importance (AI)' : filter.name + ' — relevance (AI)', stops: ramp }));
                }
                const note = scale ? scale.note
                    : filter && filter.id === 'importance' ? 'Rated by AI as you zoom in; a folder shows its strongest part'
                    : isSearch(filter) ? (ui.payload.status ? 'Dashed = keyword candidate while the AI reads the project' : 'Uncoloured = not related; a folder is red when something inside matters')
                    : filter ? 'Dashed = keyword match, solid = checked by AI; a folder shows its strongest part' : null;
                // The Book without an overlay: colour = importance from the AI's annotations.
                if (!scale && !filter && isBook() && cy && currentView()) {
                    const idx = indexView(currentView());
                    const rated = cy.nodes().some(function(n) { return bookImportance(idx.byId.get(n.id()), idx) != null; });
                    if (rated) {
                        const ramp = IMPORTANCE.levels.slice().reverse().map(function(level) {
                            const rank = levelRank(IMPORTANCE, level); return [rank, level, bookColor(rank, c)];
                        });
                        el.legend.appendChild(scaleLegend({ title: 'Importance (AI)', stops: ramp }));
                    } else {
                        const span = document.createElement('span'); span.className = 'arch-muted';
                        span.textContent = 'Colours come with Analyze: chapters and sections are rated by importance.';
                        el.legend.appendChild(span);
                    }
                }
                // The Book: links written in the text, and related sections the AI found.
                if (!scale && !filter && isBook() && cy && cy.edges('[kind = "related"]').length) {
                    const span = document.createElement('span'); span.className = 'arch-muted';
                    span.textContent = 'Solid = link in the text · dashed = related (AI)';
                    el.legend.appendChild(span);
                }
                // No overlay: the colours are roles; list the ones on screen.
                if (!scale && !filter && !(overlayApplies() && ui.overlay !== 'none') && cy) {
                    const present = new Set(cy.nodes().map(function(n) {
                        const node = currentView() && indexView(currentView()).byId.get(n.id());
                        return node && node.role && roleColor[node.role] ? node.role : null;
                    }).filter(Boolean));
                    if (present.size) {
                        const title = document.createElement('span'); title.innerHTML = '<b>Colour = role (AI)</b>';
                        el.legend.appendChild(title);
                        Object.keys(roleNames).filter(function(r) { return present.has(r); }).forEach(function(r) {
                            const span = document.createElement('span');
                            const dot = document.createElement('i'); dot.style.background = roleColor[r];
                            span.appendChild(dot); span.appendChild(document.createTextNode(roleNames[r]));
                            el.legend.appendChild(span);
                        });
                    }
                }
                const items = note ? [[null, note]]
                    : overlayApplies() && ui.overlay === 'pr'
                    ? [[c.ok, 'Looks correct'], [c.warn, 'Concerns'], [c.bad, 'Likely bug'], [c.info, 'Changed, not reviewed']]
                    : overlayApplies() && ui.overlay === 'size'
                    ? [[c.line, 'Box area grows with lines of code']]
                    : [];
                if (overlayApplies() && ui.overlay === 'tests') items.push([c.info, 'Test code']);
                const report = ui.payload.snapshot && ui.payload.snapshot.coverageReport;
                if (ui.overlay === 'tests' && report) items.push([null, 'Line coverage from ' + report]);
                items.forEach(function(item) {
                    const span = document.createElement('span');
                    if (item[0]) { const dot = document.createElement('i'); dot.style.background = item[0]; span.appendChild(dot); }
                    span.appendChild(document.createTextNode(item[1]));
                    el.legend.appendChild(span);
                });
                const hint = document.createElement('span');
                hint.className = 'arch-hint';
                hint.textContent = 'Double-click to zoom in or open';
                el.legend.appendChild(hint);
            }

            function addRow(parent, label, value) {
                if (value == null || value === '') return;
                const row = document.createElement('div'); row.className = 'arch-row';
                const k = document.createElement('span'); k.textContent = label;
                const v = document.createElement('span'); v.textContent = value;
                row.appendChild(k); row.appendChild(v); parent.appendChild(row);
            }

            function linkButton(text, onClick, cls) {
                const b = document.createElement('button');
                b.className = 'arch-link' + (cls ? ' ' + cls : '');
                b.textContent = text; b.onclick = onClick;
                return b;
            }

            function visibleOperations() {
                return ui.operations && Array.isArray(ui.operations.operations) ? ui.operations.operations : [];
            }

            function operationState(operation) {
                return (ui.operations && ui.operations.states || {})[operation.id] || {};
            }

            function isOperationRunning(operation) {
                return ['running', 'cancelling'].indexOf(operationState(operation).state) >= 0;
            }

            function renderDeployButton() {
                const operations = visibleOperations().filter(function(o) { return o.kind === 'deploy'; });
                el.deploy.hidden = !operations.length;
                el.deploy.disabled = !!(ui.operations && ui.operations.readOnly);
                el.deployPicker.hidden = true;
                if (!operations.length) return;
                const running = operations.some(isOperationRunning);
                const singleState = operations.length === 1 ? operationState(operations[0]).state : null;
                el.deploy.textContent = running ? 'Deploy · Running'
                    : singleState ? 'Deploy · ' + singleState[0].toUpperCase() + singleState.slice(1) : 'Deploy';
                el.deployPicker.textContent = '';
                const placeholder = document.createElement('option');
                placeholder.textContent = 'Choose deployment…'; placeholder.value = '';
                el.deployPicker.appendChild(placeholder);
                const unnamed = operations.filter(function(o) { return !(o.environment || '').trim(); });
                const groups = [];
                operations.forEach(function(o) {
                    const name = (o.environment || '').trim();
                    if (name && !groups.some(function(g) { return g.toLowerCase() === name.toLowerCase(); })) groups.push(name);
                });
                function option(parent, o) {
                    const item = document.createElement('option');
                    item.value = o.id;
                    item.disabled = !!((ui.operations.unavailable || {})[o.id]) && !isOperationRunning(o);
                    const outcome = operationState(o).state;
                    item.textContent = (outcome ? outcome[0].toUpperCase() + outcome.slice(1) + ' · ' : '') + o.label
                        + (o.confidence === 'low' && o.origin !== 'user' && o.discovered && o.command === o.discovered.command ? ' · Low confidence' : '')
                        + (outcome === 'dispatched' ? ' · Remote run is not tracked' : '');
                    parent.appendChild(item);
                }
                unnamed.sort(function(a, b) { return a.label.localeCompare(b.label); }).forEach(function(o) { option(el.deployPicker, o); });
                groups.forEach(function(name) {
                    const members = operations.filter(function(o) { return (o.environment || '').trim().toLowerCase() === name.toLowerCase(); });
                    const group = document.createElement('optgroup'); group.label = name + (members.some(isOperationRunning) ? ' · Running' : '');
                    members
                        .sort(function(a, b) { return a.label.localeCompare(b.label); })
                        .forEach(function(o) { option(group, o); });
                    el.deployPicker.appendChild(group);
                });
            }

            function renderOperations(d, node) {
                if (ui.view !== 'deployment' || !ui.operations) return;
                const state = ui.operations;
                const title = document.createElement('h5'); title.textContent = 'Project operations'; d.appendChild(title);
                if (state.error) {
                    const error = document.createElement('p'); error.className = 'arch-error';
                    error.textContent = state.error; d.appendChild(error); return;
                }
                if (state.message) {
                    const message = document.createElement('p'); message.className = 'arch-muted';
                    message.textContent = state.message; d.appendChild(message);
                }
                if (state.readOnly) {
                    const warning = document.createElement('p'); warning.className = 'arch-error';
                    warning.textContent = 'This operations file uses a newer schema version. Update MarkView to edit or run operations.';
                    d.appendChild(warning);
                }
                const all = visibleOperations();
                if (!all.length) {
                    const p = document.createElement('p'); p.className = 'arch-muted';
                    p.textContent = 'No runnable procedure is known for this project.';
                    d.appendChild(p);
                }
                const currentNodeIDs = new Set((currentView() && currentView().nodes || []).map(function(n) { return n.id; }));
                const related = node ? all.filter(function(o) {
                    return (o.nodes || []).some(function(n) {
                        return currentNodeIDs.has(n.id) ? n.id === node.id : n.name === node.name;
                    });
                }) : [];
                function row(operation, highlighted, parent) {
                    const wrapper = document.createElement('div');
                    wrapper.className = 'arch-operation' + (highlighted ? ' related' : '');
                    wrapper.dataset.search = [operation.label, operation.environment || '', operation.kind,
                        operation.target || '', operation.command].join(' ').toLowerCase();
                    const heading = document.createElement('strong');
                    heading.textContent = operation.label + (operation.environment ? ' · ' + operation.environment : '')
                        + ' · ' + operation.kind;
                    wrapper.appendChild(heading);
                    const status = operationState(operation);
                    const badges = document.createElement('div'); badges.className = 'arch-badges';
                    const edited = operation.origin === 'user' || (operation.discovered &&
                        (operation.command !== operation.discovered.command || operation.cwd !== operation.discovered.cwd));
                    const marks = [edited ? (operation.origin === 'user' ? 'User-added' : 'User-edited') : operation.confidence,
                        status.state, operation.remoteTrigger ? 'Remote trigger' : null,
                        operation.cwd.indexOf('..') === 0 || operation.cwd.indexOf('~') === 0 || operation.cwd.indexOf('/') === 0 ? 'Outside project' : null];
                    marks.filter(Boolean).forEach(function(mark) {
                        const badge = document.createElement('span'); badge.textContent = mark; badges.appendChild(badge);
                    });
                    wrapper.appendChild(badges);
                    if (status.state === 'dispatched') {
                        const remote = document.createElement('p'); remote.className = 'arch-muted';
                        remote.textContent = 'Remote run is not tracked.'; wrapper.appendChild(remote);
                    }
                    const command = document.createElement('code'); command.textContent = operation.command;
                    wrapper.appendChild(command);
                    addRow(wrapper, 'Directory', operation.cwd);
                    (operation.provenance || []).forEach(function(source) {
                        addRow(wrapper, 'Source', source.location + (source.line ? ':' + source.line : '') + ' · ' + source.kind);
                    });
                    (operation.prerequisites || []).forEach(function(item) { addRow(wrapper, 'Prerequisite', item); });
                    if (edited && operation.discovered &&
                        (operation.command !== operation.discovered.command || operation.cwd !== operation.discovered.cwd)) {
                        addRow(wrapper, 'Discovery suggests', operation.discovered.command + ' · ' + operation.discovered.cwd);
                    }
                    if (status.definitionNotice) addRow(wrapper, 'Changed', status.definitionNotice);
                    const unavailable = (state.unavailable || {})[operation.id];
                    if (unavailable) addRow(wrapper, 'Unavailable', unavailable);
                    const actions = document.createElement('div'); actions.className = 'arch-operation-actions';
                    const run = linkButton(isOperationRunning(operation) ? 'Open output' : 'Run', function() {
                        post(isOperationRunning(operation) ? 'operationOpen' : 'operationRun', { id: operation.id });
                    }, 'arch-action');
                    run.disabled = !!unavailable && !isOperationRunning(operation);
                    actions.appendChild(run);
                    if (status.state && !isOperationRunning(operation)) {
                        actions.appendChild(linkButton('Last run', function() {
                            post('operationOpen', { id: operation.id });
                        }, 'arch-action'));
                    }
                    const edit = linkButton('Edit', function() { post('operationEdit', { id: operation.id }); }, 'arch-action');
                    edit.disabled = !!state.readOnly;
                    actions.appendChild(edit);
                    if (edited && operation.discovered &&
                        (operation.command !== operation.discovered.command || operation.cwd !== operation.discovered.cwd)) {
                        const adopt = linkButton('Adopt discovered', function() { post('operationAdopt', { id: operation.id }); }, 'arch-action');
                        adopt.disabled = !!state.readOnly;
                        actions.appendChild(adopt);
                    }
                    wrapper.appendChild(actions);
                    (parent || d).appendChild(wrapper);
                }
                if (related.length) {
                    const h = document.createElement('h5'); h.textContent = 'Related to ' + node.name; d.appendChild(h);
                    related.forEach(function(o) { row(o, true); });
                }
                // A few main operations up front (ranked by ProjectOperation.primary); the rest by search.
                const main = (state.primary || []).map(function(id) {
                    return all.find(function(o) { return o.id === id; });
                }).filter(function(o) { return o && related.indexOf(o) < 0; });
                if (main.length) {
                    const h = document.createElement('h5'); h.textContent = 'Main operations'; d.appendChild(h);
                    main.forEach(function(o) { row(o, false); });
                }
                const kinds = ['deploy', 'install', 'build', 'restart', 'clean', 'other'];
                const rest = all.filter(function(o) { return related.indexOf(o) < 0 && main.indexOf(o) < 0; })
                    .sort(function(a, b) {
                        return (kinds.indexOf(a.kind) - kinds.indexOf(b.kind)) || a.label.localeCompare(b.label);
                    });
                if (rest.length) {
                    const h = document.createElement('h5'); h.textContent = 'All operations (' + rest.length + ')'; d.appendChild(h);
                    const search = document.createElement('input');
                    search.type = 'search'; search.placeholder = 'Search operations'; search.style.width = '100%';
                    search.value = ui.operationQuery || '';
                    d.appendChild(search);
                    const list = document.createElement('div');
                    rest.forEach(function(o) { row(o, false, list); });
                    const none = document.createElement('p'); none.className = 'arch-muted'; none.textContent = 'No matching operation.';
                    const toggle = linkButton('', function() { ui.operationsShowAll = !ui.operationsShowAll; apply(); }, 'arch-action');
                    function apply() {
                        const query = search.value.trim().toLowerCase();
                        ui.operationQuery = search.value;
                        let shown = 0;
                        Array.prototype.forEach.call(list.children, function(r) {
                            r.hidden = query ? r.dataset.search.indexOf(query) < 0 : !ui.operationsShowAll;
                            if (!r.hidden) shown += 1;
                        });
                        none.hidden = !query || shown > 0;
                        toggle.hidden = !!query;
                        toggle.textContent = ui.operationsShowAll ? 'Hide the list' : 'Show all ' + rest.length;
                    }
                    search.addEventListener('input', apply);
                    // The panel re-renders on updates: keep typing in the new field.
                    search.addEventListener('focus', function() { ui.operationSearchFocused = true; });
                    search.addEventListener('blur', function() {
                        setTimeout(function() { if (search.isConnected) ui.operationSearchFocused = false; });
                    });
                    d.appendChild(toggle);
                    d.appendChild(list);
                    d.appendChild(none);
                    apply();
                    if (ui.operationSearchFocused) {
                        search.focus();
                        search.setSelectionRange(search.value.length, search.value.length);
                    }
                }
                const addOperation = linkButton('Add operation', function() { post('operationAdd'); }, 'arch-action');
                addOperation.disabled = !!state.readOnly;
                d.appendChild(addOperation);
                if (state.sourcesChanged) {
                    const hint = document.createElement('p'); hint.className = 'arch-muted';
                    hint.textContent = 'Sources changed since the last discovery. The operations remain available.';
                    d.appendChild(hint);
                }
                if (state.discoveryPhase) {
                    const progress = document.createElement('p'); progress.className = 'arch-muted';
                    progress.textContent = 'Discovering operations · ' + state.discoveryPhase + '…';
                    d.appendChild(progress);
                    d.appendChild(linkButton('Cancel discovery', function() { post('operationCancelDiscovery'); }, 'arch-action'));
                } else {
                    const discover = linkButton(state.hasFile ? 'Re-discover' : 'Discover operations',
                        function() { post('operationDiscover'); }, 'arch-action');
                    discover.disabled = !!state.readOnly;
                    d.appendChild(discover);
                }
                const report = state.discoveryReport;
                if (report) {
                    const heading = document.createElement('h5'); heading.textContent = 'Discovery report'; d.appendChild(heading);
                    const message = document.createElement('p'); message.textContent = report.message; d.appendChild(message);
                    (report.externalFolders || []).forEach(function(path) { addRow(d, 'External folder read', path); });
                    (report.rejectedReferences || []).forEach(function(path) { addRow(d, 'Reference skipped', path); });
                    (report.webSources || []).forEach(function(url) { addRow(d, 'Web source', url); });
                    if (!report.webSearched) addRow(d, 'Web', 'Not searched');
                    (report.proposals || []).forEach(function(operation, index) {
                        const box = document.createElement('div'); box.className = 'arch-operation related';
                        const name = document.createElement('strong'); name.textContent = operation.label + ' · Proposal from outside the project';
                        box.appendChild(name);
                        const command = document.createElement('code'); command.textContent = operation.command; box.appendChild(command);
                        addRow(box, 'Confidence', operation.confidence);
                        (operation.provenance || []).forEach(function(source) { addRow(box, 'Source', source.location); });
                        box.appendChild(linkButton('Accept', function() { post('operationAcceptProposal', { index: index }); }, 'arch-action'));
                        box.appendChild(linkButton('Reject', function() { post('operationRejectProposal', { index: index }); }, 'arch-action'));
                        d.appendChild(box);
                    });
                    (report.notDetermined || []).forEach(function(item, index) {
                        const box = document.createElement('div'); box.className = 'arch-operation';
                        const name = document.createElement('strong'); name.textContent = item.label + ' · Not determined'; box.appendChild(name);
                        addRow(box, 'Reason', item.reason);
                        addRow(box, 'Investigated', item.investigated);
                        box.appendChild(linkButton('Add command', function() { post('operationAddUnknown', { index: index }); }, 'arch-action'));
                        d.appendChild(box);
                    });
                    d.appendChild(linkButton('Dismiss report', function() { post('operationDismissReport'); }, 'arch-action'));
                }
            }

            function renderDetails() {
                const d = el.details;
                const oldAnswerBody = d.querySelector('.arch-understanding-body');
                const answerScroll = oldAnswerBody ? oldAnswerBody.scrollTop : 0;
                d.textContent = '';
                const filter = currentFilter();
                const understanding = filter && (ui.payload.understandingAnswers || {})[filter.id];
                if (understanding) {
                    renderUnderstanding(d, filter, understanding);
                    const body = d.querySelector('.arch-understanding-body');
                    if (body) body.scrollTop = answerScroll;
                    const key = filter.id + ':' + understanding.state;
                    if (ui.answerDisplayKey !== key) { d.scrollTop = 0; ui.answerDisplayKey = key; }
                }
                const view = currentView();
                const snap = ui.payload && ui.payload.snapshot;
                if (!view || !snap) {
                    // Operations exist independently of an AI-built deployment map.
                    if (ui.view === 'deployment') renderOperations(d, null);
                    return;
                }
                const idx = indexView(view);
                const node = ui.selected ? idx.byId.get(ui.selected) : null;

                if (!node && ui.selectedEdge && ui.selectedEdge.view === ui.view) { renderEdgeDetails(d, idx, ui.selectedEdge); return; }
                if (!understanding && !node && isSearch(currentFilter()) && overlayApplies() && (ui.payload.searchAnswers || {})[currentFilter().id]) {
                    renderSearchAnswer(d, currentFilter(), ui.payload.searchAnswers[currentFilter().id]);
                    return;
                }
                if (!node && ui.view === 'pr') { renderPRPanel(d, snap, idx); return; }
                // A changed file in the PR X-Ray: its diff, the review and questions about it.
                // A changed file — in the PR X-Ray, or with the Pull request overlay on — shows its
                // change: what was added and removed, and why.
                const showsChange = ui.view === 'pr' || (overlayApplies() && ui.overlay === 'pr');
                if (node && showsChange && node.path && node.kind === 'file'
                    && ui.payload.pr && ui.payload.pr.files.some(function(f) { return f.path === node.path; })) {
                    renderPRFile(d, node.path);
                    return;
                }
                if (!node && isBook()) { renderBookOverview(d, view, idx, snap); return; }
                if (!node) {
                    const h = document.createElement('h4'); h.textContent = ui.view === 'logical' && snap.systemName ? snap.systemName : 'Overview';
                    d.appendChild(h);
                    if (ui.view === 'logical' && snap.systemPurpose) { const p = document.createElement('p'); p.textContent = snap.systemPurpose; d.appendChild(p); }
                    renderReport(d, view, idx);
                    const active = currentFilter();
                    if (active && active.id !== 'importance') {
                        d.appendChild(linkButton('Delete filter "' + active.name + '"', function() {
                            post('deleteFilter', { id: active.id }); ui.overlay = 'none';
                        }, 'arch-action'));
                    }
                    const files = view.nodes.filter(function(n) { return n.kind === 'file' || n.kind === 'doc'; }).length;
                    addRow(d, ui.view === 'docs' ? 'Documents' : 'Files', files ? String(files) : '');
                    addRow(d, 'Connections', String(view.edges.length));
                    addRow(d, 'Scanned', snap.scannedAt ? new Date(snap.scannedAt).toLocaleString() : '');
                    addRow(d, 'AI analysis', snap.enrichedAt ? new Date(snap.enrichedAt).toLocaleString() : 'not run');
                    if (overlayApplies() && ui.overlay === 'pr' && ui.payload.pr) {
                        const pr = ui.payload.pr;
                        const sec = document.createElement('h5'); sec.textContent = pr.source.title; d.appendChild(sec);
                        addRow(d, 'Changed files', String(pr.files.length));
                        if (pr.reviewSummary) { const p = document.createElement('p'); p.textContent = pr.reviewSummary; d.appendChild(p); }
                        pr.files.forEach(function(f) { d.appendChild(changeRow(f)); });
                    }
                    if (ui.view === 'deployment' && !view.nodes.some(function(n) { return n.kind !== 'root'; })) {
                        const p = document.createElement('p');
                        p.textContent = 'The deployment view is mapped by AI from the project’s build and deploy files. Click Analyze.';
                        d.appendChild(p);
                    }
                    renderOperations(d, null);
                    const p = document.createElement('p'); p.className = 'arch-muted';
                    p.textContent = 'Select a box for details. Double-click to zoom in; use the path above to zoom out.';
                    d.appendChild(p);
                    return;
                }

                const h = document.createElement('h4'); h.textContent = node.name; d.appendChild(h);
                if (ui.view === 'deployment') renderOperations(d, node);
                const badges = document.createElement('div'); badges.className = 'arch-badges';
                const lineBadge = isBook() && node.line ? 'lines ' + node.line + (node.endLine && node.endLine !== node.line ? '–' + node.endLine : '') : null;
                [kindLabel(node), node.role, isBook() && node.kind === 'section' ? null : node.language, node.tech, lineBadge].forEach(function(b) {
                    if (!b) return;
                    const s = document.createElement('span'); s.textContent = b; badges.appendChild(s);
                });
                d.appendChild(badges);
                const describing = (ui.payload.describing || []).indexOf(node.id) >= 0;
                if (isBook()) renderBookLineage(d, node, idx);
                const borrowed = !node.summary && bookText(node);
                if (node.summary) {
                    const p = document.createElement('p'); p.textContent = node.summary; d.appendChild(p);
                } else if (borrowed && borrowed.summary) {
                    if (borrowed.kind === 'doc' && borrowed.name !== node.name) { const t = document.createElement('p'); t.className = 'arch-muted'; t.textContent = borrowed.name; d.appendChild(t); }
                    const p = document.createElement('p'); p.textContent = borrowed.summary; d.appendChild(p);
                    if (borrowed.kind === 'doc' && !borrowed.summarySignature) {
                        const n = document.createElement('p'); n.className = 'arch-muted';
                        n.textContent = 'From the document\'s first paragraph; Analyze writes the AI\'s annotation.';
                        d.appendChild(n);
                    }
                } else if (isBook() && ['doc', 'section'].indexOf(node.kind) >= 0) {
                    renderDescribeChapter(d, node, idx);
                } else if (codeViews[ui.view] && ['dir', 'package', 'file'].indexOf(node.kind) >= 0 && !borrowed) {
                    // Describe on first selection; the answer is cached with the folder/file signature.
                    const p = document.createElement('p'); p.className = 'arch-muted';
                    p.textContent = describing || ui.describeRequested.has(node.id) ? 'Describing…' : '';
                    d.appendChild(p);
                    if (!ui.describeRequested.has(node.id)) {
                        ui.describeRequested.add(node.id);
                        post('describe', { view: ui.view, id: node.id });
                        p.textContent = 'Describing…';
                    }
                }
                const rating = ratingOf(node);
                if (rating) {
                    const sec = document.createElement('h5'); sec.textContent = currentFilter().name + ': ' + rating.level; d.appendChild(sec);
                    if (rating.reason) { const p = document.createElement('p'); p.textContent = rating.reason; d.appendChild(p); }
                }
                // Logical component of a folder or file; the user can move it.
                const comps = snap.components || [];
                if (codeViews[ui.view] && comps.length && ['dir', 'package', 'file'].indexOf(node.kind) >= 0 && node.path != null) {
                    const structural = ui.view === 'logical'
                        ? ((snap.views.find(function(v) { return v.id === 'modules'; }) || { nodes: [] }).nodes
                            .find(function(n) { return n.path === node.path && n.kind === node.kind; }) || node)
                        : node;
                    const sec = document.createElement('h5'); sec.textContent = 'Logical component'; d.appendChild(sec);
                    const select = document.createElement('select');
                    select.title = 'Where this belongs in the Logical view. Pick another component to move it; your choice is kept over the AI\'s.';
                    const overridden = snap.overrides && snap.overrides[node.path];
                    // Name the AI's own choice, so "back to AI" says where that is.
                    const aiComp = comps.find(function(c) { return c.id === (snap.assignments && (function() {
                        let p = node.path;
                        while (true) { const a = snap.assignments[p]; if (a) return a.component; if (!p) return null; p = p.indexOf('/') >= 0 ? p.slice(0, p.lastIndexOf('/')) : ''; }
                    })()); });
                    const auto = document.createElement('option'); auto.value = '';
                    auto.textContent = aiComp ? 'AI: ' + aiComp.name : 'AI: not assigned';
                    select.appendChild(auto);
                    comps.forEach(function(comp) {
                        const o = document.createElement('option'); o.value = comp.id; o.textContent = comp.name;
                        if (overridden === comp.id) o.selected = true;
                        select.appendChild(o);
                    });
                    select.onchange = function() { post('setComponent', { path: node.path, component: select.value }); };
                    d.appendChild(select);
                    const tags = structural.tags || [];
                    if (tags.length) {
                        const b = document.createElement('div'); b.className = 'arch-badges';
                        tags.forEach(function(t) { const sp = document.createElement('span'); sp.textContent = t; b.appendChild(sp); });
                        d.appendChild(b);
                    }
                }
                if (node.path != null && node.path !== '') {
                    const openable = ['file', 'doc', 'section', 'entity'].indexOf(node.kind) >= 0;
                    const title = node.kind === 'section' ? node.path + (node.line ? ':' + node.line + (node.endLine && node.endLine !== node.line ? '–' + node.endLine : '') : '') + ' › ' + node.name
                        : node.kind === 'entity' ? node.path + (node.line ? ':' + node.line : '')
                        : node.path;
                    d.appendChild(linkButton(title, function() {
                        post('openFile', node.kind === 'section' ? sectionTarget(node)
                            : node.kind === 'entity' ? entityTarget(node) : { path: node.path });
                    }, 'arch-path' + (openable ? '' : ' arch-reveal')));
                }
                // Local contents are available immediately; request a deeper AI outline.
                if (ui.view === 'logical' && node.kind === 'file' && node.path) {
                    const reading = (ui.payload.outlining || []).indexOf(node.path) >= 0;
                    const hasContents = (idx.children.get(node.id) || []).length > 0;
                    const button = linkButton(reading ? 'Outlining with AI…' : hasContents ? 'Deepen with AI' : 'Outline with AI',
                        function() { if (!reading) post('outlineFile', { path: node.path }); }, 'arch-action');
                    if (reading) button.disabled = true;
                    d.appendChild(button);
                }
                renderInsightButton(d, node);
                addRow(d, ['collection', 'group'].indexOf(node.kind) >= 0 ? 'Items' : isBook() ? 'Chapters' : 'Files',
                       ['file', 'doc', 'entity', 'section'].indexOf(node.kind) >= 0 ? '' : (node.files ? String(node.files) : ''));
                if (isBook() && ['doc', 'dir', 'root'].indexOf(node.kind) >= 0) {
                    const sections = view.nodes.filter(function(n) { return n.kind === 'section' && (node.kind === 'doc' ? n.path === node.path : isUnder(n, node.id, idx)); }).length;
                    addRow(d, 'Sections', sections ? String(sections) : '');
                }
                addRow(d, 'Lines', node.loc ? String(node.loc) : '');

                const kids = idx.children.get(node.id) || [];
                if (kids.length) {
                    const expanded = ui.expanded[ui.view].has(node.id);
                    d.appendChild(linkButton(expanded ? 'Zoom out of this' : 'Zoom into this', function() { activate(node.id); }, 'arch-action'));
                }

                if (isBook()) { renderBookRefs(d, node, idx, view); }
                // Connections of the drawn node.
                else if (cy && cy.getElementById(node.id).length) {
                    const drawn = cy.getElementById(node.id);
                    const outs = drawn.union(drawn.descendants()).outgoers('edge').filter(function(e) { return !e.target().same(drawn) && !drawn.descendants().contains(e.target()); });
                    const ins = drawn.union(drawn.descendants()).incomers('edge').filter(function(e) { return !e.source().same(drawn) && !drawn.descendants().contains(e.source()); });
                    addRow(d, 'Depends on', outs.length ? String(outs.length) : '');
                    addRow(d, 'Used by', ins.length ? String(ins.length) : '');
                }

                if (codeViews[ui.view]) {
                    const metrics = snap.metrics || {};
                    const files = descendantsFiles(node.id, idx, []).map(function(id) { return idx.byId.get(id); })
                        .filter(function(n) { return n && n.kind === 'file'; })
                        .map(function(n) { return metrics[fileKey(n)]; }).filter(Boolean);
                    if (files.length) {
                        const sec = document.createElement('h5'); sec.textContent = 'Health'; d.appendChild(sec);
                        const sum = function(k) { return files.reduce(function(a, m) { return a + (m[k] || 0); }, 0); };
                        const sources = files.filter(function(m) { return !m.isTest; });
                        const tested = sources.filter(function(m) { return m.tested; }).length;
                        const worstFn = files.reduce(function(a, m) { return (m.maxFunctionComplexity || 0) > (a ? a.maxFunctionComplexity : 0) ? m : a; }, null);
                        addRow(d, 'Functions', String(sum('functions')));
                        if (worstFn) addRow(d, 'Most complex', worstFn.maxFunctionComplexity + (worstFn.maxFunctionName ? ' — ' + worstFn.maxFunctionName : ''));
                        addRow(d, 'Functions > 10', String(sum('complexFunctions')));
                        addRow(d, 'Commits', sum('commits') ? String(sum('commits')) : '');
                        addRow(d, 'Bug-fix commits', sum('bugfixes') ? String(sum('bugfixes')) : '0');
                        const newest = files.reduce(function(a, m) { return Math.max(a, m.lastChanged || 0); }, 0);
                        if (newest) addRow(d, 'Last changed', ago(newest));
                        if (files.length > 1) {
                            const recent = files.filter(function(m) { return m.lastChanged && Date.now() / 1000 - m.lastChanged < 182 * 86400; }).length;
                            addRow(d, 'Changed in 6 months', recent + ' of ' + files.length + ' files');
                        }
                        if (node.kind === 'file' && metrics[fileKey(node)]) {
                            const m = metrics[fileKey(node)];
                            addRow(d, 'Tests', m.isTest ? 'this is a test file' : m.tested ? 'tested' : 'none found');
                            if (m.lineCoverage != null) addRow(d, 'Line coverage', Math.round(m.lineCoverage * 100) + '%');
                            (m.testFiles || []).forEach(function(t) { d.appendChild(linkButton(t, function() { post('openFile', { path: t }); }, 'arch-path')); });
                        } else if (sources.length) {
                            addRow(d, 'Tested files', tested + ' of ' + sources.length);
                        }
                    }
                    const cov = snap.coverage || {};
                    if (node.kind === 'file') {
                        const c = cov[fileKey(node)];
                        const sec = document.createElement('h5'); sec.textContent = 'Documentation'; d.appendChild(sec);
                        const status = c ? c.status : 'none';
                        const p = document.createElement('p');
                        p.textContent = status === 'fresh' ? 'Documented.' : status === 'stale'
                            ? 'Documented, but the code changed after the documents.' : 'No document mentions this file or its folders.';
                        d.appendChild(p);
                        (c ? c.docs : []).forEach(function(doc) {
                            d.appendChild(linkButton(doc, function() { post('openFile', { path: doc, find: node.name }); }, 'arch-path'));
                        });
                    } else if (ui.overlay === 'coverage') {
                        const info = overlayInfo(node, idx);
                        if (info && info.total) {
                            const sec = document.createElement('h5'); sec.textContent = 'Documentation'; d.appendChild(sec);
                            addRow(d, 'Documented', info.fresh + ' of ' + info.total);
                            addRow(d, 'Outdated docs', info.stale ? String(info.stale) : '');
                            addRow(d, 'Undocumented', info.none ? String(info.none) : '');
                        }
                    }
                    if (ui.payload.pr) {
                        const pr = prByNode();
                        const changes = descendantsFiles(node.id, idx, []).map(function(id) { return pr.get(fileKey(idx.byId.get(id))); }).filter(Boolean);
                        if (changes.length) {
                            const sec = document.createElement('h5'); sec.textContent = 'Changes in ' + ui.payload.pr.source.title; d.appendChild(sec);
                            changes.forEach(function(f) { d.appendChild(changeRow(f)); });
                        }
                    }
                }
            }

            // --------------------------------------------------------------- the Book's panel

            function isUnder(node, ancestorId, idx) {
                let cur = node.parent != null ? idx.byId.get(node.parent) : null;
                while (cur) { if (cur.id === ancestorId) return true; cur = cur.parent != null ? idx.byId.get(cur.parent) : null; }
                return false;
            }

            /** Nothing selected in the Book: what the book is, its size, and how much is annotated. */
            function renderBookOverview(d, view, idx, snap) {
                const root = view.nodes.find(function(n) { return n.kind === 'root'; });
                const h = document.createElement('h4'); h.textContent = root && root.name ? root.name : 'Book'; d.appendChild(h);
                if (root && root.summary) { const p = document.createElement('p'); p.textContent = root.summary; d.appendChild(p); }
                // Ask the book: the answer with its sources replaces this panel while it is open.
                const form = document.createElement('form'); form.className = 'temp-filter arch-ask';
                const input = document.createElement('input');
                input.placeholder = 'Ask the book, e.g. how are releases published?';
                input.style.width = '100%';
                form.appendChild(input);
                form.onsubmit = function(e) { e.preventDefault(); const text = input.value.trim(); if (text) askBook(text); };
                d.appendChild(form);
                const hint = document.createElement('p'); hint.className = 'arch-muted';
                hint.textContent = 'A question gets an answer (what, why, how, where it comes from) with the sections it rests on; press Enter.';
                d.appendChild(hint);
                renderReport(d, view, idx);
                const active = currentFilter();
                if (active && active.id !== 'importance') {
                    d.appendChild(linkButton('Delete filter "' + active.name + '"', function() {
                        post('deleteFilter', { id: active.id }); ui.overlay = 'none';
                    }, 'arch-action'));
                }
                const count = function(kind) { return view.nodes.filter(function(n) { return n.kind === kind; }).length; };
                const chapters = count('doc');
                addRow(d, 'Parts', count('dir') ? String(count('dir')) : '');
                addRow(d, 'Chapters', chapters ? String(chapters) : '');
                addRow(d, 'Sections', count('section') ? String(count('section')) : '');
                const links = view.edges.filter(function(e) { return e.kind === 'links'; }).length;
                const related = view.edges.filter(function(e) { return e.kind === 'related'; }).length;
                addRow(d, 'Cross-references', links || related ? links + ' in the text' + (related ? ', ' + related + ' related (AI)' : '') : '');
                addRow(d, 'Scanned', snap.scannedAt ? new Date(snap.scannedAt).toLocaleString() : '');
                const left = undescribedChapters(view).length;
                if (chapters) addRow(d, 'AI annotations', (chapters - left) + ' of ' + chapters + ' chapters');
                if (left) {
                    const b = linkButton(ui.payload.busy ? 'Annotating…' : 'Describe remaining chapters (' + left + ')', function() { post('describeBook', {}); }, 'arch-action');
                    if (ui.payload.busy) b.disabled = true;
                    d.appendChild(b);
                    if (!snap.enrichedAt && !ui.payload.busy) {
                        const p = document.createElement('p'); p.className = 'arch-muted';
                        p.textContent = 'Analyze annotates every chapter and section: what each says, how important it is, and what else to read.';
                        d.appendChild(p);
                    }
                }
                const insight = linkButton('Recursive Insight of the book', function() { post('recursiveInsight', { path: '' }); }, 'arch-action');
                insight.title = 'A layered narrative of all the documents, to read and dive into level by level';
                d.appendChild(insight);
                const p = document.createElement('p'); p.className = 'arch-muted';
                p.textContent = 'Select a part, chapter or section for details. Double-click opens a chapter\'s sections; double-click a section to read it.';
                d.appendChild(p);
            }

            /** Recursive Insight of a part (its folder) or a chapter (its document), from the panel. */
            function renderInsightButton(d, node) {
                if (!isBook() || node.path == null || (node.kind !== 'dir' && node.kind !== 'doc')) return;
                const b = linkButton(node.kind === 'dir' ? 'Recursive Insight of this part' : 'Recursive Insight of this chapter',
                    function() { post('recursiveInsight', { path: node.path }); }, 'arch-action');
                b.title = node.kind === 'dir' ? 'A layered narrative of this folder\'s documents, to dive into level by level'
                    : 'A layered narrative of this document, to dive into level by level';
                d.appendChild(b);
            }

            /** "In: part › chapter › section" above a Book node's summary; each step focuses it. */
            function renderBookLineage(d, node, idx) {
                const chain = [];
                let cur = node.parent != null ? idx.byId.get(node.parent) : null;
                while (cur && cur.kind !== 'root') { chain.unshift(cur); cur = cur.parent != null ? idx.byId.get(cur.parent) : null; }
                if (!chain.length) return;
                const row = document.createElement('div'); row.className = 'arch-badges';
                const label = document.createElement('span'); label.textContent = 'In:'; row.appendChild(label);
                chain.forEach(function(step, i) {
                    if (i) { const sep = document.createElement('span'); sep.textContent = '›'; row.appendChild(sep); }
                    const b = linkButton(step.name, function() { window.architectureFocus(step.id, 'docs'); }, 'arch-link');
                    b.title = kindLabel(step) + (step.path ? ' · ' + step.path : '');
                    row.appendChild(b);
                });
                d.appendChild(row);
            }

            /** A chapter (or a section of one) without annotations yet: describe it now. */
            function renderDescribeChapter(d, node, idx) {
                let chapter = node;
                while (chapter && chapter.kind !== 'doc') chapter = chapter.parent != null ? idx.byId.get(chapter.parent) : null;
                if (!chapter) return;
                const describing = (ui.payload.describing || []).indexOf(chapter.id) >= 0;
                const p = document.createElement('p'); p.className = 'arch-muted';
                p.textContent = describing ? 'Describing…' : 'Not annotated by the AI yet.';
                d.appendChild(p);
                if (!describing) {
                    const b = linkButton(ui.payload.busy ? 'Busy…' : 'Describe this chapter', function() { post('describeBook', { path: chapter.path }); }, 'arch-action');
                    if (ui.payload.busy) b.disabled = true;
                    d.appendChild(b);
                }
            }

            /** Cross-references of a Book node and everything inside it, both ways, from the
             *  view's own edges (so targets inside closed boxes are listed too). */
            function renderBookRefs(d, node, idx, view) {
                const inside = new Set([node.id]);
                (function walk(id) { (idx.children.get(id) || []).forEach(function(k) { inside.add(k); walk(k); }); })(node.id);
                const out = [], inn = [];
                view.edges.forEach(function(e) {
                    if (e.kind !== 'links' && e.kind !== 'related') return;
                    const s = inside.has(e.source), t = inside.has(e.target);
                    if (s && !t) out.push(e); else if (t && !s) inn.push(e);
                });
                function list(title, edges, otherOf) {
                    if (!edges.length) return;
                    const sec = document.createElement('h5'); sec.textContent = title + ' (' + edges.length + ')'; d.appendChild(sec);
                    const seen = new Set();
                    edges.forEach(function(e) {
                        const other = idx.byId.get(otherOf(e));
                        if (!other || seen.size >= 20) return;
                        const key = other.id + '|' + e.kind;
                        if (seen.has(key)) return;
                        seen.add(key);
                        let text = other.name;
                        if (other.kind !== 'doc' && other.path) text += ' (' + other.path.split('/').pop() + ')';
                        if (e.kind === 'related') text += ' — related (AI)' + (e.label ? ': ' + e.label : '');
                        const b = linkButton(text, function() { window.architectureFocus(other.id, 'docs'); }, 'arch-path');
                        b.title = (other.path || other.name) + (e.kind === 'related' ? ' · found by the AI' : ' · linked in the text');
                        d.appendChild(b);
                    });
                }
                list('Refers to', out, function(e) { return e.target; });
                list('Referred to by', inn, function(e) { return e.source; });
            }

            /** The overlay as an analysis: the worst / most important items, ranked. */
            function renderReport(d, view, idx) {
                if (!overlayApplies() || ui.overlay === 'pr') return;
                const snap = ui.payload.snapshot;
                const metrics = snap.metrics || {}, cov = snap.coverage || {};
                const leaves = view.nodes.filter(function(n) { return ['file', 'doc', 'section', 'component'].indexOf(n.kind) >= 0; })
                    .filter(function(n) { return !isHidden(n, idx); });
                const score = {
                    complexity: function(n) { const m = metrics[fileKey(n)]; return m && n.kind === 'file' ? [m.maxFunctionComplexity, m.maxFunctionComplexity + (m.maxFunctionName ? ' ' + m.maxFunctionName : '')] : null; },
                    bugs: function(n) { const m = metrics[fileKey(n)]; return m && n.kind === 'file' && m.bugfixes ? [m.bugfixes, m.bugfixes + ' fixes'] : null; },
                    tests: function(n) { const m = metrics[fileKey(n)]; return m && n.kind === 'file' && !m.isTest && !m.tested ? [m.loc, m.loc + ' lines, no tests'] : null; },
                    coverage: function(n) { const c = cov[fileKey(n)]; const m = metrics[fileKey(n)]; return c && c.status !== 'fresh' && n.kind === 'file' ? [(m ? m.loc : 0) + (c.status === 'stale' ? 1e6 : 0), c.status === 'stale' ? 'docs outdated' : 'undocumented'] : null; },
                    freshness: function(n) { const m = metrics[fileKey(n)]; return m && (n.kind === 'file' || n.kind === 'doc') ? [m.lastChanged, ago(m.lastChanged)] : null; },
                    size: function(n) { return n.loc && (n.kind === 'file' || n.kind === 'doc') ? [n.loc, n.loc + ' lines'] : null; },
                }[ui.overlay] || (currentFilter() && function(n) {
                    const r = ratingOf(n); return r ? [levelRank(currentFilter(), r.level), r.level] : null;
                });
                if (!score) return;
                const ranked = leaves.map(function(n) { const sc = score(n); return sc ? { node: n, value: sc[0], label: sc[1] } : null; })
                    .filter(Boolean).sort(function(a, b) { return b.value - a.value; }).slice(0, 15);
                const titles = { complexity: 'Most complex functions', bugs: 'Bug hotspots', tests: 'Largest untested files',
                    coverage: 'Documentation gaps', freshness: 'Recently changed', size: 'Largest files' };
                const sec = document.createElement('h5');
                sec.textContent = titles[ui.overlay] || (currentFilter() ? currentFilter().name + ' — strongest' : '');
                d.appendChild(sec);
                if (currentFilter() && currentFilter().criterion) {
                    const q = document.createElement('p'); q.className = 'arch-muted'; q.textContent = currentFilter().criterion; d.appendChild(q);
                }
                if (!ranked.length) {
                    const p = document.createElement('p'); p.className = 'arch-muted';
                    p.textContent = currentFilter() ? 'Zoom in: the AI rates each level as you open it.' : 'Nothing to report.';
                    d.appendChild(p); return;
                }
                const grid = document.createElement('div'); grid.className = 'arch-rank';
                ranked.forEach(function(r) {
                    const b = document.createElement('button'); b.textContent = r.node.name; b.title = r.node.path || r.node.name;
                    b.onclick = function() { window.architectureFocus(r.node.id); };
                    const v = document.createElement('span'); v.textContent = r.label;
                    grid.appendChild(b); grid.appendChild(v);
                });
                d.appendChild(grid);
            }

            /** Questions about the change (or one file of it) and the AI's answers, plus the box to ask. */
            /** An arrow: source → target, the code behind it and the AI's explanation. */
            function renderEdgeDetails(d, idx, edge) {
                const a = idx.byId.get(edge.source), b = idx.byId.get(edge.target);
                const h = document.createElement('h4');
                h.textContent = (a ? a.name : edge.source) + ' \u2192 ' + (b ? b.name : edge.target);
                d.appendChild(h);
                const kind = document.createElement('div'); kind.className = 'arch-badges';
                const chip = document.createElement('span'); chip.textContent = edge.kind + (edge.label ? ' \u00B7 ' + edge.label : '');
                kind.appendChild(chip); d.appendChild(kind);
                [a, b].forEach(function(n) {
                    if (!n) return;
                    d.appendChild(linkButton((n === a ? 'From: ' : 'To: ') + n.name, function() { ui.selectedEdge = null; ui.selected = n.id; render(n.id); }, 'arch-path'));
                });
                const sec = document.createElement('h5'); sec.textContent = 'Why this link exists'; d.appendChild(sec);
                if (edge.kind === 'related') {
                    const why = document.createElement('p'); why.className = 'arch-answer';
                    why.textContent = (edge.label ? edge.label + ' ' : '') + '(related content found by the AI while annotating the book)';
                    d.appendChild(why);
                    return;
                }
                const note = (ui.payload.edgeNotes || {})[edge.view + '|' + edge.source + '|' + edge.target];
                const p = document.createElement('p'); p.className = 'arch-answer';
                p.textContent = note && note.text ? note.text : 'The AI is reading the code behind this link\u2026';
                d.appendChild(p);
                if (note && note.pending) { const w = document.createElement('p'); w.className = 'arch-muted'; w.textContent = 'Working\u2026'; d.appendChild(w); }
                if (note && !note.pending) {
                    d.appendChild(linkButton('Explain again', function() {
                        post('explainEdge', { view: edge.view, source: edge.source, target: edge.target, kind: edge.kind, label: edge.label || undefined, again: true });
                    }, 'arch-action'));
                }
                if (note && note.evidence && note.evidence.length) {
                    const ev = document.createElement('h5'); ev.textContent = 'Code behind it'; d.appendChild(ev);
                    note.evidence.forEach(function(line) {
                        const m = /^(.*?):(\d+): (.*)$/.exec(line);
                        if (!m) return;
                        const b2 = linkButton(m[1].split('/').pop() + ':' + m[2] + '  ' + m[3], function() {
                            post('openFile', { path: m[1], line: parseInt(m[2], 10), endLine: parseInt(m[2], 10) });
                        }, 'arch-path');
                        b2.title = m[1] + ':' + m[2];
                        d.appendChild(b2);
                    });
                }
            }

            /** The ⚡ search as a question answered: the answer, then the flow step by step. */
            function revealUnderstandingSource(source) {
                if (source.kind === 'document' || source.kind === 'commit' || source.kind === 'pr') {
                    post('openUnderstandingSource', { filter: currentFilter().id, source: source.id });
                    return;
                }
                const views = (ui.payload.snapshot || {}).views || [];
                let view;
                let node;
                if (source.kind === 'component') {
                    view = views.find(function(v) { return v.id === 'logical'; });
                    node = view && view.nodes.find(function(n) { return n.id === 'l:c:' + source.target; });
                } else if (source.kind === 'deployment') {
                    view = views.find(function(v) { return v.id === 'deployment'; });
                    node = view && view.nodes.find(function(n) { return n.id.slice(2) === source.target; });
                } else {
                    // Prefer the current logical view; Structure also covers files that
                    // have not yet been assigned to a logical component.
                    view = views.find(function(v) {
                        return v.id === ui.view && v.nodes.some(function(n) { return n.path === source.path && n.kind === 'file'; });
                    }) || views.find(function(v) { return v.id === 'modules'; });
                    node = view && view.nodes.find(function(n) { return n.path === source.path && n.kind === 'file'; });
                }
                if (!node) {
                    // A file changed since the answer: still let the user inspect it.
                    if (source.kind === 'code') post('openFile', { path: source.path, line: source.start, endLine: source.end, fromSearch: true });
                    return;
                }
                ui.onlyFlagged = false;
                ui.selectedEdge = null;
                ui.hidden.clear();
                window.architectureFocus(node.id, view.id);
                renderToolbar();
            }

            /** Primary answer stays above node/edge details, with its own readable scroll area. */
            function renderUnderstanding(d, filter, result) {
                const panel = document.createElement('section'); panel.className = 'arch-understanding'; d.appendChild(panel);
                const heading = document.createElement('h4'); heading.textContent = 'Answer'; panel.appendChild(heading);
                const question = document.createElement('p'); question.className = 'arch-question'; question.textContent = result.question; panel.appendChild(question);
                if ((result.attachments || []).length) {
                    const attached = document.createElement('p'); attached.className = 'arch-muted';
                    attached.textContent = 'Attachments: ' + result.attachments.map(function(path) { return path.split('/').pop(); }).join(', ');
                    panel.appendChild(attached);
                }
                const actions = document.createElement('div'); actions.className = 'arch-understanding-actions'; panel.appendChild(actions);
                if (result.state === 'ready' && result.answer) {
                    const save = linkButton('Save as research', function() { post('saveSearchAnswer', { filter: filter.id }); }, 'arch-action');
                    save.disabled = result.saveMessage === 'Saving…'; actions.appendChild(save);
                } else if (result.state === 'failed') {
                    actions.appendChild(linkButton('Retry', function() { post('retryUnderstanding', { filter: filter.id }); }, 'arch-action'));
                }
                actions.appendChild(linkButton('Close this search', function() { post('deleteFilter', { id: filter.id }); ui.overlay = 'none'; }, 'arch-action'));
                if (result.saveMessage) { const saved = document.createElement('p'); saved.className = 'arch-muted'; saved.textContent = result.saveMessage; panel.appendChild(saved); }
                const body = document.createElement('div'); body.className = 'arch-understanding-body'; panel.appendChild(body);
                if (result.state !== 'ready' || !result.answer) {
                    const message = document.createElement('p'); message.setAttribute('role', 'status');
                    message.className = result.state === 'failed' ? 'arch-error' : 'arch-working';
                    message.textContent = result.state === 'failed' ? 'Could not answer: ' + (result.message || 'The AI returned an empty answer.') : (result.message || 'Reading the project…');
                    body.appendChild(message);
                    return;
                }
                const answer = result.answer;
                const sources = new Map((answer.sources || []).map(function(s) { return [s.id, s]; }));
                function evidenceButton(source, text) {
                    const b = linkButton(text, function() { revealUnderstandingSource(source); }, 'arch-path');
                    b.title = source.kind + ': ' + (source.path ? source.path + ':' + source.start : source.target);
                    return b;
                }
                ['what', 'why', 'how', 'origin'].forEach(function(key) {
                    const section = answer[key]; if (!section) return;
                    const h = document.createElement('h5'); h.textContent = key[0].toUpperCase() + key.slice(1); body.appendChild(h);
                    const text = document.createElement('div'); text.className = 'arch-answer'; text.textContent = section.text; body.appendChild(text);
                    if (key === 'origin' && !answer.originFound) { const missing = document.createElement('p'); missing.className = 'arch-muted'; missing.textContent = 'No origin source found.'; body.appendChild(missing); }
                    (section.sources || []).forEach(function(id) { const source = sources.get(id); if (source) body.appendChild(evidenceButton(source, '[' + id + '] ' + source.label)); });
                });
                if (sources.size) {
                    const h = document.createElement('h5'); h.textContent = 'Sources'; body.appendChild(h);
                    sources.forEach(function(source) { body.appendChild(evidenceButton(source, '[' + source.id + '] ' + source.label)); });
                }
            }

            function renderSearchAnswer(d, filter, answer) {
                const h = document.createElement('h4'); h.textContent = answer.question || filter.name; d.appendChild(h);
                if (answer.answer) {
                    const p = document.createElement('div'); p.className = 'arch-answer';
                    p.textContent = answer.answer;
                    d.appendChild(p);
                } else {
                    const summary = (ui.payload.searchSummaries || {})[filter.id];
                    if (summary) { const p = document.createElement('p'); p.textContent = summary; d.appendChild(p); }
                }
                (answer.steps || []).forEach(function(step) {
                    if (!step.places || !step.places.length) return;
                    const sec = document.createElement('h5'); sec.textContent = step.title; d.appendChild(sec);
                    step.places.forEach(function(place) {
                        const b = linkButton(place.path.split('/').pop() + ':' + place.start + '  ' + place.title, function() {
                            post('openFile', { path: place.path, line: place.start, endLine: place.end, fromSearch: true });
                        }, 'arch-path');
                        b.title = place.path + ':' + place.start + '\u2013' + place.end + '\n' + place.why;
                        d.appendChild(b);
                        if (place.why) { const w = document.createElement('div'); w.className = 'arch-muted arch-why'; w.textContent = place.why; d.appendChild(w); }
                    });
                });
                const active = filter;
                const save = linkButton('Save to docs/research', function() { post('saveSearchAnswer', { filter: active.id }); }, 'arch-action');
                save.title = 'Keep this answer and its places as a Markdown document';
                d.appendChild(save);
                d.appendChild(linkButton('Close this search', function() {
                    post('deleteFilter', { id: active.id }); ui.overlay = 'none';
                }, 'arch-action'));
            }

            function renderAsk(d, path) {
                const pr = ui.payload.pr;
                const chat = (pr.chat || []).filter(function(entry) { return (entry.path || null) === (path || null); });
                if (chat.length) {
                    const box = document.createElement('div'); box.className = 'arch-chat';
                    chat.forEach(function(entry) {
                        const q = document.createElement('div'); q.className = 'q'; q.textContent = entry.question; box.appendChild(q);
                        const a = document.createElement('div'); a.className = 'a';
                        a.textContent = entry.answer || (entry.pending ? 'Thinking…' : '');
                        if (entry.pending && entry.answer) a.textContent += ' …';
                        box.appendChild(a);
                    });
                    d.appendChild(box);
                }
                const form = document.createElement('form'); form.className = 'arch-ask';
                const input = document.createElement('textarea');
                input.placeholder = path ? 'Ask AI about this file\u2019s changes…' : 'Ask AI about this change…';
                input.rows = 2;
                const send = document.createElement('button'); send.type = 'submit'; send.className = 'arch-btn'; send.textContent = 'Ask';
                form.appendChild(input); form.appendChild(send);
                // The panel is redrawn while answers stream in: keep what is being typed, and the focus.
                const key = path || '*';
                ui.askDraft = ui.askDraft || {};
                input.value = ui.askDraft[key] || '';
                input.addEventListener('input', function() { ui.askDraft[key] = input.value; });
                input.addEventListener('focus', function() { ui.askFocus = key; });
                input.addEventListener('blur', function() { if (ui.askFocus === key) ui.askFocus = null; });
                if (ui.askFocus === key) setTimeout(function() { input.focus(); input.selectionStart = input.selectionEnd = input.value.length; }, 0);
                const submit = function(e) {
                    if (e) e.preventDefault();
                    const text = input.value.trim();
                    if (!text) return;
                    ui.askDraft[key] = '';
                    post('askPR', { question: text, path: path || '' });
                };
                form.addEventListener('submit', submit);
                input.addEventListener('keydown', function(e) { if (e.key === 'Enter' && !e.shiftKey) submit(e); });
                d.appendChild(form);
            }

            /** One changed file: its diff (click a line to open it there), the review, questions. */
            function renderPRFile(d, path) {
                const pr = ui.payload.pr;
                const f = pr.files.find(function(x) { return x.path === path; });
                const h = document.createElement('h4'); h.textContent = path.split('/').pop(); d.appendChild(h);
                const sub = document.createElement('div'); sub.className = 'arch-muted';
                sub.textContent = path + '  +' + f.additions + ' −' + f.deletions; d.appendChild(sub);
                d.appendChild(linkButton('Open file', function() { openPRFile(path); }, 'arch-action'));
                renderChangeExplanation(d, f);
                if (f.summary || (f.findings || []).length) d.appendChild(changeRow(f));
                renderDiffBox(d, path, null);
                const sec = document.createElement('h5'); sec.textContent = 'Ask AI'; d.appendChild(sec);
                renderAsk(d, path);
            }

            /** The AI's reading of a file's change; asked for the first time the file is shown. */
            function renderChangeExplanation(d, f) {
                const p = document.createElement('p');
                if (f.changeSummary) {
                    p.textContent = f.changeSummary;
                } else if (f.explaining) {
                    p.className = 'arch-muted'; p.textContent = 'Explaining the changes…';
                } else {
                    ui.explainRequested = ui.explainRequested || new Set();
                    const key = ui.payload.pr.source.id + '|' + f.path;
                    if (!ui.explainRequested.has(key)) { ui.explainRequested.add(key); post('explainPRFile', { path: f.path }); }
                    p.className = 'arch-muted'; p.textContent = 'Explaining the changes…';
                }
                d.appendChild(p);
            }

            /** A file's diff (click a line to open it there); `range` [from, to] keeps only
             *  the hunks around those new-file lines. */
            function renderDiffBox(d, path, range) {
                const pr = ui.payload.pr;
                const diff = pr.fileDiff && pr.fileDiff.path === path ? pr.fileDiff.text : null;
                if (diff == null) {
                    if (ui.diffRequested !== path) { ui.diffRequested = path; post('prFileDiff', { path: path }); }
                    const p = document.createElement('p'); p.className = 'arch-muted'; p.textContent = 'Loading the diff…'; d.appendChild(p);
                    return;
                }
                const box = document.createElement('div'); box.className = 'arch-diff';
                let newLine = 0;
                let hunk = null;
                diff.split('\n').forEach(function(line) {
                    const row = document.createElement('div');
                    const num = document.createElement('b');
                    if (line.indexOf('@@') === 0) {
                        const m = /\+(\d+)/.exec(line); newLine = m ? parseInt(m[1], 10) : newLine;
                        row.className = 'hunk'; row.textContent = line;
                        hunk = row;
                        if (!range) box.appendChild(row);
                        return;
                    }
                    let at = null;
                    if (line[0] === '+') { row.className = 'add'; at = newLine++; num.textContent = at; }
                    else if (line[0] === '-') { row.className = 'del'; }
                    else { at = newLine++; num.textContent = at; }
                    if (range) {
                        const position = at != null ? at : newLine;
                        if (position < range[0] || position > range[1]) return;
                        if (hunk) { box.appendChild(hunk); hunk = null; }
                    }
                    row.appendChild(num);
                    row.appendChild(document.createTextNode(line));
                    if (at != null) row.onclick = function() { post('openFile', { path: path, line: at, endLine: at }); };
                    box.appendChild(row);
                });
                d.appendChild(box);
            }

            /** The PR X-Ray's side panel: the AI's architectural reading, then the files. */
            function renderPRPanel(d, snap, idx) {
                const pr = ui.payload.pr;
                const h = document.createElement('h4'); h.textContent = pr ? pr.source.title : 'Pull request'; d.appendChild(h);
                if (!pr) {
                    const p = document.createElement('p');
                    p.textContent = 'Choose a pull request, your branch or your uncommitted changes above. The picture shows the parts of the X-Ray they touch; Analyze PR adds the AI\u2019s architectural review.';
                    d.appendChild(p);
                    return;
                }
                if (pr.info) renderPRHeader(d, pr.info);
                const a = pr.analysis;
                if (pr.reviewOutdated) {
                    const warn = document.createElement('p'); warn.className = 'arch-muted';
                    warn.textContent = 'The code changed since this review and analysis. Use Review again for a fresh one.';
                    d.appendChild(warn);
                }
                if (pr.analyzing) {
                    const p = document.createElement('p'); p.className = 'arch-muted'; p.textContent = 'Analysing the change…'; d.appendChild(p);
                } else if (!a) {
                    d.appendChild(linkButton('Analyze PR (AI)', function() { post('analyzePR'); }, 'arch-action'));
                }
                if (a) {
                    const verdict = document.createElement('div'); verdict.className = 'arch-badges';
                    const chip = document.createElement('span');
                    chip.textContent = { approve: 'looks good', attention: 'needs attention', risky: 'risky' }[a.verdict] || a.verdict;
                    verdict.appendChild(chip); d.appendChild(verdict);
                    const p = document.createElement('p'); p.textContent = a.summary; d.appendChild(p);
                    if (a.impact.length) {
                        const sec = document.createElement('h5'); sec.textContent = 'Impact'; d.appendChild(sec);
                        const names = new Map((snap.components || []).map(function(comp) { return [comp.id, comp.name]; }));
                        a.impact.forEach(function(i) {
                            const row = linkButton((names.get(i.component) || i.component || 'Other') + ' · ' + i.risk + ' — ' + i.note, function() {
                                ui.selected = 'l:c:' + i.component; render('l:c:' + i.component);
                            });
                            d.appendChild(row);
                        });
                    }
                    if (a.risks.length) {
                        const sec = document.createElement('h5'); sec.textContent = 'Risks'; d.appendChild(sec);
                        const list = document.createElement('ul');
                        a.risks.forEach(function(r) { const li = document.createElement('li'); li.textContent = r; list.appendChild(li); });
                        d.appendChild(list);
                    }
                    if (a.checks.length) {
                        const sec = document.createElement('h5'); sec.textContent = 'What to check'; d.appendChild(sec);
                        a.checks.forEach(function(check) {
                            d.appendChild(linkButton(check.path.split('/').pop() + (check.line ? ':' + check.line : '') + ' — ' + check.note, function() {
                                post('openFile', { path: check.path, line: check.line || undefined });
                            }));
                        });
                    }
                }
                renderPRTasks(d, pr);
                const ask = document.createElement('h5'); ask.textContent = 'Ask AI'; d.appendChild(ask);
                renderAsk(d, null);
                const deps = pr.dependencies || [];
                if (deps.length) {
                    const sec = document.createElement('h5'); sec.textContent = 'Links'; d.appendChild(sec);
                    deps.forEach(function(dep) {
                        const p = document.createElement('div'); p.className = 'arch-muted';
                        p.textContent = (dep.change === 'added' ? '+ ' : '− ') + dep.source.split('/').pop() + ' → ' + dep.target.split('/').pop();
                        d.appendChild(p);
                    });
                }
                const sec = document.createElement('h5'); sec.textContent = pr.files.length + ' changed files'; d.appendChild(sec);
                if (pr.reviewSummary) { const p = document.createElement('p'); p.textContent = pr.reviewSummary; d.appendChild(p); }
                pr.files.forEach(function(f) { d.appendChild(changeRow(f)); });
            }

            /** What the review and the analysis found, as tasks: into the AI terminal (typed,
             *  not sent) or the clipboard. */
            function renderPRTasks(d, pr) {
                let count = 0;
                pr.files.forEach(function(f) {
                    const findings = (f.findings || []).filter(function(x) { return !x.dismissed; }).length;
                    count += findings || (f.verdict && f.verdict !== 'ok' && f.summary ? 1 : 0);
                });
                if (pr.analysis) count += pr.analysis.checks.length + pr.analysis.risks.length;
                if (!count) return;
                const sec = document.createElement('h5'); sec.textContent = count + (count === 1 ? ' task' : ' tasks') + ' found'; d.appendChild(sec);
                const row = document.createElement('div'); row.className = 'arch-task-actions';
                const send = linkButton('Send to terminal', function() { post('prTasksToTerminal'); }, 'arch-action');
                send.title = 'Type the list at the AI terminal prompt (not sent: check it and press Enter)';
                const copy = linkButton('Copy', function() {
                    post('copyPRTasks');
                    copy.textContent = 'Copied'; setTimeout(function() { copy.textContent = 'Copy'; }, 1500);
                }, 'arch-action');
                copy.title = 'Copy the list as markdown tasks';
                const fixAll = linkButton('\u2726 Fix all', function() { post('prFixAll'); }, 'arch-action');
                fixAll.title = 'Send every task to the AI terminal and let it fix them (a GitHub pull request is checked out first)';
                row.appendChild(fixAll); row.appendChild(send); row.appendChild(copy);
                d.appendChild(row);
            }

            /** The pull request on GitHub: state, checks, review decision, and what to do with it.
             *  The comment typed for a review is kept in `ui` so re-renders do not lose it. */
            function renderPRHeader(d, info) {
                const box = document.createElement('div'); box.className = 'arch-pr-header';
                const badges = document.createElement('div'); badges.className = 'arch-badges';
                function badge(text, cls) { const s = document.createElement('span'); s.textContent = text; if (cls) s.className = cls; badges.appendChild(s); }
                badge(info.isDraft ? 'draft' : info.state.toLowerCase(), info.state === 'OPEN' ? 'arch-ok' : '');
                if (info.checksTotal) {
                    badge((info.checksFailed ? '\u2717 ' : info.checksPassed === info.checksTotal ? '\u2713 ' : '\u25CF ')
                        + info.checksPassed + '/' + info.checksTotal + ' checks',
                        info.checksFailed ? 'arch-bad' : info.checksPassed === info.checksTotal ? 'arch-ok' : 'arch-warn');
                }
                const decision = { APPROVED: 'approved', CHANGES_REQUESTED: 'changes requested', REVIEW_REQUIRED: 'review required' }[info.reviewDecision];
                if (decision) badge(decision, info.reviewDecision === 'APPROVED' ? 'arch-ok' : 'arch-warn');
                if (info.mergeable === 'CONFLICTING') badge('conflicts', 'arch-bad');
                box.appendChild(badges);
                const meta = document.createElement('div'); meta.className = 'arch-muted';
                meta.textContent = (info.author ? info.author + ' \u00B7 ' : '') + info.head + ' \u2192 ' + info.base;
                box.appendChild(meta);
                if (info.state === 'OPEN') {
                    // The comment belongs to this pull request, survives the panel's redraws (keeping
                    // the focus while typing) and is cleared only once GitHub took it.
                    ui.prNotes = ui.prNotes || {};
                    ui.prNoteSent = ui.prNoteSent || {};
                    const key = String(info.number);
                    if (ui.prNoteSent[key] && !info.busy && info.message) {
                        if (info.ok) ui.prNotes[key] = '';
                        ui.prNoteSent[key] = false;
                    }
                    const note = document.createElement('textarea'); note.className = 'arch-pr-note';
                    note.placeholder = 'Review comment (optional for Approve)';
                    note.value = ui.prNotes[key] || '';
                    note.addEventListener('input', function() { ui.prNotes[key] = note.value; });
                    note.addEventListener('focus', function() { ui.prNoteFocus = key; });
                    note.addEventListener('blur', function() { if (ui.prNoteFocus === key) ui.prNoteFocus = null; });
                    note.addEventListener('select', function() { ui.prNoteCaret = [note.selectionStart, note.selectionEnd]; });
                    note.addEventListener('keyup', function() { ui.prNoteCaret = [note.selectionStart, note.selectionEnd]; });
                    note.addEventListener('click', function() { ui.prNoteCaret = [note.selectionStart, note.selectionEnd]; });
                    if (ui.prNoteFocus === key) setTimeout(function() {
                        note.focus();
                        const caret = ui.prNoteCaret || [note.value.length, note.value.length];
                        note.selectionStart = caret[0]; note.selectionEnd = caret[1];
                    }, 0);
                    box.appendChild(note);
                    const row = document.createElement('div'); row.className = 'arch-task-actions';
                    function act(label, op, needsText, title) {
                        const b = linkButton(label, function() {
                            const body = (ui.prNotes[key] || '').trim();
                            if (needsText && !body) { note.focus(); note.placeholder = 'Write what should change first'; return; }
                            ui.prNoteSent[key] = true;
                            post('prAction', { op: op, body: body, method: ui.prMergeMethod || 'squash' });
                        }, 'arch-action');
                        if (title) b.title = title;
                        if (info.busy) b.disabled = true;
                        row.appendChild(b);
                    }
                    act('Approve', 'approve', false);
                    act('Request changes', 'requestChanges', true);
                    act('Comment', 'comment', true);
                    box.appendChild(row);
                    const mergeRow = document.createElement('div'); mergeRow.className = 'arch-task-actions';
                    const method = document.createElement('select'); method.className = 'arch-pr-method';
                    [['squash', 'Squash and merge'], ['merge', 'Merge commit'], ['rebase', 'Rebase and merge']].forEach(function(m) {
                        const o = document.createElement('option'); o.value = m[0]; o.textContent = m[1]; method.appendChild(o);
                    });
                    method.value = ui.prMergeMethod || 'squash';
                    method.onchange = function() { ui.prMergeMethod = method.value; };
                    // Merge and close ask for a second click within 4 s (kept in `ui` across redraws).
                    function armed(op) { return ui.prArmed && ui.prArmed.key === key + op && Date.now() < ui.prArmed.until; }
                    function confirmed(op, button, again, label, send) {
                        return linkButton(armed(op) ? again : label, function() {
                            if (!armed(op)) {
                                ui.prArmed = { key: key + op, until: Date.now() + 4000 };
                                button.self.textContent = again;
                                setTimeout(function() { if (button.self.isConnected && !armed(op)) button.self.textContent = label; }, 4100);
                                return;
                            }
                            ui.prArmed = null;
                            send();
                        }, 'arch-action');
                    }
                    const mergeRef = {}, closeRef = {};
                    const merge = confirmed('merge', mergeRef, 'Click again to merge', 'Merge', function() {
                        post('prAction', { op: 'merge', method: method.value });
                    });
                    mergeRef.self = merge;
                    if (info.busy || info.mergeable === 'CONFLICTING') merge.disabled = true;
                    const close = confirmed('close', closeRef, 'Click again to close', 'Close PR', function() {
                        post('prAction', { op: 'close' });
                    });
                    closeRef.self = close;
                    mergeRow.appendChild(method); mergeRow.appendChild(merge); mergeRow.appendChild(close);
                    box.appendChild(mergeRow);
                }
                const open = linkButton('Open on GitHub \u2197', function() { post('openURL', { url: info.url }); }, 'arch-action');
                box.appendChild(open);
                if (info.busy) { const p = document.createElement('p'); p.className = 'arch-muted'; p.textContent = 'Working\u2026'; box.appendChild(p); }
                if (info.message) { const p = document.createElement('p'); p.className = 'arch-muted'; p.textContent = info.message; box.appendChild(p); }
                d.appendChild(box);
            }

            /** One review finding with what can be done about it. */
            function findingRow(f, finding, index) {
                const pr = ui.payload && ui.payload.pr;
                const wrap = document.createElement('div');
                wrap.className = 'arch-finding-box' + (finding.dismissed ? ' arch-dismissed' : '');
                const b = linkButton('L' + finding.line + ' \u00B7 ' + finding.message, function() {
                    post('openFile', { path: f.path, line: finding.line, endLine: finding.line });
                }, 'arch-finding arch-' + finding.severity);
                wrap.appendChild(b);
                const row = document.createElement('div'); row.className = 'arch-finding-actions';
                const fields = { path: f.path, index: index };
                function act(label, action, title) {
                    const a = linkButton(label, function() { post(action, fields); });
                    a.title = title; row.appendChild(a); return a;
                }
                if (!finding.dismissed) {
                    act('\u2726 Fix it', 'prFindingFix', 'Send to the AI terminal to fix (a GitHub pull request is checked out first)');
                    const ex = act(finding.explaining ? 'Explaining\u2026' : '\u2726 Explain', 'prFindingExplain', 'Why this is a problem and how to fix it');
                    if (finding.explaining) ex.disabled = true;
                    if (pr && pr.info) {
                        const c = act(finding.commented ? '\u2713 Commented' : 'Comment on PR', 'prFindingComment', 'Post as a review comment on this line');
                        if (finding.commented) c.disabled = true;
                        if (finding.issueURL) {
                            act('Issue \u2197', 'openURL', 'Open the issue created from this finding');
                            fields.url = finding.issueURL;
                        } else {
                            act('+ Issue', 'prFindingIssue', 'Create a GitHub issue from this finding');
                        }
                    }
                }
                act(finding.dismissed ? 'Restore' : '\u2715 Dismiss', 'prFindingDismiss', finding.dismissed ? 'Show it again' : 'Not a real problem: hide it and leave it out of the tasks');
                wrap.appendChild(row);
                if (finding.explanation && !finding.dismissed) {
                    const p = document.createElement('p'); p.className = 'arch-finding-explanation'; p.textContent = finding.explanation;
                    wrap.appendChild(p);
                }
                return wrap;
            }

            function changeRow(f) {
                const c = palette();
                const wrap = document.createElement('div'); wrap.className = 'arch-change';
                const head = document.createElement('button'); head.className = 'arch-link arch-path';
                const dot = document.createElement('i');
                dot.style.background = f.verdict === 'bug' ? c.bad : f.verdict === 'concern' ? c.warn : f.verdict === 'ok' ? c.ok : c.info;
                head.appendChild(dot);
                head.appendChild(document.createTextNode(f.path + (f.deleted ? '  removed −' + f.deletions : '  +' + f.additions + ' −' + f.deletions)));
                head.onclick = function() { openPRFile(f.path); };
                wrap.appendChild(head);
                if (f.summary) { const p = document.createElement('p'); p.textContent = f.summary; wrap.appendChild(p); }
                (f.findings || []).forEach(function(finding, index) { wrap.appendChild(findingRow(f, finding, index)); });
                return wrap;
            }

            /** Rebuild the "AI filters" group of the overlay menu from the payload. */
            function renderFilterOptions() {
                const old = el.overlay.querySelector('optgroup[data-ai]');
                if (old) old.remove();
                const group = document.createElement('optgroup');
                group.label = 'AI filters'; group.setAttribute('data-ai', '1');
                aiFilters().forEach(function(f) {
                    const o = document.createElement('option'); o.value = 'ai:' + f.id; o.textContent = f.name;
                    group.appendChild(o);
                });
                const add = document.createElement('option'); add.value = '__new__'; add.textContent = '＋ New filter…';
                group.appendChild(add);
                el.overlay.appendChild(group);
            }

            function renderNewFilterForm() {
                const d = el.details;
                d.textContent = '';
                const h = document.createElement('h4'); h.textContent = 'New AI filter'; d.appendChild(h);
                const p = document.createElement('p'); p.className = 'arch-muted';
                p.textContent = 'A few words are enough. The AI rates every part against it as you zoom in: strong, moderate, weak or none.';
                d.appendChild(p);
                const criterion = document.createElement('textarea'); criterion.rows = 3; criterion.style.width = '100%';
                criterion.placeholder = 'A topic or a question, e.g. "payment flow" or "What handles user sessions?"';
                const name = document.createElement('input'); name.placeholder = 'Name (optional)'; name.style.width = '100%';
                const create = document.createElement('button'); create.className = 'arch-btn'; create.textContent = 'Create filter';
                create.onclick = function() {
                    const text = criterion.value.trim();
                    if (!text) return;
                    const label = name.value.trim() || (text.length > 28 ? text.slice(0, 28) + '…' : text);
                    ui.pendingFilterName = label;
                    post('createFilter', { name: label, criterion: text });
                };
                [criterion, name, create].forEach(function(e) { e.style.marginTop = '6px'; d.appendChild(e); });
                criterion.focus();
            }

            function renderToolbar() {
                const p = ui.payload || {};
                // A one-off filter just typed becomes the overlay once Swift knows it.
                const temp = (p.filters || []).find(function(f) { return f.id.indexOf('tmp-') === 0; });
                if (ui.pendingTemp && temp && temp.criterion === ui.pendingTemp) { ui.overlay = 'ai:' + temp.id; ui.pendingTemp = null; }
                if (!temp && ui.overlay.indexOf('ai:tmp-') === 0) ui.overlay = 'none';
                // A search started outside the X-Ray (Explain with AI on a code element).
                if (p.activateFilter && p.activateFilter !== ui.activatedFilter) {
                    ui.activatedFilter = p.activateFilter;
                    const id = p.activateFilter.split('|')[0];
                    if ((p.filters || []).some(function(f) { return f.id === id; })) ui.overlay = 'ai:' + id;
                    if ((p.understandingAnswers || {})[id]) {
                        setDetailsHidden(false, false);
                        el.details.scrollTop = 0;
                        ui.selected = null; ui.selectedEdge = null;
                        ui.onlyFlagged = false;
                    }
                }
                el.tempFilter.querySelector('button').hidden = !temp;
                if (temp && document.activeElement !== el.tempFilter.querySelector('input')) el.tempFilter.querySelector('input').value = temp.criterion;
                // A just-created filter becomes the active overlay.
                if (ui.pendingFilterName) {
                    const made = (p.filters || []).find(function(f) { return f.name === ui.pendingFilterName; });
                    if (made) { ui.overlay = 'ai:' + made.id; ui.pendingFilterName = null; }
                }
                renderFilterOptions();
                el.views.forEach(function(b) { b.classList.toggle('on', b.getAttribute('data-arch-view') === ui.view); });
                // Code metrics colour nothing in the Book: say so instead of offering them.
                const codeOnly = { coverage: 1, tests: 1, bugs: 1, complexity: 1, pr: 1 };
                Array.prototype.forEach.call(el.overlay.options, function(o) {
                    if (!codeOnly[o.value]) return;
                    o.disabled = isBook();
                    o.title = isBook() ? 'About code; in the Book use Importance, an AI filter, Freshness or Size' : '';
                });
                el.overlay.value = ui.overlay;
                el.overlay.disabled = ui.view === 'deployment' && !isSearch(currentFilter());
                // The ⚡ box asks a question in every view: the answer with its sources appears on
                // the right, and what it rests on turns red.
                const ask = el.tempFilter.querySelector('input');
                ask.placeholder = isBook() ? '⚡ Ask the book, e.g. how is a release published?' : '⚡ Ask the project, e.g. how is a plant identified?';
                el.tempFilter.title = 'Ask a question: the answer (what, why, how, where it comes from) with its sources appears on the right; the documents, sections and files it rests on turn red';
                el.flagged.checked = ui.onlyFlagged;
                el.flagged.parentElement.hidden = !overlayApplies() || ui.overlay === 'size';
                el.hide.hidden = !codeViews[ui.view];
                const sources = p.prSources || [];
                const selected = p.pr ? p.pr.source.id : '';
                el.prSource.textContent = '';
                const placeholder = document.createElement('option');
                placeholder.value = ''; placeholder.textContent = sources.length ? 'Choose a change…' : 'No git changes found';
                el.prSource.appendChild(placeholder);
                sources.forEach(function(s) {
                    const o = document.createElement('option'); o.value = s.id; o.textContent = s.title;
                    if (s.id === selected) o.selected = true;
                    el.prSource.appendChild(o);
                });
                const prTab = p.mode === 'pr';
                const prMode = prTab || (overlayApplies() && ui.overlay === 'pr');
                el.views[0].parentElement.hidden = prTab;
                el.overlay.hidden = prTab;
                el.tempFilter.hidden = prTab;
                el.hide.hidden = el.hide.hidden || prTab;
                el.flagged.parentElement.hidden = el.flagged.parentElement.hidden || prTab;
                el.prOpen.hidden = prTab;
                el.analyzePR.hidden = !prTab;
                el.prNumber.hidden = !prTab;
                el.analyzePR.disabled = !p.pr || !!(p.pr && p.pr.analyzing);
                el.analyzePR.textContent = p.pr && p.pr.analyzing ? 'Analysing…' : p.pr && p.pr.analysis ? 'Analyze again' : 'Analyze PR';
                el.prSource.hidden = !prMode;
                el.review.hidden = !prMode;
                el.review.disabled = !p.pr || p.busy;
                // After a review: the code may have changed — read it again and review anew.
                el.review.textContent = p.pr && p.pr.reviewed ? 'Review again' : 'Review with AI';
                el.review.title = p.pr && p.pr.reviewed
                    ? 'Reload the change as it is now and review it again (no cached answers)'
                    : 'AI review of every changed file';
                el.analyze.disabled = !!p.busy || !p.snapshot;
                el.rescan.disabled = !!p.busy;
                renderDeployButton();
                // The progress bar shows the analysis; the status line covers everything else.
                const codeOverlayInBook = isBook() && codeOnly[ui.overlay] ? 'This overlay is about code. In the Book use Importance, an AI filter, Freshness or Size.' : '';
                const statusText = p.error || (ui.progress ? '' : p.status) || codeOverlayInBook || '';
                el.status.textContent = statusText;
                el.status.className = p.error ? 'arch-error' : (statusText ? 'arch-working' : '');
            }

            // ------------------------------------------------------------ lifecycle

            function enter() {
                if (typeof leaveInsightView === 'function') leaveInsightView();
                if (typeof window.leaveCanvasView === 'function') window.leaveCanvasView();
                if (typeof window.leaveCodeView === 'function') window.leaveCodeView();
                state.mode = 'architecture';
                DOM.editorPane.style.display = 'none';
                DOM.previewPane.style.display = 'none';
                document.getElementById('wysiwyg-toolbar').style.display = 'none';
                document.body.classList.add('arch-mode');
                container.classList.add('visible');
                if (DOM.statusMode) DOM.statusMode.textContent = 'X-RAY';
            }

            /** Expand the path down to `id` and zoom to it (used for "reveal module"). */
            window.architectureFocus = function(id, viewId) {
                if (viewId && viewId !== ui.view) { ui.view = viewId; ui.graphKey = null; }
                const view = currentView(); if (!view) return false;
                const idx = indexView(view);
                let node = idx.byId.get(id); if (!node) return false;
                const expanded = ui.expanded[ui.view];
                if ((idx.children.get(id) || []).length) expanded.add(id);
                let parent = node.parent != null ? idx.byId.get(node.parent) : null;
                while (parent) { expanded.add(parent.id); parent = parent.parent != null ? idx.byId.get(parent.parent) : null; }
                ui.focus[ui.view] = (idx.children.get(id) || []).length ? id : node.parent;
                ui.selected = id;
                render(id);
                return true;
            };

            window.leaveArchitectureView = function() {
                if (!container.classList.contains('visible')) return;
                container.classList.remove('visible');
                document.body.classList.remove('arch-mode');
                document.getElementById('wysiwyg-toolbar').style.display = '';
            };

            /** Another X-Ray (the project's or a folder's) in the same web view: start fresh. */
            function resetForRoot(root) {
                ui.root = root;
                ui.operations = null;
                Object.keys(ui.expanded).forEach(function(k) { ui.expanded[k].clear(); });
                Object.keys(ui.focus).forEach(function(k) { ui.focus[k] = null; });
                ui.selected = null;
                ui.graphKey = null;
                ui.ratingRequested.clear();
                ui.describeRequested.clear();
                ui.userNavigated = false;
            }

            window.showArchitecture = function(payload) {
                enter();
                ui.payload = payload || {};
                if ((ui.payload.root || null) !== ui.root) resetForRoot(ui.payload.root || null);
                // The PR X-Ray tab shows one view: the change inside the X-Ray.
                if (ui.payload.mode === 'pr') {
                    ui.view = 'pr';
                    ui.overlay = 'pr';
                    ui.prView = buildPRView(ui.payload.snapshot, ui.payload.pr);
                    if (ui.prView) ui.prView.nodes.forEach(function(n) {
                        if (ui.prView.nodes.some(function(k) { return k.parent === n.id; })) ui.expanded.pr.add(n.id);
                    });
                } else if (ui.view === 'pr') {
                    ui.view = 'logical';
                    ui.overlay = 'none';
                }
                renderToolbar();
                renderDetails();
                const snap = ui.payload.snapshot;
                if (!snap) {
                    if (cy) cy.elements().remove();
                    return;
                }
                // No logical grouping yet: show the Structure view until the analysis lands.
                if (!ui.viewChosen && ui.view === 'logical' && !snap.views.some(function(v) { return v.id === 'logical'; })) {
                    ui.view = 'modules';
                    ui.graphKey = null;
                    renderToolbar();
                }
                loadLibraries().then(function() {
                    ensureCy();
                    // The structure grows live during an analysis: redraw when it changes.
                    const shape = (snap.components || []).map(function(c) { return c.id + '<' + c.parent; }).join(',')
                        + '|' + Object.keys(snap.assignments || {}).length
                        + '|' + snap.views.map(function(v) { return v.id + ':' + v.nodes.length; }).join(',');
                    const pr = ui.payload.pr;
                    const prShape = ui.view === 'pr' && pr ? '|' + pr.source.id + ':' + pr.files.length + ':' + (pr.dependencies || []).length + ':' + !!pr.analysis
                        // Changes inside files arrive later (the AI's explanation).
                        + ':' + pr.files.map(function(f) { return (f.changes || []).length + (f.changeSummary ? 'e' : ''); }).join(',') : '';
                    const key = ui.view + '|' + snap.scannedAt + '|' + (snap.enrichedAt || '') + '|' + shape + prShape;
                    if (key !== ui.graphKey) autoExpand(snap);
                    if (key !== ui.graphKey) { ui.graphKey = key; render(); } else { restyle(); renderToolbar(); }
                }).catch(function(error) {
                    el.status.textContent = 'Architecture view failed to load: ' + error.message;
                    el.status.className = 'arch-error';
                });
            };

            el.views.forEach(function(b) {
                b.addEventListener('click', function() {
                    ui.view = b.getAttribute('data-arch-view');
                    ui.viewChosen = true;
                    ui.selected = null;
                    if (ui.view === 'deployment' && !isSearch(currentFilter())) ui.overlay = 'none';
                    ui.graphKey = null;
                    window.showArchitecture(ui.payload);
                });
            });
            el.deploy.addEventListener('click', function() {
                const deploys = visibleOperations().filter(function(o) { return o.kind === 'deploy'; });
                if (deploys.length === 1) {
                    const operation = deploys[0];
                    post(isOperationRunning(operation) ? 'operationOpen' : 'operationRun', { id: operation.id });
                } else if (deploys.length > 1) {
                    el.deployPicker.hidden = !el.deployPicker.hidden;
                    if (!el.deployPicker.hidden) el.deployPicker.focus();
                }
            });
            el.deployPicker.addEventListener('change', function() {
                const operation = visibleOperations().find(function(o) { return o.id === el.deployPicker.value; });
                if (!operation) return;
                post(isOperationRunning(operation) ? 'operationOpen' : 'operationRun', { id: operation.id });
                el.deployPicker.value = '';
                el.deployPicker.hidden = true;
            });
            el.overlay.addEventListener('change', function() {
                if (el.overlay.value === '__new__') { el.overlay.value = ui.overlay; renderNewFilterForm(); return; }
                ui.overlay = el.overlay.value;
                if (ui.overlay === 'pr') post('refreshPRSources');
                renderToolbar();
                // AI filters request ratings while building elements.
                if (ui.onlyFlagged || isAIFilter()) render(); else restyle();
            });
            el.prSource.addEventListener('change', function() {
                // In the PR X-Ray a new change is loaded and analysed; elsewhere it is only shown.
                if (ui.payload && ui.payload.mode === 'pr') post('openPRXRay', { source: el.prSource.value });
                else post('showPR', { source: el.prSource.value });
            });
            el.prOpen.addEventListener('click', function() {
                const current = ui.payload && ui.payload.pr ? ui.payload.pr.source.id : '';
                post('openPRXRay', { source: current });
            });
            el.analyzePR.addEventListener('click', function() {
                const pr = ui.payload && ui.payload.pr;
                // "Analyze again": a new answer, not the cached one.
                post('analyzePR', { again: !!(pr && pr.analysis) });
            });
            el.prNumber.addEventListener('submit', function(e) {
                e.preventDefault();
                const text = el.prNumber.querySelector('input').value.trim();
                if (text) post('openPRNumber', { text: text });
                el.prNumber.querySelector('input').value = '';
            });
            el.flagged.addEventListener('change', function() { ui.onlyFlagged = el.flagged.checked; render(); });
            el.hide.addEventListener('change', function() {
                ui.hidden = new Set(el.hide.value ? el.hide.value.split(',') : []);
                render();
            });
            // ------------------------------------------------------------ analysis progress

            let progressTimer = null;
            function clock(seconds) {
                seconds = Math.max(0, Math.round(seconds));
                return Math.floor(seconds / 60) + ':' + String(seconds % 60).padStart(2, '0');
            }
            function renderProgress() {
                const p = ui.progress;
                el.progress.hidden = !p;
                if (!p) { clearInterval(progressTimer); progressTimer = null; return; }
                const steps = el.progress.querySelector('.arch-progress-steps');
                steps.textContent = '';
                for (let i = 1; i <= p.steps; i++) {
                    const s = document.createElement('span');
                    // A step with countable work fills in; otherwise it pulses.
                    const counted = i === p.step && p.total > 0;
                    s.className = i < p.step ? 'done' : i === p.step ? (counted ? 'counted' : 'now') : '';
                    if (counted) {
                        const fill = document.createElement('b');
                        fill.style.width = Math.min(100, 100 * p.done / p.total) + '%';
                        s.appendChild(fill);
                    }
                    steps.appendChild(s);
                }
                el.progress.querySelector('.arch-progress-title').textContent =
                    (p.steps > 1 ? 'Step ' + p.step + ' of ' + p.steps + ': ' : '') + p.title + (p.scope ? ' · ' + p.scope : '')
                    + (p.assistant ? ' — ' + p.assistant : '');
                const now = Date.now();
                const stats = [clock((now - Date.parse(p.stepStartedAt)) / 1000)
                    + (p.steps > 1 ? ' (total ' + clock((now - Date.parse(p.startedAt)) / 1000) + ')' : '')];
                if (p.total > 0) stats.unshift(formatCount(p.done) + ' of ' + formatCount(p.total) + ' ' + (p.unit || ''));
                if (p.filesRead) stats.push(p.filesRead + (p.filesRead === 1 ? ' file read' : ' files read'));
                if (p.searches) stats.push(p.searches + (p.searches === 1 ? ' search' : ' searches'));
                if (p.answerChars) stats.push('result ' + formatCount(p.answerChars) + ' chars');
                el.progress.querySelector('.arch-progress-stats').textContent = stats.join(' · ');
                el.progress.querySelector('.arch-progress-current').textContent = p.current || 'Waiting for the assistant…';
                if (!progressTimer) progressTimer = setInterval(renderProgress, 1000);
            }

            /** Swift → JS: live analysis progress, or null when no analysis runs. */
            window.setArchitectureProgress = function(progress) {
                const stepChanged = !ui.progress || !progress || ui.progress.step !== progress.step;
                if (!ui.progress && progress && progress.steps > 1) ui.userNavigated = false;   // a new analysis
                ui.progress = progress || null;
                renderProgress();
                renderToolbar();
                if (stepChanged) renderEmpty();
            };

            window.setProjectOperations = function(value) {
                ui.operations = value || null;
                renderDeployButton();
                renderDetails();
            };

            el.stop.addEventListener('click', function() { el.stop.disabled = true; post('cancelAnalysis'); setTimeout(function() { el.stop.disabled = false; }, 1500); });
            // Details panel: drag its left edge to resize, "Details" in the toolbar to hide it.
            const archMain = el.details.parentElement;
            window.MVPanels.resizable({ handle: el.detailsResizer, panel: el.details, host: archMain, key: 'markview-xray-details-width',
                                        width: 280, reserve: 320, onResize: function() { if (cy) cy.resize(); } });
            function setDetailsHidden(hidden, save) {
                el.details.hidden = el.detailsResizer.hidden = hidden;
                el.detailsToggle.classList.toggle('on', !hidden);
                if (save) { try { localStorage.setItem('markview-xray-details-hidden', hidden ? '1' : ''); } catch (e) {} }
                if (cy) cy.resize();
            }
            const compactDetails = function() {
                const scale = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--ui-scale')) || 1;
                return window.innerWidth < 1100 || scale >= 1.5;
            };
            let detailsUserChoice = false;
            let detailsHidden = compactDetails();
            try {
                const saved = localStorage.getItem('markview-xray-details-hidden');
                if (saved !== null) { detailsHidden = saved === '1'; detailsUserChoice = true; }
            } catch (e) {}
            setDetailsHidden(detailsHidden, false);
            el.detailsToggle.addEventListener('click', function() {
                detailsUserChoice = true;
                setDetailsHidden(!el.details.hidden, true);
            });
            window.addEventListener('resize', function() {
                if (!detailsUserChoice) setDetailsHidden(compactDetails(), false);
            });

            function askBook(text) {
                ui.pendingTemp = text;
                ui.onlyFlagged = false;
                setDetailsHidden(false, false);
                post('askBook', { question: text });
            }
            el.tempFilter.addEventListener('submit', function(e) {
                e.preventDefault();
                const text = el.tempFilter.querySelector('input').value.trim();
                if (text) { askBook(text); return; }
                ui.pendingTemp = null;
                post('tempFilter', { criterion: '' });
            });
            el.tempFilter.querySelector('button').addEventListener('click', function() {
                el.tempFilter.querySelector('input').value = '';
                ui.pendingTemp = null;
                post('tempFilter', { criterion: '' });
            });

            el.review.addEventListener('click', function() {
                const pr = ui.payload && ui.payload.pr;
                post('reviewPR', { again: !!(pr && pr.reviewed) });
            });
            el.analyze.addEventListener('click', function() { post('analyze'); });
            el.rescan.addEventListener('click', function() { post('rescan'); });
            el.fit.addEventListener('click', function() { if (cy) cy.animate({ fit: { eles: cy.elements(), padding: 28 }, duration: 240 }); });

            // Other content types take over the editor area.
            ['setContent', 'setStructuredContent', 'setCodeContent'].forEach(function(name) {
                const original = window[name];
                if (typeof original !== 'function') return;
                window[name] = function() {
                    window.leaveArchitectureView();
                    return original.apply(this, arguments);
                };
            });
            const origSetTheme = window.setTheme;
            window.setTheme = function(theme) {
                origSetTheme(theme);
                if (cy) { cy.style(stylesheet()); restyle(); }
            };
        })();
