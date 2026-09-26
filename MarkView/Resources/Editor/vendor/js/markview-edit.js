        // STATS
        // ============================================================================

        function updateStats() {
            const text = DOM.editor.value;
            const words = text.trim().split(/\s+/).filter(w => w.length > 0).length;
            const chars = text.length;

            DOM.statusWords.textContent = `${words} words`;
            DOM.statusChars.textContent = `${chars} chars`;
        }

        // ============================================================================
        // FONT SIZE CONTROL
        // ============================================================================

        (function initFontSlider() {
            const slider = document.getElementById('font-slider');
            if (!slider) return;
            const saved = localStorage.getItem('markview-font-size');
            if (saved) { slider.value = saved; applyFontSize(parseFloat(saved)); }
            slider.addEventListener('input', function() {
                const size = parseFloat(this.value);
                applyFontSize(size);
                localStorage.setItem('markview-font-size', size);
            });
        })();

        function applyFontSize(size) {
            document.documentElement.style.setProperty('--base-font-size', size + 'px');
            const rendered = document.getElementById('editor-rendered');
            if (rendered) rendered.style.fontSize = size + 'px';
            // The code viewer follows the same text size (its zoom stays relative to it).
            if (typeof window.setCodeBaseSize === 'function') window.setCodeBaseSize(size);
        }

        // ============================================================================
        // WYSIWYG MODE — Rich text editing with markdown save
        // ============================================================================

        // Turndown instance for HTML → Markdown conversion
        let turndownService = null;
        function initTurndown() {
            if (typeof TurndownService === 'undefined') return;
            turndownService = new TurndownService({
                headingStyle: 'atx',
                codeBlockStyle: 'fenced',
                bulletListMarker: '-',
                emDelimiter: '*'
            });
            if (typeof turndownPluginGfm !== 'undefined') {
                turndownService.use(turndownPluginGfm.gfm);
            }
            // Preserve mermaid — handle both old .mermaid divs and new .mermaid-canvas containers
            turndownService.addRule('mermaid', {
                filter: function(node) {
                    return (node.classList && node.classList.contains('mermaid')) ||
                           (node.classList && node.classList.contains('mermaid-canvas'));
                },
                replacement: function(content, node) {
                    const source = node.getAttribute('data-source') || node.textContent;
                    return '\n```mermaid\n' + source.trim() + '\n```\n';
                }
            });
            // Wikilinks and formulas go back to their source text.
            turndownService.addRule('wikilink', {
                filter: function(node) { return node.nodeName === 'A' && node.classList.contains('wikilink'); },
                replacement: function(content, node) {
                    return node.getAttribute('data-raw') || '[[' + node.getAttribute('data-wikilink') + ']]';
                }
            });
            turndownService.addRule('math', {
                filter: function(node) {
                    return node.classList && (node.classList.contains('math-inline') || node.classList.contains('math-block'));
                },
                replacement: function(content, node) {
                    const tex = node.getAttribute('data-tex') || '';
                    return node.classList.contains('math-block') ? '\n\n$$\n' + tex + '\n$$\n\n' : '$' + tex + '$';
                }
            });
            // Preserve SVG elements (rendered mermaid) — don't try to convert them
            turndownService.addRule('svg', {
                filter: 'svg',
                replacement: function() { return ''; }
            });
        }

        function toggleMode() {
            // In insight mode, the toggle is a no-op (mode-switching is owned by Swift bridge).
            if (state.mode === 'insight') return;
            if (state.mode === 'source') { switchToPreview(); } else { switchToSource(); }
        }

        function switchToPreview() {
            state.mode = 'preview';
            // Hide insight container if we're coming from insight mode.
            if (typeof leaveInsightView === 'function') leaveInsightView();
            DOM.editorPane.style.display = 'none';
            DOM.previewPane.style.display = 'flex';
            DOM.statusMode.textContent = 'WYSIWYG';
            document.getElementById('wysiwyg-toolbar').style.display = 'flex';
            document.getElementById('mode-toggle').textContent = 'Source ↗';
            renderMarkdown();
            setupHeadingObserver();
            updateStats();
        }

        function switchToSource() {
            state.mode = 'source';
            // Hide insight container if we're coming from insight mode.
            if (typeof leaveInsightView === 'function') leaveInsightView();
            // Sync WYSIWYG changes back to textarea before showing source
            syncWysiwygToMarkdown();
            DOM.editorPane.style.display = 'flex';
            DOM.previewPane.style.display = 'none';
            DOM.statusMode.textContent = 'Source';
            document.getElementById('wysiwyg-toolbar').style.display = 'flex';
            document.getElementById('mode-toggle').textContent = 'WYSIWYG ↗';
            updateStats();
            DOM.editor.focus();
        }

        // Track if user edited in WYSIWYG mode
        let wysiwygDirty = false;

        // Sync contentEditable HTML → markdown → textarea
        function syncWysiwygToMarkdown() {
            // Only run Turndown if user actually edited in WYSIWYG
            if (!wysiwygDirty) return;
            if (!turndownService) initTurndown();
            if (!turndownService) return;

            const html = DOM.rendered.innerHTML;
            if (!html || html.includes('editor-empty')) return;

            const md = turndownService.turndown(html);
            if (md && md.trim().length > 0) {
                DOM.editor.value = md;
                state.markdown = md;
            }
        }

        // Debounced change handler for contentEditable
        let wysiwygTimer = null;
        const rendered = document.getElementById('editor-rendered');

        rendered.addEventListener('input', function() {
            wysiwygDirty = true;
            // Do NOT auto-sync via Turndown — it corrupts markdown formatting
            // Turndown only runs on explicit Save (⌘S) or switch to Source mode
        });

        // Format commands for toolbar buttons
        function fmtCmd(cmd, value) {
            document.execCommand(cmd, false, value || null);
            rendered.focus();
        }

        function fmtHeading() {
            const sel = window.getSelection();
            if (!sel.rangeCount) return;
            const node = sel.anchorNode.parentElement;
            // Cycle: p → h2 → h3 → h4 → p
            const tag = node.tagName;
            let next = 'H2';
            if (tag === 'H2') next = 'H3';
            else if (tag === 'H3') next = 'H4';
            else if (tag === 'H4') next = 'P';
            document.execCommand('formatBlock', false, next);
        }

        function fmtBlock(tag) {
            document.execCommand('formatBlock', false, tag);
            rendered.focus();
        }

        function fmtLink() {
            const url = prompt('URL:');
            if (url) document.execCommand('createLink', false, url);
        }

        function fmtHR() {
            document.execCommand('insertHorizontalRule');
            rendered.focus();
        }

        function fmtImage() {
            const url = prompt('Image URL or filename:');
            if (!url) return;
            const alt = prompt('Alt text:', 'image') || 'image';
            document.execCommand('insertHTML', false, `<img src="${url}" alt="${alt}" style="max-width:100%">`);
            rendered.focus();
        }

        function fmtCodeBlock() {
            const lang = prompt('Language (e.g. python, javascript):', '') || '';
            const placeholder = '// code here';
            const html = `<pre><code class="language-${lang}">${placeholder}</code></pre><p><br></p>`;
            document.execCommand('insertHTML', false, html);
            rendered.focus();
        }

        function fmtMermaid() {
            const types = {
                '1': 'graph TD\\n    A[Start] --> B[Process]\\n    B --> C[End]',
                '2': 'sequenceDiagram\\n    Alice->>Bob: Hello\\n    Bob-->>Alice: Hi',
                '3': 'pie title Distribution\\n    "A" : 40\\n    "B" : 30\\n    "C" : 30',
                '4': 'flowchart LR\\n    A --> B --> C'
            };
            const choice = prompt('Mermaid diagram type:\\n1 = Flowchart\\n2 = Sequence\\n3 = Pie\\n4 = Horizontal flow\\n\\nEnter number:', '1');
            const code = types[choice] || types['1'];
            // Insert as a code block that Turndown will preserve, then re-render will make it mermaid
            const html = `<pre><code class="language-mermaid">${code.replace(/\\n/g, '\n')}</code></pre><p><br></p>`;
            document.execCommand('insertHTML', false, html);
            // Re-render to show the actual mermaid diagram
            wysiwygDirty = true;
            setTimeout(() => { renderMarkdown(); }, 100);
        }

        function fmtTable() {
            const cols = parseInt(prompt('Columns:', '3')) || 3;
            const rows = parseInt(prompt('Rows:', '3')) || 3;
            let html = '<table><thead><tr>';
            for (let c = 0; c < cols; c++) html += `<th>Header ${c+1}</th>`;
            html += '</tr></thead><tbody>';
            for (let r = 0; r < rows; r++) {
                html += '<tr>';
                for (let c = 0; c < cols; c++) html += '<td>&nbsp;</td>';
                html += '</tr>';
            }
            html += '</tbody></table><p><br></p>';
            document.execCommand('insertHTML', false, html);
            rendered.focus();
        }

        function fmtCode() {
            const sel = window.getSelection();
            if (!sel.rangeCount) return;
            const range = sel.getRangeAt(0);
            const code = document.createElement('code');
            range.surroundContents(code);
        }
        // Override the generic code button
        window.fmtCmd = function(cmd, value) {
            if (cmd === 'code') { fmtCode(); return; }
            document.execCommand(cmd, false, value || null);
            rendered.focus();
        };

        // Stores the selected text when format-bar becomes visible.
        // This is the definitive text for RU/EN/? buttons.
        let formatBarSelectedText = '';

        // Show/hide floating toolbar on selection
        document.addEventListener('selectionchange', function() {
            const sel = window.getSelection();
            const bar = document.getElementById('format-bar');
            // Formatting only applies to markdown WYSIWYG — never to the
            // structured (JSON/XML/YAML) tree or the canvas viewer.
            if (state.fileType !== 'markdown' || !sel.rangeCount || sel.isCollapsed || !rendered.contains(sel.anchorNode)) {
                bar.classList.remove('visible');
                // Drop the captured text too. Leaving it behind made RU/EN/?
                // re-run on the PREVIOUS selection instead of reporting
                // "nothing selected", which hid the whole-document path.
                formatBarSelectedText = '';
                return;
            }
            const range = sel.getRangeAt(0);
            const rect = range.getBoundingClientRect();
            bar.style.left = Math.max(8, rect.left + rect.width/2 - 120) + 'px';
            bar.style.top = Math.max(4, rect.top - 38) + 'px';
            bar.classList.add('visible');
            // Capture selection text now — by the time user clicks a button it may be gone
            formatBarSelectedText = sel.toString().trim();
        });

        // Source mode keeps its selection inside the <textarea>, which
        // window.getSelection() does not cover — the selectionchange handler
        // above can never see it. Mirror it into the same variable so the
        // RU/EN/? buttons work identically in both modes.
        function currentSourceSelection() {
            if (state.mode !== 'source' || !DOM.editor) return '';
            const start = DOM.editor.selectionStart;
            const end = DOM.editor.selectionEnd;
            if (typeof start !== 'number' || start === end) return '';
            return DOM.editor.value.substring(start, end).trim();
        }

        function saveFile() {
            // Only convert WYSIWYG→markdown if user actually edited in WYSIWYG
            if (wysiwygDirty) {
                syncWysiwygToMarkdown();
            }
            sendToSwift('contentChanged', { markdown: DOM.editor.value });
            sendToSwift('saveRequested', {});
        }

        // Whole-document translation. Sends the raw markdown from the textarea
        // (never the Turndown-converted WYSIWYG DOM) so the source structure
        // reaches Swift byte-for-byte. Swift opens the translation in a new tab.
        function translateWholeDocument(targetLang) {
            if (wysiwygDirty) {
                // Unsynced WYSIWYG edits would otherwise be translated away.
                syncWysiwygToMarkdown();
            }
            sendToSwift('translateRequested', { markdown: DOM.editor.value, targetLang: targetLang });
        }

        function refreshFile() {
            sendToSwift('refreshRequested', {});
        }

        // Keyboard shortcuts in WYSIWYG mode
        rendered.addEventListener('keydown', function(e) {
            if (e.metaKey || e.ctrlKey) {
                if (e.key === 'b') { e.preventDefault(); fmtCmd('bold'); }
                if (e.key === 'i') { e.preventDefault(); fmtCmd('italic'); }
                if (e.key === 'k') { e.preventDefault(); fmtLink(); }
                if (e.key === 's') { e.preventDefault(); saveFile(); }
                if (e.key === 'r') { e.preventDefault(); refreshFile(); }
            }
            // Cmd+Shift+P → switch to source
            if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === 'p') {
                e.preventDefault(); switchToSource();
            }
        });

        // Also catch Cmd+S in source mode
        DOM.editor.addEventListener('keydown', function(e) {
            if ((e.metaKey || e.ctrlKey) && e.key === 's') {
                e.preventDefault(); saveFile();
            }
        });

        // Escape from source → back to WYSIWYG
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && state.mode === 'source') { switchToPreview(); }
        });

        // ============================================================================
