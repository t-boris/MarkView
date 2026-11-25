(function(P) {
    function makePanel(parent, actions) {
        const host = P.element('section', 'process-inspector');
        host.setAttribute('aria-label', 'Selected block code and explanation');
        const heading = P.element('div', 'process-selection');
        const title = P.element('h3');
        const symbol = P.element('code');
        const locate = P.button('Locate block', actions.locate);
        heading.append(title, symbol, locate);
        const columns = P.element('div', 'process-columns');
        const codePanel = P.element('section', 'process-code-panel');
        const codeHead = P.element('div', 'process-panel-head');
        const open = P.button('Open full file', function() {
            if (selectedSnippet) actions.open(selectedSnippet);
        });
        codeHead.append(P.element('h4', '', 'Code excerpt'), open);
        const tabs = P.element('div', 'process-sources');
        tabs.setAttribute('role', 'group'); tabs.setAttribute('aria-label', 'Source excerpts');
        const path = P.element('div', 'process-source-path');
        const status = P.element('div', 'process-source-status'); status.setAttribute('role', 'status');
        const codeHost = P.element('div', 'process-code-host');
        codePanel.append(codeHead, tabs, path, status, codeHost);
        const explanationPanel = P.element('section', 'process-explain-panel');
        const explainHead = P.element('div', 'process-panel-head');
        explainHead.append(P.element('h4', '', 'Explain'), P.element('span', 'arch-muted', 'For the selected block and excerpt'));
        const explanation = P.element('div', 'process-explanation'); explanation.setAttribute('aria-live', 'polite');
        explanationPanel.append(explainHead, explanation);
        columns.append(codePanel, explanationPanel);
        const related = P.element('div', 'process-related');
        host.append(heading, columns, related); parent.append(host);
        let viewer = null, viewerGeneration = 0, codeStamp = '', tabsStamp = '', selectedSnippet = null;

        function showCode(snippet, key) {
            const stamp = key + '|' + (snippet ? snippet.path + '|' + snippet.language + '|' + snippet.line + '|' + snippet.code : '');
            if (stamp === codeStamp) return;
            codeStamp = stamp;
            const ticket = ++viewerGeneration;
            if (!snippet) {
                if (viewer) viewer.setDoc('', '', 1);
                else codeHost.textContent = '';
                return;
            }
            const loader = window['MVLoadCode'];
            if (!loader) { codeHost.textContent = snippet.code; return; }
            loader().then(function() {
                if (ticket !== viewerGeneration) return;
                if (!viewer) {
                    codeHost.textContent = '';
                    viewer = window['MVCode'].create(codeHost, { doc: snippet.code, language: snippet.language,
                        startLine: snippet.line, dark: document.documentElement.getAttribute('data-theme') === 'dark' });
                } else viewer.setDoc(snippet.code, snippet.language, snippet.line);
            }).catch(function() {
                if (ticket === viewerGeneration) { codeHost.textContent = ''; codeHost.append(P.element('pre', '', snippet.code)); }
            });
        }

        function render(context) {
            const node = context.node;
            host.hidden = !node;
            if (!node) { selectedSnippet = null; showCode(null, 'empty'); return; }
            const scenario = context.scenario, source = (node.sources || [])[context.source];
            const key = P.sourceKey(scenario, node, context.source), state = context.payload.processState || {};
            const error = (state.errors || {})[key];
            const snippet = error ? null : (state.snippets || {})[key];
            selectedSnippet = snippet || null;
            title.textContent = node.title;
            symbol.textContent = node.symbol || '';
            symbol.hidden = !node.symbol;
            open.disabled = !snippet;
            const nextTabs = scenario.id + '|' + node.id + '|' + JSON.stringify(node.sources || []);
            if (tabsStamp !== nextTabs) {
                tabsStamp = nextTabs; tabs.textContent = '';
                (node.sources || []).forEach(function(item, i) {
                    const label = item.path.split('/').pop() + ':' + item.line;
                    const tab = P.button(label, function() { actions.source(i); }, 'process-source-tab');
                    tab.title = item.path + ':' + item.line + '-' + item.endLine;
                    tabs.append(tab);
                });
            }
            Array.from(tabs.children).forEach(function(tab, i) { tab.setAttribute('aria-pressed', String(i === context.source)); });
            path.textContent = source ? source.path + ':' + source.line + '-' + source.endLine : 'External participant';
            const stale = snippet && snippet.stale || P.isStale(scenario, context.payload.snapshot || {});
            status.classList.toggle('process-warning', !!stale || !!error);
            status.textContent = error || (stale ? 'Source changed. Refresh the process map to update this explanation.'
                : !source ? 'This participant has no source excerpt.'
                : state.loading === key ? (snippet ? 'Checking source...' : 'Loading source...')
                : snippet && snippet.truncated ? 'Excerpt shortened. Open the full file to read all cited code.' : 'Read-only source');
            showCode(snippet, key);
            explanation.textContent = '';
            const fields = [['Purpose', node.explanation], ['This excerpt', source && source.note],
                ['Input', node.input], ['Output and continuation', node.output]];
            fields.forEach(function(pair) {
                if (!pair[1]) return;
                const part = P.element('div', 'process-explain-item');
                part.append(P.element('h5', '', pair[0]), P.element('p', '', pair[1])); explanation.append(part);
            });
            related.textContent = '';
            const connections = P.relations(scenario.graph, context.level || { edges: [], boundary: [] }, node.id);
            const byID = P.index(scenario.graph);
            [['Incoming', connections.incoming], ['Outgoing', connections.outgoing]].forEach(function(pair) {
                const section = P.element('div', 'process-connection-list');
                section.append(P.element('h5', '', pair[0] + ' connections'));
                if (!pair[1].length) section.append(P.element('span', 'arch-muted', 'No connection at this level'));
                pair[1].forEach(function(item) {
                    const target = byID.get(item.other);
                    const link = P.button((target ? target.title : item.other) + ': ' + item.edge.label,
                        function() { actions.navigate(item.other); }, 'process-reference');
                    link.classList.toggle('is-return', item.edge.kind === 'return');
                    if (item.boundary) link.title = 'Connection outside the current group';
                    section.append(link);
                });
                related.append(section);
            });
        }

        return { render: render, element: host };
    }

    Object.assign(P, { makePanel: makePanel });
})(window['MVProcess']);
