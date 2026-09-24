        // SELECTION ACTIONS (Translate / Explain)
        // ============================================================================

        // Target language per translate action. Also used as the "is this a
        // translate action?" test in the no-selection branch below.
        const TRANSLATE_TARGETS = { translate_ru: 'Russian', translate_en: 'English' };

        function selectionAction(action) {
            // Use the selection captured when format-bar appeared
            let selectedText = formatBarSelectedText;
            // Also try current selection as fallback
            if (!selectedText) {
                const sel = window.getSelection();
                if (sel.rangeCount && !sel.isCollapsed) {
                    selectedText = sel.toString().trim();
                }
            }
            // Source mode keeps its selection in the <textarea>, invisible to
            // window.getSelection().
            if (!selectedText) {
                selectedText = currentSourceSelection();
            }

            let title = 'Result';
            if (action === 'translate_ru') title = 'Перевод на русский';
            else if (action === 'translate_en') title = 'Translation to English';
            else if (action === 'explain') title = 'Explanation';

            if (!selectedText) {
                // Nothing selected. For a translate action, offer the whole
                // document instead of silently doing nothing.
                if (TRANSLATE_TARGETS[action]) proposeWholeDocumentTranslation(action, title);
                return;
            }

            // Hide format bar
            document.getElementById('format-bar').classList.remove('visible');

            showActionPopup(title, '<span class="action-popup-loading">Processing...</span>');
            sendToSwift('selectionAction', { action: action, text: selectedText });
        }

        // Confirmation step for whole-document translation. Built from the
        // existing action-popup DOM rather than window.confirm(), which
        // silently returns false in this WKWebView (no WKUIDelegate is wired).
        function proposeWholeDocumentTranslation(action, title) {
            const targetLang = TRANSLATE_TARGETS[action];
            if (!targetLang) return;
            if (state.fileType !== 'markdown') return;

            const markdown = DOM.editor ? DOM.editor.value : '';
            if (!markdown.trim()) return; // empty document — nothing to translate

            document.getElementById('format-bar').classList.remove('visible');

            const approxKb = Math.max(1, Math.round(markdown.length / 1024));
            showActionPopup(title,
                '<p>Nothing is selected.</p>' +
                '<p>Translate the <b>entire document</b> (~' + approxKb + ' KB) to ' + targetLang + '?' +
                ' The translation opens in a new tab as an unsaved copy — this file is not modified.</p>' +
                '<div class="action-popup-actions">' +
                '<button type="button" id="translate-doc-confirm">Translate whole document</button>' +
                '<button type="button" id="translate-doc-cancel">Cancel</button>' +
                '</div>');

            document.getElementById('translate-doc-confirm').addEventListener('click', function() {
                closeActionPopup();
                translateWholeDocument(targetLang);
            });
            document.getElementById('translate-doc-cancel').addEventListener('click', closeActionPopup);
        }

        function showActionPopup(title, htmlContent) {
            document.getElementById('action-popup-title').textContent = title;
            document.getElementById('action-popup-content').innerHTML = htmlContent;
            document.getElementById('action-popup').classList.add('visible');
            document.getElementById('action-popup-backdrop').classList.add('visible');
        }

        function closeActionPopup() {
            document.getElementById('action-popup').classList.remove('visible');
            document.getElementById('action-popup-backdrop').classList.remove('visible');
        }

        // Called from Swift when AI result is ready
        window.showSelectionResult = function(title, markdownContent) {
            // Render markdown to HTML using markdown-it
            let html;
            if (typeof md !== 'undefined') {
                html = md.render(markdownContent);
            } else {
                html = '<pre>' + markdownContent.replace(/</g, '&lt;') + '</pre>';
            }
            showActionPopup(title, html);
            // Apply syntax highlighting
            const content = document.getElementById('action-popup-content');
            if (typeof Prism !== 'undefined') {
                content.querySelectorAll('pre code').forEach(el => Prism.highlightElement(el));
            }
        };

        // Close popup with Escape
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && document.getElementById('action-popup').classList.contains('visible')) {
                closeActionPopup();
            }
        });

        // ============================================================================
        // FIND IN DOCUMENT
        // ============================================================================

        const findState = {
            visible: false,
            caseSensitive: false,
            useRegex: false,
            matches: [],      // Array of {node, start, end} or Range objects
            currentIndex: -1,
            highlights: [],    // DOM mark elements
        };

        function openFind() {
            findState.visible = true;
            const bar = document.getElementById('find-bar');
            bar.classList.add('visible');
            const input = document.getElementById('find-input');
            input.focus();
            input.select();
        }

        function closeFind() {
            findState.visible = false;
            document.getElementById('find-bar').classList.remove('visible');
            clearHighlights();
            document.getElementById('find-count').textContent = '';
        }

        function toggleFindCase() {
            findState.caseSensitive = !findState.caseSensitive;
            const btn = document.getElementById('find-case-btn');
            btn.style.color = findState.caseSensitive ? 'var(--accent-primary)' : '';
            btn.style.borderBottom = findState.caseSensitive ? '2px solid var(--accent-primary)' : '';
            performFind();
        }

        function toggleFindRegex() {
            findState.useRegex = !findState.useRegex;
            const btn = document.getElementById('find-regex-btn');
            btn.style.color = findState.useRegex ? 'var(--accent-primary)' : '';
            btn.style.borderBottom = findState.useRegex ? '2px solid var(--accent-primary)' : '';
            performFind();
        }

        function clearHighlights() {
            findState.highlights.forEach(mark => {
                const parent = mark.parentNode;
                if (parent) {
                    parent.replaceChild(document.createTextNode(mark.textContent), mark);
                    parent.normalize();
                }
            });
            findState.highlights = [];
            findState.matches = [];
            findState.currentIndex = -1;
        }

        function performFind() {
            clearHighlights();
            const query = document.getElementById('find-input').value;
            if (!query) {
                document.getElementById('find-count').textContent = '';
                return;
            }

            // Determine which container to search
            const container = (state.mode === 'source' || state.mode === 'structured-source')
                ? null  // For source mode, use textarea search
                : DOM.rendered;

            if (!container) {
                // Source mode: search in textarea
                findInTextarea(query);
                return;
            }

            // Build regex from query
            let regex;
            try {
                const flags = findState.caseSensitive ? 'g' : 'gi';
                regex = findState.useRegex ? new RegExp(query, flags) : new RegExp(escapeRegex(query), flags);
            } catch(e) {
                document.getElementById('find-count').textContent = 'Invalid regex';
                return;
            }

            // Walk text nodes and highlight matches
            const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT, null);
            const textNodes = [];
            let node;
            while (node = walker.nextNode()) {
                if (node.textContent.length > 0) textNodes.push(node);
            }

            for (const textNode of textNodes) {
                const text = textNode.textContent;
                const matches = [...text.matchAll(regex)];
                if (matches.length === 0) continue;

                const frag = document.createDocumentFragment();
                let lastIdx = 0;
                for (const match of matches) {
                    const start = match.index;
                    const end = start + match[0].length;
                    if (start > lastIdx) {
                        frag.appendChild(document.createTextNode(text.substring(lastIdx, start)));
                    }
                    const mark = document.createElement('mark');
                    mark.className = 'find-highlight';
                    mark.textContent = text.substring(start, end);
                    frag.appendChild(mark);
                    findState.highlights.push(mark);
                    lastIdx = end;
                }
                if (lastIdx < text.length) {
                    frag.appendChild(document.createTextNode(text.substring(lastIdx)));
                }
                textNode.parentNode.replaceChild(frag, textNode);
            }

            findState.matches = findState.highlights;
            const count = findState.matches.length;
            document.getElementById('find-count').textContent = count > 0 ? `${count} found` : 'No results';
            if (count > 0) {
                findState.currentIndex = 0;
                highlightCurrent();
            }
        }

        function findInTextarea(query) {
            const text = DOM.editor.value;
            let regex;
            try {
                const flags = findState.caseSensitive ? 'g' : 'gi';
                regex = findState.useRegex ? new RegExp(query, flags) : new RegExp(escapeRegex(query), flags);
            } catch(e) {
                document.getElementById('find-count').textContent = 'Invalid regex';
                return;
            }
            const matches = [...text.matchAll(regex)];
            document.getElementById('find-count').textContent = matches.length > 0 ? `${matches.length} found` : 'No results';
            if (matches.length > 0) {
                findState.matches = matches;
                findState.currentIndex = 0;
                // Select the first match in textarea
                selectTextareaMatch(0);
            }
        }

        function selectTextareaMatch(index) {
            if (index < 0 || index >= findState.matches.length) return;
            const match = findState.matches[index];
            DOM.editor.focus();
            DOM.editor.setSelectionRange(match.index, match.index + match[0].length);
            // Scroll textarea to show selection
            const lineHeight = parseInt(getComputedStyle(DOM.editor).lineHeight) || 18;
            const linesAbove = DOM.editor.value.substring(0, match.index).split('\n').length;
            DOM.editor.scrollTop = (linesAbove - 3) * lineHeight;
            document.getElementById('find-count').textContent = `${index + 1}/${findState.matches.length}`;
        }

        function highlightCurrent() {
            // In rendered mode with mark highlights
            findState.highlights.forEach(m => m.className = 'find-highlight');
            if (findState.currentIndex >= 0 && findState.currentIndex < findState.highlights.length) {
                const current = findState.highlights[findState.currentIndex];
                current.className = 'find-highlight find-highlight-active';
                current.scrollIntoView({ behavior: 'smooth', block: 'center' });
                document.getElementById('find-count').textContent = `${findState.currentIndex + 1}/${findState.highlights.length}`;
            }
        }

        function findNext() {
            if (findState.matches.length === 0) return;
            findState.currentIndex = (findState.currentIndex + 1) % findState.matches.length;
            if (state.mode === 'source' || state.mode === 'structured-source') {
                selectTextareaMatch(findState.currentIndex);
            } else {
                highlightCurrent();
            }
        }

        function findPrev() {
            if (findState.matches.length === 0) return;
            findState.currentIndex = (findState.currentIndex - 1 + findState.matches.length) % findState.matches.length;
            if (state.mode === 'source' || state.mode === 'structured-source') {
                selectTextareaMatch(findState.currentIndex);
            } else {
                highlightCurrent();
            }
        }

        function escapeRegex(str) {
            return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        }

        // Cmd+F keyboard shortcut
        document.addEventListener('keydown', function(e) {
            if ((e.metaKey || e.ctrlKey) && e.key === 'f') {
                e.preventDefault();
                // The code viewer has its own search panel.
                if (state.mode === 'code' && window.codeViewOpenSearch) { window.codeViewOpenSearch(); return; }
                openFind();
            }
            if (e.key === 'Escape' && findState.visible) {
                closeFind();
            }
        });

        // Find input events
        document.getElementById('find-input').addEventListener('input', function() {
            performFind();
        });
        document.getElementById('find-input').addEventListener('keydown', function(e) {
            if (e.key === 'Enter') {
                e.preventDefault();
                if (e.shiftKey) { findPrev(); } else { findNext(); }
            }
        });

        // ============================================================================
