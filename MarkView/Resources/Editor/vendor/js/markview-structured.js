        // STRUCTURED DATA SUPPORT (JSON / XML / YAML)
        // ============================================================================

        window.setStructuredContent = function(content, fileType) {
            DOM.editor.value = content;
            state.markdown = content;
            state.fileType = fileType;
            wysiwygDirty = false;
            switchToStructuredView();
        };

        function switchToStructuredView() {
            state.mode = 'structured';
            if (typeof leaveInsightView === 'function') leaveInsightView();
            state.markdown = DOM.editor.value; // sync from source textarea
            DOM.editorPane.style.display = 'none';
            DOM.previewPane.style.display = 'flex';
            DOM.previewPane.style.flexDirection = 'column';
            DOM.rendered.contentEditable = 'false';
            DOM.statusMode.textContent = state.fileType.toUpperCase();
            document.getElementById('mode-toggle').textContent = 'Source ↗';
            document.getElementById('wysiwyg-toolbar').style.display = 'none';
            renderStructuredContent();
        }

        function switchToStructuredSource() {
            state.mode = 'structured-source';
            if (state.fileType === 'json' || state.fileType === 'yaml') { openStructSourceEditor(); return; }
            if (typeof leaveInsightView === 'function') leaveInsightView();
            DOM.editorPane.style.display = 'flex';
            DOM.previewPane.style.display = 'none';
            DOM.statusMode.textContent = state.fileType.toUpperCase() + ' Source';
            document.getElementById('wysiwyg-toolbar').style.display = 'none';
            document.getElementById('mode-toggle').textContent = 'Tree ↗';
            // Apply current font size to source editor
            const currentSize = getComputedStyle(DOM.rendered).fontSize;
            if (currentSize) DOM.editor.style.fontSize = currentSize;
            DOM.editor.focus();
        }

        function renderStructuredContent() {
            // JSON Canvas gets its own interactive renderer (markview-canvas.js);
            // json/xml/yaml fall through to the fold-tree below.
            if (state.fileType === 'canvas') {
                if (typeof window.renderCanvasView === 'function') window.renderCanvasView();
                return;
            }
            if (typeof window.leaveCanvasView === 'function') window.leaveCanvasView();
            let html = '';
            try {
                if (state.fileType === 'json') {
                    const parsed = JSON.parse(state.markdown);
                    html = '<div class="struct-tree struct-editable">' + renderStructToolbar() + renderJSON(parsed, '', true, []) + '</div>';
                    extractStructHeadings(parsed, 'json');
                } else if (state.fileType === 'xml') {
                    const parser = new DOMParser();
                    const doc = parser.parseFromString(state.markdown, 'text/xml');
                    const parseError = doc.querySelector('parsererror');
                    if (parseError) throw new Error(parseError.textContent);
                    html = '<div class="struct-tree">' + renderStructToolbar() + renderXML(doc.documentElement, '', true) + '</div>';
                    extractStructHeadings(doc.documentElement, 'xml');
                } else if (state.fileType === 'yaml') {
                    const parsed = jsyaml.load(state.markdown);
                    html = '<div class="struct-tree struct-editable">' + renderStructToolbar() + renderJSON(parsed, '', true, []) + '</div>';
                    extractStructHeadings(parsed, 'yaml');
                }
            } catch (e) {
                // Parse error — show error + syntax-highlighted source
                html = '<div class="struct-error">Parse Error: ' + escapeHTML(e.message) + '</div>'
                     + '<pre class="language-' + state.fileType + '" style="padding:12px;margin:0;overflow:auto;"><code>'
                     + escapeHTML(state.markdown) + '</code></pre>';
                if (typeof Prism !== 'undefined') {
                    setTimeout(() => Prism.highlightAllUnder(DOM.rendered), 50);
                }
            }
            wireStructEditing();
            const collapsed = collapsedStructPaths();
            DOM.rendered.innerHTML = html;
            // Wire up toggle buttons
            DOM.rendered.querySelectorAll('.struct-toggle').forEach(el => {
                el.addEventListener('click', () => toggleStructNode(el));
            });
            restoreCollapsedStructPaths(collapsed);
        }

        function renderStructToolbar() {
            return '<div class="struct-toolbar">'
                + '<button onclick="structFoldAll()">Fold All</button>'
                + '<button onclick="structUnfoldAll()">Unfold All</button>'
                + (state.fileType !== 'xml' ? '<button onclick="structFormat()">Format</button>' : '')
                + (state.fileType !== 'xml' ? '<button onclick="structMinify()">Minify</button>' : '')
                + '<span class="spacer"></span>'
                + (state.fileType !== 'xml' ? '<span class="struct-hint">Double-click a value or key to edit · hover a line for + and ×</span>' : '')
                + '<button onclick="toggleStructMode()">' + (state.mode === 'structured' ? 'Source ↗' : 'Tree ↗') + '</button>'
                + '</div>';
        }

        // --- JSON / YAML tree renderer ---
        function renderJSON(value, key, isLast, path) {
            path = path || [];
            if (value === null) return renderJSONLeaf(key, '<span class="struct-null struct-value">null</span>', isLast, path);
            if (typeof value === 'boolean') return renderJSONLeaf(key, '<span class="struct-boolean struct-value">' + value + '</span>', isLast, path);
            if (typeof value === 'number') return renderJSONLeaf(key, '<span class="struct-number struct-value">' + value + '</span>', isLast, path);
            if (typeof value === 'string') return renderJSONLeaf(key, '<span class="struct-string struct-value">"' + escapeHTML(value) + '"</span>', isLast, path);
            if (value instanceof Date) return renderJSONLeaf(key, '<span class="struct-string struct-value">' + escapeHTML(value.toISOString()) + '</span>', isLast, path);

            const isArray = Array.isArray(value);
            const entries = isArray ? value.map((v, i) => [i, v]) : Object.entries(value);
            const open = isArray ? '[' : '{';
            const close = isArray ? ']' : '}';
            const count = entries.length;
            const id = 'sn-' + Math.random().toString(36).substr(2, 8);

            let html = '<div class="struct-node" id="' + id + '" data-path="' + escapeHTML(JSON.stringify(path)) + '" data-container="' + (isArray ? 'array' : 'object') + '">';
            html += '<div class="struct-line">';
            html += '<span class="struct-toggle" data-target="' + id + '-children">▼</span>';
            if (key !== '') html += '<span class="struct-key">' + (typeof key === 'number' ? key : '"' + escapeHTML(String(key)) + '"') + '</span><span class="struct-colon">: </span>';
            html += '<span class="struct-bracket">' + open + '</span>';
            html += '<span class="struct-count">' + count + (count === 1 ? ' item' : ' items') + '</span>';
            html += structActions(path, true);
            html += '</div>';
            html += '<div class="struct-children" id="' + id + '-children">';
            entries.forEach(([k, v], i) => {
                html += renderJSON(v, k, i === entries.length - 1, path.concat([k]));
            });
            html += '</div>';
            html += '<div class="struct-line"><span class="struct-placeholder"></span><span class="struct-bracket">' + close + '</span>' + (isLast ? '' : '<span class="struct-comma">,</span>') + '</div>';
            html += '</div>';
            return html;
        }

        function renderJSONLeaf(key, valueHtml, isLast, path) {
            let html = '<div class="struct-node" data-path="' + escapeHTML(JSON.stringify(path || [])) + '"><div class="struct-line"><span class="struct-placeholder"></span>';
            if (key !== '') html += '<span class="struct-key">' + (typeof key === 'number' ? key : '"' + escapeHTML(String(key)) + '"') + '</span><span class="struct-colon">: </span>';
            html += valueHtml;
            if (!isLast) html += '<span class="struct-comma">,</span>';
            html += structActions(path || [], false);
            html += '</div></div>';
            return html;
        }

        /** + (add to an object or array) and × (delete), shown on hover. */
        function structActions(path, isContainer) {
            let html = '<span class="struct-actions">';
            if (isContainer) html += '<button class="struct-act" data-act="add" title="Add an item">+</button>';
            if (path.length) html += '<button class="struct-act" data-act="delete" title="Delete">×</button>';
            return html + '</span>';
        }

        // --- XML tree renderer ---
        function renderXML(node, indent, isLast) {
            if (node.nodeType === Node.TEXT_NODE) {
                const text = node.textContent.trim();
                if (!text) return '';
                return '<div class="struct-node"><div class="struct-line"><span class="struct-placeholder"></span><span class="struct-text">' + escapeHTML(text) + '</span></div></div>';
            }
            if (node.nodeType === Node.COMMENT_NODE) {
                return '<div class="struct-node"><div class="struct-line"><span class="struct-placeholder"></span><span class="struct-comment">&lt;!-- ' + escapeHTML(node.textContent) + ' --&gt;</span></div></div>';
            }
            if (node.nodeType !== Node.ELEMENT_NODE) return '';

            const children = Array.from(node.childNodes).filter(c => c.nodeType === Node.ELEMENT_NODE || (c.nodeType === Node.TEXT_NODE && c.textContent.trim()));
            const hasChildren = children.length > 0;
            const id = 'sn-' + Math.random().toString(36).substr(2, 8);
            let attrs = '';
            for (const attr of node.attributes) {
                attrs += ' <span class="struct-attr-name">' + escapeHTML(attr.name) + '</span>=<span class="struct-attr-value">"' + escapeHTML(attr.value) + '"</span>';
            }

            let html = '<div class="struct-node" id="' + id + '">';
            html += '<div class="struct-line">';
            if (hasChildren) {
                html += '<span class="struct-toggle" data-target="' + id + '-children">▼</span>';
            } else {
                html += '<span class="struct-placeholder"></span>';
            }
            html += '<span class="struct-bracket">&lt;</span><span class="struct-tag">' + escapeHTML(node.tagName) + '</span>' + attrs;

            if (!hasChildren) {
                // Self-closing or text-only
                const textContent = node.textContent.trim();
                if (textContent && textContent.length < 80) {
                    html += '<span class="struct-bracket">&gt;</span><span class="struct-text">' + escapeHTML(textContent) + '</span>';
                    html += '<span class="struct-bracket">&lt;/</span><span class="struct-tag">' + escapeHTML(node.tagName) + '</span><span class="struct-bracket">&gt;</span>';
                } else {
                    html += '<span class="struct-bracket"> /&gt;</span>';
                }
                html += '</div></div>';
                return html;
            }

            html += '<span class="struct-bracket">&gt;</span>';
            html += '<span class="struct-count">' + children.length + '</span>';
            html += '</div>';
            html += '<div class="struct-children" id="' + id + '-children">';
            children.forEach((child, i) => {
                html += renderXML(child, indent + '  ', i === children.length - 1);
            });
            html += '</div>';
            html += '<div class="struct-line"><span class="struct-placeholder"></span><span class="struct-bracket">&lt;/</span><span class="struct-tag">' + escapeHTML(node.tagName) + '</span><span class="struct-bracket">&gt;</span></div>';
            html += '</div>';
            return html;
        }

        // --- Fold/unfold ---
        function toggleStructNode(toggleEl) {
            const targetId = toggleEl.getAttribute('data-target');
            const children = document.getElementById(targetId);
            if (!children) return;
            const collapsed = children.classList.toggle('collapsed');
            toggleEl.textContent = collapsed ? '▶' : '▼';
            toggleEl.classList.toggle('collapsed', collapsed);
        }

        window.structFoldAll = function() {
            DOM.rendered.querySelectorAll('.struct-children').forEach(el => { el.classList.add('collapsed'); });
            DOM.rendered.querySelectorAll('.struct-toggle').forEach(el => { el.textContent = '▶'; el.classList.add('collapsed'); });
        };
        window.structUnfoldAll = function() {
            DOM.rendered.querySelectorAll('.struct-children').forEach(el => { el.classList.remove('collapsed'); });
            DOM.rendered.querySelectorAll('.struct-toggle').forEach(el => { el.textContent = '▼'; el.classList.remove('collapsed'); });
        };
        window.structFormat = function() {
            try {
                if (state.fileType === 'json') {
                    const parsed = JSON.parse(state.markdown);
                    const formatted = JSON.stringify(parsed, null, 2);
                    DOM.editor.value = formatted;
                    state.markdown = formatted;
                    renderStructuredContent();
                    sendToSwift('contentChanged', { markdown: formatted, html: '' });
                } else if (state.fileType === 'yaml') {
                    const formatted = window.MVData ? window.MVData.YAML.parseDocument(state.markdown).toString({ indent: 2 })
                                                    : jsyaml.dump(jsyaml.load(state.markdown), { indent: 2 });
                    DOM.editor.value = formatted;
                    state.markdown = formatted;
                    renderStructuredContent();
                    sendToSwift('contentChanged', { markdown: formatted, html: '' });
                }
            } catch(e) {}
        };
        window.structMinify = function() {
            try {
                if (state.fileType === 'json') {
                    const parsed = JSON.parse(state.markdown);
                    const minified = JSON.stringify(parsed);
                    DOM.editor.value = minified;
                    state.markdown = minified;
                    renderStructuredContent();
                    sendToSwift('contentChanged', { markdown: minified, html: '' });
                }
            } catch(e) {}
        };
        window.toggleStructMode = function() {
            if (state.mode === 'structured') {
                switchToStructuredSource();
            } else {
                // Re-parse from the source editor
                closeStructSourceEditor();
                state.markdown = DOM.editor.value;
                switchToStructuredView();
            }
        };

        // --- Structure headings for TOC ---
        function extractStructHeadings(data, type) {
            const headings = [];
            let idCounter = 0;
            function addHeading(text, level) {
                headings.push({ id: 'struct-h-' + (idCounter++), level: level, text: text });
            }
            if (type === 'json' || type === 'yaml') {
                if (data && typeof data === 'object' && !Array.isArray(data)) {
                    for (const key of Object.keys(data)) {
                        addHeading(key, 1);
                        const val = data[key];
                        if (val && typeof val === 'object' && !Array.isArray(val)) {
                            for (const k2 of Object.keys(val)) {
                                addHeading(k2, 2);
                            }
                        }
                    }
                }
            } else if (type === 'xml') {
                // data is the root element
                addHeading(data.tagName, 1);
                for (const child of data.children) {
                    addHeading(child.tagName, 2);
                    for (const grandchild of child.children) {
                        addHeading(grandchild.tagName, 3);
                    }
                }
            }
            sendToSwift('headingsUpdated', headings);
        }

        function escapeHTML(str) {
            if (typeof str !== 'string') return String(str);
            return str.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
        }

        // Override mode toggle for structured files
        const originalToggleMode = typeof toggleMode === 'function' ? toggleMode : null;
        function toggleModeWrapper() {
            // Insight mode does not participate in editor source/preview toggling.
            if (state.mode === 'insight') return;
            if (state.fileType !== 'markdown') {
                toggleStructMode();
            } else if (originalToggleMode) {
                originalToggleMode();
            }
        }

        // ============================================================================

        // --- Editing JSON / YAML (Task 84) ------------------------------------------------

        /** Paths of collapsed containers, to keep them collapsed after an edit re-renders the tree. */
        function collapsedStructPaths() {
            const out = new Set();
            DOM.rendered.querySelectorAll('.struct-node[data-path] > .struct-children.collapsed').forEach(el => out.add(el.parentElement.dataset.path));
            return out;
        }
        function restoreCollapsedStructPaths(paths) {
            if (!paths || !paths.size) return;
            DOM.rendered.querySelectorAll('.struct-node[data-path]').forEach(node => {
                if (!paths.has(node.dataset.path)) return;
                const children = node.querySelector(':scope > .struct-children');
                const toggle = node.querySelector(':scope > .struct-line > .struct-toggle');
                if (children) children.classList.add('collapsed');
                if (toggle) { toggle.textContent = '▶'; toggle.classList.add('collapsed'); }
            });
        }

        /** The indentation the JSON file uses (2 or 4 spaces, or a tab), to keep it on save. */
        function jsonIndent(text) {
            const m = text.match(/\n([ \t]+)\S/);
            if (!m) return 2;
            return m[1][0] === '\t' ? '\t' : m[1].length;
        }

        /** Text typed for a value: JSON literals (numbers, true, null, "…", {…}, […]) or plain text. */
        function parseTypedValue(text) {
            const t = text.trim();
            if (t === '') return '';
            try { return JSON.parse(t); } catch (e) { return text; }
        }

        function loadYAMLLibrary() {
            if (window.MVData) return Promise.resolve(window.MVData);
            return new Promise((resolve, reject) => {
                const script = document.createElement('script');
                script.src = 'vendor/js/data.bundle.js';
                script.onload = () => resolve(window.MVData);
                script.onerror = () => reject(new Error('YAML editing library missing'));
                document.head.appendChild(script);
            });
        }

        /** Apply `change(document)` and save the new text into the tab (not to disk: ⌘S does that). */
        async function editStructured(change) {
            let next;
            if (state.fileType === 'json') {
                const data = JSON.parse(state.markdown);
                const result = change({
                    get: (path) => path.reduce((o, k) => o[k], data),
                    set: (path, value) => { if (!path.length) return value; path.slice(0, -1).reduce((o, k) => o[k], data)[path[path.length - 1]] = value; },
                    remove: (path) => { const parent = path.slice(0, -1).reduce((o, k) => o[k], data); const key = path[path.length - 1];
                                        if (Array.isArray(parent)) parent.splice(key, 1); else delete parent[key]; },
                    rename: (path, name) => { const parent = path.slice(0, -1).reduce((o, k) => o[k], data); const old = path[path.length - 1];
                                              const rebuilt = {}; for (const k of Object.keys(parent)) rebuilt[k === old ? name : k] = parent[k];
                                              for (const k of Object.keys(parent)) delete parent[k]; Object.assign(parent, rebuilt); },
                });
                next = JSON.stringify(result === undefined ? data : result, null, jsonIndent(state.markdown)) + (state.markdown.endsWith('\n') ? '\n' : '');
            } else {
                const { YAML } = await loadYAMLLibrary();
                const doc = YAML.parseDocument(state.markdown);
                change({
                    get: (path) => doc.getIn(path),
                    set: (path, value) => { if (!path.length) doc.contents = doc.createNode(value); else doc.setIn(path, doc.createNode(value)); },
                    remove: (path) => doc.deleteIn(path),
                    rename: (path, name) => {
                        const parent = path.length > 1 ? doc.getIn(path.slice(0, -1), true) : doc.contents;
                        const pair = parent && parent.items && parent.items.find(p => p.key && (p.key.value ?? p.key) == path[path.length - 1]);
                        // Keep the key node (its comments stay with it); only its text changes.
                        if (pair && pair.key && typeof pair.key === 'object' && 'value' in pair.key) pair.key.value = name;
                        else if (pair) pair.key = doc.createNode(name);
                    },
                });
                next = doc.toString();
            }
            DOM.editor.value = next;
            state.markdown = next;
            renderStructuredContent();
            sendToSwift('contentChanged', { markdown: next, html: '' });
        }

        function inlineEditor(anchor, initial, onCommit) {
            const input = document.createElement('input');
            input.className = 'struct-inline-input';
            input.value = initial;
            input.size = Math.max(8, Math.min(60, initial.length + 2));
            anchor.replaceWith(input);
            input.focus();
            input.select();
            let done = false;
            const finish = (commit) => {
                if (done) return;
                done = true;
                if (commit && input.value !== initial) onCommit(input.value);
                else renderStructuredContent();
            };
            input.addEventListener('keydown', e => {
                if (e.key === 'Enter') { e.preventDefault(); finish(true); }
                else if (e.key === 'Escape') { e.preventDefault(); finish(false); }
                e.stopPropagation();
            });
            input.addEventListener('blur', () => finish(true));
        }

        let structEditingWired = false;
        function wireStructEditing() {
        if (structEditingWired) return;
        structEditingWired = true;
        DOM.rendered.addEventListener('dblclick', e => {
            if (state.mode !== 'structured' || (state.fileType !== 'json' && state.fileType !== 'yaml')) return;
            const node = e.target.closest('.struct-node[data-path]');
            if (!node) return;
            const path = JSON.parse(node.dataset.path);
            const valueEl = e.target.closest('.struct-value');
            const keyEl = e.target.closest('.struct-key');
            if (valueEl && node.contains(valueEl)) {
                const raw = valueEl.classList.contains('struct-string') ? valueEl.textContent.replace(/^"|"$/g, '') : valueEl.textContent;
                const shown = valueEl.classList.contains('struct-string') ? JSON.stringify(raw) : raw;
                inlineEditor(valueEl, shown, text => editStructured(doc => doc.set(path, parseTypedValue(text))).catch(showStructEditError));
            } else if (keyEl && path.length && typeof path[path.length - 1] === 'string') {
                inlineEditor(keyEl, String(path[path.length - 1]), name => {
                    if (!name.trim()) return renderStructuredContent();
                    editStructured(doc => doc.rename(path, name)).catch(showStructEditError);
                });
            }
        });

        DOM.rendered.addEventListener('click', e => {
            const button = e.target.closest('.struct-act');
            if (!button || state.mode !== 'structured') return;
            e.stopPropagation();
            const node = button.closest('.struct-node[data-path]');
            const path = JSON.parse(node.dataset.path);
            if (button.dataset.act === 'delete') {
                editStructured(doc => doc.remove(path)).catch(showStructEditError);
            } else if (node.dataset.container === 'array') {
                editStructured(doc => { const list = doc.get(path); const length = Array.isArray(list) ? list.length : (list && list.items ? list.items.length : 0); doc.set(path.concat([length]), null); }).catch(showStructEditError);
            } else {
                // Ask for the key on the line itself.
                const placeholder = document.createElement('span');
                button.parentElement.appendChild(placeholder);
                inlineEditor(placeholder, 'newKey', name => {
                    if (!name.trim()) return renderStructuredContent();
                    editStructured(doc => doc.set(path.concat([name]), null)).catch(showStructEditError);
                });
            }
        });

        }

        function showStructEditError(error) {
            renderStructuredContent();
            const bar = document.createElement('div');
            bar.className = 'struct-error';
            bar.textContent = 'Could not change: ' + (error && error.message || error);
            DOM.rendered.prepend(bar);
        }

        // --- Source view for JSON / YAML: the plain editor (find, go to line and ⌘S work there),
        // with a line under the toolbar saying whether the text parses. ---
        function structSourceStatus() {
            let bar = document.getElementById('struct-source-status');
            if (!bar) {
                bar = document.createElement('div');
                bar.id = 'struct-source-status';
                bar.className = 'struct-source-status';
                DOM.editorPane.insertBefore(bar, DOM.editorPane.firstChild);
                DOM.editor.addEventListener('input', () => {
                    if (state.mode !== 'structured-source') return;
                    clearTimeout(bar.t);
                    bar.t = setTimeout(validateStructSource, 250);
                });
            }
            return bar;
        }

        function validateStructSource() {
            const bar = structSourceStatus();
            const text = DOM.editor.value;
            try {
                if (state.fileType === 'json') JSON.parse(text); else jsyaml.load(text);
                bar.textContent = 'Valid ' + state.fileType.toUpperCase();
                bar.className = 'struct-source-status ok';
            } catch (e) {
                bar.textContent = state.fileType.toUpperCase() + ': ' + e.message.split('\n')[0];
                bar.className = 'struct-source-status bad';
            }
        }

        function openStructSourceEditor() {
            DOM.editorPane.style.display = 'flex';
            DOM.previewPane.style.display = 'none';
            DOM.statusMode.textContent = state.fileType.toUpperCase() + ' Source';
            document.getElementById('wysiwyg-toolbar').style.display = 'none';
            document.getElementById('mode-toggle').textContent = 'Tree ↗';
            const currentSize = getComputedStyle(DOM.rendered).fontSize;
            if (currentSize) DOM.editor.style.fontSize = currentSize;
            structSourceStatus().style.display = '';
            validateStructSource();
            DOM.editor.focus();
        }

        function closeStructSourceEditor() {
            const bar = document.getElementById('struct-source-status');
            if (bar) bar.style.display = 'none';
        }

        // A new file closes the source editor.
        const origSetStructuredForSource = window.setStructuredContent;
        window.setStructuredContent = function(content, fileType) {
            closeStructSourceEditor();
            return origSetStructuredForSource(content, fileType);
        };
