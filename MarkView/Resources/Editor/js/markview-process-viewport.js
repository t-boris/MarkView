(function(P) {
    let nextID = 0;
    function svg(tag, attributes) {
        const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
        Object.keys(attributes || {}).forEach(function(key) { node.setAttribute(key, String(attributes[key])); });
        return node;
    }

    function makeViewport(parent, actions) {
        const viewport = P.element('div', 'process-viewport');
        viewport.setAttribute('aria-label', 'Process graph. Drag the background to pan. Use the zoom controls to magnify.');
        const scene = P.element('div', 'process-scene');
        const paths = svg('svg', { class: 'process-edges', 'aria-hidden': 'true' });
        const nodes = P.element('div', 'process-nodes');
        scene.append(paths, nodes); viewport.append(scene); parent.append(viewport);
        const prefix = 'process-arrow-' + (++nextID);
        let drawing = null, pose = { x: 0, y: 0, zoom: 1 }, drag = null;
        const nodeElements = new Map(), edgeElements = [];

        function apply() {
            scene.style.transform = 'translate(' + pose.x + 'px,' + pose.y + 'px) scale(' + pose.zoom + ')';
            actions.changed(pose.zoom);
        }

        function zoom(value, point) {
            const target = Math.max(0.12, Math.min(3, value));
            const center = point || { x: viewport.clientWidth / 2, y: viewport.clientHeight / 2 };
            const factor = target / pose.zoom;
            pose.x = center.x - (center.x - pose.x) * factor;
            pose.y = center.y - (center.y - pose.y) * factor;
            pose.zoom = target; apply();
        }

        function focus(id) {
            const node = drawing && drawing.nodes.get(id);
            if (!node) return;
            pose.x = viewport.clientWidth / 2 - (node.x + node.width / 2) * pose.zoom;
            pose.y = viewport.clientHeight / 2 - (node.y + node.height / 2) * pose.zoom;
            apply();
        }

        function fit(readable) {
            if (!drawing || !viewport.clientWidth || !viewport.clientHeight) return;
            const value = Math.min((viewport.clientWidth - 36) / drawing.width, (viewport.clientHeight - 36) / drawing.height, 1.3);
            pose.zoom = Math.max(readable ? 0.7 : 0.12, value);
            pose.x = (viewport.clientWidth - drawing.width * pose.zoom) / 2;
            pose.y = (viewport.clientHeight - drawing.height * pose.zoom) / 2;
            apply();
        }

        function setDrawing(next, graph, savedPose, selected) {
            drawing = next;
            scene.style.width = next.width + 'px'; scene.style.height = next.height + 'px';
            paths.setAttribute('width', String(next.width)); paths.setAttribute('height', String(next.height));
            paths.setAttribute('viewBox', '0 0 ' + next.width + ' ' + next.height);
            paths.textContent = ''; nodes.textContent = ''; nodeElements.clear(); edgeElements.length = 0;
            const definitions = svg('defs');
            ['normal', 'selected', 'return'].forEach(function(kind) {
                const marker = svg('marker', { id: prefix + '-' + kind, viewBox: '0 0 8 8', refX: 7, refY: 4,
                    markerWidth: 7, markerHeight: 7, orient: 'auto' });
                marker.append(svg('path', { d: 'M0 0 L8 4 L0 8 Z', class: 'process-arrow-' + kind }));
                definitions.append(marker);
            });
            paths.append(definitions);
            next.edges.forEach(function(edge) {
                const group = svg('g', { class: 'process-edge-group' });
                const caption = svg('title'); caption.textContent = edge.fullLabel || edge.label; group.append(caption);
                const strokes = [];
                edge.sections.forEach(function(section, i) {
                    const d = P.path(section);
                    if (edge.kind === 'return') group.append(svg('path', { d: d, class: 'process-return-halo' }));
                    const stroke = svg('path', { d: d, class: 'process-edge' + (edge.kind === 'return' ? ' is-return' : '') });
                    if (i === edge.sections.length - 1) stroke.setAttribute('marker-end', 'url(#' + prefix + '-' + (edge.kind === 'return' ? 'return' : 'normal') + ')');
                    group.append(stroke); strokes.push(stroke);
                });
                if (edge.labelBox) {
                    const box = edge.labelBox;
                    group.append(svg('rect', { x: box.x, y: box.y, width: box.width, height: box.height, rx: 3, class: 'process-edge-label-bg' }));
                    const text = svg('text', { x: box.x + box.width / 2, y: box.y + 12, 'text-anchor': 'middle',
                        class: 'process-edge-label' + (edge.kind === 'return' ? ' is-return' : '') });
                    box.lines.forEach(function(line, i) {
                        const span = svg('tspan', { x: box.x + box.width / 2, dy: i ? 14 : 0 }); span.textContent = line; text.append(span);
                    });
                    group.append(text);
                }
                paths.append(group); edgeElements.push({ group: group, strokes: strokes, edge: edge });
            });
            const byID = P.index(graph);
            next.nodes.forEach(function(at, id) {
                const node = byID.get(id);
                if (!node) return;
                const count = P.children(graph, id).length;
                const button = P.button('', function() { actions.select(id); }, 'process-node');
                const rawKind = node.kind || (count ? 'group' : 'action');
                const kind = rawKind.charAt(0).toUpperCase() + rawKind.slice(1);
                button.append(P.element('span', 'process-node-kind', kind + (count ? ', ' + count + ' steps' : '')),
                    P.element('span', 'process-node-title', node.title));
                button.dataset.processNode = id;
                button.title = node.title + (count ? '\nDouble-click to open the group' : '');
                button.setAttribute('aria-label', node.title + (count ? ', group with ' + count + ' steps' : ''));
                Object.assign(button.style, { left: at.x + 'px', top: at.y + 'px', width: at.width + 'px', height: at.height + 'px' });
                button.addEventListener('dblclick', function(event) {
                    if (!count) return;
                    event.preventDefault(); event.stopPropagation(); actions.openGroup(id);
                });
                nodes.append(button); nodeElements.set(id, button);
            });
            if (savedPose) { pose = Object.assign({}, savedPose); apply(); }
            else {
                fit(true);
                if (pose.zoom <= 0.7 && selected) {
                    focus(selected);
                    const entry = next.nodes.get(selected);
                    if (entry && !next.edges.some(function(edge) { return edge.to === selected && edge.kind !== 'return'; })) {
                        if (next.direction === 'DOWN') pose.y = 24 - entry.y * pose.zoom;
                        else pose.x = 24 - entry.x * pose.zoom;
                        apply();
                    }
                }
            }
        }

        function highlight(selected, neighborsOnly) {
            const neighbors = new Set([selected]);
            edgeElements.forEach(function(item) {
                if (item.edge.from === selected) neighbors.add(item.edge.to);
                if (item.edge.to === selected) neighbors.add(item.edge.from);
            });
            nodeElements.forEach(function(node, id) {
                node.setAttribute('aria-pressed', String(id === selected));
                node.classList.toggle('is-muted', !!neighborsOnly && !neighbors.has(id));
            });
            edgeElements.forEach(function(item) {
                const active = item.edge.from === selected || item.edge.to === selected;
                item.group.style.display = neighborsOnly && !active ? 'none' : '';
                item.strokes.forEach(function(stroke, i) {
                    stroke.classList.toggle('is-selected', active);
                    if (i === item.strokes.length - 1) stroke.setAttribute('marker-end', 'url(#' + prefix + '-'
                        + (item.edge.kind === 'return' ? 'return' : active ? 'selected' : 'normal') + ')');
                });
            });
        }

        viewport.addEventListener('wheel', function(event) {
            if (!drawing) return;
            event.preventDefault();
            const bounds = viewport.getBoundingClientRect();
            if (event.ctrlKey || event.metaKey) zoom(pose.zoom * Math.exp(-event.deltaY * 0.008), { x: event.clientX - bounds.left, y: event.clientY - bounds.top });
            else { pose.x -= event.deltaX; pose.y -= event.deltaY; apply(); }
        }, { passive: false });
        viewport.addEventListener('pointerdown', function(event) {
            if (event.button !== 0 || event.target.closest('button')) return;
            drag = { x: event.clientX - pose.x, y: event.clientY - pose.y };
            viewport.setPointerCapture(event.pointerId); viewport.classList.add('is-dragging');
        });
        viewport.addEventListener('pointermove', function(event) {
            if (!drag) return;
            pose.x = event.clientX - drag.x; pose.y = event.clientY - drag.y; apply();
        });
        function endDrag() { drag = null; viewport.classList.remove('is-dragging'); }
        viewport.addEventListener('pointerup', endDrag); viewport.addEventListener('pointercancel', endDrag);
        return { element: viewport, setDrawing: setDrawing, highlight: highlight, fit: function() { fit(false); },
            zoom: function(factor) { zoom(pose.zoom * factor); }, actualSize: function(id) { zoom(1); focus(id); },
            focus: focus, pose: function() { return Object.assign({}, pose); },
            clear: function() { drawing = null; paths.textContent = ''; nodes.textContent = ''; } };
    }

    Object.assign(P, { makeViewport: makeViewport });
})(window['MVProcess']);
