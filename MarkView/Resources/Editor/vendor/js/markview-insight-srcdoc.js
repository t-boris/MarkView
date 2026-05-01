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
            const csp = "default-src 'none'; script-src 'unsafe-inline' blob:; style-src 'unsafe-inline'; connect-src 'none'; img-src data: blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'";
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
            const libOrder = ['prism', 'mermaid', 'chart', 'katex', 'katex-auto'];
            let libScripts = '';
            for (const libName of libOrder) {
                const url = libBlobURLs.get(libName);
                if (!url) continue;
                libScripts += '<script src="' + escapeForHTMLAttribute(url) + '"></script>\n';
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
                                mermaid.initialize({ startOnLoad: false, securityLevel: 'strict' });
                                mermaid.run({ nodes: sec.querySelectorAll('.mermaid'), suppressErrors: true });
                            } catch (e) { /* per-block recover handled by mermaid */ }
                        } else if (type === 'chartJsChart' && typeof Chart !== 'undefined') {
                            var canvases = sec.querySelectorAll('canvas[data-chart-config]');
                            for (var j = 0; j < canvases.length; j++) {
                                try {
                                    var cfg = JSON.parse(canvases[j].getAttribute('data-chart-config') || '{}');
                                    new Chart(canvases[j], cfg);
                                } catch (e) { /* skip invalid chart */ }
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
                    }
                }, false);

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
                '<div class="spacer"></div>' +
                '<button id="iframe-btn-save" title="Save current node as Markdown">💾 Save as .md</button>' +
                '</div>' +
                '<script>' + iframeScript + '</script>' +
                '</body></html>';
        }

        // ---------------------------------------------------------------------------
        // Mode entry/exit. v2 keeps state.mode === 'insight' semantics. Mermaid
        // theme is no longer initialized in main frame — Mermaid lives inside
        // iframe and re-inits on each srcdoc reload.
        // ---------------------------------------------------------------------------
