        // END STRUCTURED DATA SUPPORT
        // ============================================================================

        // ============================================================================
        // RECURSIVE INSIGHT MODE v2 (state.mode === 'insight')
        //
        // Architecture: ALL LLM-rendered content lives inside a single
        // <iframe sandbox="allow-scripts"> (null-origin). The parent (this scope)
        // owns: chrome (breadcrumbs + status bar), bridge plumbing, blob-URL
        // lifecycle for vendored libs, and message validation.
        //
        // Trust boundary: parent ↔ iframe via postMessage. Strict 5-type allowlist
        // (insightIframeReady, insightDeepDiveClicked, insightBreadcrumbClicked,
        //  insightRequestSave, insightRequestUp). The 5 Swift→JS setters are:
        //  loadInsightSkeleton, updateInsightSection, setInsightError,
        //  setInsightStatus, releaseInsightBlobs.
        //
        // See task 5 / tech-spec Decisions 2, 3, 5, 10, 11.
        // ============================================================================

        // ---------------------------------------------------------------------------
        // Escape utilities (Decision 10) — SOLE permitted path for any LLM-controlled
        // string entering an HTML or attribute context anywhere in parent JS.
        // For chrome that uses textContent we don't need them; they exist for cases
        // where strings get interpolated into srcdoc string construction.
        // ---------------------------------------------------------------------------
        function escapeForHTMLText(s) {
            if (s == null) return '';
            return String(s)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#39;');
        }
        function escapeForHTMLAttribute(s) {
            // Same five metachars per Decision 10 — attribute and text use the
            // identical escape set; functions kept distinct for call-site clarity.
            if (s == null) return '';
            return String(s)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#39;');
        }

        // ---------------------------------------------------------------------------
        // Lib mapping — skeleton drives which vendored libs to materialize as blobs.
        // Prism is always loaded (universal code highlighting). Mermaid only if any
        // section.type === 'mermaidDiagram'. Chart only if 'chartJsChart'. KaTeX only
        // if skeleton.metadata.hasMath === true OR a section declares hasMath.
        // ---------------------------------------------------------------------------
        const INSIGHT_LIB_FILES = {
            // libName: relative path under Resources/Editor/
            mermaid: 'vendor/js/mermaid.min.js',
            chart: 'vendor/js/chart-4.4.9.min.js',
            katex: 'vendor/js/katex.min.js',
            'katex-auto': 'vendor/js/auto-render.min.js',
            prism: 'vendor/js/prism.min.js',
        };
        // KaTeX webfonts list (used only if KaTeX is required) — base64-inlined into
        // CSS @font-face rules per Decision 5 caveats.
        const KATEX_FONTS = [
            'KaTeX_Main-Regular.woff2',
            'KaTeX_Math-Italic.woff2',
        ];

        function computeRequiredLibs(skeleton) {
            const libs = new Set(['prism']);
            if (!skeleton || !Array.isArray(skeleton.sections)) return libs;
            let needsMath = false;
            for (const s of skeleton.sections) {
                if (!s || typeof s.type !== 'string') continue;
                if (s.type === 'mermaidDiagram') libs.add('mermaid');
                if (s.type === 'chartJsChart') libs.add('chart');
                if (s.metadata && (s.metadata.hasMath === true)) needsMath = true;
            }
            if (skeleton.metadata && skeleton.metadata.hasMath === true) needsMath = true;
            if (needsMath) {
                libs.add('katex');
                libs.add('katex-auto');
            }
            return libs;
        }

        // ---------------------------------------------------------------------------
        // Lazy lib materialization (Decision 5).
        // ensureLibBlob fetches the lib source from app bundle (same-origin to
        // parent), wraps it in a Blob, creates a blob: URL, and caches it. Iframe
        // <script src="blob:..."> tags reference these URLs.
        // ---------------------------------------------------------------------------
        async function ensureLibBlob(libName) {
            if (state.insightBlobURLs.has(libName)) {
                return state.insightBlobURLs.get(libName);
            }
            const path = INSIGHT_LIB_FILES[libName];
            if (!path) {
                console.warn('[insight] unknown lib name:', libName);
                return null;
            }
            let src = state.insightLibBytes.get(libName);
            if (typeof src !== 'string') {
                try {
                    const resp = await fetch(path);
                    if (!resp.ok) throw new Error('HTTP ' + resp.status);
                    src = await resp.text();
                    state.insightLibBytes.set(libName, src);
                } catch (e) {
                    console.warn('[insight] failed to fetch lib', libName, e);
                    return null;
                }
            }
            const blob = new Blob([src], { type: 'application/javascript' });
            const url = URL.createObjectURL(blob);
            state.insightBlobURLs.set(libName, url);
            return url;
        }

        // KaTeX CSS + base64-inlined webfonts (Decision 5 caveat). Returns a string
        // suitable for inlining into iframe srcdoc <style>. Heavy first call; then
        // cached in state.insightLibBytes under key '__katex-css-inline'.
        async function ensureKatexCSSInline() {
            const cacheKey = '__katex-css-inline';
            if (state.insightLibBytes.has(cacheKey)) {
                return state.insightLibBytes.get(cacheKey);
            }
            try {
                const cssResp = await fetch('vendor/css/katex.min.css');
                if (!cssResp.ok) throw new Error('katex.min.css HTTP ' + cssResp.status);
                let css = await cssResp.text();
                for (const fontName of KATEX_FONTS) {
                    try {
                        const fr = await fetch('vendor/css/fonts/' + fontName);
                        if (!fr.ok) continue;
                        const buf = await fr.arrayBuffer();
                        // Base64 encode the binary woff2.
                        let binary = '';
                        const bytes = new Uint8Array(buf);
                        for (let i = 0; i < bytes.byteLength; i++) binary += String.fromCharCode(bytes[i]);
                        const b64 = btoa(binary);
                        // Replace any url(...fontName) / url(...fontName?...) reference with data: URL.
                        // KaTeX CSS uses paths like "fonts/KaTeX_Main-Regular.woff2".
                        const dataUrl = 'data:font/woff2;base64,' + b64;
                        const escapedName = fontName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
                        const re = new RegExp('url\\([^)]*' + escapedName + '[^)]*\\)', 'g');
                        css = css.replace(re, 'url(' + dataUrl + ')');
                    } catch (e) {
                        // Skip missing webfont — KaTeX still renders with fallback.
                    }
                }
                state.insightLibBytes.set(cacheKey, css);
                return css;
            } catch (e) {
                console.warn('[insight] failed to inline KaTeX CSS:', e);
                return '';
            }
        }

        // ---------------------------------------------------------------------------
        // Iframe srcdoc builder. Constructs a full self-contained HTML document with
        // CSP meta, optional lib script tags (via blob URLs), section placeholders,
        // and an inline iframe-side message dispatch script.
        // ---------------------------------------------------------------------------
        async function buildInsightSrcdoc(skeleton, libBlobURLs, katexCSSInline) {
            // CSP per task spec / Decision 10.
            // 'self' allows the iframe to load <script src="vendor/js/..."> from
            // its file:// origin (with sandbox allow-same-origin set on the
            // iframe element by the parent).
            const csp = "default-src 'none'; script-src 'self' 'unsafe-inline' blob: data:; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data: blob:; font-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";
            const title = escapeForHTMLText(skeleton && skeleton.title ? skeleton.title : 'Insight');

            // Lib <script src="blob:..."> tags — the blob URL approach. Note
            // WebKit blocks cross-origin blob loads in null-origin sandboxed
            // iframes, so libs may end up undefined inside the iframe; that
            // disables mermaid/Chart rendering, but the iframe IIFE itself
            // still runs and the section HTML still renders as text/tables.
            // The previous inline-`<script>SRC</script>` attempt produced a
            // ~1MB srcdoc that broke iframe parsing entirely (no IIFE run,
            // no `insightIframeReady` fired, all chunks stuck in pending
            // buffer — rendering nothing). Diagram rendering is a separate
            // concern; tracked as TODO.
            // Iframe runs with sandbox="allow-scripts allow-same-origin", so
            // it inherits parent's file:// origin and can load relative
            // <script src="vendor/js/..."> directly. Direct paths avoid
            // WebKit's null-origin block on cross-origin blob: URLs (which
            // is why mermaid/Chart/Prism stayed undefined with blob: URLs).
            const LIB_PATHS = {
                prism:        'vendor/js/prism.min.js',
                mermaid:      'vendor/js/mermaid.min.js',
                chart:        'vendor/js/chart-4.4.9.min.js',
                katex:        'vendor/js/katex.min.js',
                'katex-auto': 'vendor/js/auto-render.min.js',
            };
            const libOrder = ['prism', 'mermaid', 'chart', 'katex', 'katex-auto'];
            const libsNeeded = computeRequiredLibs(skeleton);
            let libScripts = '';
            for (const libName of libOrder) {
                if (!libsNeeded.has(libName)) continue;
                const path = LIB_PATHS[libName];
                if (!path) continue;
                libScripts += '<script src="' + escapeForHTMLAttribute(path) + '"></script>\n';
            }

            // KaTeX CSS (only if math required and we successfully inlined).
            const katexStyleBlock = katexCSSInline ? '<style>' + katexCSSInline + '</style>' : '';

            // Section placeholders + inline 🤿 deep-dive buttons.
            let sectionsHTML = '';
            const sections = (skeleton && Array.isArray(skeleton.sections)) ? skeleton.sections : [];
            for (const s of sections) {
                if (!s || typeof s.id !== 'string') continue;
                const sid = escapeForHTMLAttribute(s.id);
                const sTitle = escapeForHTMLText(s.title || '');
                const sType = escapeForHTMLAttribute(s.type || '');
                let buttonsHTML = '';
                if (Array.isArray(s.deepDiveTopics)) {
                    s.deepDiveTopics.forEach(function(topic, idx) {
                        if (!topic) return;
                        const label = escapeForHTMLText(topic.label || '');
                        buttonsHTML += '<button class="dd-btn" data-section-id="' + sid + '" data-topic-index="' + idx + '">🤿 ' + label + '</button>';
                    });
                }
                sectionsHTML +=
                    '<section data-section-id="' + sid + '" data-section-type="' + sType + '">' +
                    '<h2 class="section-title">' + sTitle + '</h2>' +
                    '<div class="section-body" id="placeholder-' + sid + '">' +
                    '<div class="skeleton-loader"></div>' +
                    '<div class="skeleton-loader skeleton-loader-short"></div>' +
                    '<div class="skeleton-loader"></div>' +
                    '</div>' +
                    (buttonsHTML ? '<div class="dd-buttons">' + buttonsHTML + '</div>' : '') +
                    '</section>';
            }

            // Iframe-side script — string body (not LLM-derived). LLM strings
            // interpolated INTO the script body MUST go through JSON.stringify.
            // (Currently we don't inject any LLM strings into the script body.)
            const iframeScript = `
            (function() {
                'use strict';
                function postParent(type, payload) {
                    try { window.parent.postMessage({ type: type, payload: payload || {} }, '*'); }
                    catch (e) { /* no-op */ }
                }
                // Diagnostic: log IIFE entry, libs, errors. If only IIFE-START
                // arrives in diag log but no IIFE-END, something between threw.
                postParent('insightDebug', { where: 'iife', msg: 'IIFE-START readyState=' + document.readyState + ' libs={mermaid:' + (typeof mermaid) + ',Chart:' + (typeof Chart) + ',Prism:' + (typeof Prism) + '}' });
                window.addEventListener('error', function(ev) {
                    postParent('insightDebug', { where: 'iframe-window-error', msg: String(ev.message || ev.error || 'unknown') + ' @ ' + (ev.filename || '?') + ':' + (ev.lineno || 0) });
                });
                function escAttr(s) {
                    if (s == null) return '';
                    return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
                }
                // Per-section pending lib-init flag (deferred until section streamed).
                function initSectionLib(sectionId) {
                    var sec = document.querySelector('section[data-section-id="' + escAttr(sectionId) + '"]');
                    if (!sec) {
                        postParent('insightDebug', { where: 'initSectionLib', msg: 'no section element for sid=' + sectionId });
                        return;
                    }
                    var type = sec.getAttribute('data-section-type') || '';
                    var bodyEl = sec.querySelector('.section-body');
                    var bodyLen = bodyEl ? (bodyEl.innerHTML || '').length : -1;
                    var preCount = sec.querySelectorAll('pre').length;
                    var canvasCount = sec.querySelectorAll('canvas').length;
                    var mermaidCount = sec.querySelectorAll('.mermaid, pre code.language-mermaid').length;
                    postParent('insightDebug', { where: 'initSectionLib', msg: 'sid=' + sectionId + ' type=' + type + ' bodyLen=' + bodyLen + ' pre=' + preCount + ' canvas=' + canvasCount + ' mermaid=' + mermaidCount + ' libs={mermaid:' + (typeof mermaid) + ',Chart:' + (typeof Chart) + ',Prism:' + (typeof Prism) + '}' });
                    try {
                        if (type === 'mermaidDiagram' && typeof mermaid !== 'undefined') {
                            // Accept several markup forms — LLM may emit any of:
                            //   <pre><code class="language-mermaid">SRC</code></pre>
                            //   <pre class="mermaid">SRC</pre>
                            //   <pre>graph TD...</pre>  (no class — fallback heuristic)
                            //   <div class="mermaid">SRC</div>
                            // Convert all to canonical <div class="mermaid">.
                            var nodesToConvert = sec.querySelectorAll(
                                'pre code.language-mermaid, pre.mermaid'
                            );
                            for (var i = 0; i < nodesToConvert.length; i++) {
                                var node = nodesToConvert[i];
                                var pre = (node.tagName === 'CODE') ? node.parentElement : node;
                                if (!pre) continue;
                                var src = (node.textContent || '').trim();
                                if (!src) continue;
                                // LLM sometimes emits literal "\\n" instead of newlines
                                // and "<br/>" inside node labels; normalise both.
                                var BS = String.fromCharCode(92);
                                var LF = String.fromCharCode(10);
                                src = src.split(BS + 'n').join(LF);
                                src = src.split(BS + BS).join(BS);
                                src = src.replace(/<br\\s*\\/>/gi, '<br>');
                                var div = document.createElement('div');
                                div.className = 'mermaid';
                                div.textContent = src;
                                pre.replaceWith(div);
                            }
                            // Heuristic fallback: any remaining <pre> whose first
                            // non-blank line starts with a known mermaid keyword.
                            var preList = sec.querySelectorAll('pre');
                            for (var pi = 0; pi < preList.length; pi++) {
                                var p = preList[pi];
                                var ptxt = (p.textContent || '').trim();
                                if (!ptxt) continue;
                                var firstLine = ptxt.split(/\\r?\\n/)[0].trim().toLowerCase();
                                if (/^(graph|flowchart|sequencediagram|classdiagram|statediagram|gantt|pie|gitgraph|journey|erdiagram|mindmap|timeline|quadrantchart)/.test(firstLine)) {
                                    var d = document.createElement('div');
                                    d.className = 'mermaid';
                                    d.textContent = ptxt;
                                    p.replaceWith(d);
                                }
                            }
                            try {
                                mermaid.initialize({ startOnLoad: false, securityLevel: 'loose', flowchart: { htmlLabels: true } });
                                mermaid.run({ nodes: sec.querySelectorAll('.mermaid'), suppressErrors: true });
                            } catch (e) { /* per-block recover handled by mermaid */ }
                        } else if (type === 'chartJsChart' && typeof Chart !== 'undefined') {
                            // Phase 2 prompt uses data-chart; older code looked for
                            // data-chart-config. Accept both. LLM sometimes embeds
                            // JS function strings inside the JSON (callback fields)
                            // — strip those before JSON.parse so the rest renders.
                            var canvases = sec.querySelectorAll('canvas[data-chart], canvas[data-chart-config]');
                            for (var j = 0; j < canvases.length; j++) {
                                var cv = canvases[j];
                                if (cv.dataset && cv.dataset.chartRendered === '1') continue;
                                var cfgStr = cv.getAttribute('data-chart') || cv.getAttribute('data-chart-config') || '';
                                if (!cfgStr) continue;
                                var cleaned = cfgStr.replace(/"function"\\s*:\\s*"function[\\s\\S]*?"\\s*\\}/g, '"_stripped":true}');
                                try {
                                    var cfg = JSON.parse(cleaned);
                                    new Chart(cv, cfg);
                                    cv.dataset.chartRendered = '1';
                                } catch (e) {
                                    postParent('insightDebug', { where: 'chart-render', msg: 'sid=' + sectionId + ' parse/init failed: ' + String(e).substr(0, 200) });
                                }
                            }
                        }
                        if (typeof renderMathInElement === 'function') {
                            try { renderMathInElement(sec, { throwOnError: false }); } catch (e) {}
                        }
                        if (typeof Prism !== 'undefined') {
                            try { Prism.highlightAllUnder(sec); } catch (e) {}
                        }
                    } catch (e) { /* swallow lib init errors per section */ }
                }

                // Per-section buffer: HTML chunks streamed by Swift arrive
                // mid-tag (e.g. <canvas data-chart='{partial JSON ...). Calling
                // insertAdjacentHTML on each chunk re-parses fragmentary HTML
                // and the browser treats orphan attributes/text as text nodes
                // OUTSIDE the intended element — producing the "raw attribute
                // text" symptom users saw. Solution: append chunks to a string
                // buffer, flush via innerHTML once on section completion (the
                // initSectionLib trigger). Browser parses the FULL HTML at
                // once and elements like canvas end up correctly formed.
                var sectionBuffers = Object.create(null);
                var flushedSections = Object.create(null);
                function flushSectionBuffer(sectionId) {
                    var ph = document.getElementById('placeholder-' + sectionId);
                    if (!ph) return;
                    var html = sectionBuffers[sectionId] || '';
                    if (!html) return;
                    // innerHTML replaces all children — wipes skeleton loaders
                    // AND any prior partial parse. Browser parses the full
                    // string in one go.
                    try { ph.innerHTML = html; }
                    catch (e) { /* malformed — leave skeleton in place */ }
                    flushedSections[sectionId] = true;
                }

                window.addEventListener('message', function(ev) {
                    var data = ev.data;
                    if (!data || typeof data !== 'object') return;
                    if (typeof data.type !== 'string') return;
                    var p = data.payload || {};
                    if (data.type === 'updateInsightSection') {
                        var sid = String(p.sectionId || '');
                        if (!sid) return;
                        // Buffer the chunk; do NOT touch the DOM yet.
                        if (!sectionBuffers[sid]) sectionBuffers[sid] = '';
                        sectionBuffers[sid] += String(p.htmlChunk || '');
                    } else if (data.type === 'initSectionLib') {
                        var ssid = String(p.sectionId || '');
                        if (ssid) flushSectionBuffer(ssid);
                        initSectionLib(ssid);
                    } else if (data.type === 'updateInsightProgress') {
                        // In-iframe progress banner — prominent feedback while
                        // generation is in flight. textContent ONLY (Decision 10).
                        var banner = document.getElementById('insight-progress-banner');
                        if (!banner) return;
                        var textEl = banner.querySelector('.insight-progress-text');
                        if (textEl && p.message != null) {
                            textEl.textContent = String(p.message);
                        }
                        if (p.phase === 'ready') {
                            banner.classList.add('insight-progress-done');
                            setTimeout(function() {
                                if (banner && banner.parentNode) {
                                    banner.parentNode.removeChild(banner);
                                }
                            }, 800);
                        }
                    } else if (data.type === 'setIframeStatus') {
                        // No iframe-side status surface yet; ignore.
                    }
                }, false);

                // 🤿 deep-dive button click delegation.
                document.addEventListener('click', function(ev) {
                    var t = ev.target;
                    if (!t || !t.classList) return;
                    if (t.classList.contains('dd-btn')) {
                        var sid = t.getAttribute('data-section-id') || '';
                        var idx = parseInt(t.getAttribute('data-topic-index') || '0', 10);
                        postParent('insightDeepDiveClicked', { sectionId: sid, topicIndex: idx });
                    } else if (t.id === 'iframe-btn-save') {
                        postParent('insightRequestSave', {});
                    } else if (t.id === 'iframe-btn-up') {
                        postParent('insightRequestUp', {});
                    } else if (t.id === 'iframe-btn-custom-dd') {
                        var inp = document.getElementById('iframe-input-topic');
                        var topic = (inp && inp.value || '').trim();
                        if (!topic) return;
                        var langSel = document.getElementById('iframe-lang');
                        var lang = langSel ? langSel.value : 'auto';
                        postParent('insightRequestCustomDeepDive', { topic: topic, lang: lang });
                        if (inp) inp.value = '';
                    } else if (t.id === 'iframe-btn-explore-all') {
                        var sel = document.getElementById('iframe-explore-depth');
                        var depth = sel ? parseInt(sel.value || '1', 10) : 1;
                        if (!(depth >= 1 && depth <= 3)) depth = 1;
                        var langSel2 = document.getElementById('iframe-lang');
                        var lang2 = langSel2 ? langSel2.value : 'auto';
                        postParent('insightRequestExploreAll', { depth: depth, lang: lang2 });
                    } else if (t.hasAttribute && t.hasAttribute('data-retry-section')) {
                        var rsid = t.getAttribute('data-retry-section') || '';
                        if (rsid) postParent('insightRequestRetrySection', { sectionId: rsid });
                    }
                }, false);

                // Lightbox click-to-zoom for diagrams/charts/images. Builds
                // a fullscreen modal on first click, clones target into it,
                // provides +/-/reset/close + keyboard. Wrapped in try so any
                // closest()/clone failure can't kill iframeReady signal.
                try {
                    var lb = null, lbContent = null, lbZoom = 1, lbPanX = 0, lbPanY = 0;
                    var lbDragging = false, lbDragStartX = 0, lbDragStartY = 0, lbDragInitX = 0, lbDragInitY = 0;
                    function lbApplyTransform() {
                        if (lbContent) lbContent.style.transform = 'translate(' + lbPanX + 'px,' + lbPanY + 'px) scale(' + lbZoom + ')';
                    }
                    function lbSetZoom(z) {
                        lbZoom = Math.max(0.25, Math.min(8, z));
                        lbApplyTransform();
                        var pct = lb && lb.querySelector('.lb-pct');
                        if (pct) pct.textContent = Math.round(lbZoom * 100) + '%';
                    }
                    function lbResetPan() { lbPanX = 0; lbPanY = 0; lbApplyTransform(); }
                    function lbClose() { if (lb) lb.classList.remove('on'); if (lbContent) lbContent.innerHTML = ''; lbPanX = 0; lbPanY = 0; lbZoom = 1; }
                    function lbEnsure() {
                        if (lb) return;
                        lb = document.createElement('div'); lb.id = 'lb';
                        lb.innerHTML = '<div class="lb-stage"><div class="lb-content"></div></div>' +
                            '<div class="lb-bar">' +
                            '<button class="lb-out" title="Zoom out (-)">−</button>' +
                            '<span class="lb-pct">100%</span>' +
                            '<button class="lb-in" title="Zoom in (+)">+</button>' +
                            '<button class="lb-reset" title="Reset (1)">1:1</button>' +
                            '<button class="lb-close" title="Close (Esc)">✕</button>' +
                            '</div>';
                        document.body.appendChild(lb);
                        lbContent = lb.querySelector('.lb-content');
                        lb.querySelector('.lb-in').addEventListener('click', function(e) { e.stopPropagation(); lbSetZoom(lbZoom * 1.25); });
                        lb.querySelector('.lb-out').addEventListener('click', function(e) { e.stopPropagation(); lbSetZoom(lbZoom / 1.25); });
                        lb.querySelector('.lb-reset').addEventListener('click', function(e) { e.stopPropagation(); lbResetPan(); lbSetZoom(1); });
                        lb.querySelector('.lb-close').addEventListener('click', function(e) { e.stopPropagation(); lbClose(); });
                        lb.addEventListener('click', function(ev) {
                            if (ev.target === lb || (ev.target.classList && ev.target.classList.contains('lb-stage'))) lbClose();
                        });
                        document.addEventListener('keydown', function(ev) {
                            if (!lb.classList.contains('on')) return;
                            if (ev.key === 'Escape') lbClose();
                            else if (ev.key === '+' || ev.key === '=') lbSetZoom(lbZoom * 1.25);
                            else if (ev.key === '-' || ev.key === '_') lbSetZoom(lbZoom / 1.25);
                            else if (ev.key === '0' || ev.key === '1') { lbResetPan(); lbSetZoom(1); }
                        });
                        lb.addEventListener('wheel', function(ev) {
                            if (ev.ctrlKey || ev.metaKey) { ev.preventDefault(); lbSetZoom(lbZoom * (ev.deltaY < 0 ? 1.1 : 0.9)); }
                        }, { passive: false });
                        // Drag-to-pan: mousedown anywhere on the content (or
                        // empty stage). Disable smooth-transition while dragging.
                        lbContent.addEventListener('mousedown', function(ev) {
                            if (ev.target.closest('.lb-bar')) return;
                            lbDragging = true;
                            lbDragStartX = ev.clientX; lbDragStartY = ev.clientY;
                            lbDragInitX = lbPanX; lbDragInitY = lbPanY;
                            lbContent.style.transition = 'none';
                            lbContent.style.cursor = 'grabbing';
                            ev.preventDefault();
                        });
                        document.addEventListener('mousemove', function(ev) {
                            if (!lbDragging) return;
                            lbPanX = lbDragInitX + (ev.clientX - lbDragStartX);
                            lbPanY = lbDragInitY + (ev.clientY - lbDragStartY);
                            lbApplyTransform();
                        });
                        document.addEventListener('mouseup', function() {
                            if (!lbDragging) return;
                            lbDragging = false;
                            if (lbContent) { lbContent.style.transition = ''; lbContent.style.cursor = ''; }
                        });
                    }
                    function lbOpen(el) {
                        lbEnsure();
                        lbContent.innerHTML = '';
                        var clone = null;
                        if (el.classList && el.classList.contains('mermaid')) {
                            var inner = el.querySelector('svg');
                            if (inner) el = inner;
                        }
                        if (el.tagName && el.tagName.toUpperCase() === 'CANVAS') {
                            try {
                                var img = document.createElement('img');
                                img.src = el.toDataURL('image/png');
                                img.style.width = el.width + 'px';
                                img.style.height = el.height + 'px';
                                clone = img;
                            } catch (_) { clone = el.cloneNode(true); }
                        } else if (el.tagName && el.tagName.toLowerCase() === 'svg') {
                            try {
                                var serializer = new XMLSerializer();
                                var svgStr = serializer.serializeToString(el);
                                var box = el.viewBox && el.viewBox.baseVal;
                                var w = (box && box.width) ? box.width : (el.getBoundingClientRect().width || 800);
                                var h = (box && box.height) ? box.height : (el.getBoundingClientRect().height || 600);
                                var holder = document.createElement('div');
                                holder.style.cssText = 'width:' + (w * 2) + 'px; height:' + (h * 2) + 'px;';
                                holder.innerHTML = svgStr;
                                var ns = holder.querySelector('svg');
                                if (ns) { ns.setAttribute('width', '100%'); ns.setAttribute('height', '100%'); ns.style.maxWidth = 'none'; ns.style.maxHeight = 'none'; }
                                clone = holder;
                            } catch (_) { clone = el.cloneNode(true); }
                        } else {
                            clone = el.cloneNode(true);
                        }
                        if (!clone) clone = el.cloneNode(true);
                        lbContent.appendChild(clone);
                        lbSetZoom(1);
                        lb.classList.add('on');
                    }
                    document.addEventListener('click', function(ev) {
                        var t = ev.target;
                        if (!t || typeof t.closest !== 'function') return;
                        var pick = t.closest('.mermaid, .section-body canvas, .section-body img');
                        if (!pick) return;
                        if (t.closest('.dd-btn, .iframe-footer, .lb-bar, #lb')) return;
                        ev.preventDefault(); ev.stopPropagation();
                        try { lbOpen(pick); } catch (e) { postParent('insightDebug', { where: 'lb-open', msg: String(e).substr(0, 200) }); }
                    }, false);
                } catch (e) { /* lightbox not critical */ }

                // Selection-driven custom deep-dive. Highlight any text in
                // the page → popup appears next to selection → click =
                // sends the selected text as a custom deep-dive topic
                // (same path as the footer 🤿 Explore input).
                try {
                    var selPopup = document.createElement('div');
                    selPopup.id = 'sel-popup';
                    selPopup.innerHTML = '<span>🤿</span><span>Deep dive on this</span>';
                    document.body.appendChild(selPopup);
                    var selText = '';
                    function hideSelPopup() { selPopup.classList.remove('on'); selText = ''; }
                    document.addEventListener('mouseup', function(ev) {
                        if (ev.target && ev.target.id === 'sel-popup') return;
                        if (ev.target && ev.target.closest && ev.target.closest('#sel-popup')) return;
                        // Defer one tick so getSelection reflects the final state.
                        setTimeout(function() {
                            var sel = window.getSelection();
                            var raw = sel ? String(sel.toString() || '').trim() : '';
                            // Skip very short / oversized selections.
                            if (raw.length < 3 || raw.length > 600) { hideSelPopup(); return; }
                            // Position popup just above the selection rect.
                            try {
                                var range = sel.getRangeAt(0);
                                var rect = range.getBoundingClientRect();
                                if (!rect || (rect.width === 0 && rect.height === 0)) { hideSelPopup(); return; }
                                var top = (rect.top + window.scrollY) - 36;
                                var left = (rect.left + window.scrollX) + Math.min(rect.width, 200) - 60;
                                if (top < 8) top = (rect.bottom + window.scrollY) + 8;
                                if (left < 8) left = 8;
                                selPopup.style.top = top + 'px';
                                selPopup.style.left = left + 'px';
                                selText = raw;
                                selPopup.classList.add('on');
                            } catch (e) { hideSelPopup(); }
                        }, 0);
                    });
                    selPopup.addEventListener('click', function(ev) {
                        ev.stopPropagation();
                        if (!selText) return;
                        postParent('insightRequestCustomDeepDive', { topic: selText });
                        hideSelPopup();
                        try { window.getSelection().removeAllRanges(); } catch (_) {}
                    });
                    document.addEventListener('mousedown', function(ev) {
                        if (ev.target && ev.target.closest && ev.target.closest('#sel-popup')) return;
                        hideSelPopup();
                    });
                } catch (e) { /* selection popup not critical */ }

                postParent('insightDebug', { where: 'iife', msg: 'IIFE-END about to signal ready, readyState=' + document.readyState });
                // Signal readiness once DOM is parsed.
                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', function() { postParent('insightIframeReady', {}); });
                } else {
                    postParent('insightIframeReady', {});
                }
            })();
            `;

            // Inline CSS — skeleton-loader pulse, section + button styling.
            const inlineCSS = `
            html, body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; background: #fff; color: #1e1e1e; }
            body { padding: 16px 24px; padding-top: 0; }
            .insight-progress-banner {
                position: sticky;
                top: 0;
                left: 0;
                right: 0;
                z-index: 100;
                margin: 0 -24px 16px;
                background: linear-gradient(90deg, rgba(74,158,255,0.18), rgba(74,158,255,0.06));
                border-bottom: 1px solid rgba(74,158,255,0.35);
                padding: 14px 18px;
                display: flex;
                align-items: center;
                gap: 12px;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
                font-size: 14px;
                color: #2563eb;
                transition: opacity 0.6s ease-out;
            }
            .insight-progress-icon {
                font-size: 18px;
                display: inline-block;
                animation: insight-spin 1.5s linear infinite;
                transform-origin: 50% 50%;
            }
            .insight-progress-text { flex: 1; }
            @keyframes insight-spin {
                from { transform: rotate(0deg); }
                to { transform: rotate(360deg); }
            }
            .insight-progress-banner.insight-progress-done {
                opacity: 0;
                pointer-events: none;
            }
            .insight-progress-banner.insight-progress-done .insight-progress-icon {
                animation: none;
            }
            .insight-doc-title { font-size: 20px; font-weight: 700; margin: 16px 0 16px; }
            section { margin-bottom: 28px; padding-bottom: 20px; border-bottom: 1px solid #e0e0e0; }
            section:last-of-type { border-bottom: none; }
            .section-title { font-size: 16px; font-weight: 600; margin: 0 0 8px; color: #2a2a2a; }
            .section-body { font-size: 14px; line-height: 1.6; }
            .section-body img { max-width: 100%; height: auto; }
            /* Hero: compact. */
            section[data-section-type="hero"] { margin-bottom: 18px; padding-bottom: 14px; }
            section[data-section-type="hero"] .section-title { display: none; }
            section[data-section-type="hero"] .section-body h1 { font-size: 22px; line-height: 1.2; margin: 0 0 6px; color: #1e1e1e; font-weight: 700; }
            section[data-section-type="hero"] .section-body h1 + p { font-size: 14px; line-height: 1.5; margin: 0 0 4px; color: #4a4a4a; }
            section[data-section-type="hero"] .section-body p { margin: 4px 0; }
            section[data-section-type="hero"] .section-body { font-size: 13px; }
            /* Mermaid: cap diagram height; the lightbox shows it full-size. */
            .mermaid { max-height: 520px; overflow: hidden; cursor: zoom-in; }
            .mermaid svg { max-width: 100%; height: auto; max-height: 520px; display: block; margin: 0 auto; }
            /* Chart: cap height + overflow hidden. */
            section[data-section-type="chartJsChart"] .section-body {
                position: relative; height: 360px; max-height: 50vh; overflow: hidden; cursor: zoom-in;
            }
            section[data-section-type="chartJsChart"] canvas {
                max-height: 360px !important; max-width: 100% !important; display: block;
            }
            /* Tables: zebra rows + hover. */
            .section-body table { width: 100%; border-collapse: collapse; margin: 6px 0 12px; font-size: 13px; }
            .section-body th, .section-body td { padding: 6px 10px; border: 1px solid #e0e0e0; text-align: left; vertical-align: top; }
            .section-body th { background: #f5f7fb; font-weight: 600; color: #1e1e1e; }
            .section-body tbody tr:nth-child(odd) td { background: #fafafa; }
            .section-body tbody tr:hover td { background: #f0f4ff; }
            /* Cards grid + Callouts + Timeline. */
            .cards-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; }
            .cards-grid .card { background: #f8f9fb; border: 1px solid #e0e0e0; border-radius: 6px; padding: 10px 12px; }
            .cards-grid .card h3 { margin: 0 0 6px; font-size: 13px; font-weight: 600; }
            .cards-grid .card p { margin: 4px 0; font-size: 12px; line-height: 1.45; }
            .callout { padding: 10px 14px; border-left: 4px solid #6b7280; background: #f5f7fb; margin: 8px 0; border-radius: 4px; }
            .callout.callout-info { border-color: #3b82f6; background: #eff6ff; }
            .callout.callout-warn { border-color: #f59e0b; background: #fffbeb; }
            .callout.callout-danger { border-color: #ef4444; background: #fef2f2; }
            .callout.callout-tip { border-color: #10b981; background: #ecfdf5; }
            .timeline { list-style: none; padding: 0; margin: 8px 0; border-left: 2px solid #d4d4d4; }
            .timeline li { position: relative; padding: 4px 0 8px 16px; }
            .timeline li::before { content: ''; position: absolute; left: -6px; top: 8px; width: 10px; height: 10px; background: #569cd6; border-radius: 50%; }
            .timeline time { display: inline-block; font-weight: 600; color: #1e1e1e; margin-right: 6px; }
            /* Lightbox modal for click-to-zoom on diagrams/charts/images. */
            #lb {
                position: fixed; inset: 0; z-index: 10000;
                background: rgba(0,0,0,0.88);
                display: none; align-items: center; justify-content: center;
                padding: 32px; box-sizing: border-box;
            }
            #lb.on { display: flex; }
            #lb .lb-stage { position: relative; width: 100%; height: 100%; overflow: auto; display: flex; align-items: center; justify-content: center; }
            #lb .lb-content { transform-origin: center center; transition: transform 0.18s ease; background: #fff; padding: 16px; border-radius: 6px; cursor: grab; user-select: none; }
            #lb .lb-content svg, #lb .lb-content img, #lb .lb-content canvas { display: block; max-width: none; max-height: none; }
            #lb .lb-bar { position: absolute; top: 16px; right: 16px; display: flex; gap: 6px; background: #fff; padding: 6px 10px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.3); }
            #lb .lb-bar button { background: #f4f4f4; color: #1e1e1e; border: 1px solid #d0d0d0; border-radius: 4px; padding: 6px 12px; font-size: 14px; cursor: pointer; font-family: inherit; min-width: 36px; }
            #lb .lb-bar button:hover { background: #2563eb; color: #fff; border-color: #2563eb; }
            #lb .lb-bar .lb-pct { display: inline-flex; align-items: center; padding: 0 6px; font-size: 13px; color: #666; min-width: 50px; justify-content: center; }
            /* Selection popup — appears on text selection inside the iframe.
               Click → custom deep-dive on the selected text. */
            #sel-popup {
                position: absolute; z-index: 9999;
                display: none;
                background: #1e1e1e; color: #fff;
                border-radius: 6px; padding: 6px 10px;
                box-shadow: 0 4px 12px rgba(0,0,0,0.3);
                font-size: 12px; cursor: pointer;
                user-select: none; white-space: nowrap;
            }
            #sel-popup.on { display: inline-flex; align-items: center; gap: 6px; }
            #sel-popup:hover { background: #2563eb; }
            .skeleton-loader {
                height: 12px; margin: 6px 0; border-radius: 4px;
                background: linear-gradient(90deg, #e8e8e8 25%, #f4f4f4 50%, #e8e8e8 75%);
                background-size: 200% 100%;
                animation: skeleton-pulse 1.4s ease-in-out infinite;
            }
            .skeleton-loader-short { width: 60%; }
            @keyframes skeleton-pulse {
                0% { background-position: 200% 0; }
                100% { background-position: -200% 0; }
            }
            .dd-buttons { margin-top: 10px; display: flex; flex-wrap: wrap; gap: 6px; }
            .dd-btn {
                background: #f4f4f4; color: #1e1e1e; border: 1px solid #d0d0d0; border-radius: 4px;
                padding: 4px 10px; font-size: 12px; cursor: pointer; font-family: inherit;
            }
            .dd-btn:hover { background: #e8e8e8; border-color: #909090; }
            .iframe-footer {
                position: sticky; bottom: 0; left: 0; right: 0;
                background: #fafafa; border-top: 1px solid #e0e0e0;
                padding: 8px 0; margin-top: 24px; display: flex; gap: 8px;
            }
            .iframe-footer .spacer { flex: 1; }
            .iframe-footer input#iframe-input-topic {
                flex: 2; min-width: 220px; max-width: 520px;
                padding: 6px 10px; font-size: 12px; font-family: inherit;
                border: 1px solid #d0d0d0; border-radius: 4px; background: #fff; color: #1e1e1e;
            }
            .iframe-footer input#iframe-input-topic:focus { outline: none; border-color: #2563eb; }
            .iframe-footer select#iframe-explore-depth { padding: 5px 6px; font-size: 11px; border: 1px solid #d0d0d0; border-radius: 4px; background: #fff; color: #1e1e1e; cursor: pointer; }
            .iframe-footer button {
                background: #f4f4f4; color: #1e1e1e; border: 1px solid #d0d0d0; border-radius: 4px;
                padding: 5px 12px; font-size: 11px; cursor: pointer; font-family: inherit;
            }
            .iframe-footer button:hover { background: #2563eb; color: #fff; border-color: #2563eb; }
            pre { background: #f6f8fa; padding: 10px; border-radius: 4px; overflow-x: auto; font-size: 12px; }
            code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
            `;

            // Compose final document. Note: title/sectionsHTML already escaped.
            return '<!DOCTYPE html><html><head>' +
                '<meta http-equiv="Content-Security-Policy" content="' + escapeForHTMLAttribute(csp) + '">' +
                '<meta charset="UTF-8">' +
                '<title>' + title + '</title>' +
                '<style>' + inlineCSS + '</style>' +
                katexStyleBlock +
                libScripts +
                '</head><body>' +
                '<div id="insight-progress-banner" class="insight-progress-banner">' +
                    '<div class="insight-progress-icon">⚙</div>' +
                    '<div class="insight-progress-text">Initializing…</div>' +
                '</div>' +
                '<h1 class="insight-doc-title">' + title + '</h1>' +
                sectionsHTML +
                '<div class="iframe-footer">' +
                '<button id="iframe-btn-up" title="Up to parent">↑ Up</button>' +
                '<select id="iframe-lang" title="Language for generated insight content (auto = match source files)"><option value="auto" selected>lang: auto</option><option value="en">English</option><option value="ru">Русский</option><option value="es">Español</option><option value="fr">Français</option><option value="de">Deutsch</option><option value="zh">中文</option><option value="ja">日本語</option></select>' +
                '<select id="iframe-explore-depth" title="Recursion depth for Explore-all"><option value="1" selected>depth 1</option><option value="2">depth 2</option><option value="3">depth 3</option></select>' +
                '<button id="iframe-btn-explore-all" title="Generate deep-dive pages for EVERY 🤿 topic on this page. Depth>1 means recursively expand each child\'s topics too — cost grows fast.">🤿×N Explore all</button>' +
                '<input id="iframe-input-topic" placeholder="Custom deep-dive topic (e.g. \'Compare auth approaches across the project\')…" />' +
                '<button id="iframe-btn-custom-dd" title="Generate a deep-dive page on this custom topic using all source files">🤿 Explore</button>' +
                '<div class="spacer"></div>' +
                '<button id="iframe-btn-save" title="Export the whole insight tree as a self-contained ZIP website">📦 Export ZIP</button>' +
                '</div>' +
                '<script>' + iframeScript + '</script>' +
                '</body></html>';
        }

        // ---------------------------------------------------------------------------
        // Mode entry/exit. v2 keeps state.mode === 'insight' semantics. Mermaid
        // theme is no longer initialized in main frame — Mermaid lives inside
        // iframe and re-inits on each srcdoc reload.
        // ---------------------------------------------------------------------------
