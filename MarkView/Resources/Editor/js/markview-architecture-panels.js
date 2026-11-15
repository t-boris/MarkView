        // X-Ray tab, part 3 of 5: breadcrumbs, legend, deploy and operations, the code coverage and trace panels and the code sequence view.
        (function (A) {
            if (!A.ready) return;   // no #arch-container on this page (the first part returned early): nothing to set up
            const {
                IMPORTANCE, bookColor, bookImportance, changeShown, collapse, currentFilter, currentView, el,
                highlightNeighbourhood, indexView, isBook, isSearch, isTransparent, levelColor, levelRank,
                overlayApplies, palette, post, render, roleColor, roleNames, scales, stateKey, ui
            } = A;
            Object.assign(A, {
                addRow, codeModelOf, hideCodeSequence, isOperationRunning, linkButton, renderCodeTraces, renderCrumbs,
                renderDeployButton, renderLegend, renderOperations, showCodeSequence, visibleOperations
            });

            function renderCrumbs() {
                const view = currentView();
                el.crumbs.textContent = '';
                if (!view) return;
                const idx = indexView(view);
                const chain = [];
                let cur = ui.focus[stateKey()] ? idx.byId.get(ui.focus[stateKey()]) : null;
                while (cur) { if (!isTransparent(cur)) chain.unshift(cur); cur = cur.parent != null ? idx.byId.get(cur.parent) : null; }
                const top = document.createElement('button');
                top.className = 'arch-crumb';
                top.textContent = ({ code: 'Code architecture', logical: 'Logical', modules: 'Modules', deployment: 'Deployment', docs: 'Book', pr: 'Pull request' })[ui.view];
                // The top level: the details panel goes back to the view's overview (the PR panel
                // in the PR X-Ray) — nothing stays selected.
                top.onclick = function() {
                    ui.expanded[stateKey()].clear(); ui.focus[stateKey()] = null;
                    ui.selected = null; ui.selectedEdge = null;
                    if (A.cy) { A.cy.elements().unselect(); highlightNeighbourhood(null); }
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
                        ui.focus[stateKey()] = node.id; ui.selected = node.id; ui.selectedEdge = null;
                        if (A.cy) A.cy.elements().unselect();
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
                if (!scale && !filter && isBook() && A.cy && currentView()) {
                    const idx = indexView(currentView());
                    const rated = A.cy.nodes().some(function(n) { return bookImportance(idx.byId.get(n.id()), idx) != null; });
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
                if (!scale && !filter && isBook() && currentView() && currentView().edges.some(function(e) { return e.kind === 'related'; })) {
                    const span = document.createElement('span'); span.className = 'arch-muted';
                    span.textContent = 'Solid = link in the text · dashed = related (AI), shown for the selected box';
                    el.legend.appendChild(span);
                }
                // No overlay: the colours are roles; list the ones on screen.
                if (!scale && !filter && !(overlayApplies() && ui.overlay !== 'none') && A.cy) {
                    const present = new Set(A.cy.nodes().map(function(n) {
                        const node = currentView() && indexView(currentView()).byId.get(n.id());
                        return node && node.role && roleColor[node.role] ? node.role : null;
                    }).filter(Boolean));
                    if (present.size) {
                        const title = document.createElement('span'); const roleTitle = document.createElement('b'); roleTitle.textContent = ui.view === 'code' ? 'Colour = layer' : 'Colour = role (AI)'; title.appendChild(roleTitle);
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
                // Another overlay colours the boxes: the change keeps its own marks.
                if (ui.prTab && ui.payload.pr && ui.overlay !== 'pr') items.push([c.info, 'Halo = changed (+added −removed lines)']);
                if (changeShown() && ui.payload.pr && ui.payload.pr.files.some(function(f) { return f.deleted; })) {
                    items.push([c.bad, '✕ dashed = removed file']);
                }
                if (overlayApplies() && ui.overlay === 'tests') items.push([c.info, 'Test code']);
                const report = ui.payload.snapshot && ui.payload.snapshot.coverageReport;
                if (ui.overlay === 'tests' && report) items.push([null, 'Line coverage from ' + report]);
                items.forEach(function(item) {
                    const span = document.createElement('span');
                    if (item[0]) { const dot = document.createElement('i'); dot.style.background = item[0]; span.appendChild(dot); }
                    span.appendChild(document.createTextNode(item[1]));
                    el.legend.appendChild(span);
                });
                if (ui.view === 'code' && !scale && !filter) {
                    const span = document.createElement('span'); span.className = 'arch-muted';
                    span.textContent = 'Solid arrow = fact (scanner) · dashed = inference (AI, cited)' + (codeModelOf(ui.payload.snapshot) ? '' : ' · dotted layer = draft from paths');
                    el.legend.appendChild(span);
                }
                const hint = document.createElement('span');
                hint.className = 'arch-hint';
                hint.textContent = ui.view === 'code' ? 'Select a box for dependencies · Double-click to zoom in or open' : 'Double-click to zoom in or open';
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
                function row(operation, highlighted) {
                    const wrapper = document.createElement('div');
                    wrapper.className = 'arch-operation' + (highlighted ? ' related' : '');
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
                    d.appendChild(wrapper);
                }
                if (related.length) {
                    const h = document.createElement('h5'); h.textContent = 'Related to ' + node.name; d.appendChild(h);
                    related.forEach(function(o) { row(o, true); });
                }
                // Every other operation, grouped by kind (REQ-010, DEC-009): none is hidden or kept behind a toggle.
                // Known kinds come first in a fixed order, then any other kind by name; operations inside a group by label.
                const kinds = ['deploy', 'build', 'test', 'run', 'install', 'clean', 'restart', 'other'];
                const groups = new Map();
                all.filter(function(o) { return related.indexOf(o) < 0; }).forEach(function(o) {
                    const kind = o.kind || 'other';
                    if (!groups.has(kind)) groups.set(kind, []);
                    groups.get(kind).push(o);
                });
                function kindRank(kind) { return kinds.indexOf(kind) < 0 ? kinds.length : kinds.indexOf(kind); }
                Array.from(groups.keys()).sort(function(a, b) {
                    return (kindRank(a) - kindRank(b)) || a.localeCompare(b);
                }).forEach(function(kind) {
                    const members = groups.get(kind).sort(function(a, b) { return a.label.localeCompare(b.label); });
                    const h = document.createElement('h5');
                    h.textContent = kind.charAt(0).toUpperCase() + kind.slice(1) + ' (' + members.length + ')';
                    d.appendChild(h);
                    members.forEach(function(o) { row(o, false); });
                });
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

            function codeScope(node) { return node ? node.id : 'code:'; }
            function codeModelOf(snap) { return snap && snap.codeModel ? snap.codeModel : null; }
            function moduleRoot(snap) {
                return ((snap.views.find(function(v) { return v.id === 'modules'; }) || {}).nodes || []).find(function(n) { return n.id === 'm:'; });
            }

            /** "5 minutes ago" for the status line; the date once it is a week old. */
            function relativeTime(iso) {
                const date = new Date(iso); if (isNaN(date.getTime())) return '';
                const seconds = Math.max(0, (Date.now() - date.getTime()) / 1000);
                if (seconds < 60) return 'just now';
                const minutes = Math.round(seconds / 60);
                if (minutes < 60) return minutes + (minutes === 1 ? ' minute ago' : ' minutes ago');
                const hours = Math.round(minutes / 60);
                if (hours < 24) return hours + (hours === 1 ? ' hour ago' : ' hours ago');
                const days = Math.round(hours / 24);
                if (days < 7) return days === 1 ? 'yesterday' : days + ' days ago';
                return 'on ' + date.toLocaleDateString();
            }

            /** The automatic analysis in one line (REQ-002, DEC-004). Older payloads carry no
             *  state: a model's own date then, nothing without one. */
            function codeStatusText(snap) {
                const state = ui.payload.automaticState || { kind: 'idle' };
                switch (state.kind) {
                case 'scanning': case 'analyzing': return 'Analyzing code in the background…' + (state.step ? ' ' + state.step : '');
                case 'done': return 'Analyzed ' + relativeTime(state.date);
                case 'off': return 'Automatic analysis is off';
                case 'unavailable': return 'AI analysis unavailable: ' + (state.reason || 'no assistant');
                case 'tooLarge': return 'Project too large for automatic analysis (' + (state.files || 0) + ' files); use Refresh';
                case 'skipped': return state.reason || '';
                default: return snap.codeModel && snap.codeModel.analyzedAt ? 'Analyzed ' + relativeTime(snap.codeModel.analyzedAt) : '';
                }
            }

            /** What the scenario list shows for sequence `i`: from the payload, or derived
             *  from the snapshot for payloads without `codeSequenceInfo`. */
            function sequenceInfo(snap, i) {
                const info = (ui.payload.codeSequenceInfo || [])[i];
                if (info) return info;
                const trace = snap.codeSequences[i];
                const root = moduleRoot(snap);
                return { title: trace.diagram.title, scope: trace.scope, auto: !!trace.auto,
                    stale: !!(root && root.signature !== trace.signature), createdAt: trace.createdAt };
            }

            /** One scenario: its title opens the sequence; automatic or manual, and stale when a cited file changed. */
            function sequenceRow(snap, i) {
                const info = sequenceInfo(snap, i);
                const row = document.createElement('div'); row.className = 'arch-sequence';
                row.appendChild(linkButton(info.title, function() { showCodeSequence(i); }, 'arch-action'));
                const badges = document.createElement('span'); badges.className = 'arch-badges';
                const kind = document.createElement('span'); kind.textContent = info.auto ? 'Automatic' : 'Manual';
                kind.title = info.auto ? 'Chosen and traced by the automatic analysis' : 'Traced from your question; kept across automatic refreshes';
                badges.appendChild(kind);
                if (info.stale) {
                    const stale = document.createElement('span'); stale.className = 'arch-warn'; stale.textContent = 'stale';
                    stale.title = 'A cited source file changed since this trace'; badges.appendChild(stale);
                }
                row.appendChild(badges);
                return row;
            }

            const LEVEL_NAMES = { full: 'full', partial: 'partial', notAnalyzed: 'not analyzed' };
            /** "What was understood" (REQ-003): per language the level and file counts, the
             *  reasons and the unassigned files. Collapsed when every language is full. */
            function renderCoverage(d, snap) {
                const report = snap.codeCoverage; if (!report) return;
                const languages = report.languages || [];
                const details = document.createElement('details'); details.className = 'arch-coverage';
                details.open = languages.some(function(l) { return l.level !== 'full'; });
                const summary = document.createElement('summary'); summary.textContent = 'What was understood'; details.appendChild(summary);
                if (languages.length) {
                    const table = document.createElement('table');
                    const head = table.createTHead().insertRow();
                    ['Language', 'Level', 'Full', 'Partial', 'Not analyzed'].forEach(function(text) {
                        const cell = document.createElement('th'); cell.textContent = text; head.appendChild(cell);
                    });
                    const body = table.createTBody();
                    languages.forEach(function(l) {
                        const row = body.insertRow(); row.className = 'arch-level-' + l.level;
                        [l.language, LEVEL_NAMES[l.level] || l.level, l.full, l.partial, l.notAnalyzed].forEach(function(value, i) {
                            const cell = row.insertCell(); cell.textContent = String(value == null ? '' : value); if (i >= 2) cell.className = 'arch-num';
                        });
                    });
                    details.appendChild(table);
                } else {
                    const p = document.createElement('p'); p.className = 'arch-muted'; p.textContent = 'No source files were scanned.'; details.appendChild(p);
                }
                addRow(details, 'Files outside the components', String(report.unassignedFiles || 0));
                if (!report.hasModel) {
                    const p = document.createElement('p'); p.className = 'arch-muted';
                    p.textContent = 'Local scan only: the AI analysis assigns files to components.'; details.appendChild(p);
                }
                if ((report.reasons || []).length) {
                    const list = document.createElement('ul'); list.className = 'arch-coverage-reasons';
                    report.reasons.forEach(function(reason) { const item = document.createElement('li'); item.textContent = reason; list.appendChild(item); });
                    details.appendChild(list);
                }
                d.appendChild(details);
            }

            /** Fact, inference and draft (REQ-004), as the graph draws them. */
            function renderFactLegend(d) {
                const legend = document.createElement('div'); legend.className = 'arch-fact-legend';
                [['arch-fact', 'Fact', 'found in the source by the scanner (solid arrow)'],
                 ['arch-inference', 'Inference', 'read from the code by the AI, with a citation (dashed arrow)'],
                 ['arch-draft', 'Draft', 'layers guessed from file paths until the analysis runs (dotted box)']].forEach(function(item) {
                    const span = document.createElement('span');
                    const mark = document.createElement('i'); mark.className = item[0]; span.appendChild(mark);
                    const name = document.createElement('b'); name.textContent = item[1]; span.appendChild(name);
                    span.appendChild(document.createTextNode(' ' + item[2]));
                    legend.appendChild(span);
                });
                d.appendChild(legend);
            }

            function renderCodeTraces(d, node, view, snap) {
                if (!view.nodes.some(function(n) { return n.kind === 'file'; })) return;
                const scope = codeScope(node);
                const section = document.createElement('div'); section.className = 'arch-code-traces';
                const sequences = snap.codeSequences || [];
                if (!node) {
                    // The overview: the automatic analysis, its scenarios, then the manual trace.
                    const status = codeStatusText(snap);
                    if (status) { const line = document.createElement('p'); line.className = 'arch-code-status'; line.textContent = status; section.appendChild(line); }
                    const heading = document.createElement('h5'); heading.textContent = 'Scenarios'; section.appendChild(heading);
                    if (sequences.length) sequences.forEach(function(trace, i) { section.appendChild(sequenceRow(snap, i)); });
                    else { const p = document.createElement('p'); p.className = 'arch-muted'; p.textContent = 'No scenarios traced yet.'; section.appendChild(p); }
                }
                const title = document.createElement('h5'); title.textContent = 'Trace a scenario' + (node ? ' in ' + node.name : ' in the code'); section.appendChild(title);
                const note = document.createElement('p'); note.className = 'arch-muted';
                note.textContent = 'Layers → components → files → symbols. Double-click to explore. ' +
                    (!snap.codeModel && (snap.logicalDraft || !(snap.components || []).length) ? 'Draft layers use file paths; the analysis refines components from source. ' : '') +
                    'A sequence is an AI interpretation of one code path, with source evidence; it is not a runtime trace.' +
                    (ui.codeHidden.size ? ' Use Show all to include filtered source code.' : '');
                section.appendChild(note);
                const root = moduleRoot(snap);
                if (snap.codeModel && root && snap.codeModel.signature !== root.signature) {
                    const warning = document.createElement('p'); warning.className = 'arch-muted'; warning.textContent = 'Source changed since the architecture analysis. Refresh to update the components.'; section.appendChild(warning);
                }
                const component = snap.codeModel && node && snap.codeModel.components.find(function(c) { return c.id === node.component; });
                if (component) {
                    const match = /^(.*):(\d+)$/.exec(component.evidence);
                    if (match) section.appendChild(linkButton('Source: ' + component.evidence, function() { post('openFile', { path: match[1], line: Number(match[2]) }); }, 'arch-path'));
                }
                const input = document.createElement('textarea'); input.className = 'arch-code-question'; input.maxLength = 4000;
                input.setAttribute('aria-label', 'Scenario to trace'); input.placeholder = 'e.g. How is a document saved?';
                input.value = ui.codeQuestions[scope] || '';
                const submit = linkButton(ui.payload.busy ? 'Analysis in progress…' : 'Draw sequence', function() {
                    const question = input.value.trim(); if (!question || ui.payload.busy) return;
                    ui.codeAwaitingScope = scope;
                    ui.codePreviousTime = (snap.codeSequences || []).map(function(s) { return s.createdAt; }).join('|');
                    post('traceCode', { scope: scope, question: question });
                }, 'arch-action');
                submit.disabled = ui.payload.busy || !input.value.trim();
                input.oninput = function() { ui.codeQuestions[scope] = input.value; submit.disabled = ui.payload.busy || !input.value.trim(); };
                section.appendChild(input); section.appendChild(submit);
                // A selected box lists the scenarios traced inside it; the overview listed them all above.
                if (node) sequences.forEach(function(trace, i) { if (trace.scope === scope) section.appendChild(sequenceRow(snap, i)); });
                else { renderCoverage(section, snap); renderFactLegend(section); }
                d.appendChild(section);
            }

            let sequenceRenderToken = 0;
            function hideCodeSequence() {
                ++sequenceRenderToken;
                ui.codeSequenceIndex = null;
                document.getElementById('arch-code-sequence').hidden = true;
            }
            document.getElementById('arch-code-sequence-close').onclick = hideCodeSequence;
            function showCodeSequence(i) {
                const trace = ((ui.payload.snapshot || {}).codeSequences || [])[i];
                const source = (ui.payload.codeSequenceDiagrams || [])[i];
                if (!trace || !source) return;
                ui.codeSequenceIndex = i;
                const token = ++sequenceRenderToken;
                const panel = document.getElementById('arch-code-sequence'); panel.hidden = false;
                document.getElementById('arch-code-sequence-title').textContent = trace.diagram.title;
                document.getElementById('arch-code-sequence-takeaway').textContent = trace.diagram.takeaway;
                document.getElementById('arch-code-sequence-omitted').textContent = trace.diagram.omitted || '';
                const sources = document.getElementById('arch-code-sequence-sources'); sources.textContent = '';
                const subtitle = document.createElement('h4'); subtitle.textContent = 'Messages and source evidence'; sources.appendChild(subtitle);
                trace.diagram.edges.forEach(function(edge) {
                    const row = document.createElement('p'); row.textContent = edge.label; sources.appendChild(row);
                    const match = /^(.*):(\d+)$/.exec(edge.evidence || '');
                    if (match) sources.appendChild(linkButton(edge.evidence, function() { post('openFile', { path: match[1], line: Number(match[2]) }); }, 'arch-path'));
                });
                const body = document.getElementById('arch-code-sequence-svg'); body.textContent = 'Drawing sequence…';
                try {
                    mermaid.render('code-sequence-' + token, source).then(function(result) {
                        if (token !== sequenceRenderToken) return;
                        body.innerHTML = window.mvKit.sanitizeMermaidSvg(result.svg);
                    }).catch(function() { if (token === sequenceRenderToken) body.textContent = 'The sequence could not be rendered. Its messages and source evidence are listed below.'; });
                } catch (e) { body.textContent = 'The sequence could not be rendered. Its messages and source evidence are listed below.'; }
            }
        })(window.MVArchitecture);
