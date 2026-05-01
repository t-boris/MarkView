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
            let html = '';
            try {
                if (state.fileType === 'json') {
                    const parsed = JSON.parse(state.markdown);
                    html = '<div class="struct-tree">' + renderStructToolbar() + renderJSON(parsed, '', true) + '</div>';
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
                    html = '<div class="struct-tree">' + renderStructToolbar() + renderJSON(parsed, '', true) + '</div>';
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
            DOM.rendered.innerHTML = html;
            // Wire up toggle buttons
            DOM.rendered.querySelectorAll('.struct-toggle').forEach(el => {
                el.addEventListener('click', () => toggleStructNode(el));
            });
        }

        function renderStructToolbar() {
            return '<div class="struct-toolbar">'
                + '<button onclick="structFoldAll()">Fold All</button>'
                + '<button onclick="structUnfoldAll()">Unfold All</button>'
                + (state.fileType !== 'xml' ? '<button onclick="structFormat()">Format</button>' : '')
                + (state.fileType !== 'xml' ? '<button onclick="structMinify()">Minify</button>' : '')
                + '<span class="spacer"></span>'
                + '<button onclick="toggleStructMode()">' + (state.mode === 'structured' ? 'Source ↗' : 'Tree ↗') + '</button>'
                + '</div>';
        }

        // --- JSON / YAML tree renderer ---
        function renderJSON(value, key, isLast) {
            if (value === null) return renderJSONLeaf(key, '<span class="struct-null">null</span>', isLast);
            if (typeof value === 'boolean') return renderJSONLeaf(key, '<span class="struct-boolean">' + value + '</span>', isLast);
            if (typeof value === 'number') return renderJSONLeaf(key, '<span class="struct-number">' + value + '</span>', isLast);
            if (typeof value === 'string') return renderJSONLeaf(key, '<span class="struct-string">"' + escapeHTML(value) + '"</span>', isLast);

            const isArray = Array.isArray(value);
            const entries = isArray ? value.map((v, i) => [i, v]) : Object.entries(value);
            const open = isArray ? '[' : '{';
            const close = isArray ? ']' : '}';
            const count = entries.length;
            const id = 'sn-' + Math.random().toString(36).substr(2, 8);

            let html = '<div class="struct-node" id="' + id + '">';
            html += '<div class="struct-line">';
            html += '<span class="struct-toggle" data-target="' + id + '-children">▼</span>';
            if (key !== '') html += '<span class="struct-key">' + (typeof key === 'number' ? key : '"' + escapeHTML(String(key)) + '"') + '</span><span class="struct-colon">: </span>';
            html += '<span class="struct-bracket">' + open + '</span>';
            html += '<span class="struct-count">' + count + (count === 1 ? ' item' : ' items') + '</span>';
            html += '</div>';
            html += '<div class="struct-children" id="' + id + '-children">';
            entries.forEach(([k, v], i) => {
                html += renderJSON(v, k, i === entries.length - 1);
            });
            html += '</div>';
            html += '<div class="struct-line"><span class="struct-placeholder"></span><span class="struct-bracket">' + close + '</span>' + (isLast ? '' : '<span class="struct-comma">,</span>') + '</div>';
            html += '</div>';
            return html;
        }

        function renderJSONLeaf(key, valueHtml, isLast) {
            let html = '<div class="struct-node"><div class="struct-line"><span class="struct-placeholder"></span>';
            if (key !== '') html += '<span class="struct-key">' + (typeof key === 'number' ? key : '"' + escapeHTML(String(key)) + '"') + '</span><span class="struct-colon">: </span>';
            html += valueHtml;
            if (!isLast) html += '<span class="struct-comma">,</span>';
            html += '</div></div>';
            return html;
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
                    const parsed = jsyaml.load(state.markdown);
                    const formatted = jsyaml.dump(parsed, { indent: 2 });
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
                // Re-parse from source textarea
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
