(function () {
    'use strict';
    const thread = document.getElementById('thread');
    let dark = true, turns = [], live = null, pending = null;

    function post(message) {
        try { window.webkit.messageHandlers.discussion.postMessage(message); } catch (e) { console.log('[discussion]', e); }
    }
    const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    const VISUAL = ['mermaid', 'svg', 'chart', 'html'];

    // ---- SVG: parsed, stripped of anything active, serialized back ----
    function cleanSVG(source) {
        const doc = new DOMParser().parseFromString(source, 'image/svg+xml');
        const root = doc.documentElement;
        if (!root || root.nodeName.toLowerCase() !== 'svg' || doc.querySelector('parsererror')) return null;
        root.querySelectorAll('script, foreignObject, iframe, object, embed, audio, video, animate, set').forEach((n) => n.remove());
        const all = [root, ...root.querySelectorAll('*')];
        for (const node of all) {
            for (const attr of [...node.attributes]) {
                const name = attr.name.toLowerCase(), value = attr.value.trim().toLowerCase();
                const link = name === 'href' || name === 'xlink:href';
                if (name.startsWith('on') || (link && !value.startsWith('#')) || /url\(\s*['"]?(?!#)/.test(value) || value.startsWith('javascript:')) node.removeAttribute(attr.name);
            }
        }
        root.removeAttribute('width'); root.removeAttribute('height');
        if (!root.getAttribute('viewBox')) root.setAttribute('viewBox', '0 0 800 500');
        return new XMLSerializer().serializeToString(root);
    }

    // ---- Markdown ----
    const md = window.markdownit({ html: false, linkify: true, breaks: false });
    const defaultFence = md.renderer.rules.fence;
    md.renderer.rules.fence = function (tokens, idx, options, env, self) {
        const token = tokens[idx];
        const lang = (token.info || '').trim().split(/\s+/)[0].toLowerCase();
        const src = token.content;
        const tools = (label) => '<div class="tools">' + (label === 'Save PNG' ? '' : '<button data-expand>Expand</button> ') + '<button data-save>' + label + '</button></div>';
        if (lang === 'mermaid') return '<figure class="visual" data-kind="mermaid" data-src="' + encodeURIComponent(src) + '">' + tools('Save SVG') + '<div class="body"></div></figure>';
        if (lang === 'svg') {
            const svg = cleanSVG(src);
            return svg ? '<figure class="visual" data-kind="svg">' + tools('Save SVG') + svg + '</figure>'
                       : '<p class="drawing error">The drawing could not be read.</p>';
        }
        if (lang === 'chart') return '<figure class="visual" data-kind="chart" data-src="' + encodeURIComponent(src) + '">' + tools('Save PNG') + '<canvas></canvas></figure>';
        if (lang === 'html') {
            const page = '<!DOCTYPE html><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; img-src data:"><meta charset="utf-8"><style>body{font:14px/1.5 -apple-system,system-ui,sans-serif;margin:12px;color:#1f2328}</style>' + src;
            return '<figure class="visual" data-kind="html"><iframe sandbox="" srcdoc="' + esc(page) + '"></iframe></figure>';
        }
        return defaultFence(tokens, idx, options, env, self);
    };
    md.renderer.rules.link_open = function (tokens, idx, options, env, self) {
        tokens[idx].attrSet('target', '_blank');
        return self.renderToken(tokens, idx, options);
    };

    // The notes block at the end is for the app, not for the reader.
    function visibleText(text, streaming) {
        let out = text;
        const notes = out.indexOf('```discussion-notes');
        if (notes >= 0) out = out.slice(0, notes);
        let drawing = false;
        if (streaming) {
            const fences = [...out.matchAll(/^```/gm)];
            if (fences.length % 2 === 1) {
                const at = fences[fences.length - 1].index;
                const lang = (out.slice(at + 3).split('\n')[0] || '').trim().toLowerCase();
                if (VISUAL.includes(lang)) { out = out.slice(0, at); drawing = true; }
            }
        }
        return { text: out.trim(), drawing };
    }

    // ---- Hydration of diagrams and charts ----
    const mermaidCache = new Map();
    let counter = 0;
    function themeMermaid() { try { mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default' }); } catch (e) {} }
    function hydrate(root) {
        root.querySelectorAll('figure[data-kind="mermaid"]').forEach((fig) => {
            const src = decodeURIComponent(fig.dataset.src), body = fig.querySelector('.body');
            const key = (dark ? 'd:' : 'l:') + src;
            if (mermaidCache.has(key)) { body.innerHTML = mermaidCache.get(key); return; }
            body.innerHTML = '<span class="drawing">Drawing…</span>';
            mermaid.render('mmd' + (++counter), src).then((r) => { mermaidCache.set(key, r.svg); body.innerHTML = r.svg; })
                .catch(() => { body.innerHTML = '<pre><code>' + esc(src) + '</code></pre><p class="drawing error">This diagram could not be drawn; its source is shown.</p>'; });
        });
        root.querySelectorAll('figure[data-kind="chart"]').forEach((fig) => {
            try {
                const config = JSON.parse(decodeURIComponent(fig.dataset.src));
                config.options = Object.assign({ animation: false, responsive: true, maintainAspectRatio: true }, config.options || {});
                const palette = ['#569cd6', '#4ec9b0', '#ce9178', '#dcdcaa', '#c586c0', '#9cdcfe', '#d7ba7d', '#6a9955'];
                const pie = ['pie', 'doughnut', 'polarArea'].includes(config.type);
                ((config.data || {}).datasets || []).forEach((ds, i) => {
                    if (!ds.backgroundColor) ds.backgroundColor = pie ? palette : palette[i % palette.length];
                    if (!ds.borderColor && !pie && ['line', 'radar'].includes(config.type)) ds.borderColor = palette[i % palette.length];
                });
                Chart.defaults.color = dark ? '#d4d4d4' : '#1f2328';
                Chart.defaults.borderColor = dark ? '#3c3c3c' : '#d0d7de';
                new Chart(fig.querySelector('canvas'), config);
            } catch (e) {
                fig.innerHTML = '<p class="drawing error">This chart could not be drawn.</p>';
            }
        });
    }

    // ---- Full-window viewer of a drawing: wheel zooms, drag pans, Esc closes ----
    function openViewer(svg) {
        const box = svg.viewBox && svg.viewBox.baseVal;
        const w = (box && box.width) || svg.getBoundingClientRect().width || 800;
        const h = (box && box.height) || svg.getBoundingClientRect().height || 600;
        const copy = svg.cloneNode(true);
        copy.removeAttribute('style');
        copy.setAttribute('width', w); copy.setAttribute('height', h);
        copy.style.cssText = 'display:block;max-width:none;max-height:none;';
        const overlay = document.createElement('div');
        overlay.id = 'viewer';
        overlay.innerHTML = '<div class="vbar"><button data-v="in">+</button><button data-v="out">&minus;</button><button data-v="fit">Fit</button><button data-v="one">100%</button><button data-v="close">Close</button></div><div class="vstage"></div>';
        const stage = overlay.querySelector('.vstage');
        stage.appendChild(copy);
        document.body.appendChild(overlay);
        let k = 1, x = 0, y = 0;
        const apply = () => { copy.style.transform = 'translate(' + x + 'px,' + y + 'px) scale(' + k + ')'; };
        copy.style.transformOrigin = '0 0';
        const fit = () => {
            const r = stage.getBoundingClientRect();
            k = Math.min(r.width / w, r.height / h) * 0.96;
            x = (r.width - w * k) / 2; y = (r.height - h * k) / 2; apply();
        };
        const zoomAt = (factor, cx, cy) => {
            const nk = Math.min(Math.max(k * factor, 0.05), 20);
            x = cx - (cx - x) * (nk / k); y = cy - (cy - y) * (nk / k); k = nk; apply();
        };
        const center = () => { const r = stage.getBoundingClientRect(); return [r.width / 2, r.height / 2]; };
        const close = () => { overlay.remove(); document.removeEventListener('keydown', onKey, true); };
        const onKey = (e) => { if (e.key === 'Escape') { e.preventDefault(); close(); } };
        document.addEventListener('keydown', onKey, true);
        stage.addEventListener('wheel', (e) => {
            e.preventDefault();
            const r = stage.getBoundingClientRect();
            zoomAt(Math.exp(-e.deltaY * 0.0025), e.clientX - r.left, e.clientY - r.top);
        }, { passive: false });
        let drag = null;
        stage.addEventListener('mousedown', (e) => { drag = { x: e.clientX - x, y: e.clientY - y }; stage.classList.add('grab'); });
        window.addEventListener('mousemove', (e) => { if (drag) { x = e.clientX - drag.x; y = e.clientY - drag.y; apply(); } });
        window.addEventListener('mouseup', () => { drag = null; stage.classList.remove('grab'); });
        stage.addEventListener('dblclick', fit);
        overlay.querySelector('.vbar').addEventListener('click', (e) => {
            const a = e.target.dataset && e.target.dataset.v;
            if (a === 'close') close();
            else if (a === 'fit') fit();
            else if (a === 'one') { const c = center(); zoomAt(1 / k, c[0], c[1]); }
            else if (a === 'in') { const c = center(); zoomAt(1.4, c[0], c[1]); }
            else if (a === 'out') { const c = center(); zoomAt(1 / 1.4, c[0], c[1]); }
        });
        fit();
    }

    thread.addEventListener('dblclick', (event) => {
        const fig = event.target.closest('figure.visual');
        const svg = fig && fig.querySelector('svg');
        if (svg) openViewer(svg);
    });

    thread.addEventListener('click', (event) => {
        const copy = event.target.closest('[data-copy]');
        if (copy) {
            const source = copy.dataset.copy === 'live' ? live && live.text : turns[Number(copy.dataset.copy)]?.answer;
            const text = visibleText(source || '', copy.dataset.copy === 'live').text;
            if (text) {
                post({ type: 'copy', text });
                copy.textContent = 'Copied';
                setTimeout(() => { copy.textContent = 'Copy Markdown'; }, 1500);
            }
            return;
        }
        const expand = event.target.closest('[data-expand]');
        if (expand) {
            const svg = expand.closest('figure').querySelector('svg');
            if (svg) openViewer(svg);
            return;
        }
        const button = event.target.closest('[data-save]');
        if (!button) return;
        const fig = button.closest('figure');
        const kind = fig.dataset.kind;
        if (kind === 'chart') {
            post({ type: 'save', name: 'chart.png', base64: true, data: fig.querySelector('canvas').toDataURL('image/png').split(',')[1] });
        } else {
            const svg = fig.querySelector('svg');
            if (svg) post({ type: 'save', name: (kind === 'mermaid' ? 'diagram' : 'figure') + '.svg', base64: false, data: new XMLSerializer().serializeToString(svg) });
        }
    });

    // ---- Rendering of the thread ----
    function nearBottom() { return window.innerHeight + window.scrollY >= document.body.scrollHeight - 120; }

    function render() {
        const stick = nearBottom();
        let html = '';
        if (!turns.length && !live) html = '<div id="empty">Ask a question about the project. The answer comes in the form that fits it: text, a table, a diagram.</div>';
        for (const [index, turn] of turns.entries()) {
            html += '<div class="turn"><div class="who">You</div><div class="q">' + esc(turn.question) + '</div><div class="answer-header"><div class="who">Assistant</div><button data-copy="' + index + '">Copy Markdown</button></div><div class="a">' + md.render(visibleText(turn.answer, false).text) + '</div></div>';
        }
        if (live) {
            const v = visibleText(live.text || '', true);
            html += '<div class="turn"><div class="who">You</div><div class="q">' + esc(live.question) + '</div><div class="answer-header"><div class="who">Assistant</div>' + (v.text ? '<button data-copy="live">Copy Markdown</button>' : '') + '</div><div class="a">' + md.render(v.text) +
                (v.drawing ? '<p class="drawing">Drawing…</p>' : '') + '</div><div class="status">' + esc(live.status || 'Working') + '</div>' +
                (live.error ? '<div class="error">' + esc(live.error) + '</div>' : '') + '</div>';
        }
        thread.innerHTML = html;
        hydrate(thread);
        if (stick || (live && !live.text)) window.scrollTo(0, document.body.scrollHeight);
    }

    let timer = null;
    function scheduleRender() {
        if (timer) return;
        timer = setTimeout(() => { timer = null; render(); }, 180);
    }

    window.mvSetTheme = function (isDark) {
        dark = !!isDark;
        document.documentElement.classList.toggle('light', !dark);
        themeMermaid();
        render();
    };
    window.mvSetTurns = function (json) { turns = JSON.parse(json); render(); window.scrollTo(0, document.body.scrollHeight); };
    window.mvSetLive = function (json) { live = json ? JSON.parse(json) : null; if (live) scheduleRender(); else render(); };
    window.mvScrollToEnd = function () { window.scrollTo(0, document.body.scrollHeight); };

    themeMermaid();
    post({ type: 'ready' });
})();
