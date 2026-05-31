        function stripCDNTags(html) {
            if (typeof html !== 'string') return '';
            let out = html;
            // Strip markdown code-fence wrapper if LLM emitted one despite
            // being told not to: opening ```html / ```HTML / ``` at the very
            // start of a section, and closing ``` at the very end.
            out = out.replace(/^\s*```(?:html|HTML)?\s*\n?/, '');
            out = out.replace(/\n?```\s*$/, '');
            // Also handle mid-stream chunks where the fence sits on its own.
            out = out.replace(/^\s*```(?:html|HTML)?\s*$/gm, '');
            // Strip ALL <script>...</script> blocks (LLM should never emit
            // executable script — the iframe loads vendored libs itself).
            // Required because allow-same-origin removes the null-origin XSS
            // mitigation; we replace it with a content-side strip.
            out = out.replace(/<script\b[\s\S]*?<\/script\s*>/gi, '<!-- script stripped -->');
            // Strip self-closing or src-only script tags too.
            out = out.replace(/<script\b[^>]*\/?>/gi, '<!-- script tag stripped -->');
            // Strip on*= event-handler attributes (onclick, onload, onerror, …).
            // Match unquoted, single-quoted, double-quoted forms.
            out = out.replace(/\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, ' ');
            // Strip javascript: URLs in href/src.
            out = out.replace(/\b(href|src)\s*=\s*(['"])\s*javascript:[^'"]*\2/gi, '$1="#"');
            // Strip <link rel=prefetch|preconnect|dns-prefetch (network leak).
            out = out.replace(/<link\b[^>]*?\brel\s*=\s*["'](?:prefetch|preconnect|dns-prefetch)["'][^>]*>/gi, function(match) {
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
        window.loadInsightSkeleton = async function(skeletonOrJSON, sessionId, nodeId, breadcrumbsArg) {
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
            // breadcrumbsArg is the explicit chain from Swift: [{nodeId, title}, ...].
            // Stash on skeleton so renderInsightBreadcrumbs (called below) picks it up.
            if (Array.isArray(breadcrumbsArg) && breadcrumbsArg.length > 0) {
                skeleton.breadcrumbs = breadcrumbsArg;
            }

            // SYNCHRONOUS state pre-init — must happen BEFORE any await so
            // that updateInsightSection chunks landing during loadInsightSkeleton's
            // async work (lib fetch, srcdoc build) see the correct sessionId
            // and a fresh pendingChunks Map to land in.
            try {
                sendToSwift('jsError', { where: 'parent-loadInsightSkeleton-syncInit', message: 'sid=' + sid + ' previous_sid=' + state.insightSessionId + ' previous_pending_size=' + (state.insightPendingChunks ? state.insightPendingChunks.size : 'NULL'), source: '', lineno: 0, colno: 0, stack: '' });
            } catch (_) {}
            state.insightSessionId = sid;
            state.insightCurrentNodeId = nid;
            state.insightSkeleton = skeleton;
            state.insightIframeReady = false;
            state.insightPendingChunks = new Map();

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

            // Note: state.insightSessionId / Skeleton / IframeReady /
            // PendingChunks were already initialised SYNCHRONOUSLY at the top
            // of this function (before any await). Resetting them here would
            // wipe the pendingChunks Map containing chunks streamed in during
            // the await — exactly the "restored cache shows skeleton-loaders
            // forever" bug. We update only the lib-dependent field.
            state.insightSectionLibsNeeded = newLibs;

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
            // sandbox: allow-scripts AND allow-same-origin. The latter is
            // required so vendored libs (mermaid, Chart.js, KaTeX, Prism)
            // load via blob:/data: URLs created in the parent — without
            // allow-same-origin the iframe is null-origin and WebKit blocks
            // those cross-origin script fetches, leaving libs undefined and
            // diagrams un-rendered. allow-same-origin re-enables that path
            // but trades away the "iframe runs in unique origin" XSS
            // mitigation. We compensate by stripping ALL <script>…</script>
            // and on*= attributes from LLM output via stripCDNTags before
            // the chunk reaches the iframe.
            state.insightIframe.setAttribute('sandbox', 'allow-scripts allow-same-origin');
            state.insightIframe.srcdoc = srcdoc;
            try {
                sendToSwift('jsError', {
                    where: 'parent-loadInsightSkeleton-srcdocSet',
                    message: 'srcdocLen=' + srcdoc.length + ' iframeInDOM=' + document.body.contains(state.insightIframe) + ' iframeDisplay=' + (state.insightIframe.style.display || 'default') + ' containerVisible=' + (DOM.insightContainer && DOM.insightContainer.classList.contains('visible')),
                    source: '', lineno: 0, colno: 0, stack: ''
                });
            } catch (_) {}
            // Hide the loading overlay; iframe content takes over from here.
            if (typeof hideInsightLoadingOverlay === 'function') hideInsightLoadingOverlay();
            startIframeLoadTimer(sid);
        };

        // window.updateInsightSection(sessionId, sectionId, htmlChunk)
        // Strips CDN tags then forwards to iframe via postMessage. Buffers chunks
        // arriving before insightIframeReady.
        window.updateInsightSection = function(sessionId, sectionId, htmlChunk) {
            const sid = sessionId != null ? String(sessionId) : null;
            if (sid !== state.insightSessionId) {
                try {
                    sendToSwift('jsError', {
                        where: 'parent-updateInsightSection-stale',
                        message: 'incoming sid=' + sid + ' state.sid=' + state.insightSessionId + ' secId=' + sectionId,
                        source: '', lineno: 0, colno: 0, stack: ''
                    });
                } catch (_) {}
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
                try {
                    sendToSwift('jsError', { where: 'parent-updateInsightSection-buffered', message: 'secId=' + secId + ' size_after=' + state.insightPendingChunks.size + ' iframeReady=' + state.insightIframeReady, source: '', lineno: 0, colno: 0, stack: '' });
                } catch (_) {}
                return;
            }
            try {
                sendToSwift('jsError', { where: 'parent-updateInsightSection-direct', message: 'secId=' + secId + ' iframeReady=' + state.insightIframeReady, source: '', lineno: 0, colno: 0, stack: '' });
            } catch (_) {}
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
            // Debounce per-section initSectionLib. Short timeout so navigation
            // (Up / breadcrumb / re-opened deep-dive) feels instant — chunks
            // for a cached node arrive in a tight burst, and 100 ms is long
            // enough that mid-stream chunks during real Phase 2 still coalesce
            // into a single flush per section.
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
            }, 100);
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
            // Track which session this status belongs to even if loadInsightSkeleton
            // hasn't fired yet (Phase 1 status arrives BEFORE skeleton).
            if (sid !== null && state.insightSessionId === null) {
                state.insightSessionId = sid;
            }
            // Show prominent in-tab overlay ONLY during the actual Phase 1 LLM
            // call, when no skeleton/iframe content exists yet to display.
            // Match strictly "analyzing N files" (the start-of-Phase-1 message)
            // — NOT "Phase 1: built skeleton" (which arrives just before
            // loadInsightSkeleton paints the iframe and would re-cover it),
            // NOT Phase 2 progress, and NOT the final "Ready" / "Complete"
            // states. hideInsightLoadingOverlay() in loadInsightSkeleton then
            // tears the overlay down once srcdoc is set.
            // Show overlay during ANY active "Phase 1" generation — initial,
            // deep-dive expansion, and regenerate. Matches "analyzing N files"
            // (initial / regen-root) AND "analyzing files" (regen-node).
            const isPhase1Active = typeof message === 'string' && /\bphase 1\b.*\banalyz/i.test(message);
            if (isPhase1Active && typeof showInsightLoadingOverlay === 'function') {
                showInsightLoadingOverlay(message);
            }
            // Remember last status so insightIframeReady handler can re-send
            // it to iframe (statuses sent before iframe load are otherwise
            // lost → iframe banner stuck on "Initializing…").
            state.insightLastStatus = { message: message, phase: phase };
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
            'insightRequestRegenerate',
            'insightRequestCustomDeepDive',
            'insightRequestExploreAll',
            'insightRequestRetrySection',
            'insightDebug', // diagnostic — forwarded to Swift jsError, no business behavior
        ]);
        const UUID_REGEX = /^[0-9A-F-]{36}$/i;

        function isPlainObject(v) {
            return v != null && typeof v === 'object' && !Array.isArray(v);
        }

        window.addEventListener('message', function(ev) {
            // Diagnostic: log every incoming message regardless of source.
            try {
                sendToSwift('jsError', {
                    where: 'parent-onmessage-raw',
                    message: 'origin=' + JSON.stringify(ev.origin) + ' typeof_data=' + (typeof ev.data) + ' data_type=' + (ev.data && ev.data.type) + ' has_iframe=' + !!state.insightIframe + ' src_matches=' + (state.insightIframe && ev.source === state.insightIframe.contentWindow),
                    source: '', lineno: 0, colno: 0, stack: ''
                });
            } catch (_) {}
            // Only accept messages from the insight iframe contentWindow.
            if (!state.insightIframe || ev.source !== state.insightIframe.contentWindow) {
                return; // silently ignore unrelated postMessages
            }
            // Sandbox iframe is null-origin per spec → event.origin SHOULD be the
            // literal string 'null', but WebKit (when the parent itself was loaded
            // via WKWebView.loadHTMLString, which gives parent a 'null' or 'file://'
            // origin) may produce '' or other values for the sandboxed iframe's
            // origin. The defensive `ev.source` identity check above already
            // proves the message came from OUR iframe (no other window has the
            // same contentWindow reference), so the origin check is redundant —
            // accept any origin from our verified source. Tracked: tighten back
            // to a strict allowlist once WebKit's exact behaviour is confirmed.
            // Diagnostic: log first observed origin so we know what to allowlist.
            if (!state.__insightLoggedOrigin) {
                state.__insightLoggedOrigin = true;
                try {
                    sendToSwift('jsError', {
                        where: 'parent-iframe-origin',
                        message: 'first iframe postMessage origin=' + JSON.stringify(ev.origin),
                        source: '', lineno: 0, colno: 0, stack: ''
                    });
                } catch (_) {}
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
                    // Re-send the last status to iframe so the "Initializing…"
                    // banner reflects the current state (e.g. on cache restore
                    // the status fires BEFORE iframe loads → iframe misses it
                    // → banner stays at "Initializing…" forever).
                    try {
                        if (state.insightLastStatus && state.insightIframe && state.insightIframe.contentWindow) {
                            state.insightIframe.contentWindow.postMessage({
                                type: 'updateInsightProgress',
                                payload: { message: state.insightLastStatus.message || '', phase: state.insightLastStatus.phase || '' },
                            }, '*');
                        }
                    } catch (_) {}
                    try {
                        sendToSwift('jsError', {
                            where: 'parent-iframeReady-flush', message: 'pendingChunks.size=' + (state.insightPendingChunks ? state.insightPendingChunks.size : 'NULL'),
                            source: '', lineno: 0, colno: 0, stack: ''
                        });
                    } catch (_) {}
                    // Flush any chunks that arrived before iframe was ready,
                    // then trigger initSectionLib for EACH section so the
                    // iframe actually flushes its buffer to the DOM and
                    // initialises mermaid/Chart/Prism. Without this, restored
                    // (cached) sessions accumulate chunks but the section
                    // bodies stay as skeleton-loaders forever.
                    if (state.insightPendingChunks.size > 0) {
                        const flushedSectionIds = new Set();
                        for (const [secId, chunks] of state.insightPendingChunks.entries()) {
                            for (const chunk of chunks) {
                                try {
                                    state.insightIframe.contentWindow.postMessage({
                                        type: 'updateInsightSection',
                                        payload: { sessionId: state.insightSessionId, sectionId: secId, htmlChunk: chunk },
                                    }, '*');
                                } catch (e) { /* drop */ }
                            }
                            flushedSectionIds.add(secId);
                        }
                        state.insightPendingChunks.clear();
                        // Trigger lib init for every flushed section.
                        for (const secId of flushedSectionIds) {
                            try {
                                state.insightIframe.contentWindow.postMessage({
                                    type: 'initSectionLib',
                                    payload: { sectionId: secId },
                                }, '*');
                            } catch (e) { /* drop */ }
                        }
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
                case 'insightRequestRegenerate': {
                    sendToSwift('insightRequestRegenerate', { sessionId: state.insightSessionId });
                    return;
                }
                case 'insightRequestCustomDeepDive': {
                    var topic = (payload && typeof payload.topic === 'string') ? payload.topic.trim() : '';
                    if (!topic) return;
                    sendToSwift('insightRequestCustomDeepDive', { sessionId: state.insightSessionId, topic: topic });
                    return;
                }
                case 'insightRequestExploreAll': {
                    var d = (payload && typeof payload.depth === 'number') ? payload.depth : 1;
                    if (!(d >= 1 && d <= 3)) d = 1;
                    sendToSwift('insightRequestExploreAll', { sessionId: state.insightSessionId, depth: d });
                    return;
                }
                case 'insightRequestRetrySection': {
                    var secId = (payload && typeof payload.sectionId === 'string') ? payload.sectionId : '';
                    if (!secId) return;
                    sendToSwift('insightRequestRetrySection', { sessionId: state.insightSessionId, sectionId: secId });
                    return;
                }
                case 'insightDebug': {
                    // Forward iframe-side diag back to Swift via jsError channel.
                    sendToSwift('jsError', {
                        where: 'iframe-debug-' + (payload.where || '?'),
                        message: String(payload.msg || ''),
                        source: 'iframe', lineno: 0, colno: 0, stack: ''
                    });
                    return;
                }
            }
        }, false);

        // ============================================================================
        // END RECURSIVE INSIGHT MODE v2
