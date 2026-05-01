        function stripCDNTags(html) {
            if (typeof html !== 'string') return '';
            let out = html;
            // Match <script ... src="https://..." ...> ... </script> (or self-closing variants).
            out = out.replace(/<script\b[^>]*?\bsrc\s*=\s*(["'])(\s*(?:https?:|\/\/)[^"'>\s]*)\1[^>]*>\s*(?:<\/script>)?/gi, function(_, _q, url) {
                return '<!-- script src stripped: ' + String(url).replace(/--/g, '- -') + ' -->';
            });
            // Match <link ... rel="prefetch|preconnect|dns-prefetch" ...>.
            out = out.replace(/<link\b[^>]*?\brel\s*=\s*["'](?:prefetch|preconnect|dns-prefetch)["'][^>]*>/gi, function(match) {
                // Extract href if present for the comment.
                const hrefMatch = match.match(/\bhref\s*=\s*["']([^"']*)["']/i);
                const href = hrefMatch ? hrefMatch[1] : '(no href)';
                return '<!-- link prefetch/preconnect stripped: ' + String(href).replace(/--/g, '- -') + ' -->';
            });
            return out;
        }

        // ---------------------------------------------------------------------------
        // Five Swift→JS setters (the ONLY parent-side surface for v2).
        // ---------------------------------------------------------------------------

        // window.loadInsightSkeleton(skeletonOrJSON, sessionId, nodeId)
        // Builds iframe srcdoc, materializes only required libs lazily, switches
        // mode, starts the 10s readiness timer.
        window.loadInsightSkeleton = async function(skeletonOrJSON, sessionId, nodeId) {
            let skeleton = skeletonOrJSON;
            if (typeof skeleton === 'string') {
                try { skeleton = JSON.parse(skeleton); }
                catch (e) {
                    console.warn('[insight] loadInsightSkeleton: invalid JSON');
                    return;
                }
            }
            if (!skeleton || typeof skeleton !== 'object' || !Array.isArray(skeleton.sections)) {
                console.warn('[insight] loadInsightSkeleton: missing sections array');
                return;
            }

            const sid = sessionId != null ? String(sessionId) : null;
            const nid = nodeId != null ? String(nodeId) : null;

            // Compute required libs and diff against existing.
            const newLibs = computeRequiredLibs(skeleton);
            // Revoke libs no longer needed.
            for (const [libName, blobURL] of state.insightBlobURLs.entries()) {
                if (!newLibs.has(libName)) {
                    try { URL.revokeObjectURL(blobURL); } catch (e) {}
                    state.insightBlobURLs.delete(libName);
                }
            }
            // Materialize new ones.
            const blobURLPromises = [];
            for (const libName of newLibs) {
                blobURLPromises.push(ensureLibBlob(libName));
            }
            await Promise.all(blobURLPromises);

            // KaTeX inline CSS only if KaTeX in set.
            let katexCSSInline = '';
            if (newLibs.has('katex')) {
                katexCSSInline = await ensureKatexCSSInline();
            }

            // Update state.
            state.insightSessionId = sid;
            state.insightCurrentNodeId = nid;
            state.insightSkeleton = skeleton;
            state.insightSectionLibsNeeded = newLibs;
            state.insightIframeReady = false;
            state.insightPendingChunks = new Map();

            // Switch to insight view & render breadcrumbs.
            switchToInsightView();
            const crumbs = Array.isArray(skeleton.breadcrumbs) ? skeleton.breadcrumbs : [{ nodeId: nid, title: skeleton.title || '' }];
            renderInsightBreadcrumbs(crumbs);
            setStatusBar('Loading…', 'phase-1', false);

            // Build srcdoc.
            const srcdoc = await buildInsightSrcdoc(skeleton, state.insightBlobURLs, katexCSSInline);

            // (Re)acquire iframe ref — DOM ref might have been replaced.
            if (!state.insightIframe || !document.body.contains(state.insightIframe)) {
                state.insightIframe = document.getElementById('insight-iframe');
                DOM.insightIframe = state.insightIframe;
            }
            if (!state.insightIframe) {
                console.warn('[insight] iframe element missing');
                return;
            }
            state.insightIframe.setAttribute('sandbox', 'allow-scripts');
            state.insightIframe.srcdoc = srcdoc;
            startIframeLoadTimer(sid);
        };

        // window.updateInsightSection(sessionId, sectionId, htmlChunk)
        // Strips CDN tags then forwards to iframe via postMessage. Buffers chunks
        // arriving before insightIframeReady.
        window.updateInsightSection = function(sessionId, sectionId, htmlChunk) {
            const sid = sessionId != null ? String(sessionId) : null;
            if (sid !== state.insightSessionId) {
                console.warn('[insight] updateInsightSection: stale session', sid);
                return;
            }
            const secId = String(sectionId || '');
            if (!secId) return;
            const skel = state.insightSkeleton;
            if (!skel || !Array.isArray(skel.sections) || !skel.sections.find(function(s) { return s && s.id === secId; })) {
                console.warn('[insight] updateInsightSection: unknown sectionId', secId);
                return;
            }
            const stripped = stripCDNTags(typeof htmlChunk === 'string' ? htmlChunk : '');
            if (!state.insightIframeReady || !state.insightIframe) {
                // Buffer until iframe ready.
                if (!state.insightPendingChunks.has(secId)) state.insightPendingChunks.set(secId, []);
                state.insightPendingChunks.get(secId).push(stripped);
                return;
            }
            try {
                state.insightIframe.contentWindow.postMessage({
                    type: 'updateInsightSection',
                    payload: { sessionId: sid, sectionId: secId, htmlChunk: stripped },
                }, '*');
            } catch (e) {
                console.warn('[insight] failed to post updateInsightSection:', e);
            }
            // Schedule per-section lib init after a quiet period (500 ms with no
            // further chunks for this section). The iframe srcdoc's
            // `initSectionLib` is idempotent: mermaid skips `data-processed`
            // diagrams, Chart.js construction is gated by canvas attribute,
            // KaTeX auto-render only walks new nodes. Running it once the
            // section is fully streamed turns LLM-emitted code blocks into
            // rendered diagrams/charts. Without this, diagrams stay as raw
            // <pre> text.
            if (!state.insightSectionInitTimers) state.insightSectionInitTimers = new Map();
            const prevTimer = state.insightSectionInitTimers.get(secId);
            if (prevTimer) clearTimeout(prevTimer);
            const t = setTimeout(function() {
                state.insightSectionInitTimers.delete(secId);
                if (!state.insightIframe || !state.insightIframe.contentWindow) return;
                try {
                    state.insightIframe.contentWindow.postMessage({
                        type: 'initSectionLib',
                        payload: { sectionId: secId },
                    }, '*');
                } catch (e) { /* iframe gone — ignore */ }
            }, 500);
            state.insightSectionInitTimers.set(secId, t);
        };

        // window.setInsightError(sessionId, message, retryable)
        // Renders error in status bar (chrome — parent frame). The 5-type
        // postMessage allowlist does NOT include a retry message; user retries by
        // re-invoking the original action (Up navigation, deep-dive click, etc.).
        // TODO(T6/T7 owner): if a 6th `insightRequestRetry` type is desired,
        // escalate to user before adding — would change the allowlist count.
        window.setInsightError = function(sessionId, message, retryable) {
            const sid = sessionId != null ? String(sessionId) : null;
            if (sid !== null && state.insightSessionId !== null && sid !== state.insightSessionId) {
                return; // drop stale
            }
            setStatusBar(message || 'Error', null, true);
            // retryable is currently surfaced only via the status bar text;
            // no in-DOM Retry button (would require adding a 6th postMessage type).
            if (retryable) {
                // Append a hint that user can retry via the originating action.
                const bar = DOM.insightStatusBar;
                if (bar && message) bar.textContent = String(message) + ' — retry by re-invoking action';
            }
        };

        // window.setInsightStatus(sessionId, message, phase)
        // Updates the status bar with phase tinting (phase-1/phase-2/ready) AND
        // forwards the same message to the in-iframe progress banner so the
        // user sees prominent feedback inside the content area (the bottom
        // status bar is easy to miss). Bottom bar kept as defense-in-depth.
        // Note: parent→iframe postMessage direction is NOT covered by the
        // 5-type JS→Swift bridge allowlist (Decision 2.5) — that allowlist
        // applies to webkit.messageHandlers.bridge only.
        window.setInsightStatus = function(sessionId, message, phase) {
            const sid = sessionId != null ? String(sessionId) : null;
            if (sid !== null && state.insightSessionId !== null && sid !== state.insightSessionId) {
                return;
            }
            setStatusBar(message, phase, false);
            // Forward to iframe progress banner.
            try {
                const iframe = state.insightIframe || (DOM.insightContainer && DOM.insightContainer.querySelector('iframe'));
                if (iframe && iframe.contentWindow) {
                    iframe.contentWindow.postMessage({
                        type: 'updateInsightProgress',
                        payload: { message: message == null ? '' : String(message), phase: phase || '' },
                    }, '*');
                }
            } catch (e) { /* iframe not ready / cross-origin — banner will catch up on next update */ }
        };

        // window.releaseInsightBlobs()
        // Revokes all blob URLs and clears caches. Called by Swift bridge BEFORE
        // session.cancel() per Decision 11.
        window.releaseInsightBlobs = function() {
            for (const url of state.insightBlobURLs.values()) {
                try { URL.revokeObjectURL(url); } catch (e) {}
            }
            state.insightBlobURLs.clear();
            state.insightLibBytes.clear();
            state.insightSectionLibsNeeded = new Set();
        };

        // ---------------------------------------------------------------------------
        // Parent-side message listener — SOLE inbound channel from iframe.
        // Strict 5-type allowlist + per-type payload schema validation +
        // event.source / event.origin validation.
        // ---------------------------------------------------------------------------
        const INSIGHT_ALLOWED_TYPES = new Set([
            'insightIframeReady',
            'insightDeepDiveClicked',
            'insightBreadcrumbClicked',
            'insightRequestSave',
            'insightRequestUp',
        ]);
        const UUID_REGEX = /^[0-9A-F-]{36}$/i;

        function isPlainObject(v) {
            return v != null && typeof v === 'object' && !Array.isArray(v);
        }

        window.addEventListener('message', function(ev) {
            // Only accept messages from the insight iframe contentWindow.
            if (!state.insightIframe || ev.source !== state.insightIframe.contentWindow) {
                return; // silently ignore unrelated postMessages
            }
            // Sandbox iframe is null-origin → event.origin is the literal string 'null'.
            if (ev.origin !== 'null') {
                console.warn('[insight] rejected postMessage with unexpected origin:', ev.origin);
                return;
            }
            const data = ev.data;
            if (!isPlainObject(data) || typeof data.type !== 'string') {
                console.warn('[insight] rejected malformed postMessage');
                return;
            }
            if (!INSIGHT_ALLOWED_TYPES.has(data.type)) {
                console.warn('[insight] rejected disallowed type:', data.type);
                return;
            }
            const payload = isPlainObject(data.payload) ? data.payload : {};

            switch (data.type) {
                case 'insightIframeReady': {
                    state.insightIframeReady = true;
                    clearIframeLoadTimer();
                    // Flush any chunks that arrived before iframe was ready.
                    if (state.insightPendingChunks.size > 0) {
                        for (const [secId, chunks] of state.insightPendingChunks.entries()) {
                            for (const chunk of chunks) {
                                try {
                                    state.insightIframe.contentWindow.postMessage({
                                        type: 'updateInsightSection',
                                        payload: { sessionId: state.insightSessionId, sectionId: secId, htmlChunk: chunk },
                                    }, '*');
                                } catch (e) { /* drop */ }
                            }
                        }
                        state.insightPendingChunks.clear();
                    }
                    sendToSwift('insightIframeReady', {
                        sessionId: state.insightSessionId,
                        nodeId: state.insightCurrentNodeId,
                    });
                    return;
                }
                case 'insightDeepDiveClicked': {
                    const sectionId = typeof payload.sectionId === 'string' ? payload.sectionId : null;
                    const topicIndex = (typeof payload.topicIndex === 'number' && Number.isInteger(payload.topicIndex)) ? payload.topicIndex : null;
                    if (!sectionId || topicIndex === null) {
                        console.warn('[insight] insightDeepDiveClicked: invalid payload');
                        return;
                    }
                    const skel = state.insightSkeleton;
                    if (!skel || !Array.isArray(skel.sections)) return;
                    const sec = skel.sections.find(function(s) { return s && s.id === sectionId; });
                    if (!sec) {
                        console.warn('[insight] insightDeepDiveClicked: unknown sectionId', sectionId);
                        return;
                    }
                    const topics = Array.isArray(sec.deepDiveTopics) ? sec.deepDiveTopics : [];
                    if (topicIndex < 0 || topicIndex >= topics.length) {
                        console.warn('[insight] insightDeepDiveClicked: topicIndex out of bounds', topicIndex);
                        return;
                    }
                    sendToSwift('insightDeepDiveClicked', {
                        sessionId: state.insightSessionId,
                        sectionId: sectionId,
                        topicIndex: topicIndex,
                    });
                    return;
                }
                case 'insightBreadcrumbClicked': {
                    const nodeId = typeof payload.nodeId === 'string' ? payload.nodeId : null;
                    if (!nodeId || !UUID_REGEX.test(nodeId)) {
                        console.warn('[insight] insightBreadcrumbClicked: nodeId not a UUID');
                        return;
                    }
                    sendToSwift('insightBreadcrumbClicked', {
                        sessionId: state.insightSessionId,
                        nodeId: nodeId,
                    });
                    return;
                }
                case 'insightRequestSave': {
                    sendToSwift('insightRequestSave', { sessionId: state.insightSessionId });
                    return;
                }
                case 'insightRequestUp': {
                    sendToSwift('insightRequestUp', { sessionId: state.insightSessionId });
                    return;
                }
            }
        }, false);

        // ============================================================================
        // END RECURSIVE INSIGHT MODE v2
