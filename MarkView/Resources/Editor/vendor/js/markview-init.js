        // EVENT LISTENERS
        // ============================================================================

        DOM.editor.addEventListener('input', () => {
            state.markdown = DOM.editor.value;
            if (state.fileType === 'markdown') {
                renderMarkdown();
                updateStats();
            } else {
                sendToSwift('contentChanged', { markdown: state.markdown, html: '' });
            }
        });

        DOM.btnToggleMode.addEventListener('click', function() {
            if (state.fileType !== 'markdown') { toggleStructMode(); } else { toggleMode(); }
        });
        // Intercept all link clicks in rendered content
        DOM.rendered.addEventListener('click', function(e) {
            const link = e.target.closest('a');
            if (!link) return;

            const rawHref = link.getAttribute('href');
            if (!rawHref) return;

            e.preventDefault();
            e.stopPropagation();

            // Anchor links — scroll to heading in-page
            if (rawHref.startsWith('#')) {
                const targetId = decodeURIComponent(rawHref.substring(1));
                const target = document.getElementById(targetId);
                if (target) {
                    target.scrollIntoView({ behavior: 'smooth' });
                    sendToSwift('scrollPosition', { activeHeadingId: targetId });
                }
                return;
            }

            // Use link.href (DOM property) which resolves relative paths against the page's baseURL
            // e.g., "./other.md" → "file:///path/to/doc/dir/other.md"
            sendToSwift('linkClicked', { href: link.href });
        });

        // Keyboard shortcuts
        document.addEventListener('keydown', (e) => {
            // Cmd/Ctrl+Shift+P to toggle mode
            if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.code === 'KeyP') {
                e.preventDefault();
                toggleMode();
            }
            // Cmd/Ctrl+Shift+T to toggle theme
            if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.code === 'KeyT') {
                e.preventDefault();
                toggleTheme();
            }
        });

        // ============================================================================
        // INITIALIZATION
        // ============================================================================

        function init() {
            // Auto-detect document base URL from the page's baseURI
            // (set by loadHTMLString(html, baseURL: documentDir))
            if (!state.documentBaseURL && document.baseURI && document.baseURI.startsWith('file://')) {
                state.documentBaseURL = document.baseURI;
            }

            // Set initial theme
            applyTheme(state.theme);

            // Focus editor
            DOM.editor.focus();

            // Send ready signal to Swift
            sendToSwift('ready', {});
        }

        // Initialize when DOM is ready
        // ============================================================================
