        // X-Ray tab, part 5 of 5: the toolbar, history, entry points (window.showArchitecture and friends) and the event wiring.
        (function (A) {
            if (!A.ready) return;   // no #arch-container on this page (the first part returned early): nothing to set up
            const {
                autoExpand, buildFullPRView, buildPRView, codeViews, container, currentFilter, currentView, el,
                ensureCy, formatCount, hiddenTags, hideCodeSequence, indexView, isAIFilter, isBook, isHidden,
                isOperationRunning, isSearch, loadLibraries, overlayApplies, post, render, renderDeployButton,
                renderDetails, renderEmpty, renderFilterOptions, renderNewFilterForm, restyle, showCodeSequence,
                stateKey, stylesheet, ui, visibleOperations
            } = A;
            Object.assign(A, { askBook, renderToolbar });

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
                // The PR X-Ray offers the overlays that colour a change's parts; AI filters rate parts as you zoom in.
                if (ui.prTab && ui.overlay.indexOf('ai:') === 0) ui.overlay = 'pr';
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
                el.hide.value = Array.from(hiddenTags()).join(',');
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
                // Complexity, size and the other overlays work on a change too: its parts keep their marks.
                el.overlay.hidden = false;
                el.tempFilter.hidden = prTab;
                el.prMap.hidden = !prTab;
                Array.prototype.forEach.call(el.prMap.querySelectorAll('[data-arch-pr-map]'), function(b) {
                    b.classList.toggle('on', b.getAttribute('data-arch-pr-map') === ui.prMap);
                });
                // Comparison with a date stands on its own (BUG-110): the project X-Ray offers it too, not only the PR X-Ray.
                // A folder X-Ray has no comparison view to open, so it does not.
                el.prDate.hidden = p.mode === 'folder';
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
                el.codeTrace.hidden = ui.view !== 'code' || p.mode === 'pr';
                renderHistory();
                el.analyze.disabled = !!p.busy || !p.snapshot;
                el.analyze.textContent = ui.view === 'code' ? 'Refresh' : 'Analyze';
                // A folder X-Ray has no automatic pipeline: its Refresh re-reads components and layers only.
                el.analyze.title = ui.view !== 'code' ? 'Describe modules and map deployment with the selected AI assistant'
                    : p.automaticAnalysis === false ? 'Analyze the code of this folder again now: components and layers (traces stay manual)'
                    : 'Analyze the code again now: components, layers and automatic scenarios (manual traces are kept)';
                el.rescan.disabled = !!p.busy;
                renderDeployButton();
                // The progress bar shows the analysis; the status line covers everything else.
                const codeOverlayInBook = isBook() && codeOnly[ui.overlay] ? 'This overlay is about code. In the Book use Importance, an AI filter, Freshness or Size.' : '';
                const statusText = p.error || (ui.progress ? '' : p.status) || codeOverlayInBook || '';
                el.status.textContent = statusText;
                el.status.className = p.error ? 'arch-error' : (statusText ? 'arch-working' : '');
            }

            // ------------------------------------------------------- comparison by date

            function localDay(date) {
                const pad = function(n) { return String(n).padStart(2, '0'); };
                return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate());
            }

            /** Ask Swift for the commits of the chosen day (every local branch; the day is the user's own calendar day). */
            function askHistory() {
                if (el.historyDay.value) post('historyCommits', { day: el.historyDay.value });
                renderHistory();
            }

            /** The date picker (project X-Ray and PR X-Ray): a day first, then one of the commits made that day, to compare the
             *  working copy with. A day without commits says so. */
            function renderHistory() {
                const p = ui.payload || {};
                const open = ui.historyOpen && p.mode !== 'folder';
                el.history.hidden = !open;
                if (!open) { delete el.historyList.dataset.key; return; }
                const list = el.historyList;
                const day = el.historyDay.value, h = p.history;
                // The list is rebuilt only when it differs: a progress tick must not replace the row under the pointer.
                const key = [day, h && h.day, h && h.state, h ? (h.commits || []).map(function(c) { return c.sha; }).join(',') : ''].join('|');
                if (list.dataset.key === key) return;
                list.dataset.key = key;
                list.textContent = '';
                const note = function(text) {
                    const div = document.createElement('div');
                    div.className = 'arch-history-note'; div.textContent = text;
                    list.appendChild(div);
                };
                if (!day) { note('Choose a day.'); return; }
                if (!h || h.day !== day || h.state === 'loading') { note('Reading the history…'); return; }
                if (h.state === 'unavailable') { note('The history could not be read. Is this folder a git repository?'); return; }
                if (!h.commits.length) { note('No commits were made on this day.'); return; }
                h.commits.forEach(function(c) {
                    const row = document.createElement('button');
                    row.type = 'button'; row.className = 'arch-history-row';
                    row.title = c.sha + '\n' + c.subject;
                    [['when', new Date(c.time * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })],
                     ['sha', c.short], ['what', c.subject], ['who', c.author]].forEach(function(part) {
                        const span = document.createElement('span');
                        span.className = part[0]; span.textContent = part[1];
                        row.appendChild(span);
                    });
                    row.addEventListener('click', function() {
                        ui.historyOpen = false;
                        post('compareWithCommit', { sha: c.sha });
                        renderHistory();
                    });
                    list.appendChild(row);
                });
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
                if (ui.view === 'code' && isHidden(node, idx)) {
                    ui.codeHidden.clear(); ui.codeFilterInitialized = true; renderToolbar();
                }
                const expanded = ui.expanded[stateKey()];
                if ((idx.children.get(id) || []).length) expanded.add(id);
                let parent = node.parent != null ? idx.byId.get(node.parent) : null;
                while (parent) { expanded.add(parent.id); parent = parent.parent != null ? idx.byId.get(parent.parent) : null; }
                ui.focus[stateKey()] = (idx.children.get(id) || []).length ? id : node.parent;
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
                ui.codeFilterInitialized = false; ui.codeHidden.clear();
                ui.codeQuestions = {}; ui.codeAwaitingScope = null; ui.selectedEdge = null; hideCodeSequence();
                ui.operations = null;
                Object.keys(ui.expanded).forEach(function(k) { ui.expanded[k].clear(); });
                Object.keys(ui.focus).forEach(function(k) { ui.focus[k] = null; });
                ui.prExpandedFor = null;
                ui.selected = null;
                ui.graphKey = null;
                ui.ratingRequested.clear();
                ui.describeRequested.clear();
                ui.userNavigated = false;
            }

            /** The full map opens the parts the change touches, once per change, so that every changed file is a node on
             *  screen; what the person opens or closes afterwards stays as it is. */
            function openChangedParts(pr) {
                // Once per change: the same source with other files (a reload of the local changes) or on another view opens again.
                if (!pr) return;
                const key = ui.prFull.id + '|' + pr.source.id + '|' + pr.files.map(function(f) { return f.path; }).join('\n');
                if (ui.prExpandedFor === key) return;
                ui.prExpandedFor = key;
                const byId = new Map(ui.prFull.nodes.map(function(n) { return [n.id, n]; }));
                const prefix = ui.prFull.id === 'logical' ? 'l:f:' : 'm:';
                pr.files.forEach(function(f) {
                    for (let n = byId.get(prefix + f.path); n && n.parent != null; n = byId.get(n.parent)) ui.expanded[stateKey()].add(n.parent);
                });
            }

            window.showArchitecture = function(payload) {
                enter();
                ui.payload = payload || {};
                if ((ui.payload.root || null) !== ui.root) resetForRoot(ui.payload.root || null);
                // The PR X-Ray tab shows the change inside the X-Ray: on the focused map (the parts it touches, with the
                // context they need) or on the full map (the whole X-Ray, the change marked). The overlay starts as the
                // change's own colours; the person may pick another, and the marks of the change stay.
                if (ui.payload.mode === 'pr') {
                    if (!ui.prTab) { ui.prTab = true; ui.overlay = 'pr'; ui.selected = null; ui.selectedEdge = null; }
                    ui.prView = buildPRView(ui.payload.snapshot, ui.payload.pr);
                    ui.prFull = ui.prMap === 'full' ? buildFullPRView(ui.payload.snapshot, ui.payload.pr) : null;
                    ui.view = ui.prFull ? ui.prFull.id : 'pr';
                    if (ui.prFull) openChangedParts(ui.payload.pr);
                    else if (ui.prView) ui.prView.nodes.forEach(function(n) {
                        if (ui.prView.nodes.some(function(k) { return k.parent === n.id; })) ui.expanded.pr.add(n.id);
                    });
                } else if (ui.view === 'pr' || ui.prTab) {
                    ui.prTab = false;
                    ui.prFull = null;
                    ui.selected = null; ui.selectedEdge = null;
                    ui.view = 'logical';
                    ui.overlay = 'none';
                }
                renderToolbar();
                renderDetails();
                const snap = ui.payload.snapshot;
                const traces = snap && snap.codeSequences || [];
                if (ui.view === 'code' && ui.codeAwaitingScope && !ui.payload.busy && traces.map(function(s) { return s.createdAt; }).join('|') !== ui.codePreviousTime) {
                    const latest = traces.length - 1;
                    if (latest >= 0 && traces[latest].scope === ui.codeAwaitingScope) { showCodeSequence(latest); ui.codeAwaitingScope = null; }
                }
                if (!snap) {
                    if (A.cy) A.cy.elements().remove();
                    return;
                }
                if (!ui.viewChosen && snap.views.some(function(v) { return v.id === 'code' && v.nodes.some(function(n) { return n.kind === 'file'; }); })) {
                    ui.view = 'code'; renderToolbar(); renderDetails();
                }
                // No logical grouping yet: show the Structure view until the analysis lands.
                if (!ui.viewChosen && ui.view === 'logical' && !snap.views.some(function(v) { return v.id === 'logical'; })) {
                    ui.view = 'modules';
                    ui.graphKey = null;
                    renderToolbar();
                }
                if (ui.view === 'code' && !ui.codeFilterInitialized) {
                    const view = currentView();
                    const files = view ? view.nodes.filter(function(n) { return n.kind === 'file'; }) : [];
                    if (files.length) {
                        const defaults = ['tests'];
                        // A tests-only folder is still a code project: show it rather than an empty map.
                        const product = files.some(function(n) { return !(n.tags || []).some(function(t) { return defaults.indexOf(t) >= 0; }); });
                        ui.codeHidden = new Set(product ? defaults : []);
                        ui.codeFilterInitialized = true;
                        renderToolbar();
                    }
                }
                loadLibraries().then(function() {
                    ensureCy();
                    // The structure grows live during an analysis: redraw when it changes.
                    const shape = (snap.components || []).map(function(c) { return c.id + '<' + c.parent; }).join(',')
                        + '|' + (snap.codeModel ? JSON.stringify(snap.codeModel) : '')
                        + '|' + Object.keys(snap.assignments || {}).length
                        + '|' + snap.views.map(function(v) { return v.id + ':' + v.nodes.length; }).join(',');
                    const pr = ui.payload.pr;
                    const prShape = ui.prTab && pr ? '|' + pr.source.id + ':' + pr.files.length + ':' + (pr.dependencies || []).length + ':' + !!pr.analysis
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
                    hideCodeSequence();
                    ui.view = b.getAttribute('data-arch-view');
                    ui.viewChosen = true;
                    ui.selectedEdge = null;
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
                // A comparison with an earlier commit can span months of work: it is shown, and analysed when asked.
                if (ui.payload && ui.payload.mode === 'pr' && el.prSource.value.indexOf('at:') !== 0) post('openPRXRay', { source: el.prSource.value });
                else post('showPR', { source: el.prSource.value });
            });
            Array.prototype.forEach.call(el.prMap.querySelectorAll('[data-arch-pr-map]'), function(b) {
                b.addEventListener('click', function() {
                    ui.prMap = b.getAttribute('data-arch-pr-map');
                    ui.selected = null;
                    ui.selectedEdge = null;
                    ui.graphKey = null;
                    window.showArchitecture(ui.payload);
                });
            });
            el.prDate.addEventListener('click', function() {
                ui.historyOpen = !ui.historyOpen;
                if (ui.historyOpen) {
                    const today = localDay(new Date());
                    el.historyDay.max = today;
                    if (!el.historyDay.value) el.historyDay.value = today;
                    askHistory();
                } else renderHistory();
            });
            el.historyDay.addEventListener('change', askHistory);
            el.history.addEventListener('keydown', function(e) {
                if (e.key === 'Escape') { ui.historyOpen = false; renderHistory(); }
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
                const hidden = new Set(el.hide.value ? el.hide.value.split(',') : []);
                if (ui.view === 'code') { ui.codeHidden = hidden; ui.codeFilterInitialized = true; } else ui.hidden = hidden;
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
                                        width: 280, reserve: 320, onResize: function() { if (A.cy) A.cy.resize(); } });
            function setDetailsHidden(hidden, save) {
                el.details.hidden = el.detailsResizer.hidden = hidden;
                el.detailsToggle.classList.toggle('on', !hidden);
                if (save) { try { localStorage.setItem('markview-xray-details-hidden', hidden ? '1' : ''); } catch (e) {} }
                if (A.cy) A.cy.resize();
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
            el.codeTrace.addEventListener('click', function() {
                setDetailsHidden(false, false);
                const input = el.details.querySelector('.arch-code-question');
                if (input) input.focus();
            });
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
            el.analyze.addEventListener('click', function() { post(ui.view === 'code' ? 'refreshCode' : 'analyze'); });
            el.rescan.addEventListener('click', function() { post('rescan'); });
            el.fit.addEventListener('click', function() { if (!A.cy) return; if (ui.view === 'code') A.cy.fit(A.cy.elements(), 28); else A.cy.animate({ fit: { eles: A.cy.elements(), padding: 28 }, duration: 240 }); });

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
            window.setTheme = function(id, accent) {
                origSetTheme(id, accent);
                if (A.cy) { A.cy.style(stylesheet()); restyle(); }
            };
        })(window.MVArchitecture);
