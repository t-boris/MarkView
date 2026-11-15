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

            // Focus editor
            DOM.editor.focus();

            // Send ready signal to Swift
            sendToSwift('ready', {});
        }

        // Bind declarative UI actions (AR-01: replaced inline on*= handlers so CSP needs no 'unsafe-inline' in script-src)
        (function bindDeclarativeActions() {
            document.querySelectorAll('[data-mv-prevent-mousedown]').forEach(function(el) {
                el.addEventListener('mousedown', function(e) { e.preventDefault(); });
            });
            document.querySelectorAll('[data-mv-action]').forEach(function(el) {
                el.addEventListener('click', function() {
                    const spec = el.getAttribute('data-mv-action') || '';
                    const parts = spec.split(':');
                    const fn = parts[0];
                    const arg1 = parts[1];
                    const arg2 = parts[2];
                    switch (fn) {
                        case 'findPrev': if (typeof findPrev === 'function') findPrev(); break;
                        case 'findNext': if (typeof findNext === 'function') findNext(); break;
                        case 'toggleFindCase': if (typeof toggleFindCase === 'function') toggleFindCase(); break;
                        case 'toggleFindRegex': if (typeof toggleFindRegex === 'function') toggleFindRegex(); break;
                        case 'closeFind': if (typeof closeFind === 'function') closeFind(); break;
                        case 'fmtCmd': if (typeof fmtCmd === 'function') fmtCmd(arg1, arg2); break;
                        case 'fmtBlock': if (typeof fmtBlock === 'function') fmtBlock(arg1); break;
                        case 'fmtHeading': if (typeof fmtHeading === 'function') fmtHeading(); break;
                        case 'fmtLink': if (typeof fmtLink === 'function') fmtLink(); break;
                        case 'fmtCodeBlock': if (typeof fmtCodeBlock === 'function') fmtCodeBlock(); break;
                        case 'fmtImage': if (typeof fmtImage === 'function') fmtImage(); break;
                        case 'fmtHR': if (typeof fmtHR === 'function') fmtHR(); break;
                        case 'fmtTable': if (typeof fmtTable === 'function') fmtTable(); break;
                        case 'fmtMermaid': if (typeof fmtMermaid === 'function') fmtMermaid(); break;
                        case 'saveFile': if (typeof saveFile === 'function') saveFile(); break;
                        case 'refreshFile': if (typeof refreshFile === 'function') refreshFile(); break;
                        case 'selectionAction': if (typeof selectionAction === 'function') selectionAction(arg1); break;
                        case 'showFeatureMenu': if (typeof showFeatureMenu === 'function') showFeatureMenu(); break;
                        case 'featureAction': if (typeof featureAction === 'function') featureAction(arg1); break;
                        case 'closeActionPopup': if (typeof closeActionPopup === 'function') closeActionPopup(); break;
                        case 'toggleMode':
                            if (typeof toggleModeWrapper === 'function') toggleModeWrapper();
                            else if (typeof toggleMode === 'function') toggleMode();
                            break;
                    }
                });
            });
            const featureAsk = document.getElementById('feature-ask');
            if (featureAsk) {
                featureAsk.addEventListener('keydown', function(event) {
                    if (event.key === 'Enter' && typeof featureAction === 'function') featureAction('ask');
                    if (event.key === 'Escape' && typeof hideFeatureMenu === 'function') hideFeatureMenu();
                });
            }
            const more = document.querySelector('.editor-more');
            if (more) {
                const menu = more.querySelector('.editor-more-menu');
                if (menu) {
                    menu.addEventListener('click', function(event) {
                        if (event.target.closest('button')) more.open = false;
                    });
                }
                document.addEventListener('click', function(event) {
                    if (!more.contains(event.target)) more.open = false;
                });
            }
        })();

        // Initialize when DOM is ready (AR-05: runs after init is defined)
        // ============================================================================
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', init);
        } else {
            init();
        }
