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

        // X-Ray tab, part 1 of 5: the tab's elements and state, library loading, the views (PR, book, code), overlays, ratings, labels and the graph elements.
        (function (A) {
            Object.assign(A, {
                ago, aiFilters, bookColor, bookImportance, bookText, buildElements, buildFullPRView, buildPRView,
                changeShown, codeOverview, currentFilter, currentView, descendantsFiles, expandedSet, fileKey,
                formatCount, hiddenTags, indexView, isAIFilter, isBook, isHidden, isSearch, isTransparent, kindLabel,
                levelColor, levelRank, loadLibraries, overlayApplies, overlayInfo, palette, post, prByNode, ratingOf,
                representative, scales, stateKey, undescribedChapters
            });

            const container = document.getElementById('arch-container');
            A.container = container;
            if (!container) return;
            A.ready = true;

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
                prMap: document.getElementById('arch-pr-map'),
                prDate: document.getElementById('arch-pr-date'),
                history: document.getElementById('arch-history'),
                historyDay: document.getElementById('arch-history-day'),
                historyList: document.getElementById('arch-history-list'),
                review: document.getElementById('arch-review'),
                analyze: document.getElementById('arch-analyze'),
                codeTrace: document.getElementById('arch-code-trace'),
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
            A.el = el;

            const ui = {
                payload: null,
                view: 'logical',
                codeQuestions: {},
                codeSequenceIndex: null,
                overlay: 'none',
                onlyFlagged: false,
                hidden: new Set(),
                codeHidden: new Set(),
                codeFilterInitialized: false,
                ratingRequested: new Set(),   // parents whose children were sent for AI importance
                describeRequested: new Set(),
                expanded: { code: new Set(), logical: new Set(), modules: new Set(), deployment: new Set(), docs: new Set(), pr: new Set(),
                            'prfull:logical': new Set(), 'prfull:modules': new Set() },
                focus: { code: null, logical: null, modules: null, deployment: null, docs: null, pr: null, 'prfull:logical': null, 'prfull:modules': null },
                prView: null,       // the PR X-Ray's own view, built from the X-Ray and the change
                prTab: false,       // this page is the PR X-Ray tab (payload mode "pr")
                prMap: 'focused',   // PR X-Ray map: 'focused' (the parts the change touches) or 'full' (the whole X-Ray, changes marked)
                prFull: null,       // the full map's view: the X-Ray's own view plus the files the change removes or adds
                prExpandedFor: null, // change whose touched parts were opened on the full map
                historyOpen: false, // the date picker is shown (project X-Ray and PR X-Ray)
                flow: 'RIGHT',      // the direction the top level of the last connected graph was laid out in (BUG-111)
                selected: null,
                graphKey: null,     // view + snapshot version the canvas was built from
                viewChosen: false,  // the user picked a view (no automatic fallback to Structure)
                root: null,         // root folder of the X-Ray shown (project or one of its folders)
                progress: null,     // live analysis progress (setArchitectureProgress)
                operations: null,   // project-root operations only; folder X-Rays receive none
            };
            A.ui = ui;
            A.cy = null;
            A.flowToken = 0; // a layout that starts while a direction is still being chosen replaces it
            let libs = null;

            function post(action, fields) {
                // A file opened while a change is shown opens on that change (viewer's "Pull request" lens).
                if (action === 'openFile' && ui.payload && ui.payload.pr && (ui.view === 'pr' || ui.prTab || ui.overlay === 'pr')) {
                    fields = Object.assign({ fromPR: true }, fields || {});
                }
                sendToSwift('arch', Object.assign({ action: action }, fields || {}));
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
                const t = MarkViewThemes.token, dark = isDark();
                return { bg: t('--arch-bg'), node: t('--arch-node'), box: t('--arch-box'), boxAlpha: dark ? 0.07 : 0.045, boxLine: t('--arch-box-line'),
                         line: t('--arch-line'), text: t('--arch-text'), mute: t('--arch-mute'), accent: t('--arch-accent'), ok: t('--arch-ok'),
                         warn: t('--arch-warn'), bad: t('--arch-bad'), info: t('--arch-info'), dim: dark ? 0.28 : 0.3 };
            }
            // With no overlay, boxes are coloured by the role the AI gave them (legend below).
            const roleNames = { presentation: 'Presentation', application: 'Application', infrastructure: 'Infrastructure', platform: 'Shared platform', other: 'Unclassified', ui: 'UI', api: 'API', domain: 'Domain logic', data: 'Data', infra: 'Infrastructure',
                integration: 'Integration', tooling: 'Tooling', tests: 'Tests', docs: 'Docs', config: 'Config',
                shared: 'Shared', app: 'App' };
                A.roleNames = roleNames;
            const roleColor = { presentation: '#6c8cff', application: '#b07cff', infrastructure: '#8a94a6', platform: '#5bb3a8', other: '#9aa3b2', ui: '#6c8cff', api: '#b07cff', domain: '#2fa37a', data: '#d9822b', infra: '#8a94a6',
                integration: '#b98ad6', tooling: '#8a94a6', tests: '#a0a7b1', docs: '#4aa3c4', config: '#a0a7b1',
                shared: '#5bb3a8', app: '#6c8cff' };
                A.roleColor = roleColor;

            // ------------------------------------------------------------------ model

            function currentView() {
                const snap = ui.payload && ui.payload.snapshot;
                if (!snap) return null;
                if (ui.view === 'pr') return ui.prView;
                const view = snap.views.find(function(v) { return v.id === ui.view; }) || null;
                // The PR X-Ray's full map: the X-Ray's own view, with the files the change removes added to it.
                return view && ui.prFull && ui.prFull.id === view.id ? ui.prFull : view;
            }

            /** A change is on screen: the PR X-Ray tab (either map), or the Pull request overlay of the project X-Ray. */
            function changeShown() {
                return ui.view === 'pr' || ui.prTab || (overlayApplies() && ui.overlay === 'pr');
            }

            /** Links the change adds or removes, as edges between the given view's file ids. */
            function prDependencyEdges(prefix) {
                const pr = ui.payload && ui.payload.pr;
                return ((pr && pr.dependencies) || []).map(function(d) {
                    return { source: prefix + d.source, target: prefix + d.target, kind: d.change, weight: 1, label: d.change === 'added' ? 'new' : 'removed' };
                });
            }

            /** The view a change is drawn in (the Logical view, else Structure) and where its files go in it. */
            function changeBase(snap) {
                const logical = snap.views.find(function(v) { return v.id === 'logical'; });
                const base = logical || snap.views.find(function(v) { return v.id === 'modules'; });
                if (!base) return null;
                return { view: base, logical: !!logical, prefix: logical ? 'l:f:' : 'm:' };
            }

            /** Files of the change the X-Ray has no node for: new ones, which the scan may not know yet, and
             *  removed ones, which the scan of the working copy cannot know. Each is drawn in the component of its
             *  folder (or, without the logical view, in its nearest folder of the Structure view); a removed file whose
             *  folder is gone as well goes to the nearest folder that is still there. With no container at all it
             *  stands alone at the top. */
            function changeExtras(snap, pr, base) {
                const byId = new Map(base.view.nodes.map(function(n) { return [n.id, n]; }));
                const assigned = function(path) {
                    for (let folder = path.split('/').slice(0, -1).join('/'); ; folder = folder.split('/').slice(0, -1).join('/')) {
                        const a = (snap.overrides || {})[folder] || ((snap.assignments || {})[folder] || {}).component;
                        if (a) return a;
                        if (!folder) return null;
                    }
                };
                const parentFor = function(path) {
                    if (base.logical) {
                        const comp = assigned(path);
                        return comp && byId.has('l:c:' + comp) ? 'l:c:' + comp : byId.has('l:') ? 'l:' : null;
                    }
                    for (let folder = path.split('/').slice(0, -1).join('/'); folder; folder = folder.split('/').slice(0, -1).join('/')) {
                        if (byId.has('m:' + folder)) return 'm:' + folder;
                    }
                    return byId.has('m:') ? 'm:' : null;
                };
                const extra = [];
                pr.files.forEach(function(f) {
                    const id = base.prefix + f.path;
                    if (byId.has(id)) return;
                    extra.push({ id: id, parent: parentFor(f.path), kind: 'file', name: f.path.split('/').pop(), path: f.path,
                                 loc: f.deleted ? f.deletions : f.additions, files: 1, removed: !!f.deleted,
                                 summary: f.deleted ? 'Removed in this change' : 'New in this change' });
                });
                return extra;
            }

            /** The PR X-Ray's focused map: only the parts of the structure the change touches — its files
             *  inside their components and subsystems — with existing links between them and
             *  the links the change adds (green) or removes (red, dashed). A file is the leaf:
             *  what changed inside it is shown when it is opened (the viewer's Pull request lens). */
            function buildPRView(snap, pr) {
                if (!snap || !pr) return null;
                const base = changeBase(snap);
                if (!base) return null;
                const prefix = base.prefix;
                const byId = new Map(base.view.nodes.map(function(n) { return [n.id, n]; }));
                const keep = new Set();
                const changed = new Set(pr.files.map(function(f) { return prefix + f.path; }));
                (pr.dependencies || []).forEach(function(d) { changed.add(prefix + d.target); });
                changed.forEach(function(id) {
                    for (let n = byId.get(id); n && !keep.has(n.id); n = n.parent != null ? byId.get(n.parent) : null) keep.add(n.id);
                });
                // The context of a file the X-Ray has no node for (removed, or new) is the container it belongs to.
                const extra = changeExtras(snap, pr, base);
                extra.forEach(function(node) {
                    for (let n = node.parent != null ? byId.get(node.parent) : null; n && !keep.has(n.id); n = n.parent != null ? byId.get(n.parent) : null) keep.add(n.id);
                    keep.add(node.id);
                });
                const nodes = base.view.nodes.filter(function(n) { return keep.has(n.id); }).concat(extra);
                const edges = base.view.edges.filter(function(e) { return keep.has(e.source) && keep.has(e.target) && changed.has(e.source) && changed.has(e.target); })
                    .concat(prDependencyEdges(prefix).filter(function(e) { return keep.has(e.source) && keep.has(e.target); }));
                return { id: 'pr', nodes: nodes, edges: edges };
            }

            /** The PR X-Ray's full map: the whole X-Ray (the Logical view, else Structure) with the files the change
             *  removes or adds drawn in their containers, so that every changed file is a node as on the focused map. */
            function buildFullPRView(snap, pr) {
                if (!snap) return null;
                const base = changeBase(snap);
                if (!base) return null;
                if (!pr) return base.view;
                return { id: base.view.id, nodes: base.view.nodes.concat(changeExtras(snap, pr, base)), edges: base.view.edges };
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
            const codeViews = { code: 1, modules: 1, logical: 1, pr: 1 };
            A.codeViews = codeViews;
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
                if (!node || node.kind === 'change' || node.kind === 'changePart' || (ui.view === 'code' && node.kind === 'layer')) return null;
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
            A.IMPORTANCE = IMPORTANCE;
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
            const noTags = new Set();
            // The PR X-Ray has no "hide tests" menu: what was hidden in the project's X-Ray does not hide parts of a change.
            function hiddenTags() { return ui.view === 'code' ? ui.codeHidden : ui.prTab ? noTags : ui.hidden; }
            function isHidden(node, idx) {
                const hidden = hiddenTags();
                if (!hidden.size || node.kind === 'root') return false;
                if (tagsOf(node, idx).some(function(t) { return hidden.has(t); })) return true;
                // A container whose files are all hidden goes too (no empty "Tests" box).
                const kids = idx.children.get(node.id) || [];
                if (!kids.length) return false;
                const files = descendantsFiles(node.id, idx, []).map(function(id) { return idx.byId.get(id); })
                    .filter(function(n) { return n && (n.kind === 'file' || n.kind === 'doc'); });
                return files.length > 0 && files.every(function(f) { return tagsOf(f, idx).some(function(t) { return hidden.has(t); }); });
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

            // The change's files by Structure-view id, built once per payload (every drawn node asks for it).
            let prByNodeFor = null, prByNodeMap = new Map();
            function prByNode() {
                const pr = ui.payload && ui.payload.pr;
                if (!pr) return new Map();
                if (pr !== prByNodeFor) {
                    prByNodeFor = pr;
                    prByNodeMap = new Map();
                    pr.files.forEach(function(f) { prByNodeMap.set('m:' + f.path, f); });
                }
                return prByNodeMap;
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

            /** What the shown change did to a drawn node, whatever overlay colours it: how many changed files are in it
             *  (a container sums its files), their added and removed lines, and whether it is a file the change removes.
             *  Null when no change is shown or the node is not touched. */
            function changeFacts(node, idx) {
                const pr = ui.payload && ui.payload.pr;
                if (!pr || !changeShown()) return null;
                if (['collection', 'group', 'entity', 'change', 'changePart'].indexOf(node.kind) >= 0) return null;
                const byPath = prByNode();
                let changed = 0, adds = 0, dels = 0;
                const seen = new Set();
                descendantsFiles(node.id, idx, []).forEach(function(id) {
                    const key = fileKey(idx.byId.get(id));
                    const f = key && !seen.has(key) ? byPath.get(key) : null;
                    if (!f) return;
                    seen.add(key);
                    changed++; adds += f.additions; dels += f.deletions;
                });
                if (!changed) return null;
                const own = node.kind === 'file' ? byPath.get(fileKey(node)) : null;
                return { changed: changed, adds: adds, dels: dels, removed: !!(own && own.deleted) };
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
                const a = (ui.view === 'pr' || ui.prTab) && ui.overlay === 'pr' && ui.payload.pr && ui.payload.pr.analysis;
                if (!a || node.kind !== 'component') return null;
                const id = node.id.replace(/^l:c:/, '');
                return a.impact.find(function(i) { return i.component === id; }) || null;
            }

            /** `isBox`: an opened container — its title sits above its children and stays short. */
            function nodeLabel(node, info, isBox, facts) {
                // Long names (dated notes, generated files) are cut; the details panel has them whole.
                let label = node.name || node.id;
                if (label.length > 40) label = label.slice(0, 38) + '…';
                // A file the change removes: marked in its name, so it cannot be taken for a live one.
                if (facts && facts.removed) label = '✕ ' + label;
                if (ui.view === 'code' && node.kind === 'layer' && !isBox) {
                    const first = (node.summary || '').split(' · ')[0];
                    if (first) label += '\n' + (first.length > 48 ? first.slice(0, 46) + '…' : first);
                    if (node.files) label += '\n' + formatCount(node.files) + ' files';
                    return label;
                }
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
                if (info && info.kind === 'pr' && info.changed && !inside) meta.push(facts && facts.removed ? 'removed −' + info.dels : '+' + info.adds + ' −' + info.dels);
                // Another overlay colours the box: the change is still counted in its label.
                else if (facts && (!info || info.kind !== 'pr')) meta.push(facts.removed ? 'removed −' + facts.dels : '+' + facts.adds + ' −' + facts.dels);
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

            // The Code view is a layered diagram: the layers of the flow are bands stacked
            // top to bottom, the cross-cutting ones stand as columns beside them (REQ-005).
            // Opening a part unfolds it inside its layer; the layers keep their places (BUG-085).
            const bandRoles = ['presentation', 'application', 'domain', 'data', 'other'];
            A.bandRoles = bandRoles;
            const crossRoles = ['integration', 'infrastructure', 'platform', 'tooling', 'tests'];
            A.crossRoles = crossRoles;
            // Above this many parts a layer stays a plain band: its contents are read by zooming in.
            const bandPartsLimit = 18;

            /** True while the Code view shows its overview — nothing opened by the user yet. */
            function codeOverview() { return ui.view === 'code' && !ui.expanded.code.size; }

            /** Layers open themselves in the Code overview, so each band shows its components. */
            /** Which open parts and focus the shown view keeps: the full map of a change has its own, so that what is
             *  opened while reviewing a change does not open the same parts of the project's Logical or Structure view. */
            function stateKey() { return ui.prTab && ui.prFull ? 'prfull:' + ui.view : ui.view; }

            function expandedSet(idx) {
                const expanded = ui.expanded[stateKey()];
                if (!codeOverview()) return expanded;
                const open = new Set();
                idx.byId.forEach(function(n) {
                    const kids = (idx.children.get(n.id) || []).length;
                    if ((n.kind === 'layer' || n.kind === 'externalGroup') && kids && kids <= bandPartsLimit) open.add(n.id);
                });
                return open;
            }

            function buildElements() {
                const view = currentView();
                if (!view) return [];
                const idx = indexView(view);
                const expanded = expandedSet(idx);
                const drawn = drawnNodes(idx, expanded).filter(function(n) { return !isHidden(n, idx); });
                requestRatings(idx, drawn);
                const drawnIds = new Set(drawn.map(function(n) { return n.id; }));
                const c = palette();
                const elements = [];
                drawn.forEach(function(node) {
                    const kids = idx.children.get(node.id) || [];
                    const isBox = expanded.has(node.id) && kids.length > 0;
                    const info = overlayInfo(node, idx);
                    const facts = changeFacts(node, idx);
                    const label = nodeLabel(node, info, isBox, facts);
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
                        id: node.id, parent: parent, label: label, kind: node.kind, role: node.role || '',
                        w: w, tw: Math.max(40, w - 14),
                        h: (rows > 2 ? 12 + (described ? 11 : 12) * rows : rows > 1 ? 38 : 26) * grow,
                        fill: (prImpact(node) ? { high: c.bad, medium: c.warn, low: c.ok }[prImpact(node).risk] : null)
                            || overlayColor(info, c) || bookColor(bookImportance(node, idx), c) || (node.role ? roleColor[node.role] : null) || '',
                        // Without a change loaded there is nothing to tell apart: nothing is dimmed.
                        dimmed: ui.overlay === 'pr' && ui.payload.pr && info && !info.changed ? 1 : 0,
                        // The change, whatever overlay colours the node: a halo (a container that is open shows it on its parts).
                        changed: facts && !isBox ? 1 : 0,
                        removed: facts && facts.removed ? 1 : 0,
                        // Keyword match not yet confirmed by the AI: drawn dashed.
                        provisional: info && info.kind === 'ai' && info.provisional && info.level > 0 ? 1 : 0,
                        // "Only flagged": the top two levels of an AI filter, else anything not green/neutral.
                        flag: overlayFlag(info) ? 1 : 0,
                        expandable: kids.length && !isBox ? 1 : 0,
                    }, classes: [node.kind, isBox ? 'box' : 'leaf', kids.length && !isBox ? 'expandable' : '', described ? 'described' : '',
                        // Draft layers (REQ-004): guessed from file paths until the code analysis names components.
                        ui.view === 'code' && node.kind === 'layer' && !A.codeModelOf(ui.payload.snapshot) ? 'draft' : ''].join(' ') });
                });
                // The people the system serves: the layered diagram has them above the top band, as the
                // classic diagram does, also while parts are open. They are a caption, not a part of the model.
                if (ui.view === 'code' && drawn.some(function(n) { return n.kind === 'layer'; })) {
                    elements.push({ group: 'nodes', data: { id: 'code:actors', label: 'Users', kind: 'actors',
                        w: 260, tw: 240, h: 30, fill: '', dimmed: 0, provisional: 0, flag: 0, expandable: 0 }, classes: 'actors leaf' });
                }
                const agg = new Map();
                const prEdges = ui.view !== 'pr' && ((overlayApplies() && ui.overlay === 'pr') || (ui.prTab && ui.payload.pr && codeViews[ui.view]))
                    ? prDependencyEdges(ui.view === 'logical' ? 'l:f:' : 'm:') : [];
                view.edges.concat(prEdges).forEach(function(e) {
                    if (!idx.byId.has(e.source) || !idx.byId.has(e.target)) return;
                    const s = representative(e.source, idx, expanded), t = representative(e.target, idx, expanded);
                    if (!s || !t || s === t || !drawnIds.has(s) || !drawnIds.has(t)) return;
                    // Related sections the AI found are many; they are drawn for the selected box only
                    // (`showRelated`), so the overview shows the authors' links and stays readable.
                    if (e.kind === 'related') return;
                    const key = s + '→' + t + (e.kind === 'added' || e.kind === 'removed' ? '|' + e.kind : '');
                    const cur = agg.get(key);
                    if (cur) {
                        cur.weight += e.weight || 1;
                        if (!cur.label && e.label) cur.label = e.label;
                        if (e.evidence && cur.evidence.indexOf(e.evidence) < 0 && cur.evidence.length < 20) cur.evidence.push(e.evidence);
                    }
                    else agg.set(key, { id: 'e:' + key, source: s, target: t, weight: e.weight || 1, label: e.label || '', kind: e.kind, evidence: e.evidence ? [e.evidence] : [] });
                });
                // A dependency with a citation is the AI's inference; one without is a scanner fact (REQ-004).
                agg.forEach(function(e) { elements.push({ group: 'edges', data: e, classes: e.evidence.length ? 'inference' : '' }); });
                if (ui.onlyFlagged && !ui.prTab && overlayApplies() && ui.overlay !== 'size') return keepFlagged(elements, c);
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
        })(window.MVArchitecture = {});
