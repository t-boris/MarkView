(function(global) {
    function setup(fixture) {
        const A = global.MVArchitecture;
        const payload = fixture.payload, requests = [];
        A.post = function(action, fields) {
            fields = fields || {}; requests.push({ action: action, fields: fields });
            if (action === 'processLevel') {
                const key = fields.scenario + '|' + (fields.parent || '');
                payload.processState.levels[key] = fixture.levels[key];
                queueMicrotask(function() { global.showArchitecture(payload); });
            } else if (action === 'processSource') {
                const key = fields.scenario + '|' + fields.node + '|' + fields.index;
                payload.processState.loading = key;
                queueMicrotask(function() {
                    global.showArchitecture(payload);
                    queueMicrotask(function() {
                        payload.processState.snippets[key] = fixture.snippets[key];
                        payload.processState.loading = null;
                        global.showArchitecture(payload);
                    });
                });
            }
        };
        global.showArchitecture(payload);
        document.querySelector('[data-arch-view="process"]').click();
        return { fixture: fixture, payload: payload, requests: requests };
    }

    async function run(state) {
        let count = 0;
        const root = document.getElementById('arch-process');
        const q = function(selector) { return root.querySelector(selector); };
        function check(value, message) { if (!value) throw new Error(message); count++; }
        async function until(test, message) {
            const end = Date.now() + 12000;
            while (!test() && Date.now() < end) await new Promise(function(resolve) { setTimeout(resolve, 20); });
            check(test(), message);
        }
        function node(id) { return q('[data-process-node="' + id + '"]'); }
        function sourceCode() { return q('.process-code-host').textContent; }
        function clickText(text) {
            const button = Array.from(root.querySelectorAll('button')).find(function(button) { return button.textContent === text; });
            check(!!button, 'Button exists: ' + text); button.click();
        }
        await until(function() { return !!node('11'); }, 'The real process view draws the top-level graph');
        check(root.querySelectorAll('.process-node').length === 14, 'All fourteen groups are visible');
        const entryBox = node('1').getBoundingClientRect(), mapBox = q('.process-viewport').getBoundingClientRect();
        check(entryBox.left >= mapBox.left + 16 && entryBox.left <= mapBox.left + 36, 'A large map starts near its leading edge without wasting half the viewport');
        check(root.querySelectorAll('.process-edge.is-return').length === 2, 'Both feedback paths are drawn');
        const group = node('11'); group.click();
        await until(function() { return sourceCode().includes('stage_11'); }, 'A click loads the selected code');
        check(q('.process-selection h3').textContent === 'Code task', 'The inspector describes the selected block');
        check(root.querySelectorAll('.process-node').length === 14, 'A single click keeps the overview open');
        check(node('11') === group, 'Source updates preserve the same block element for double-click');
        const originalTransform = q('.process-scene').style.transform;
        group.click();
        check(q('.process-scene').style.transform === originalTransform, 'Selecting a block keeps graph positions and zoom');
        group.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, detail: 2 }));
        await until(function() { return !!node('11.2'); }, 'Double-click enters the group');
        check(root.querySelectorAll('.process-node').length === 4, 'The group exposes its four internal blocks');
        check(q('.process-breadcrumbs').textContent.includes('Code task'), 'The breadcrumb keeps the parent context');
        node('11.2').click();
        node('11.2').dispatchEvent(new MouseEvent('dblclick', { bubbles: true, detail: 2 }));
        await until(function() { return !!node('11.2.1'); }, 'Double-click opens the third level');
        await until(function() { return sourceCode().includes('stage_11_2_1'); }, 'Nested code follows the selected block');
        check(q('.process-breadcrumbs').textContent.includes('Imports'), 'The nested group remains named');
        const tabs = root.querySelectorAll('.process-source-tab');
        check(tabs.length === 2, 'Multiple source excerpts are available'); tabs[1].click();
        await until(function() { return sourceCode().includes('guard_stage_11_2_1'); }, 'Switching sources changes the code');
        check(q('.process-source-path').textContent === 'rules.py:10-12', 'The selected citation is shown');
        check(root.querySelectorAll('.process-source-tab')[1] === tabs[1], 'Loading a source keeps its tab element and keyboard focus');
        check(q('.process-explanation').textContent.includes('The rule that guards this operation.'), 'Explain changes with the excerpt');
        check(q('.process-code-host .cm-content').getAttribute('contenteditable') === 'false', 'The excerpt is read-only');
        check(Array.from(root.querySelectorAll('.cm-lineNumbers .cm-gutterElement')).some(function(line) { return line.textContent === '10'; }), 'Line numbers start at the real source line');
        clickText('Open full file');
        const opened = state.requests.filter(function(item) { return item.action === 'openFile'; }).pop();
        check(opened && opened.fields.path === 'rules.py' && opened.fields.line === 10, 'The full-file action carries the selected source location');
        global.showArchitecture(state.payload);
        check(q('.process-source-path').textContent === 'rules.py:10-12', 'Returning to X-Ray preserves the selected excerpt');
        check(q('.process-breadcrumbs').textContent.includes('Imports'), 'Returning preserves the nested group');
        clickText('1:1');
        check(q('.process-zoom').textContent === '100%', 'Actual size makes the graph readable');
        clickText('+');
        check(parseInt(q('.process-zoom').textContent, 10) > 100, 'The zoom-in control works');
        clickText('-');
        const direction = q('[aria-label="Flow direction"]'); direction.value = 'DOWN'; direction.dispatchEvent(new Event('change'));
        await until(function() { return !!node('11.2.4'); }, 'The graph can run from top to bottom');
        const top = node('11.2.1').getBoundingClientRect(), bottom = node('11.2.4').getBoundingClientRect();
        check(bottom.y > top.y, 'Top-to-bottom direction changes the layout');
        const parentCrumb = Array.from(root.querySelectorAll('.process-breadcrumbs button')).find(function(button) { return button.textContent === 'Code task'; });
        check(!!parentCrumb, 'The ancestor group has a breadcrumb'); parentCrumb.click();
        await until(function() { return !!node('11.2'); }, 'An ancestor breadcrumb opens that group');
        check(node('11.2').getAttribute('aria-pressed') === 'true', 'Returning to the parent retains its selected child');
        const first = q('.process-breadcrumbs button'); first.click();
        await until(function() { return !!node('13'); }, 'The root breadcrumb returns to the overview');
        node('13').click();
        check(q('.process-related').textContent.includes('Temporary failure'), 'The inspector retains the retry condition');
        check(q('.process-related').textContent.includes('Plan must be recalculated'), 'The inspector retains the replan condition');
        const checkbox = q('.process-context input'); checkbox.checked = true; checkbox.dispatchEvent(new Event('change'));
        check(Array.from(root.querySelectorAll('.process-edge-group')).some(function(edge) { return edge.style.display === 'none'; }), 'Focus hides unrelated connections without moving blocks');
        check(root.querySelectorAll('.process-node').length === 14, 'Focus retains the surrounding structure');
        checkbox.checked = false; checkbox.dispatchEvent(new Event('change'));
        return { passed: count, requests: state.requests.length, blocks: state.payload.snapshot.processGraphs[0].graph.nodes.length };
    }

    global.ProcessGraphWebChecks = { setup: setup, run: run };
})(window);
