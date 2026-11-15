        // EARLIEST POSSIBLE GLOBAL ERROR CAPTURE — must precede any other code so
        // it catches initialization-time exceptions that would otherwise prevent
        // window.loadInsightSkeleton/updateInsightSection/setInsightStatus/...
        // from being defined.
        // ============================================================================
        (function installEarlyErrorCapture() {
            function postEarlyDiag(payload) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                        window.webkit.messageHandlers.bridge.postMessage({ type: 'jsError', payload: payload });
                    }
                } catch (_) {}
            }
            window.addEventListener('error', function(event) {
                postEarlyDiag({
                    where: 'early-window.error',
                    message: String(event.message || event.error || 'unknown'),
                    source: String(event.filename || 'inline'),
                    lineno: event.lineno || 0,
                    colno: event.colno || 0,
                    stack: (event.error && event.error.stack) ? String(event.error.stack) : ''
                });
            });
            window.addEventListener('unhandledrejection', function(event) {
                const reason = event.reason;
                postEarlyDiag({
                    where: 'early-unhandledrejection',
                    message: (reason && reason.message) ? String(reason.message) : String(reason),
                    source: 'promise',
                    lineno: 0, colno: 0,
                    stack: (reason && reason.stack) ? String(reason.stack) : ''
                });
            });
            // Init-checkpoint sentinel — fires once if early code reached this point.
            postEarlyDiag({ where: 'init-checkpoint', message: 'early-error-capture installed', source: '', lineno: 0, colno: 0, stack: '' });
        })();

        // ============================================================================
