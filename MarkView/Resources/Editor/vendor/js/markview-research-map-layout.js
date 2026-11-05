// Research map layout engine (DEC-007). A pure function: MVResearchMapLayout.compute({nodes, layouts, size}) returns
// {positions: {id: {x, y}}, bounds} with node CENTRES in map coordinates. It works in the editor page
// (window.MVResearchMapLayout) and in node (module.exports), so tools/tests/research-map-layout.test.js can check it.
//
// Rules
//  - Presets: balanced, right, left, down, up, radial, outline. The root defaults to balanced.
//  - A node's own `layout` arranges ALL its descendants; a node without one uses the nearest ancestor's. An id that is
//    not a known preset (or not in the optional `layouts` list) is ignored, so the node inherits.
//  - The branch node itself is placed by its parent's layout, not by its own.
//  - A node with numeric x and y stays exactly there; its descendants without manual positions are placed relative to
//    its final position, so a moved branch carries its layout along. The other nodes do not move: a manually placed
//    node keeps the slot it would have had, so dragging one node never reflows its siblings.
//  - Every subtree is measured as a box (the node and everything below it). Siblings are stacked by those boxes,
//    so no two node boxes of different branches overlap. Radial rings grow until no two boxes touch.
(function (root, factory) {
    'use strict';
    var api = factory();
    if (typeof module === 'object' && module && module.exports) module.exports = api;
    if (typeof window !== 'undefined' && root === window) window.MVResearchMapLayout = api;
})(typeof window !== 'undefined' ? window : this, function () {
    'use strict';

    var PRESETS = ['balanced', 'right', 'left', 'down', 'up', 'radial', 'outline'];
    var D = {
        level: 56,        // free space between a node and its children's boxes, along the growth axis
        minStepX: 230,    // smallest centre-to-centre step of a horizontal tree (the prototype's level spacing)
        minStepY: 112,    // the same for vertical trees
        siblingV: 40,     // space between stacked siblings of a horizontal tree
        siblingH: 36,     // space between side-by-side siblings of a vertical tree
        rowGap: 14,       // outline row spacing
        indent: 40,       // outline indent per level
        ringGap: 28,      // free space between boxes on a radial layout
        ring1: 170,       // smallest radius of the first ring
        ringStep: 150     // smallest distance between rings
    };

    function isManual(node) {
        return !!node && typeof node.x === 'number' && isFinite(node.x) && typeof node.y === 'number' && isFinite(node.y);
    }

    /** A size guess for a node when the page cannot measure it: roughly the prototype's node look. */
    function estimateSize(node, isRoot) {
        var title = String((node && node.title) || '');
        var font = isRoot ? 16 : 14;
        var charWidth = font * 0.6;
        var padX = isRoot ? 52 : 52;      // 17 + 28 padding and the border
        var minW = isRoot ? 170 : 110;
        var maxW = 220;
        var perLine = Math.max(4, Math.floor((maxW - padX) / charWidth));
        var words = title.split(/\s+/).filter(Boolean);
        var lines = [], line = '';
        words.forEach(function (word) {
            while (word.length > perLine) {
                if (line) { lines.push(line); line = ''; }
                lines.push(word.slice(0, perLine));
                word = word.slice(perLine);
            }
            if (!line) line = word;
            else if ((line + ' ' + word).length <= perLine) line += ' ' + word;
            else { lines.push(line); line = word; }
        });
        if (line || !lines.length) lines.push(line);
        var widest = lines.reduce(function (m, l) { return Math.max(m, l.length); }, 0);
        var w = Math.min(maxW, Math.max(minW, Math.round(widest * charWidth + padX)));
        var h = Math.round(lines.length * font * 1.3 + (isRoot ? 40 : 26));
        return { w: w, h: h };
    }

    function validPresets(layouts) {
        var set = new Set(PRESETS);
        if (Array.isArray(layouts) && layouts.length) {
            var listed = new Set(layouts.map(function (l) { return l && l.id; }));
            PRESETS.forEach(function (id) { if (!listed.has(id)) set.delete(id); });
        }
        return set;
    }

    // ---- boxes: {l, t, r, b} relative to a node's centre --------------------------------------------------------
    function rect(item) { return { l: -item.w / 2, t: -item.h / 2, r: item.w / 2, b: item.h / 2 }; }
    function shift(b, dx, dy) { return { l: b.l + dx, t: b.t + dy, r: b.r + dx, b: b.b + dy }; }
    function union(a, b) {
        if (!a) return b;
        if (!b) return a;
        return { l: Math.min(a.l, b.l), t: Math.min(a.t, b.t), r: Math.max(a.r, b.r), b: Math.max(a.b, b.b) };
    }
    function touches(a, b, gap) { return a.l < b.r + gap && b.l < a.r + gap && a.t < b.b + gap && b.t < a.b + gap; }

    /** A box seen along the growth axis g and the cross axis c of a tree that grows in direction `dir`. */
    function toAxis(b, dir) {
        if (dir === 'right') return { g0: b.l, g1: b.r, c0: b.t, c1: b.b };
        if (dir === 'left') return { g0: -b.r, g1: -b.l, c0: b.t, c1: b.b };
        if (dir === 'down') return { g0: b.t, g1: b.b, c0: b.l, c1: b.r };
        return { g0: -b.b, g1: -b.t, c0: b.l, c1: b.r };
    }
    function fromAxis(g, c, dir) {
        if (dir === 'right') return { x: g, y: c };
        if (dir === 'left') return { x: -g, y: c };
        if (dir === 'down') return { x: c, y: g };
        return { x: c, y: -g };
    }

    // ---- the tree --------------------------------------------------------------------------------------------------
    function build(opts) {
        var list = Array.isArray(opts.nodes) ? opts.nodes : [];
        var valid = validPresets(opts.layouts);
        var byId = new Map(), items = [];
        list.forEach(function (node) {
            if (!node || node.id == null) return;
            var id = String(node.id);
            if (byId.has(id)) return;
            var item = {
                id: id, node: node, kids: [], parent: null,
                parentId: node.parent == null ? '' : String(node.parent),
                own: (typeof node.layout === 'string' && valid.has(node.layout)) ? node.layout : null,
                eff: null, manual: isManual(node), x: Number(node.x), y: Number(node.y),
                w: 0, h: 0, rel: { x: 0, y: 0 }, box: null
            };
            byId.set(id, item);
            items.push(item);
        });
        if (!items.length) return null;
        var top = items.filter(function (i) { return i.parentId === ''; })[0] || items[0];
        items.forEach(function (item) {
            if (item === top) return;
            var parent = byId.get(item.parentId);
            item.parent = (parent && parent !== item) ? parent : top;
            item.parent.kids.push(item);
        });
        // Nodes that cannot be reached from the root (a parent cycle) hang from the root.
        var reached = new Set();
        function walk(start) {
            var stack = [start];
            while (stack.length) {
                var cur = stack.pop();
                if (reached.has(cur)) continue;
                reached.add(cur);
                for (var k = cur.kids.length - 1; k >= 0; k--) stack.push(cur.kids[k]);
            }
        }
        walk(top);
        items.forEach(function (item) {
            if (reached.has(item)) return;
            if (item.parent) item.parent.kids = item.parent.kids.filter(function (k) { return k !== item; });
            item.parent = top;
            top.kids.push(item);
            walk(item);
        });
        // Effective layout, parents before children.
        var order = [];
        (function pre(start) {
            var stack = [start];
            while (stack.length) {
                var cur = stack.pop();
                order.push(cur);
                for (var k = cur.kids.length - 1; k >= 0; k--) stack.push(cur.kids[k]);
            }
        })(top);
        order.forEach(function (item) { item.eff = item.own || (item.parent ? item.parent.eff : 'balanced'); });
        return { root: top, items: items, order: order, byId: byId };
    }

    // ---- arrangement -----------------------------------------------------------------------------------------------
    function arrange(item, mode) {
        var box = rect(item);
        if (item.kids.length) {
            if (mode === 'radial') box = arrangeRadial(item);
            else if (mode === 'outline') box = arrangeOutline(item);
            else if (mode === 'balanced') {
                var right = [], left = [];
                item.kids.forEach(function (kid, i) { (i % 2 === 0 ? right : left).push(kid); });
                box = union(box, placeLinear(item, right, 'right'));
                box = union(box, placeLinear(item, left, 'left'));
            } else box = union(box, placeLinear(item, item.kids, mode));
        }
        item.box = box;
        return box;
    }

    /** Children in one row or column on one side of `item`: right/left stack vertically, down/up side by side. */
    function placeLinear(item, kids, dir) {
        if (!kids.length) return null;
        var horizontal = dir === 'right' || dir === 'left';
        var gap = horizontal ? D.siblingV : D.siblingH;
        var nodeG = (horizontal ? item.w : item.h) / 2;
        var rows = kids.map(function (kid) {
            return { kid: kid, a: toAxis(arrange(kid, kid.own || dir), dir), c: 0 };
        });
        var step = horizontal ? D.minStepX : D.minStepY;
        rows.forEach(function (row) { step = Math.max(step, nodeG + D.level - row.a.g0); });
        var cursor = 0;
        rows.forEach(function (row) {
            row.c = cursor - row.a.c0;
            cursor += (row.a.c1 - row.a.c0) + gap;
        });
        var mid = (rows[0].c + rows[rows.length - 1].c) / 2;
        var out = null;
        rows.forEach(function (row) {
            var p = fromAxis(step, row.c - mid, dir);
            row.kid.rel = p;
            out = union(out, shift(row.kid.box, p.x, p.y));
        });
        return out;
    }

    /** Compact indented list below the node: every level moves right by one indent. */
    function arrangeOutline(item) {
        var box = rect(item);
        var cursor = item.h / 2 + D.rowGap;
        item.kids.forEach(function (kid) {
            var kb = arrange(kid, kid.own || 'outline');
            var p = { x: -item.w / 2 + D.indent - kb.l, y: cursor - kb.t };
            kid.rel = p;
            box = union(box, shift(kb, p.x, p.y));
            cursor += (kb.b - kb.t) + D.rowGap;
        });
        return box;
    }

    /** Rings around the node. Each child owns an angular sector proportional to its subtree; deeper levels sit on wider
        rings inside that sector. A descendant with a layout of its own is an atom: its whole box is kept clear. */
    function arrangeRadial(owner) {
        var top = { item: owner, parent: null, depth: 0, kids: [], off: { x: 0, y: 0 } };
        var members = [];
        (function grow(m) {
            m.item.kids.forEach(function (kid) {
                var km = { item: kid, parent: m, depth: m.depth + 1, kids: [], atom: !!kid.own, off: null, angle: 0, weight: 1 };
                m.kids.push(km);
                members.push(km);
                if (km.atom) {
                    km.box = arrange(kid, kid.own);
                    km.weight = Math.max(1, Math.round(Math.max(km.box.r - km.box.l, km.box.b - km.box.t) / 200));
                } else {
                    km.box = rect(kid);
                    grow(km);
                    km.weight = km.kids.length ? km.kids.reduce(function (s, k) { return s + k.weight; }, 0) : 1;
                }
            });
        })(top);
        var total = top.kids.reduce(function (s, k) { return s + k.weight; }, 0);
        var full = Math.PI * 2;
        function assign(m, a0, a1) {
            var sum = m.kids.reduce(function (s, k) { return s + k.weight; }, 0);
            var a = a0;
            m.kids.forEach(function (k) {
                var span = (a1 - a0) * k.weight / sum;
                k.angle = a + span / 2;
                assign(k, a, a + span);
                a += span;
            });
        }
        var firstSpan = full * top.kids[0].weight / total;
        assign(top, -firstSpan / 2, full - firstSpan / 2);

        var placed = [rect(owner)];
        var maxDepth = members.reduce(function (m, k) { return Math.max(m, k.depth); }, 0);
        var previous = 0;
        for (var depth = 1; depth <= maxDepth; depth++) {
            var ring = members.filter(function (m) { return m.depth === depth; });
            var r = Math.max(previous + D.ringStep, depth === 1 ? D.ring1 : 0);
            for (var guard = 0; guard < 6000; guard++) {
                ring.forEach(function (m) {
                    m.off = { x: Math.cos(m.angle) * r, y: Math.sin(m.angle) * r };
                    m.rect = shift(m.box, m.off.x, m.off.y);
                });
                var clash = false;
                for (var i = 0; i < ring.length && !clash; i++) {
                    for (var j = 0; j < placed.length && !clash; j++) if (touches(ring[i].rect, placed[j], D.ringGap)) clash = true;
                    for (var k = 0; k < i && !clash; k++) if (touches(ring[i].rect, ring[k].rect, D.ringGap)) clash = true;
                }
                if (!clash) break;
                r += 10 + Math.floor(guard / 60) * 10;
            }
            ring.forEach(function (m) { placed.push(m.rect); });
            previous = r;
        }
        var box = rect(owner);
        members.forEach(function (m) {
            var parentOff = m.parent.off;
            m.item.rel = { x: m.off.x - parentOff.x, y: m.off.y - parentOff.y };
            box = union(box, m.rect);
        });
        return box;
    }

    function sizeOf(opts, item, isRoot) {
        var s = null;
        try { s = typeof opts.size === 'function' ? opts.size(item.node) : null; } catch (e) { s = null; }
        if (!s || !(s.w > 0) || !(s.h > 0) || !isFinite(s.w) || !isFinite(s.h)) s = estimateSize(item.node, isRoot);
        return s;
    }

    /** compute({nodes, layouts, size}) -> {positions: {id: {x, y}}, bounds: {l, t, r, b}} */
    function compute(opts) {
        opts = opts || {};
        var model = build(opts);
        if (!model) return { positions: {}, bounds: { l: 0, t: 0, r: 0, b: 0 } };
        model.items.forEach(function (item) {
            var s = sizeOf(opts, item, item === model.root);
            item.w = s.w;
            item.h = s.h;
        });
        arrange(model.root, model.root.eff);
        var abs = new Map();
        var positions = {}, bounds = null;
        model.order.forEach(function (item) {
            var base = item.parent ? abs.get(item.parent) : { x: 0, y: 0 };
            var p = item.manual ? { x: item.x, y: item.y } : { x: base.x + item.rel.x, y: base.y + item.rel.y };
            abs.set(item, p);
            var out = item.manual ? { x: p.x, y: p.y } : { x: Math.round(p.x) || 0, y: Math.round(p.y) || 0 };
            positions[item.id] = out;
            bounds = union(bounds, { l: out.x - item.w / 2, t: out.y - item.h / 2, r: out.x + item.w / 2, b: out.y + item.h / 2 });
        });
        return { positions: positions, bounds: bounds };
    }

    /** The layout that arranges the children of a node: its own, else the nearest ancestor's, else balanced. */
    function effectiveLayout(nodes, id, layouts) {
        var model = build({ nodes: nodes, layouts: layouts });
        if (!model) return 'balanced';
        var item = model.byId.get(String(id));
        return item ? item.eff : 'balanced';
    }

    return { PRESETS: PRESETS, compute: compute, effectiveLayout: effectiveLayout, estimateSize: estimateSize, isManual: isManual };
});
