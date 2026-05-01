        // THEME SWITCHING
        // ============================================================================

        function applyTheme(theme) {
            if (state.theme === theme) return;
            state.theme = theme;
            document.documentElement.setAttribute('data-theme', theme);
            localStorage.setItem('markview-theme', theme);

            const isDark = theme === 'dark';

            if (typeof mermaid !== 'undefined') {
                try { mermaid.initialize({ theme: isDark ? 'dark' : 'default' }); } catch(e) {}
            }
        }

        function toggleTheme() {
            const newTheme = state.theme === 'light' ? 'dark' : 'light';
            applyTheme(newTheme);
        }

        // ============================================================================
        // SWIFT BRIDGE
        // ============================================================================

        function sendToSwift(type, payload) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                window.webkit.messageHandlers.bridge.postMessage({
                    type: type,
                    payload: payload
                });
            }
        }

        // ============================================================================
        // GLOBAL JS ERROR CAPTURE (diagnostic — pipes to /tmp/markview-insight-diag.log)
        // ============================================================================
        // Without this, exceptions inside Swift→JS evaluateJavaScript calls (e.g.
        // window.loadInsightSkeleton, window.updateInsightSection) surface only as
        // opaque WKWebView "Request to run JavaScript failed with error <private>"
        // entries in macOS unified log. Capturing them in JS and routing back via
        // the existing bridge gives the actual exception message + stack.
        window.addEventListener('error', function(event) {
            try {
                sendToSwift('jsError', {
                    where: 'window.error',
                    message: String(event.message || event.error || 'unknown'),
                    source: String(event.filename || 'inline'),
                    lineno: event.lineno || 0,
                    colno: event.colno || 0,
                    stack: (event.error && event.error.stack) ? String(event.error.stack) : ''
                });
            } catch (_) { /* never throw from the error handler */ }
        });
        window.addEventListener('unhandledrejection', function(event) {
            try {
                const reason = event.reason;
                sendToSwift('jsError', {
                    where: 'unhandledrejection',
                    message: (reason && reason.message) ? String(reason.message) : String(reason),
                    source: 'promise',
                    lineno: 0,
                    colno: 0,
                    stack: (reason && reason.stack) ? String(reason.stack) : ''
                });
            } catch (_) { /* never throw */ }
        });

        // Global functions called from Swift
        window.setContent = function(markdown) {
            DOM.editor.value = markdown;
            state.markdown = markdown;
            wysiwygDirty = false; // Fresh content — don't run Turndown until user edits
            initTurndown();
            switchToPreview();
        };

        // ============================================================================
