(function(P, A) {
    if (!A.ready) return;
    const root = document.getElementById('arch-process');
    const main = root && root.parentElement;
    if (!root || !main) return;
    const form = P.element('form', 'process-question');
    const question = P.element('textarea'); question.rows = 2; question.maxLength = 4000;
    question.setAttribute('aria-label', 'Process to trace'); question.placeholder = 'How is a request handled, including parallel work, refusals and retries?';
    const submit = P.button('Trace process', function() { requestTrace(); });
    const stop = P.button('Stop', function() { A.post('cancelAnalysis'); }); stop.hidden = true;
    const picker = P.element('select'); picker.setAttribute('aria-label', 'Saved process');
    const formActions = P.element('div', 'process-question-actions'); formActions.append(picker, submit, stop);
    form.append(question, formActions);
    const scopeInfo = P.element('details', 'process-scope-info');
    const scopeTitle = P.element('summary', '', 'Process context');
    const takeaway = P.element('p'), omitted = P.element('p');
    scopeInfo.append(scopeTitle, takeaway, omitted);
    const tools = P.element('div', 'process-tools');
    const breadcrumbs = P.element('nav', 'process-breadcrumbs'); breadcrumbs.setAttribute('aria-label', 'Process hierarchy');
    const direction = P.element('select'); direction.setAttribute('aria-label', 'Flow direction');
    [['RIGHT', 'Left to right'], ['DOWN', 'Top to bottom']].forEach(function(item) {
        const option = P.element('option', '', item[1]); option.value = item[0]; direction.append(option);
    });
    const zoomText = P.element('span', 'process-zoom', '100%');
    const controls = P.element('div', 'process-map-controls');
    const zoomOut = P.button('-', function() { surface.zoom(1 / 1.2); }); zoomOut.setAttribute('aria-label', 'Zoom out');
    const zoomIn = P.button('+', function() { surface.zoom(1.2); }); zoomIn.setAttribute('aria-label', 'Zoom in');
    const fit = P.button('Fit', function() { surface.fit(); });
    const actual = P.button('1:1', function() { surface.actualSize(selected); });
    const expand = P.button('Expand map', function() {
        const expanded = root.classList.toggle('process-map-expanded'); expand.textContent = expanded ? 'Compact map' : 'Expand map';
    });
    controls.append(direction, zoomOut, zoomText, zoomIn, fit, actual, expand);
    tools.append(breadcrumbs, controls);
    const context = P.element('div', 'process-context');
    const summary = P.element('span', 'arch-muted');
    const focusLabel = P.element('label', 'arch-check');
    const focus = P.element('input'); focus.type = 'checkbox'; focusLabel.append(focus, document.createTextNode('Only neighboring connections'));
    const openGroup = P.button('Open group', function() { drill(selected); });
    context.append(summary, focusLabel, openGroup);
    const canvas = P.element('div', 'process-map');
    const message = P.element('p', 'process-map-message'); message.setAttribute('role', 'status');
    const returns = P.element('div', 'process-returns');
    const caption = P.element('div', 'process-map-caption');
    caption.append(P.element('span', 'arch-muted', 'Drag to pan. Pinch or Ctrl+wheel to zoom. Double-click a group to enter.'),
        P.button('Code + Explain', function() { panel.element.scrollIntoView({ block: 'start' }); }));
    root.append(form, scopeInfo, tools, context, message, canvas, returns, caption);
    let payload = {}, project = null, activeID = null, parent = null, selected = null, source = 0;
    let requestedSource = '', savedChoices = '', savedVersion = '', awaiting = false, active = false;
    let renderedKey = '', pendingKey = '', layoutToken = 0;
    const layouts = new Map(), poses = new Map(), scopeSelections = new Map(), pendingLevels = new Set();
    const surface = P.makeViewport(canvas, { select: select, openGroup: drill,
        changed: function(value) { zoomText.textContent = Math.round(value * 100) + '%'; } });
    const panel = P.makePanel(root, { source: function(index) { source = index; requestedSource = ''; render(payload); },
        navigate: navigate, locate: function() { surface.focus(selected); canvas.scrollIntoView({ block: 'nearest' }); },
        open: function(snippet) { A.post('openFile', { path: snippet.path, line: snippet.line, endLine: snippet.requestedEndLine }); } });

    function scenarios() { return payload.snapshot && payload.snapshot.processGraphs || []; }
    function canTrace() {
        const modules = payload.snapshot && (payload.snapshot.views || []).find(function(view) { return view.id === 'modules'; });
        return !!modules && modules.nodes.some(function(node) { return node.kind === 'file' && node.language !== 'markdown'; });
    }
    function current() { return scenarios().find(function(item) { return item.id === activeID; }) || null; }
    function remember() {
        if (renderedKey) poses.set(renderedKey, surface.pose());
        if (activeID) scopeSelections.set(activeID + '|' + (parent || ''), selected);
    }
    function reset() {
        remember(); project = null; activeID = null; parent = null; selected = null; source = 0;
        requestedSource = ''; savedChoices = ''; savedVersion = ''; awaiting = false;
        renderedKey = ''; pendingKey = ''; layoutToken += 1;
        layouts.clear(); poses.clear(); scopeSelections.clear(); pendingLevels.clear(); surface.clear();
    }
    function requestTrace() {
        if (payload.busy || !canTrace() || !question.value.trim()) return;
        awaiting = true; A.post('traceProcess', { question: question.value.trim() });
    }
    function select(id) {
        selected = id; source = 0;
        const scenario = current();
        const key = scenario && P.sourceKey(scenario, { id: id }, 0);
        if (key && ((payload.processState || {}).errors || {})[key]) requestedSource = '';
        render(payload);
    }
    function setScope(next, selection) {
        remember(); parent = next || null; source = 0; requestedSource = ''; pendingKey = ''; layoutToken += 1;
        selected = selection || scopeSelections.get(activeID + '|' + (parent || '')) || null;
        render(payload);
    }
    function drill(id) {
        const scenario = current();
        if (scenario && P.children(scenario.graph, id).length) setScope(id, null);
    }
    function navigate(id) {
        const scenario = current(), node = scenario && P.index(scenario.graph).get(id);
        if (!node) return;
        if ((node.parent || null) !== parent) setScope(node.parent || null, id);
        else { select(id); surface.focus(id); }
    }

    function draw(scenario, level) {
        const key = scenario.id + '|' + scenario.createdAt + '|' + (parent || '') + '|' + direction.value;
        const known = layouts.get(key);
        if (known) {
            if (renderedKey !== key) {
                remember(); surface.setDrawing(known, scenario.graph, poses.get(key), selected); renderedKey = key;
                returns.textContent = '';
                known.edges.filter(function(edge) { return edge.returnName; }).forEach(function(edge) {
                    returns.append(P.button(edge.returnName + ': ' + edge.fullLabel, function() { navigate(edge.from); }, 'process-return-link'));
                });
            }
            message.hidden = true; surface.highlight(selected, focus.checked); return;
        }
        if (pendingKey === key) return;
        pendingKey = key; const ticket = ++layoutToken;
        message.hidden = false; message.textContent = 'Laying out the process...';
        remember(); surface.clear(); renderedKey = ''; returns.textContent = '';
        A.loadLibraries().then(function() { return P.layout(level, new window['ELK'](), direction.value); }).then(function(drawing) {
            if (ticket !== layoutToken) return;
            layouts.set(key, drawing);
            while (layouts.size > 32) layouts.delete(layouts.keys().next().value);
            pendingKey = '';
            if (active && current() && current().id === scenario.id) draw(scenario, level);
        }).catch(function(error) {
            if (ticket !== layoutToken) return;
            pendingKey = ''; message.hidden = false; message.textContent = 'The process layout could not be drawn: ' + error.message;
        });
    }

    function render(next) {
        payload = next || {}; active = true; root.hidden = false; main.classList.add('process-mode');
        if (project !== payload.root) { reset(); project = payload.root; question.value = ''; }
        const saved = scenarios();
        const version = saved.map(function(item) { return item.id + '|' + item.createdAt; }).join(';');
        if (!saved.some(function(item) { return item.id === activeID; }) || awaiting && version !== savedVersion) {
            remember(); const latest = saved[saved.length - 1]; activeID = latest ? latest.id : null;
            parent = null; selected = null; source = 0; requestedSource = ''; awaiting = false;
        }
        savedVersion = version;
        const scenario = current();
        scopeInfo.hidden = !scenario;
        takeaway.textContent = scenario ? scenario.graph.takeaway : '';
        omitted.textContent = scenario && scenario.graph.omitted ? 'Not mapped: ' + scenario.graph.omitted : '';
        omitted.hidden = !omitted.textContent;
        if (savedChoices !== version) {
            picker.textContent = ''; savedChoices = version;
            saved.forEach(function(item) { const option = P.element('option', '', item.graph.title); option.value = item.id; picker.append(option); });
        }
        picker.hidden = saved.length < 2; picker.value = activeID || '';
        if (!question.value && scenario) question.value = scenario.graph.question;
        submit.disabled = !!payload.busy || !canTrace() || !question.value.trim();
        submit.title = canTrace() ? 'Read the source again and trace this process' : 'Scan a project with source files first';
        submit.textContent = (payload.processState || {}).tracing ? 'Tracing...' : 'Trace process';
        stop.hidden = !(payload.processState || {}).tracing;
        breadcrumbs.textContent = '';
        breadcrumbs.append(P.button(scenario ? scenario.graph.title : 'Process', function() {
            const first = scenario && P.ancestors(scenario.graph, parent)[0]; setScope(null, first ? first.id : null);
        }, 'arch-crumb'));
        if (!scenario) {
            canvas.hidden = true; returns.textContent = ''; panel.render({ node: null });
            message.hidden = false; message.textContent = canTrace() ? 'Describe a process to map its branches, joins and returns from source code.' : 'Scan a project with source files to build a process map.';
            summary.textContent = 'Source interpretation'; openGroup.hidden = true; return;
        }
        canvas.hidden = false;
        P.ancestors(scenario.graph, parent).forEach(function(node) {
            breadcrumbs.append(P.element('span', 'arch-muted', '/'), P.button(node.title, function() { setScope(node.id, null); }, 'arch-crumb'));
        });
        const state = payload.processState || {}, key = P.levelKey(scenario, parent);
        const level = (state.levels || {})[key];
        if (level) pendingLevels.delete(key);
        else if (!pendingLevels.has(key)) { pendingLevels.add(key); A.post('processLevel', { scenario: scenario.id, parent: parent }); }
        const byID = P.index(scenario.graph);
        if (level && !level.nodes.some(function(node) { return node.id === selected; })) {
            const first = level.nodes.find(function(node) { return node.kind === 'entry'; }) || level.nodes[0]; selected = first ? first.id : null;
        }
        const node = byID.get(selected);
        openGroup.hidden = !node || !P.children(scenario.graph, node.id).length;
        openGroup.textContent = node ? 'Open group (' + P.children(scenario.graph, node.id).length + ')' : 'Open group';
        summary.textContent = (P.isStale(scenario, payload.snapshot) ? 'Source changed. ' : '')
            + (level ? level.nodes.length + ' blocks on this level, ' + level.edges.length + ' transitions. ' : '') + 'Source interpretation';
        if (level && level.nodes.length) draw(scenario, level);
        else { remember(); surface.clear(); renderedKey = ''; message.hidden = false; message.textContent = level ? 'This group has no internal steps.' : 'Opening the group...'; }
        surface.highlight(selected, focus.checked);
        panel.render({ node: node, scenario: scenario, payload: payload, level: level, source: source });
        if (node && (node.sources || [])[source]) {
            const stamp = P.sourceKey(scenario, node, source) + '|' + scenario.createdAt + '|' + payload.snapshot.scannedAt;
            if (requestedSource !== stamp) { requestedSource = stamp; A.post('processSource', { scenario: scenario.id, node: node.id, index: source }); }
        }
    }

    question.addEventListener('input', function() { submit.disabled = !!payload.busy || !canTrace() || !question.value.trim(); });
    form.addEventListener('submit', function(event) { event.preventDefault(); requestTrace(); });
    picker.addEventListener('change', function() {
        remember(); activeID = picker.value; parent = null; selected = null; source = 0; requestedSource = '';
        const scenario = current(); question.value = scenario ? scenario.graph.question : ''; render(payload);
    });
    direction.addEventListener('change', function() { remember(); render(payload); });
    focus.addEventListener('change', function() { surface.highlight(selected, focus.checked); });
    Object.assign(A, { process: { render: render, fit: surface.fit, reset: reset,
        hide: function() { active = false; remember(); root.hidden = true; main.classList.remove('process-mode'); },
        ask: function() { question.focus(); } } });
})(window['MVProcess'], window['MVArchitecture']);
