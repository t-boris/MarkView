        // THEME SWITCHING
        // ============================================================================

        // The window theme (markview-themes.js): `id` is one of MarkViewThemes.ids, `accent` a '#RRGGBB' or ''.
        function applyTheme(id, accent) {
            const theme = MarkViewThemes.apply(id, accent);
            state.theme = theme.mode;
            // An open Recursive Insight page (same-origin iframe) follows the mode too.
            try {
                const insight = document.getElementById('insight-iframe');
                if (insight && insight.contentDocument) insight.contentDocument.documentElement.setAttribute('data-theme', theme.mode);
            } catch (e) {}

            if (typeof mermaid !== 'undefined') {
                try { mermaid.initialize(MarkViewThemes.mermaid()); } catch(e) {}
            }
        }

        // ============================================================================
        // SWIFT BRIDGE
        // ============================================================================

        // `window.mvDocumentId` is the id of the tab whose document this page shows. Swift sets it in the
        // same script that loads the document, so a message always names the document it describes, even
        // when the selected tab has changed by the time Swift handles it (BUG-031).
        function sendToSwift(type, payload) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                window.webkit.messageHandlers.bridge.postMessage({
                    type: type,
                    payload: payload,
                    doc: window.mvDocumentId || ''
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
