        function switchToInsightView() {
            state.mode = 'insight';
            if (DOM.editorPane) DOM.editorPane.style.display = 'none';
            if (DOM.previewPane) DOM.previewPane.style.display = 'none';
            if (DOM.insightContainer) {
                DOM.insightContainer.classList.add('visible');
                DOM.insightContainer.style.display = 'flex';
            }
            const wt = document.getElementById('wysiwyg-toolbar');
            if (wt) wt.style.display = 'none';
            if (DOM.statusMode) DOM.statusMode.textContent = 'Insight';
        }

        // Show a prominent in-tab "generating" placeholder BEFORE the iframe
        // srcdoc is built (Phase 1 LLM call ~30-60s). Without this the user
        // sees a blank pane during Phase 1 and assumes nothing is happening.
        // Replaced with the iframe content once `loadInsightSkeleton` runs
        // (the iframe element overwrites this overlay area).
        function showInsightLoadingOverlay(message) {
            if (!DOM.insightContainer) return;
            switchToInsightView();
            // Hide the iframe element while overlay is up.
            if (state.insightIframe) state.insightIframe.style.display = 'none';
            else if (DOM.insightIframe) DOM.insightIframe.style.display = 'none';
            let overlay = document.getElementById('insight-loading-overlay');
            if (!overlay) {
                overlay = document.createElement('div');
                overlay.id = 'insight-loading-overlay';
                overlay.style.cssText = 'position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:18px;font-family:-apple-system,system-ui,sans-serif;background:var(--bg-primary,#1e1e1e);color:var(--text-primary,#d4d4d4);padding:40px;text-align:center;';
                const spinner = document.createElement('div');
                spinner.style.cssText = 'width:48px;height:48px;border:4px solid #3c3c3c;border-top-color:#569cd6;border-radius:50%;animation:insight-spin 1s linear infinite;';
                overlay.appendChild(spinner);
                const title = document.createElement('div');
                title.id = 'insight-loading-title';
                title.style.cssText = 'font-size:18px;font-weight:600;';
                title.textContent = 'Generating insight…';
                overlay.appendChild(title);
                const sub = document.createElement('div');
                sub.id = 'insight-loading-sub';
                sub.style.cssText = 'font-size:13px;color:var(--text-secondary,#808080);max-width:480px;line-height:1.5;';
                sub.textContent = message || 'Phase 1: analysing files (typically 30–60 s)…';
                overlay.appendChild(sub);
                if (!document.getElementById('insight-loading-style')) {
                    const st = document.createElement('style');
                    st.id = 'insight-loading-style';
                    st.textContent = '@keyframes insight-spin { to { transform: rotate(360deg); } }';
                    document.head.appendChild(st);
                }
                if (DOM.insightContainer && getComputedStyle(DOM.insightContainer).position === 'static') {
                    DOM.insightContainer.style.position = 'relative';
                }
                DOM.insightContainer.appendChild(overlay);
            } else {
                const sub = document.getElementById('insight-loading-sub');
                if (sub && message != null) sub.textContent = String(message);
            }
        }

        function hideInsightLoadingOverlay() {
            const overlay = document.getElementById('insight-loading-overlay');
            if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
            if (state.insightIframe) state.insightIframe.style.display = '';
            else if (DOM.insightIframe) DOM.insightIframe.style.display = '';
        }

        function leaveInsightView() {
            // Hide container only — Decision 11 places blob URL revocation under
            // Swift `releaseInsightBlobs` ownership at tab close.
            if (DOM.insightContainer) {
                DOM.insightContainer.classList.remove('visible');
                DOM.insightContainer.style.display = 'none';
            }
        }

        // ---------------------------------------------------------------------------
        // Breadcrumbs (chrome — main frame). Uses textContent (no escape needed).
        // ---------------------------------------------------------------------------
        function renderInsightBreadcrumbs(crumbs) {
            const bar = DOM.insightBreadcrumbs;
            if (!bar) return;
            while (bar.firstChild) bar.removeChild(bar.firstChild);
            const arr = Array.isArray(crumbs) ? crumbs : [];
            arr.forEach(function(crumb, idx) {
                const isLast = idx === arr.length - 1;
                const item = document.createElement('span');
                item.className = 'insight-breadcrumb-item' + (isLast ? ' current' : '');
                item.textContent = (crumb && crumb.title) ? String(crumb.title) : '(untitled)';
                if (!isLast) {
                    const nodeId = (crumb && crumb.nodeId) ? String(crumb.nodeId) : null;
                    item.addEventListener('click', function() {
                        sendToSwift('insightBreadcrumbClicked', {
                            sessionId: state.insightSessionId,
                            nodeId: nodeId,
                        });
                    });
                }
                bar.appendChild(item);
                if (!isLast) {
                    const sep = document.createElement('span');
                    sep.className = 'insight-breadcrumb-sep';
                    sep.textContent = '›';
                    bar.appendChild(sep);
                }
            });
        }

        // ---------------------------------------------------------------------------
        // Status bar (chrome — main frame).
        // ---------------------------------------------------------------------------
        function setStatusBar(message, phase, isError) {
            const bar = DOM.insightStatusBar;
            if (!bar) return;
            const next = message == null ? '' : String(message);
            const changed = (bar.textContent !== next);
            // textContent ONLY (Decision 10 escape policy) — never innerHTML on
            // LLM-derived strings. Status messages are Swift-side literals here
            // but the policy is uniform regardless of provenance.
            bar.textContent = next;
            bar.classList.remove('phase-1', 'phase-2', 'ready', 'error');
            if (isError) bar.classList.add('error');
            else if (phase === 'phase-1' || phase === 'phase-2' || phase === 'ready') bar.classList.add(phase);
            // Brief pulse so the user notices status changes during long generation.
            if (changed && next !== '') {
                bar.classList.remove('insight-status-pulse');
                // Force reflow so re-adding the class restarts the animation.
                // Reading offsetWidth is the canonical idiom; void cast to mute
                // the unused-expression lint signal.
                void bar.offsetWidth;
                bar.classList.add('insight-status-pulse');
            }
        }

        // ---------------------------------------------------------------------------
        // Iframe load timeout (10s). If the iframe never posts insightIframeReady,
        // surface a retryable error and tear down the iframe.
        // ---------------------------------------------------------------------------
        function handleIframeLoadTimeout(sessionId) {
            // Guard against race: tab closed before timeout fired.
            if (!state.insightIframe) return;
            if (state.insightIframeReady) return;
            if (state.insightSessionId !== sessionId) return;
            console.warn('[insight] iframe failed to load within 10s for session', sessionId);
            setStatusBar('iframe failed to load within 10s', null, true);
            // Tear down by clearing srcdoc; Swift can call loadInsightSkeleton again to retry.
            try { state.insightIframe.removeAttribute('srcdoc'); } catch (e) {}
        }

        function startIframeLoadTimer(sessionId) {
            if (state.insightLoadTimer) {
                clearTimeout(state.insightLoadTimer);
                state.insightLoadTimer = null;
            }
            state.insightLoadTimer = setTimeout(function() {
                handleIframeLoadTimeout(sessionId);
            }, 10000);
        }

        function clearIframeLoadTimer() {
            if (state.insightLoadTimer) {
                clearTimeout(state.insightLoadTimer);
                state.insightLoadTimer = null;
            }
        }

        // ---------------------------------------------------------------------------
        // CDN strip (Decision 10). Removes <script src="https://..."> /
        // <script src="//..."> and <link rel="prefetch|preconnect|dns-prefetch">
        // BEFORE forwarding chunks to iframe. Replaced with HTML comment for
        // visibility. Iframe sandbox CSP `connect-src 'none'` is the second line
        // of defense (per task spec edge cases).
        // ---------------------------------------------------------------------------
