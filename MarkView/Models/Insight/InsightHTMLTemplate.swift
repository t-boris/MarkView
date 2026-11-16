import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The HTML page of one Insight node: the single deterministic template behind both the cached page
/// (`InsightSession.writeFinalHTMLToCache`) and the ZIP export (`InsightCoordinator.exportInsightArchive`).
/// Pure: no state, no clock, no random ids, so equal input gives byte-identical output.
enum InsightHTMLTemplate {
    /// Lib reference mode for the rebuilt HTML.
    /// - `runtimeBlobs(libBlobURLs:)` — passes blob: URLs from parent (T7's lazy materialisation).
    /// - `exportRelative` — references `../_assets/<lib>` for ZIP export portability (T8).
    /// Currently `writeFinalHTMLToCache` always uses `exportRelative` because cache also
    /// serves as the ZIP-export source (Decision 4: `_assets/` lives inside session dir).
    enum LibRefMode {
        case runtimeBlobs(libBlobURLs: [String: String])
        case exportRelative
    }

    /// Deterministic HTML composition. Reproducible: identical (skeleton, sectionStates,
    /// breadcrumbs) input → byte-identical output. NO Date interpolation, NO new UUIDs —
    /// only known-good fields from the in-memory tree.
    ///
    /// `cache` is optional and only consulted in `.exportRelative` mode to resolve
    /// vendored lib filenames dynamically from `_assets/` (Wave 6 audit T9 #1 fix).
    /// In `.runtimeBlobs(...)` mode the caller supplies the blob URLs directly so no
    /// disk lookup is required.
    static func html(
        skeleton: InsightSkeleton,
        sectionStates: [String: SectionState],
        breadcrumbs: [(nodeId: String, title: String)],
        libRefMode: LibRefMode,
        cache: InsightCache? = nil
    ) -> String {
        let escapedTitle = escape(skeleton.title)

        // Breadcrumb chrome (parent frame — uses textContent in JS, but we still escape
        // because the static HTML is rendered as HTML at file-open / ZIP-export time).
        var breadcrumbHTML = ""
        for (idx, crumb) in breadcrumbs.enumerated() {
            let label = escape(crumb.title)
            let isLast = (idx == breadcrumbs.count - 1)
            if isLast {
                breadcrumbHTML += "<span class=\"crumb crumb-active\">\(label)</span>"
            } else {
                let nodeIdAttr = escape(crumb.nodeId)
                breadcrumbHTML += "<a class=\"crumb\" href=\"#\(nodeIdAttr)\">\(label)</a>"
                breadcrumbHTML += "<span class=\"crumb-sep\"> / </span>"
            }
        }

        // Per-section HTML — buffer interpolated VERBATIM (already inside iframe trust
        // boundary). Section title + id + scopeHint paths displayed are escaped.
        var sectionsHTML = ""
        for section in skeleton.sections {
            let buffer = sectionStates[section.id]?.buffer ?? ""
            let sectionId = escape(section.id)
            let title = section.title.map { "<h2>\(escape($0))</h2>" } ?? ""

            // Inline 🤿 deep-dive controls. Each control posts `insightDeepDiveClicked`
            // with sectionId+topicIndex via the iframe → parent → bridge chain (T7).
            var topicsHTML = ""
            if let topics = section.deepDiveTopics, !topics.isEmpty {
                topicsHTML += "<div class=\"deep-dives\">"
                for (idx, topic) in topics.enumerated() {
                    let label = escape(topic.label)
                    let hint = escape(topic.hint)
                    topicsHTML += """
                    <button class="deep-dive" data-section-id="\(sectionId)" data-topic-index="\(idx)" title="\(hint)">🤿 \(label)</button>
                    """
                }
                topicsHTML += "</div>"
            }

            sectionsHTML += """
            <section class="insight-section" data-section-id="\(sectionId)" data-section-type="\(section.type.rawValue)">
              \(title)
              <div class="section-body">\(buffer)</div>
              \(topicsHTML)
            </section>
            """
        }

        // Lib references (Decision 5).
        var libRefs = ""
        switch libRefMode {
        case .runtimeBlobs(let blobs):
            // Each lib blob: <script src="blob:...">. Iframe sandbox null-origin can load these.
            for (name, blobURL) in blobs.sorted(by: { $0.key < $1.key }) {
                let safe = escape(blobURL)
                if name.hasSuffix(".css") {
                    libRefs += "<link rel=\"stylesheet\" href=\"\(safe)\">\n"
                } else {
                    libRefs += "<script src=\"\(safe)\"></script>\n"
                }
            }
        case .exportRelative:
            // Export-friendly relative refs to `_assets/`. Filenames are resolved
            // dynamically from the cache's `_assets/` directory so version bumps in
            // `Resources/Editor/vendor/` (e.g. `chart-4.4.9.min.js` →
            // `chart-5.x.min.js`) do not desync with a hard-coded list (Wave 6
            // audit T9 #1 fix). Each entry is a (prefix, extension) pair; the
            // shortest-name match wins for determinism. Output order is sorted by
            // resolved filename so the byte-for-byte reproducibility contract holds.
            let prefixes: [(prefix: String, ext: String)] = [
                ("prism", "css"),
                ("prism", "js"),
                ("mermaid", "js"),
                ("chart", "js"),
                ("katex", "css"),
                ("katex", "js"),
                ("auto-render", "js"),
                ("markdown-it", "js")
            ]
            var resolved: [(filename: String, kind: String)] = []
            for entry in prefixes {
                if let url = cache?.vendoredLibURL(matching: entry.prefix, extension: entry.ext) {
                    resolved.append((filename: url.lastPathComponent, kind: entry.ext))
                }
            }
            for entry in resolved.sorted(by: { $0.filename < $1.filename }) {
                if entry.kind == "css" {
                    libRefs += "<link rel=\"stylesheet\" href=\"../_assets/\(entry.filename)\">\n"
                } else {
                    libRefs += "<script src=\"../_assets/\(entry.filename)\"></script>\n"
                }
            }
        }

        // CSP for the cached HTML (Wave 6 audit T9 #3 fix). Aligned with the iframe
        // srcdoc CSP (Decision 10 §3 / index.html:2827) but adapted for the cached /
        // exported context: scripts and styles load from `'self'` (the cache root or
        // the unzipped export) instead of `blob:`. Webfonts and images come from
        // `'self'` + `data:` only — no wildcard CDNs. Matches the iframe's
        // defense-in-depth posture (`default-src 'none'`, `connect-src 'none'`,
        // `object-src 'none'`, `base-uri 'none'`, `frame-ancestors 'none'`).
        let csp = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"

        // Mirror the iframe srcdoc's section/hero/table/callout/timeline/
        // cards-grid/mermaid/chart styling so the exported standalone site
        // looks the same as the in-app view. Plus minimal mermaid/chart
        // bootstrap scripts (libs are loaded via libRefs above).
        let inlineCSS = """
        html, body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; background: #fff; color: #1e1e1e; }
        body { padding: 16px 24px; }
        header.insight-breadcrumbs { padding: 8px 0 12px; border-bottom: 1px solid #e0e0e0; margin-bottom: 16px; font-size: 13px; }
        .crumb { color: #2563eb; text-decoration: none; padding: 2px 6px; border-radius: 3px; }
        .crumb:hover { background: #f0f4ff; }
        .crumb-active { color: #1e1e1e; font-weight: 600; }
        .crumb-sep { color: #999; padding: 0 2px; }
        section.insight-section { margin-bottom: 28px; padding-bottom: 20px; border-bottom: 1px solid #e0e0e0; }
        section.insight-section:last-of-type { border-bottom: none; }
        section.insight-section h2 { font-size: 16px; font-weight: 600; margin: 0 0 8px; color: #2a2a2a; }
        .section-body { font-size: 14px; line-height: 1.6; }
        .section-body img { max-width: 100%; height: auto; }
        section[data-section-type="hero"] h2 { display: none; }
        section[data-section-type="hero"] .section-body h1 { font-size: 22px; line-height: 1.2; margin: 0 0 6px; color: #1e1e1e; font-weight: 700; }
        section[data-section-type="hero"] .section-body h1 + p { font-size: 14px; line-height: 1.5; margin: 0 0 4px; color: #4a4a4a; }
        section[data-section-type="hero"] .section-body p { margin: 4px 0; }
        section[data-section-type="hero"] .section-body { font-size: 13px; }
        .mermaid { max-height: 520px; overflow: hidden; cursor: zoom-in; }
        .mermaid svg { max-width: 100%; height: auto; max-height: 520px; display: block; margin: 0 auto; }
        section[data-section-type="chartJsChart"] .section-body { position: relative; height: 360px; max-height: 50vh; overflow: hidden; }
        section[data-section-type="chartJsChart"] canvas { max-height: 360px !important; max-width: 100% !important; display: block; }
        .section-body table { width: 100%; border-collapse: collapse; margin: 6px 0 12px; font-size: 13px; }
        .section-body th, .section-body td { padding: 6px 10px; border: 1px solid #e0e0e0; text-align: left; vertical-align: top; }
        .section-body th { background: #f5f7fb; font-weight: 600; color: #1e1e1e; }
        .section-body tbody tr:nth-child(odd) td { background: #fafafa; }
        .cards-grid { display: grid !important; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; align-items: stretch; }
        .cards-grid .card, .cards-grid > article { background: #f8f9fb; border: 1px solid #e0e0e0; border-radius: 6px; padding: 12px 14px; min-width: 0; display: flex; flex-direction: column; }
        .cards-grid .card h3, .cards-grid > article h3 { margin: 0 0 6px; font-size: 13px; font-weight: 600; color: #1e1e1e; }
        .cards-grid .card p, .cards-grid > article p { margin: 4px 0; font-size: 12px; line-height: 1.45; }
        .cards-grid .card .meta, .cards-grid > article .meta { font-size: 11px; color: #6b7280; }
        .callout { padding: 10px 14px; border-left: 4px solid #6b7280; background: #f5f7fb; margin: 8px 0; border-radius: 4px; }
        .callout.callout-info { border-color: #3b82f6; background: #eff6ff; }
        .callout.callout-warn { border-color: #f59e0b; background: #fffbeb; }
        .callout.callout-danger { border-color: #ef4444; background: #fef2f2; }
        .callout.callout-tip { border-color: #10b981; background: #ecfdf5; }
        .timeline { list-style: none; padding: 0; margin: 8px 0; border-left: 2px solid #d4d4d4; }
        .timeline li { position: relative; padding: 4px 0 8px 16px; }
        .timeline li::before { content: ''; position: absolute; left: -6px; top: 8px; width: 10px; height: 10px; background: #569cd6; border-radius: 50%; }
        .timeline time { display: inline-block; font-weight: 600; color: #1e1e1e; margin-right: 6px; }
        .deep-dives { margin-top: 10px; display: flex; flex-wrap: wrap; gap: 6px; }
        .deep-dive { background: #f4f4f4; color: #1e1e1e; border: 1px solid #d0d0d0; border-radius: 4px; padding: 4px 10px; font-size: 12px; cursor: pointer; font-family: inherit; text-decoration: none; }
        .deep-dive:hover { background: #e8e8e8; border-color: #909090; }
        pre { background: #f6f8fa; padding: 10px; border-radius: 4px; overflow-x: auto; font-size: 12px; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        .inferred { color: #b45309; font-style: italic; border-bottom: 1px dashed #b45309; }
        .mermaid, .section-body canvas, .section-body img { cursor: zoom-in; }
        #lb { position: fixed; inset: 0; z-index: 10000; background: rgba(0,0,0,0.88); display: none; align-items: center; justify-content: center; padding: 32px; box-sizing: border-box; }
        #lb.on { display: flex; }
        #lb .lb-stage { position: relative; width: 100%; height: 100%; overflow: auto; display: flex; align-items: center; justify-content: center; }
        #lb .lb-content { transform-origin: center center; transition: transform 0.18s ease; background: #fff; padding: 16px; border-radius: 6px; cursor: grab; user-select: none; }
        #lb .lb-content svg, #lb .lb-content img, #lb .lb-content canvas { display: block; max-width: none; max-height: none; }
        #lb .lb-bar { position: absolute; top: 16px; right: 16px; display: flex; gap: 6px; background: #fff; padding: 6px 10px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.3); }
        #lb .lb-bar button { background: #f4f4f4; color: #1e1e1e; border: 1px solid #d0d0d0; border-radius: 4px; padding: 6px 12px; font-size: 14px; cursor: pointer; font-family: inherit; min-width: 36px; }
        #lb .lb-bar button:hover { background: #2563eb; color: #fff; border-color: #2563eb; }
        #lb .lb-bar .lb-pct { display: inline-flex; align-items: center; padding: 0 6px; font-size: 13px; color: #666; min-width: 50px; justify-content: center; }
        /* The exported site follows the system theme. */
        @media (prefers-color-scheme: dark) {
        html, body { background: #1e1e1e; color: #d4d4d4; }
        h1, h2, h3, h4, th, .crumb-active, .timeline time, section.insight-section h2,
        section[data-section-type="hero"] .section-body h1, .cards-grid .card h3, .cards-grid > article h3 { color: #d4d4d4; }
        section[data-section-type="hero"] .section-body h1 + p { color: #a0a0a0; }
        a, .crumb { color: #4a9eff; }
        .crumb:hover { background: #2d2d30; }
        .crumb-sep { color: #808080; }
        header.insight-breadcrumbs, section.insight-section { border-color: #3c3c3c; }
        .section-body th, .section-body td { border-color: #3c3c3c; }
        .section-body th { background: #2d2d30; }
        .section-body tbody tr:nth-child(odd) td { background: #232323; }
        .cards-grid .card, .cards-grid > article { background: #252526; border-color: #3c3c3c; }
        .cards-grid .card .meta, .cards-grid > article .meta { color: #9a9a9a; }
        .callout { background: #252526; border-left-color: #6b7280; }
        .callout.callout-info { background: #1b2838; }
        .callout.callout-warn { background: #2d2614; }
        .callout.callout-danger { background: #2e1a1a; }
        .callout.callout-tip { background: #16281f; }
        .timeline { border-left-color: #3c3c3c; }
        .deep-dive, .dd-btn, .iframe-footer button, #lb .lb-bar button { background: #2d2d30; color: #d4d4d4; border-color: #3c3c3c; }
        .deep-dive:hover, .dd-btn:hover { background: #3c3c3c; border-color: #5a5a5a; }
        .iframe-footer { background: #252526; border-top-color: #3c3c3c; }
        .iframe-footer input#iframe-input-topic, .iframe-footer select { background: #1e1e1e; color: #d4d4d4; border-color: #3c3c3c; }
        pre { background: #252526; color: #d4d4d4; }
        .inferred { color: #e2a93b; border-bottom-color: #e2a93b; }
        .skeleton-loader { background: linear-gradient(90deg, #2d2d30 25%, #3c3c3c 50%, #2d2d30 75%); background-size: 200% 100%; }
        #lb .lb-content, #lb .lb-bar { background: #252526; }
        #lb .lb-bar .lb-pct { color: #a0a0a0; }
        .insight-progress-banner { color: #4a9eff; }
        }
        """

        // Bootstrap script — initialises mermaid + chart, wires lightbox click-to-zoom.
        let bootstrap = """
        <script>
        (function() {
            try {
                if (typeof mermaid !== 'undefined') {
                    mermaid.initialize({ startOnLoad: false, securityLevel: 'loose', flowchart: { htmlLabels: true },
                                         theme: window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default' });
                    var mNodes = document.querySelectorAll('.mermaid, pre code.language-mermaid, pre.mermaid');
                    for (var i = 0; i < mNodes.length; i++) {
                        var n = mNodes[i];
                        if (n.tagName !== 'DIV') {
                            var pre = (n.tagName === 'CODE') ? n.parentElement : n;
                            if (!pre) continue;
                            var src = (n.textContent || '').trim().replace(/<br\\s*\\/>/gi, '<br>');
                            var d = document.createElement('div');
                            d.className = 'mermaid';
                            d.textContent = src;
                            pre.replaceWith(d);
                        }
                    }
                    try { mermaid.run({ nodes: document.querySelectorAll('.mermaid'), suppressErrors: true }); } catch (e) {}
                }
                if (typeof Chart !== 'undefined') {
                    var canvases = document.querySelectorAll('canvas[data-chart], canvas[data-chart-config]');
                    for (var j = 0; j < canvases.length; j++) {
                        var cv = canvases[j];
                        var s = cv.getAttribute('data-chart') || cv.getAttribute('data-chart-config') || '';
                        if (!s) continue;
                        var clean = s.replace(/"function"\\s*:\\s*"function[\\s\\S]*?"\\s*\\}/g, '"_stripped":true}');
                        try { var cfg = JSON.parse(clean); new Chart(cv, cfg); } catch (e) {}
                    }
                }
                // Lightbox.
                var lb = null, lbContent = null, lbZoom = 1, lbPanX = 0, lbPanY = 0;
                var dragging = false, dsx = 0, dsy = 0, dix = 0, diy = 0;
                function applyTransform() { if (lbContent) lbContent.style.transform = 'translate(' + lbPanX + 'px,' + lbPanY + 'px) scale(' + lbZoom + ')'; }
                function setZoom(z) { lbZoom = Math.max(0.25, Math.min(8, z)); applyTransform(); var p = lb && lb.querySelector('.lb-pct'); if (p) p.textContent = Math.round(lbZoom * 100) + '%'; }
                function close() { if (lb) lb.classList.remove('on'); if (lbContent) lbContent.innerHTML = ''; lbPanX = lbPanY = 0; lbZoom = 1; }
                function ensure() {
                    if (lb) return;
                    lb = document.createElement('div'); lb.id = 'lb';
                    lb.innerHTML = '<div class="lb-stage"><div class="lb-content"></div></div>' +
                        '<div class="lb-bar">' +
                        '<button class="lb-out">−</button><span class="lb-pct">100%</span>' +
                        '<button class="lb-in">+</button><button class="lb-reset">1:1</button>' +
                        '<button class="lb-close">✕</button></div>';
                    document.body.appendChild(lb);
                    lbContent = lb.querySelector('.lb-content');
                    lb.querySelector('.lb-in').onclick = function(e) { e.stopPropagation(); setZoom(lbZoom * 1.25); };
                    lb.querySelector('.lb-out').onclick = function(e) { e.stopPropagation(); setZoom(lbZoom / 1.25); };
                    lb.querySelector('.lb-reset').onclick = function(e) { e.stopPropagation(); lbPanX = lbPanY = 0; setZoom(1); };
                    lb.querySelector('.lb-close').onclick = function(e) { e.stopPropagation(); close(); };
                    lb.addEventListener('click', function(ev) { if (ev.target === lb || (ev.target.classList && ev.target.classList.contains('lb-stage'))) close(); });
                    document.addEventListener('keydown', function(ev) {
                        if (!lb.classList.contains('on')) return;
                        if (ev.key === 'Escape') close();
                        else if (ev.key === '+' || ev.key === '=') setZoom(lbZoom * 1.25);
                        else if (ev.key === '-' || ev.key === '_') setZoom(lbZoom / 1.25);
                        else if (ev.key === '0' || ev.key === '1') { lbPanX = lbPanY = 0; setZoom(1); }
                    });
                    lb.addEventListener('wheel', function(ev) {
                        if (ev.ctrlKey || ev.metaKey) { ev.preventDefault(); setZoom(lbZoom * (ev.deltaY < 0 ? 1.1 : 0.9)); }
                    }, { passive: false });
                    lbContent.addEventListener('mousedown', function(ev) {
                        if (ev.target.closest('.lb-bar')) return;
                        dragging = true; dsx = ev.clientX; dsy = ev.clientY; dix = lbPanX; diy = lbPanY;
                        lbContent.style.transition = 'none'; lbContent.style.cursor = 'grabbing';
                        ev.preventDefault();
                    });
                    document.addEventListener('mousemove', function(ev) {
                        if (!dragging) return;
                        lbPanX = dix + (ev.clientX - dsx); lbPanY = diy + (ev.clientY - dsy);
                        applyTransform();
                    });
                    document.addEventListener('mouseup', function() { if (!dragging) return; dragging = false; if (lbContent) { lbContent.style.transition = ''; lbContent.style.cursor = ''; } });
                }
                function open(el) {
                    ensure();
                    lbContent.innerHTML = '';
                    if (el.classList && el.classList.contains('mermaid')) { var inner = el.querySelector('svg'); if (inner) el = inner; }
                    var clone;
                    if (el.tagName && el.tagName.toUpperCase() === 'CANVAS') {
                        try { var img = document.createElement('img'); img.src = el.toDataURL('image/png'); img.style.width = el.width + 'px'; img.style.height = el.height + 'px'; clone = img; }
                        catch (_) { clone = el.cloneNode(true); }
                    } else if (el.tagName && el.tagName.toLowerCase() === 'svg') {
                        try {
                            var ser = new XMLSerializer();
                            var svgStr = ser.serializeToString(el);
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
                    } else { clone = el.cloneNode(true); }
                    lbContent.appendChild(clone);
                    lbPanX = lbPanY = 0; setZoom(1);
                    lb.classList.add('on');
                }
                document.addEventListener('click', function(ev) {
                    var t = ev.target;
                    if (!t || typeof t.closest !== 'function') return;
                    var pick = t.closest('.mermaid, .section-body canvas, .section-body img');
                    if (!pick) return;
                    if (t.closest('.deep-dive, .crumb, .lb-bar, #lb')) return;
                    ev.preventDefault(); ev.stopPropagation();
                    try { open(pick); } catch (_) {}
                }, false);
            } catch (e) {}
        })();
        </script>
        """

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <title>\(escapedTitle)</title>
        <style>\(inlineCSS)</style>
        \(libRefs)
        </head>
        <body>
        <header class="insight-chrome insight-breadcrumbs">\(breadcrumbHTML)</header>
        <main class="insight-content">
        \(sectionsHTML)
        </main>
        <footer class="insight-chrome insight-status"></footer>
        \(bootstrap)
        </body>
        </html>
        """
    }

    /// HTML-escape utility (Decision 10). Applied to ALL LLM-controlled strings BEFORE
    /// interpolation into the rebuilt HTML. The five canonical replacements + single-quote
    /// (covers attribute and text contexts).
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }
}
