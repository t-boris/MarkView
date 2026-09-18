        // ============================================================================
        // JSON CANVAS SUPPORT (.canvas — jsoncanvas.org spec 1.0)
        // Read-only viewer: pan, zoom, node selection, properties panel.
        // Renders inside DOM.rendered via the structured-content pipeline
        // (setStructuredContent → switchToStructuredView → renderStructuredContent).
        // ============================================================================

        // Obsidian preset palette (color "1".."6"); hex values pass through.
        const CANVAS_PRESET_COLORS = {
            '1': '#fb464c', '2': '#e9973f', '3': '#e0de71',
            '4': '#44cf6e', '5': '#53dfdd', '6': '#a882ff'
        };

        const cv = {
            nodes: [],          // parsed nodes (spec order preserved)
            edges: [],
            nodeById: new Map(),
            tx: 0, ty: 0, scale: 1,
            minScale: 0.05, maxScale: 4,
            selectedId: null,   // node or edge id
            pan: null,          // active drag-pan state {x, y, tx, ty}
            viewport: null, world: null, svg: null, propsPanel: null, zoomLabel: null
        };

        function canvasColor(color, fallback) {
            if (!color) return fallback;
            return CANVAS_PRESET_COLORS[color] || color;
        }

        window.renderCanvasView = function() {
            document.body.classList.add('canvas-mode');
            let data;
            try {
                data = JSON.parse(state.markdown);
                if (!data || typeof data !== 'object') throw new Error('Root is not an object');
            } catch (e) {
                window.leaveCanvasView(); // restore normal padding/scroll for the error view
                DOM.rendered.innerHTML = '<div class="struct-error">Canvas Parse Error: ' + escapeHTML(e.message) + '</div>'
                    + '<pre class="language-json" style="padding:12px;margin:0;overflow:auto;"><code>'
                    + escapeHTML(state.markdown) + '</code></pre>';
                return;
            }
            cv.nodes = Array.isArray(data.nodes) ? data.nodes.filter(n => n && n.id != null) : [];
            cv.edges = Array.isArray(data.edges) ? data.edges.filter(e => e && e.id != null) : [];
            cv.nodeById = new Map(cv.nodes.map(n => [String(n.id), n]));
            cv.selectedId = null;
            buildCanvasDOM();
            canvasZoomFit();
            sendCanvasHeadings();
        };

        window.leaveCanvasView = function() {
            document.body.classList.remove('canvas-mode');
        };

        // Cleanup when Swift loads a markdown file into the editor: setContent is the
        // markdown entry point, so restore markdown fileType + editability (they are
        // left stale by the structured/canvas pipeline otherwise).
        const _cvOrigSetContent = window.setContent;
        window.setContent = function(markdown) {
            window.leaveCanvasView();
            state.fileType = 'markdown';
            DOM.rendered.contentEditable = 'true';
            _cvOrigSetContent(markdown);
        };

        // TOC clicks: pan/zoom to the node when a canvas is active.
        const _cvOrigScrollToHeading = window.scrollToHeading;
        window.scrollToHeading = function(id) {
            if (state.fileType === 'canvas' && typeof id === 'string' && id.indexOf('cv-') === 0) {
                canvasFocusNode(id.slice(3));
                return;
            }
            if (_cvOrigScrollToHeading) _cvOrigScrollToHeading(id);
        };

        // --- DOM construction -------------------------------------------------

        function buildCanvasDOM() {
            DOM.rendered.innerHTML = '';
            const viewport = document.createElement('div');
            viewport.className = 'canvas-viewport';

            const toolbar = document.createElement('div');
            toolbar.className = 'canvas-toolbar';
            toolbar.innerHTML =
                '<button data-act="fit" title="Zoom to fit (double-click background)">Fit</button>'
                + '<button data-act="100" title="Actual size">100%</button>'
                + '<button data-act="out" title="Zoom out">−</button>'
                + '<span class="canvas-zoom-label">100%</span>'
                + '<button data-act="in" title="Zoom in">+</button>'
                + '<span class="canvas-stats">' + cv.nodes.length + ' nodes · ' + cv.edges.length + ' edges</span>'
                + '<span class="spacer"></span>'
                + '<button data-act="source" title="Show raw JSON">Source ↗</button>';
            toolbar.addEventListener('click', ev => {
                const act = ev.target.getAttribute && ev.target.getAttribute('data-act');
                if (!act) return;
                if (act === 'fit') canvasZoomFit();
                else if (act === '100') canvasSetZoom(1);
                else if (act === 'out') canvasZoomBy(1 / 1.25);
                else if (act === 'in') canvasZoomBy(1.25);
                else if (act === 'source') window.toggleStructMode();
            });

            const world = document.createElement('div');
            world.className = 'canvas-world';

            const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
            svg.setAttribute('class', 'canvas-edges');
            svg.setAttribute('width', '1');
            svg.setAttribute('height', '1');
            world.appendChild(svg);

            // Groups behind everything, larger groups further back.
            const groups = cv.nodes.filter(n => n.type === 'group')
                .sort((a, b) => (b.width * b.height) - (a.width * a.height));
            const others = cv.nodes.filter(n => n.type !== 'group');
            groups.concat(others).forEach(n => world.appendChild(buildCanvasNode(n)));

            cv.edges.forEach(e => drawCanvasEdge(svg, e));

            const props = document.createElement('div');
            props.className = 'canvas-props';
            props.style.display = 'none';

            viewport.appendChild(world);
            viewport.appendChild(toolbar);
            viewport.appendChild(props);
            DOM.rendered.appendChild(viewport);

            cv.viewport = viewport;
            cv.world = world;
            cv.svg = svg;
            cv.propsPanel = props;
            cv.zoomLabel = toolbar.querySelector('.canvas-zoom-label');

            wireCanvasInteractions();
        }

        function buildCanvasNode(n) {
            const el = document.createElement('div');
            el.className = 'canvas-node canvas-node-' + (n.type || 'text');
            el.setAttribute('data-node-id', String(n.id));
            el.style.left = (n.x || 0) + 'px';
            el.style.top = (n.y || 0) + 'px';
            el.style.width = (n.width || 0) + 'px';
            el.style.height = (n.height || 0) + 'px';
            const color = canvasColor(n.color, '');
            if (color) {
                el.style.borderColor = color;
                el.style.setProperty('--cv-node-color', color);
            }

            if (n.type === 'group') {
                const label = document.createElement('div');
                label.className = 'canvas-group-label';
                label.textContent = n.label || '';
                el.appendChild(label);
            } else if (n.type === 'text') {
                const content = document.createElement('div');
                content.className = 'canvas-node-content markdown-body';
                try {
                    content.innerHTML = (typeof md !== 'undefined' && md)
                        ? md.render(String(n.text || ''))
                        : '<pre>' + escapeHTML(String(n.text || '')) + '</pre>';
                } catch (e) {
                    content.innerHTML = '<pre>' + escapeHTML(String(n.text || '')) + '</pre>';
                }
                el.appendChild(content);
            } else if (n.type === 'file') {
                const path = String(n.file || '');
                const name = path.split('/').pop();
                const ext = (name.indexOf('.') >= 0 ? name.split('.').pop() : '').toLowerCase();
                const icon = ['png','jpg','jpeg','gif','svg','webp','bmp'].includes(ext) ? '🖼'
                    : ext === 'canvas' ? '🗺' : ext === 'pdf' ? '📕' : '📄';
                el.innerHTML = '<div class="canvas-node-content canvas-file">'
                    + '<div class="canvas-file-icon">' + icon + '</div>'
                    + '<div class="canvas-file-name">' + escapeHTML(name) + '</div>'
                    + '<div class="canvas-file-path">' + escapeHTML(path) + (n.subpath ? escapeHTML(String(n.subpath)) : '') + '</div>'
                    + '<div class="canvas-file-hint">double-click to open</div>'
                    + '</div>';
                el.addEventListener('dblclick', ev => {
                    ev.stopPropagation();
                    sendToSwift('canvasOpenFile', { path: path });
                });
            } else if (n.type === 'link') {
                const url = String(n.url || '');
                el.innerHTML = '<div class="canvas-node-content canvas-link">'
                    + '<div class="canvas-file-icon">🌐</div>'
                    + '<div class="canvas-link-url">' + escapeHTML(url) + '</div>'
                    + '<div class="canvas-file-hint">double-click to open</div>'
                    + '</div>';
                el.addEventListener('dblclick', ev => {
                    ev.stopPropagation();
                    if (/^https?:\/\//i.test(url)) sendToSwift('linkClicked', { href: url });
                });
            }
            return el;
        }

        // --- Edges -------------------------------------------------------------

        function canvasAnchor(n, side) {
            const x = n.x || 0, y = n.y || 0, w = n.width || 0, h = n.height || 0;
            switch (side) {
                case 'top':    return { x: x + w / 2, y: y,     dx: 0,  dy: -1 };
                case 'bottom': return { x: x + w / 2, y: y + h, dx: 0,  dy: 1 };
                case 'left':   return { x: x,         y: y + h / 2, dx: -1, dy: 0 };
                case 'right':  return { x: x + w,     y: y + h / 2, dx: 1,  dy: 0 };
            }
            return null;
        }

        // Pick the side facing the other node when the spec omits it.
        function canvasBestSide(from, to) {
            const fx = (from.x || 0) + (from.width || 0) / 2, fy = (from.y || 0) + (from.height || 0) / 2;
            const tx = (to.x || 0) + (to.width || 0) / 2, ty = (to.y || 0) + (to.height || 0) / 2;
            const dx = tx - fx, dy = ty - fy;
            if (Math.abs(dx) > Math.abs(dy)) return dx > 0 ? 'right' : 'left';
            return dy > 0 ? 'bottom' : 'top';
        }

        function drawCanvasEdge(svg, e) {
            const from = cv.nodeById.get(String(e.fromNode));
            const to = cv.nodeById.get(String(e.toNode));
            if (!from || !to) return;
            const a = canvasAnchor(from, e.fromSide || canvasBestSide(from, to));
            const b = canvasAnchor(to, e.toSide || canvasBestSide(to, from));
            if (!a || !b) return;

            const dist = Math.hypot(b.x - a.x, b.y - a.y);
            const k = Math.min(Math.max(dist * 0.35, 40), 220);
            const c1 = { x: a.x + a.dx * k, y: a.y + a.dy * k };
            const c2 = { x: b.x + b.dx * k, y: b.y + b.dy * k };
            const color = canvasColor(e.color, 'var(--cv-edge-color)');
            const ns = 'http://www.w3.org/2000/svg';

            const g = document.createElementNS(ns, 'g');
            g.setAttribute('class', 'canvas-edge');
            g.setAttribute('data-edge-id', String(e.id));

            const d = 'M' + a.x + ',' + a.y + ' C' + c1.x + ',' + c1.y + ' ' + c2.x + ',' + c2.y + ' ' + b.x + ',' + b.y;
            const hit = document.createElementNS(ns, 'path');   // fat invisible hit area
            hit.setAttribute('d', d);
            hit.setAttribute('class', 'canvas-edge-hit');
            const path = document.createElementNS(ns, 'path');
            path.setAttribute('d', d);
            path.setAttribute('class', 'canvas-edge-line');
            path.style.stroke = color;
            g.appendChild(hit);
            g.appendChild(path);

            // Arrowheads: toEnd defaults to 'arrow', fromEnd to 'none' (spec).
            if ((e.toEnd || 'arrow') === 'arrow') g.appendChild(canvasArrowHead(b, c2, color));
            if ((e.fromEnd || 'none') === 'arrow') g.appendChild(canvasArrowHead(a, c1, color));

            if (e.label) {
                const mid = canvasBezierPoint(a, c1, c2, b, 0.5);
                const label = document.createElementNS(ns, 'text');
                label.setAttribute('x', mid.x);
                label.setAttribute('y', mid.y);
                label.setAttribute('class', 'canvas-edge-label');
                label.textContent = String(e.label);
                g.appendChild(label);
            }
            svg.appendChild(g);
        }

        function canvasBezierPoint(p0, p1, p2, p3, t) {
            const u = 1 - t;
            return {
                x: u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x,
                y: u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y
            };
        }

        function canvasArrowHead(tip, ctrl, color) {
            let dx = tip.x - ctrl.x, dy = tip.y - ctrl.y;
            const len = Math.hypot(dx, dy) || 1;
            dx /= len; dy /= len;
            const size = 10;
            const p1 = { x: tip.x - dx * size - dy * size * 0.5, y: tip.y - dy * size + dx * size * 0.5 };
            const p2 = { x: tip.x - dx * size + dy * size * 0.5, y: tip.y - dy * size - dx * size * 0.5 };
            const poly = document.createElementNS('http://www.w3.org/2000/svg', 'polygon');
            poly.setAttribute('points', tip.x + ',' + tip.y + ' ' + p1.x + ',' + p1.y + ' ' + p2.x + ',' + p2.y);
            poly.setAttribute('class', 'canvas-edge-arrow');
            poly.style.fill = color;
            return poly;
        }

        // --- Pan / zoom ---------------------------------------------------------

        function canvasApplyTransform() {
            cv.world.style.transform = 'translate(' + cv.tx + 'px,' + cv.ty + 'px) scale(' + cv.scale + ')';
            if (cv.zoomLabel) cv.zoomLabel.textContent = Math.round(cv.scale * 100) + '%';
        }

        function canvasContentBounds() {
            if (!cv.nodes.length) return { x: 0, y: 0, w: 100, h: 100 };
            let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
            cv.nodes.forEach(n => {
                minX = Math.min(minX, n.x || 0);
                minY = Math.min(minY, n.y || 0);
                maxX = Math.max(maxX, (n.x || 0) + (n.width || 0));
                maxY = Math.max(maxY, (n.y || 0) + (n.height || 0));
            });
            return { x: minX, y: minY, w: Math.max(maxX - minX, 1), h: Math.max(maxY - minY, 1) };
        }

        function canvasZoomFit(retryCount) {
            const vp = cv.viewport.getBoundingClientRect();
            // The tab-restore path can render before WebKit lays the pane out;
            // a 0×0 viewport would clamp the fit to minScale (5%). Retry next frame.
            if ((vp.width < 40 || vp.height < 40) && (retryCount || 0) < 30) {
                requestAnimationFrame(() => canvasZoomFit((retryCount || 0) + 1));
                return;
            }
            const b = canvasContentBounds();
            const s = Math.min(Math.min(vp.width / b.w, vp.height / b.h) * 0.9, 1.5);
            cv.scale = Math.max(cv.minScale, Math.min(cv.maxScale, s));
            cv.tx = (vp.width - b.w * cv.scale) / 2 - b.x * cv.scale;
            cv.ty = (vp.height - b.h * cv.scale) / 2 - b.y * cv.scale;
            canvasApplyTransform();
        }

        function canvasSetZoom(s, pivot) {
            const vp = cv.viewport.getBoundingClientRect();
            const p = pivot || { x: vp.width / 2, y: vp.height / 2 };
            s = Math.max(cv.minScale, Math.min(cv.maxScale, s));
            const wx = (p.x - cv.tx) / cv.scale, wy = (p.y - cv.ty) / cv.scale;
            cv.scale = s;
            cv.tx = p.x - wx * s;
            cv.ty = p.y - wy * s;
            canvasApplyTransform();
        }

        function canvasZoomBy(factor, pivot) { canvasSetZoom(cv.scale * factor, pivot); }

        function canvasFocusNode(nodeId, zoom) {
            const n = cv.nodeById.get(String(nodeId));
            if (!n || !cv.viewport) return;
            const vp = cv.viewport.getBoundingClientRect();
            const s = zoom || Math.max(Math.min(cv.scale, 1), 0.5);
            cv.scale = Math.max(cv.minScale, Math.min(cv.maxScale, s));
            cv.tx = vp.width / 2 - ((n.x || 0) + (n.width || 0) / 2) * cv.scale;
            cv.ty = vp.height / 2 - ((n.y || 0) + (n.height || 0) / 2) * cv.scale;
            canvasApplyTransform();
            canvasSelect(String(nodeId), 'node');
        }

        // --- Interactions --------------------------------------------------------

        function wireCanvasInteractions() {
            const vpEl = cv.viewport;

            vpEl.addEventListener('wheel', ev => {
                // Let a selected node's overflowing content scroll natively.
                if (!ev.ctrlKey && !ev.metaKey) {
                    const scrollable = ev.target.closest && ev.target.closest('.canvas-node.selected .canvas-node-content');
                    if (scrollable && scrollable.scrollHeight > scrollable.clientHeight) return;
                }
                ev.preventDefault();
                const rect = vpEl.getBoundingClientRect();
                const pivot = { x: ev.clientX - rect.left, y: ev.clientY - rect.top };
                // Wheel = zoom around the cursor (pinch arrives as ctrlKey+wheel and
                // zooms too). Shift+wheel pans; dragging the background also pans.
                if (ev.shiftKey && !ev.ctrlKey && !ev.metaKey) {
                    cv.tx -= ev.deltaX;
                    cv.ty -= ev.deltaY;
                    canvasApplyTransform();
                } else {
                    canvasZoomBy(Math.exp(-ev.deltaY * 0.01), pivot);
                }
            }, { passive: false });

            vpEl.addEventListener('mousedown', ev => {
                const onChrome = ev.target.closest('.canvas-toolbar, .canvas-props');
                if (onChrome) return;
                const onNode = ev.target.closest('.canvas-node, .canvas-edge');
                if (ev.button === 0 && onNode) return; // left-click on node = select, not pan
                if (ev.button !== 0 && ev.button !== 1) return;
                cv.pan = { x: ev.clientX, y: ev.clientY, tx: cv.tx, ty: cv.ty };
                vpEl.classList.add('panning');
                ev.preventDefault();
            });
            // Named handlers → addEventListener dedupes across re-renders (no leak).
            window.addEventListener('mousemove', canvasPanMove);
            window.addEventListener('mouseup', canvasPanEnd);

            vpEl.addEventListener('click', ev => {
                if (ev.target.closest('.canvas-toolbar, .canvas-props')) return;
                const nodeEl = ev.target.closest('.canvas-node');
                const edgeEl = ev.target.closest('.canvas-edge');
                if (nodeEl) canvasSelect(nodeEl.getAttribute('data-node-id'), 'node');
                else if (edgeEl) canvasSelect(edgeEl.getAttribute('data-edge-id'), 'edge');
                else canvasSelect(null);
            });

            vpEl.addEventListener('dblclick', ev => {
                if (ev.target.closest('.canvas-toolbar, .canvas-props')) return;
                const nodeEl = ev.target.closest('.canvas-node');
                if (nodeEl) {
                    const n = cv.nodeById.get(nodeEl.getAttribute('data-node-id'));
                    // file/link nodes own their dblclick (open); text/group zoom in
                    if (n && (n.type === 'text' || n.type === 'group')) canvasFocusNode(n.id, 1);
                    return;
                }
                canvasZoomFit();
            });

            document.addEventListener('keydown', canvasKeyHandler);
        }

        function canvasPanMove(ev) {
            if (!cv.pan) return;
            cv.tx = cv.pan.tx + (ev.clientX - cv.pan.x);
            cv.ty = cv.pan.ty + (ev.clientY - cv.pan.y);
            canvasApplyTransform();
        }

        function canvasPanEnd() {
            if (!cv.pan) return;
            cv.pan = null;
            if (cv.viewport) cv.viewport.classList.remove('panning');
        }

        function canvasKeyHandler(ev) {
            if (state.fileType !== 'canvas' || state.mode !== 'structured') return;
            if (ev.key === 'Escape') canvasSelect(null);
        }

        // --- Selection + properties panel -----------------------------------------

        function canvasSelect(id, kind) {
            cv.selectedId = id;
            cv.viewport.querySelectorAll('.canvas-node.selected, .canvas-edge.selected')
                .forEach(el => el.classList.remove('selected'));
            if (!id) { cv.propsPanel.style.display = 'none'; return; }
            const sel = kind === 'node'
                ? cv.viewport.querySelector('.canvas-node[data-node-id="' + CSS.escape(id) + '"]')
                : cv.viewport.querySelector('.canvas-edge[data-edge-id="' + CSS.escape(id) + '"]');
            if (sel) sel.classList.add('selected');
            renderCanvasProps(id, kind);
        }

        function canvasPropRow(key, valueHtml) {
            return '<div class="canvas-prop"><span class="canvas-prop-key">' + key + '</span>'
                + '<span class="canvas-prop-value">' + valueHtml + '</span></div>';
        }

        function renderCanvasProps(id, kind) {
            let html = '';
            if (kind === 'node') {
                const n = cv.nodeById.get(String(id));
                if (!n) return;
                html += '<div class="canvas-props-title">' + escapeHTML(n.type || 'text') + ' node'
                    + '<button class="canvas-props-close" title="Close (Esc)">✕</button></div>';
                html += canvasPropRow('id', escapeHTML(String(n.id)));
                html += canvasPropRow('x', String(n.x || 0)) + canvasPropRow('y', String(n.y || 0));
                html += canvasPropRow('width', String(n.width || 0)) + canvasPropRow('height', String(n.height || 0));
                if (n.color) {
                    const c = canvasColor(n.color, '');
                    html += canvasPropRow('color', '<span class="canvas-swatch" style="background:' + c + '"></span>' + escapeHTML(String(n.color)));
                }
                if (n.type === 'file') {
                    html += canvasPropRow('file', escapeHTML(String(n.file || '')));
                    if (n.subpath) html += canvasPropRow('subpath', escapeHTML(String(n.subpath)));
                } else if (n.type === 'link') {
                    html += canvasPropRow('url', escapeHTML(String(n.url || '')));
                } else if (n.type === 'group') {
                    if (n.label) html += canvasPropRow('label', escapeHTML(String(n.label)));
                    if (n.background) html += canvasPropRow('background', escapeHTML(String(n.background)));
                    if (n.backgroundStyle) html += canvasPropRow('bg style', escapeHTML(String(n.backgroundStyle)));
                } else if (n.type === 'text' || n.text != null) {
                    const text = String(n.text || '');
                    html += canvasPropRow('length', text.length + ' chars');
                    html += '<div class="canvas-prop-block"><pre>' + escapeHTML(text) + '</pre></div>';
                }
            } else {
                const e = cv.edges.find(x => String(x.id) === String(id));
                if (!e) return;
                const fromN = cv.nodeById.get(String(e.fromNode));
                const toN = cv.nodeById.get(String(e.toNode));
                html += '<div class="canvas-props-title">edge'
                    + '<button class="canvas-props-close" title="Close (Esc)">✕</button></div>';
                html += canvasPropRow('id', escapeHTML(String(e.id)));
                html += canvasPropRow('from', escapeHTML(canvasNodeTitle(fromN) || String(e.fromNode)) + (e.fromSide ? ' · ' + escapeHTML(e.fromSide) : ''));
                html += canvasPropRow('to', escapeHTML(canvasNodeTitle(toN) || String(e.toNode)) + (e.toSide ? ' · ' + escapeHTML(e.toSide) : ''));
                html += canvasPropRow('ends', escapeHTML((e.fromEnd || 'none') + ' → ' + (e.toEnd || 'arrow')));
                if (e.label) html += canvasPropRow('label', escapeHTML(String(e.label)));
                if (e.color) {
                    const c = canvasColor(e.color, '');
                    html += canvasPropRow('color', '<span class="canvas-swatch" style="background:' + c + '"></span>' + escapeHTML(String(e.color)));
                }
            }
            cv.propsPanel.innerHTML = html;
            cv.propsPanel.style.display = 'block';
            const close = cv.propsPanel.querySelector('.canvas-props-close');
            if (close) close.addEventListener('click', () => canvasSelect(null));
        }

        // --- TOC integration -------------------------------------------------------

        function canvasNodeTitle(n) {
            if (!n) return '';
            if (n.type === 'group') return n.label || 'Group';
            if (n.type === 'file') return String(n.file || '').split('/').pop();
            if (n.type === 'link') return String(n.url || '');
            const text = String(n.text || '').trim();
            const firstLine = text.split('\n')[0].replace(/^#+\s*/, '').replace(/[*_`~]/g, '');
            return firstLine.slice(0, 60) || 'Text';
        }

        function canvasNodeInGroup(n, groups) {
            const cx = (n.x || 0) + (n.width || 0) / 2, cy = (n.y || 0) + (n.height || 0) / 2;
            return groups.some(g => cx >= g.x && cx <= g.x + g.width && cy >= g.y && cy <= g.y + g.height);
        }

        function sendCanvasHeadings() {
            const groups = cv.nodes.filter(n => n.type === 'group');
            const headings = cv.nodes.map(n => ({
                id: 'cv-' + String(n.id),
                level: n.type === 'group' ? 1 : (canvasNodeInGroup(n, groups) ? 2 : 1),
                text: canvasNodeTitle(n)
            }));
            sendToSwift('headingsUpdated', headings);
        }
