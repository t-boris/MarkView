(function(P) {
    function points(section) {
        return [section.startPoint].concat(section.bendPoints || [], [section.endPoint]);
    }

    function path(line) {
        return line.map(function(point, i) {
            return (i ? 'L' : 'M') + Math.round(point.x * 10) / 10 + ' ' + Math.round(point.y * 10) / 10;
        }).join(' ');
    }

    function wrap(text, size) {
        const words = String(text || '').split(/\s+/).flatMap(function(word) {
            const pieces = [];
            for (let i = 0; i < word.length; i += size) pieces.push(word.slice(i, i + size));
            return pieces;
        }), lines = [];
        let line = '';
        words.forEach(function(word) {
            if (line && (line + ' ' + word).length > size) { lines.push(line); line = ''; }
            line += (line ? ' ' : '') + word;
        });
        if (line) lines.push(line);
        if (lines.length > 3) return lines.slice(0, 2).concat(lines[2].slice(0, size - 3) + '...');
        return lines.length ? lines : [''];
    }

    async function layout(level, elk, direction) {
        const down = direction === 'DOWN';
        const grouped = P.bundle(level.edges || []);
        const forward = grouped.filter(function(edge) { return edge.kind !== 'return'; });
        const returns = grouped.filter(function(edge) { return edge.kind === 'return'; });
        const ids = new Set(level.nodes.map(function(node) { return node.id; }));
        const graph = {
            id: 'process',
            layoutOptions: {
                'elk.algorithm': 'layered', 'elk.direction': down ? 'DOWN' : 'RIGHT',
                'elk.edgeRouting': 'ORTHOGONAL', 'elk.padding': '[top=32,left=32,bottom=32,right=32]',
                'elk.spacing.nodeNode': '38', 'elk.layered.spacing.nodeNodeBetweenLayers': '58',
                'elk.layered.considerModelOrder.strategy': 'NODES_AND_EDGES',
                'elk.layered.crossingMinimization.strategy': 'LAYER_SWEEP',
                'elk.layered.nodePlacement.strategy': 'NETWORK_SIMPLEX',
                'elk.layered.mergeEdges': 'false'
            },
            children: level.nodes.map(function(node) { return { id: node.id, width: 156, height: 82 }; }),
            edges: forward.filter(function(edge) { return ids.has(edge.from) && ids.has(edge.to); }).map(function(edge) {
                const show = edge.kind === 'branch' || edge.kind === 'error' || edge.kind === 'parallel';
                const lines = wrap(edge.label, 18);
                return { id: edge.id, sources: [edge.from], targets: [edge.to],
                    labels: show ? [{ id: edge.id + '-label', text: edge.label,
                        width: Math.min(124, Math.max.apply(null, lines.map(function(line) { return line.length; })) * 6.5 + 8),
                        height: lines.length * 14 + 4 }] : [] };
            })
        };
        const placed = await elk.layout(graph);
        const before = Math.ceil(returns.length / 2), after = Math.floor(returns.length / 2);
        const paddingBefore = before ? before * 34 + 20 : 0;
        const paddingAfter = after ? after * 34 + 20 : 0;
        const shiftX = down ? paddingBefore : 0, shiftY = down ? 0 : paddingBefore;
        const positions = new Map();
        (placed.children || []).forEach(function(node) {
            if (![node.x, node.y, node.width, node.height].every(Number.isFinite)) throw new Error('Invalid process layout');
            positions.set(node.id, { x: node.x + shiftX, y: node.y + shiftY, width: node.width, height: node.height });
        });
        const edges = [];
        (placed.edges || []).forEach(function(edge) {
            const original = grouped.find(function(item) { return item.id === edge.id; });
            if (!original || !edge.sections || !edge.sections.length) return;
            const sections = edge.sections.map(function(section) {
                return points(section).map(function(point) { return { x: point.x + shiftX, y: point.y + shiftY }; });
            });
            const label = edge.labels && edge.labels[0];
            edges.push(Object.assign({}, original, { sections: sections,
                labelBox: label ? { x: label.x + shiftX, y: label.y + shiftY, width: label.width,
                    height: label.height, lines: wrap(original.label, 18) } : null }));
        });
        returns.forEach(function(edge, i) {
            const a = positions.get(edge.from), b = positions.get(edge.to);
            if (!a || !b) return;
            const first = i % 2 === 0, slot = Math.floor(i / 2), track = first
                ? paddingBefore - 18 - slot * 34
                : paddingBefore + (down ? placed.width : placed.height) + 18 + slot * 34;
            let route, labelBox;
            if (down) {
                const ax = a.x + a.width / 2, bx = b.x + b.width / 2;
                const sy = a.y + a.height, ty = b.y;
                route = [{ x: ax, y: sy }, { x: ax, y: sy + 16 }, { x: track, y: sy + 16 },
                    { x: track, y: ty - 16 }, { x: bx, y: ty - 16 }, { x: bx, y: ty }];
                labelBox = { x: track - 12, y: (sy + ty) / 2 - 9, width: 24, height: 18, lines: ['R' + (i + 1)] };
            } else {
                const ay = a.y + a.height / 2, by = b.y + b.height / 2;
                const sx = a.x + a.width, tx = b.x;
                route = [{ x: sx, y: ay }, { x: sx + 16, y: ay }, { x: sx + 16, y: track },
                    { x: tx - 16, y: track }, { x: tx - 16, y: by }, { x: tx, y: by }];
                labelBox = { x: (sx + tx) / 2 - 12, y: track - 9, width: 24, height: 18, lines: ['R' + (i + 1)] };
            }
            edges.push(Object.assign({}, edge, { sections: [route], labelBox: labelBox, returnName: 'R' + (i + 1) }));
        });
        return { nodes: positions, edges: edges, width: placed.width + (down ? paddingBefore + paddingAfter : 0),
            height: placed.height + (down ? 0 : paddingBefore + paddingAfter), direction: down ? 'DOWN' : 'RIGHT' };
    }

    Object.assign(P, { layout: layout, path: path });
})(window['MVProcess']);
