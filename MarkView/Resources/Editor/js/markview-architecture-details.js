        // X-Ray tab, part 4 of 5: the details panel: node, edge, book, report, understanding, ask and pull request panels.
        (function (A) {
            if (!A.ready) return;   // no #arch-container on this page (the first part returned early): nothing to set up
            const {
                activate, addRow, ago, aiFilters, bookText, codeViews, currentFilter, currentView, descendantsFiles,
                el, entityTarget, expandedSet, fileKey, hiddenTags, indexView, isBook, isHidden, isSearch, kindLabel,
                levelRank, linkButton, openPRFile, overlayApplies, overlayInfo, palette, post, prByNode, ratingOf,
                render, renderCodeTraces, renderOperations, sectionTarget, ui, undescribedChapters
            } = A;
            Object.assign(A, { renderDetails, renderFilterOptions, renderNewFilterForm });

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
                if (ui.view === 'code') renderCodeTraces(d, node, view, snap);

                if (!node && ui.selectedEdge && ui.selectedEdge.view === ui.view) { renderEdgeDetails(d, idx, ui.selectedEdge); return; }
                if (!understanding && !node && isSearch(currentFilter()) && overlayApplies() && (ui.payload.searchAnswers || {})[currentFilter().id]) {
                    renderSearchAnswer(d, currentFilter(), ui.payload.searchAnswers[currentFilter().id]);
                    return;
                }
                if (!node && (ui.view === 'pr' || ui.prTab)) { renderPRPanel(d, snap, idx); return; }
                // A changed file in the PR X-Ray: its diff, the review and questions about it.
                // A changed file — in the PR X-Ray, or with the Pull request overlay on — shows its
                // change: what was added and removed, and why.
                const showsChange = ui.view === 'pr' || ui.prTab || (overlayApplies() && ui.overlay === 'pr');
                if (node && showsChange && node.path && node.kind === 'file'
                    && ui.payload.pr && ui.payload.pr.files.some(function(f) { return f.path === node.path; })) {
                    renderPRFile(d, node.path);
                    return;
                }
                if (!node && isBook()) { renderBookOverview(d, view, idx, snap); return; }
                if (!node) {
                    const h = document.createElement('h4'); h.textContent = ui.view === 'code' && snap.codeModel ? snap.codeModel.name : ui.view === 'logical' && snap.systemName ? snap.systemName : 'Overview';
                    d.appendChild(h);
                    if (ui.view === 'code' && snap.codeModel) { const p = document.createElement('p'); p.textContent = snap.codeModel.purpose; d.appendChild(p); }
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
                    const analyzedAt = ui.view === 'code' && snap.codeModel ? snap.codeModel.analyzedAt : snap.enrichedAt;
                    addRow(d, 'AI analysis', analyzedAt ? new Date(analyzedAt).toLocaleString() : snap.codeModel && ui.view === 'code' ? 'available' : 'not run');
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
                        post('describe', { view: ui.view === 'code' ? 'modules' : ui.view, id: ui.view === 'code' ? 'm:' + node.path : node.id });
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
                if (ui.view !== 'code' && codeViews[ui.view] && comps.length && ['dir', 'package', 'file'].indexOf(node.kind) >= 0 && node.path != null) {
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
                if ((ui.view === 'logical' || ui.view === 'code') && node.kind === 'file' && node.path) {
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
                    const expanded = expandedSet(idx).has(node.id);
                    d.appendChild(linkButton(expanded ? 'Zoom out of this' : 'Zoom into this', function() { activate(node.id); }, 'arch-action'));
                }

                if (isBook()) { renderBookRefs(d, node, idx, view); }
                // Connections of the drawn node.
                else if (A.cy && A.cy.getElementById(node.id).length) {
                    const drawn = A.cy.getElementById(node.id);
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
                form.onsubmit = function(e) { e.preventDefault(); const text = input.value.trim(); if (text) A.askBook(text); };
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
                const chapterTitle = function(n) {
                    if (n.kind !== 'section' || !n.path) return n.name;
                    const chapter = view.nodes.find(function(c) { return c.kind === 'doc' && c.path === n.path; });
                    return (chapter ? chapter.name + ' › ' : '') + n.name;
                };
                const ranked = leaves.map(function(n) { const sc = score(n); return sc ? { node: n, value: sc[0], label: sc[1], title: chapterTitle(n) } : null; })
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
                    const b = document.createElement('button'); b.textContent = r.title || r.node.name; b.title = r.node.path || r.node.name;
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
                if (edge.view === 'code') {
                    const text = document.createElement('p'); text.textContent = edge.evidence.length ? 'Inference: a source-backed dependency inferred by the code analysis.' : 'Fact: a static dependency found by the source scanner. Trace a scenario to inspect execution order.'; d.appendChild(text);
                    edge.evidence.forEach(function(source) {
                        const match = /^(.*):(\d+)$/.exec(source);
                        if (match) d.appendChild(linkButton(source, function() { post('openFile', { path: match[1], line: Number(match[2]) }); }, 'arch-path'));
                    });
                    [a, b].forEach(function(n) { if (n && n.path) d.appendChild(linkButton(n.path, function() { post('openFile', { path: n.path }); }, 'arch-path')); });
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
                hiddenTags().clear();
                window.architectureFocus(node.id, view.id);
                A.renderToolbar();
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
                if (ui.prTab) return;
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
        })(window.MVArchitecture);
