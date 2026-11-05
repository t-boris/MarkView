// Standalone check of the research map layout engine (DEC-007): the seven presets, inheritance, nested layouts, manual
// positions and the guarantee that no two node boxes overlap. Run with tools/tests/research-map-layout-tests.sh (node, no packages).
'use strict';
const assert = require('node:assert');
const L = require('../../MarkView/Resources/Editor/vendor/js/markview-research-map-layout.js');

let failures = 0;
function check(name, ok, detail) {
    if (ok) console.log('ok   ' + name);
    else { failures++; console.log('FAIL ' + name + (detail ? ' ' + detail : '')); }
}
function checkEqual(name, actual, expected) {
    try { assert.deepStrictEqual(actual, expected); console.log('ok   ' + name); }
    catch (e) { failures++; console.log('FAIL ' + name + ' got ' + JSON.stringify(actual).slice(0, 300) + ' want ' + JSON.stringify(expected).slice(0, 300)); }
}

// ---- generators ------------------------------------------------------------------------------------------------------
function rng(seed) {
    let a = seed >>> 0;
    return function () {
        a = (a + 0x6D2B79F5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}
function node(id, parent, title, extra) { return Object.assign({ id: id, parent: parent, title: title, layout: '', x: null, y: null }, extra || {}); }
function single() { return [node('n1', '', 'Only node')]; }
function chain(n) {
    const out = [node('n1', '', 'Root of a long chain')];
    for (let i = 2; i <= n; i++) out.push(node('n' + i, 'n' + (i - 1), 'Step ' + i + ' of the chain'));
    return out;
}
function fan(n) {
    const out = [node('n1', '', 'Central question')];
    for (let i = 2; i <= n + 1; i++) out.push(node('n' + i, 'n1', 'Child number ' + (i - 1) + (i % 3 === 0 ? ' with a rather long descriptive title' : '')));
    return out;
}
function mixed(count, seed) {
    const random = rng(seed);
    const out = [node('n1', '', 'What is the best way to organise the research?')];
    const depth = { n1: 0 };
    for (let i = 2; i <= count; i++) {
        let parent;
        do { parent = out[Math.floor(random() * out.length)]; } while (depth[parent.id] >= 3 && random() < 0.8);
        const words = 1 + Math.floor(random() * 9);
        const title = Array.from({ length: words }, function () { return 'w'.repeat(2 + Math.floor(random() * 8)); }).join(' ');
        out.push(node('n' + i, parent.id, title));
        depth['n' + i] = depth[parent.id] + 1;
    }
    return out;
}
/** Seven branches, each with its own layout and its own subtree; one of them contains a nested branch with another layout. */
function nested() {
    const out = [node('r', '', 'Root of a map with nested layouts')];
    const presets = ['balanced', 'right', 'left', 'down', 'up', 'radial', 'outline'];
    presets.forEach(function (preset, i) {
        const id = 'b' + i;
        out.push(node(id, 'r', 'Branch ' + preset, { layout: preset }));
        for (let k = 0; k < 4; k++) {
            out.push(node(id + 'c' + k, id, 'Child ' + k + ' of ' + preset));
            if (k < 2) for (let g = 0; g < 2; g++) out.push(node(id + 'c' + k + 'g' + g, id + 'c' + k, 'Grandchild ' + g + ' under child ' + k));
        }
    });
    out.push(node('deep', 'b5c1', 'A nested branch laid out to the right', { layout: 'right' }));
    for (let k = 0; k < 3; k++) out.push(node('deep' + k, 'deep', 'Nested leaf number ' + k));
    out.push(node('deeper', 'b3c0', 'A nested radial branch', { layout: 'radial' }));
    for (let k = 0; k < 5; k++) out.push(node('deeper' + k, 'deeper', 'Radial leaf ' + k));
    return out;
}

// ---- measuring helpers -----------------------------------------------------------------------------------------------
const sizers = {
    estimate: function (n) { return L.estimateSize(n, n.parent === ''); },
    big: function () { return { w: 220, h: 90 }; },
    varied: function (n) {
        let h = 0;
        for (const ch of n.id) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
        return { w: 110 + (h % 111), h: 40 + ((h >>> 8) % 51) };
    }
};
function boxes(positions, nodes, size) {
    return nodes.map(function (n) {
        const p = positions[n.id], s = size(n);
        return { id: n.id, l: p.x - s.w / 2, t: p.y - s.h / 2, r: p.x + s.w / 2, b: p.y + s.h / 2 };
    });
}
/** The closest pair: negative when two boxes overlap. */
function tightest(positions, nodes, size) {
    const bs = boxes(positions, nodes, size);
    let worst = { gap: Infinity, pair: '' };
    for (let i = 0; i < bs.length; i++) {
        for (let j = i + 1; j < bs.length; j++) {
            const a = bs[i], b = bs[j];
            const gx = Math.max(a.l - b.r, b.l - a.r), gy = Math.max(a.t - b.b, b.t - a.b);
            const gap = Math.max(gx, gy);
            if (gap < worst.gap) worst = { gap: gap, pair: a.id + '/' + b.id };
        }
    }
    return worst;
}
function run(nodes, size, extra) { return L.compute(Object.assign({ nodes: nodes, size: size }, extra || {})); }
function withLayout(nodes, id, layout) { return nodes.map(function (n) { return n.id === id ? Object.assign({}, n, { layout: layout }) : n; }); }
function withRootLayout(nodes, layout) { return withLayout(nodes, nodes[0].id, layout); }
function byId(nodes) { const m = {}; nodes.forEach(function (n) { m[n.id] = n; }); return m; }
function descendants(nodes, id) {
    const out = [id];
    for (let i = 0; i < out.length; i++) nodes.forEach(function (n) { if (n.parent === out[i] && out.indexOf(n.id) < 0) out.push(n.id); });
    return out;
}
function topAncestor(nodes, id) {
    const m = byId(nodes);
    let cur = m[id];
    while (cur.parent && m[cur.parent].parent) cur = m[cur.parent];
    return cur;
}
const MIN_GAP = 8;

// ---- 1. no overlaps, determinism, full coverage in every preset ------------------------------------------------------
const trees = { 'single node': single(), 'deep chain (30)': chain(30), 'fan of 12': fan(12), '60 mixed nodes': mixed(60, 7), 'another 60': mixed(60, 99), '30 mixed nodes': mixed(30, 3) };
L.PRESETS.forEach(function (preset) {
    Object.keys(trees).forEach(function (name) {
        const nodes = withRootLayout(trees[name], preset);
        let worst = { gap: Infinity, pair: '' }, deterministic = true, complete = true, sizeName = '';
        Object.keys(sizers).forEach(function (key) {
            const size = sizers[key];
            const first = run(nodes, size), second = run(nodes, size);
            try { assert.deepStrictEqual(first, second); } catch (e) { deterministic = false; }
            nodes.forEach(function (n) {
                const p = first.positions[n.id];
                if (!p || !Number.isFinite(p.x) || !Number.isFinite(p.y)) complete = false;
            });
            const t = tightest(first.positions, nodes, size);
            if (t.gap < worst.gap) { worst = t; sizeName = key; }
        });
        check(preset + ' / ' + name + ': no two boxes touch (closest ' + (worst.gap === Infinity ? 'n/a' : Math.round(worst.gap) + 'px') + ')',
              worst.gap >= MIN_GAP, worst.pair + ' with ' + sizeName + ' sizes');
        check(preset + ' / ' + name + ': deterministic and every node placed', deterministic && complete);
    });
});

// ---- 2. every preset has the shape its name promises ----------------------------------------------------------------
(function shapes() {
    const nodes = mixed(60, 7);
    const size = sizers.estimate;
    const m = byId(nodes);
    function each(pos, test) { return nodes.filter(function (n) { return n.parent; }).every(function (n) { return test(n, pos[n.id], pos[n.parent]); }); }
    const pos = function (preset) { return run(withRootLayout(nodes, preset), size).positions; };

    check('right: every child is right of its parent', each(pos('right'), function (n, p, q) { return p.x > q.x; }));
    check('left: every child is left of its parent', each(pos('left'), function (n, p, q) { return p.x < q.x; }));
    check('down: every child is below its parent', each(pos('down'), function (n, p, q) { return p.y > q.y; }));
    check('up: every child is above its parent', each(pos('up'), function (n, p, q) { return p.y < q.y; }));
    check('right: the level spacing is at least the prototype\'s 230', each(pos('right'), function (n, p, q) { return p.x - q.x >= 230; }));

    const balanced = pos('balanced');
    const tops = nodes.filter(function (n) { return n.parent === 'n1'; });
    check('balanced: root children alternate right, left, right, left',
          tops.every(function (n, i) { return i % 2 === 0 ? balanced[n.id].x > 0 : balanced[n.id].x < 0; }));
    check('balanced: deeper levels continue away from the root on their side',
          nodes.filter(function (n) { return n.parent && n.parent !== 'n1'; }).every(function (n) {
              const side = Math.sign(balanced[topAncestor(nodes, n.id).id].x);
              return Math.sign(balanced[n.id].x - balanced[n.parent].x) === side;
          }));
    const rightCount = tops.filter(function (n) { return balanced[n.id].x > 0; }).length;
    check('balanced: both sides are used about equally', Math.abs(rightCount - (tops.length - rightCount)) <= 1);

    const radial = pos('radial');
    const dist = function (id) { return Math.hypot(radial[id].x, radial[id].y); };
    check('radial: every level is on a wider ring than its parent', nodes.filter(function (n) { return n.parent; }).every(function (n) { return dist(n.id) > dist(n.parent) + 100; }));
    const levelOf = function (id) { let d = 0; for (let c = m[id]; c.parent; c = m[c.parent]) d++; return d; };
    const ringRadius = {};
    nodes.forEach(function (n) { const d = levelOf(n.id); (ringRadius[d] = ringRadius[d] || []).push(dist(n.id)); });
    check('radial: the nodes of one level share one ring',
          Object.keys(ringRadius).every(function (d) { const r = ringRadius[d]; return Math.max.apply(null, r) - Math.min.apply(null, r) < 2; }));
    check('radial: the root children surround the root (not all on one side)',
          tops.some(function (n) { return radial[n.id].x > 0; }) && tops.some(function (n) { return radial[n.id].x < 0; }) &&
          tops.some(function (n) { return radial[n.id].y > 0; }) && tops.some(function (n) { return radial[n.id].y < 0; }));
    const leaves = function (id) {
        const kids = nodes.filter(function (k) { return k.parent === id; });
        return kids.length ? kids.reduce(function (s, k) { return s + leaves(k.id); }, 0) : 1;
    };
    const totalLeaves = tops.reduce(function (s, t) { return s + leaves(t.id); }, 0);
    check('radial: a subtree stays inside the sector of its branch (sectors follow subtree size)', tops.every(function (top) {
        const a = Math.atan2(radial[top.id].y, radial[top.id].x), half = Math.PI * leaves(top.id) / totalLeaves + 0.03;
        return descendants(nodes, top.id).every(function (id) {
            let d = Math.atan2(radial[id].y, radial[id].x) - a;
            while (d > Math.PI) d -= 2 * Math.PI;
            while (d < -Math.PI) d += 2 * Math.PI;
            return Math.abs(d) <= half;
        });
    }));

    const outline = pos('outline');
    const sizeOf = function (id) { return size(m[id]); };
    check('outline: every child is below its parent and indented', each(outline, function (n, p, q) {
        return p.y > q.y && (p.x - sizeOf(n.id).w / 2) > (q.x - sizeOf(n.parent).w / 2) + 20;
    }));
    check('outline: siblings keep their order from top to bottom', nodes.every(function (n) {
        const kids = nodes.filter(function (k) { return k.parent === n.id; });
        return kids.every(function (k, i) { return i === 0 || outline[k.id].y > outline[kids[i - 1].id].y; });
    }));
    check('outline: the first row follows the root directly', outline['n2'].y - outline['n1'].y < 120);
})();

// ---- 3. inheritance, root default and unknown ids --------------------------------------------------------------------
(function inheritance() {
    const nodes = mixed(40, 21);
    const size = sizers.estimate;
    const plain = run(nodes, size).positions;
    checkEqual('the root defaults to balanced', run(withRootLayout(nodes, 'balanced'), size).positions, plain);
    checkEqual('an empty layout string means no layout', run(withRootLayout(nodes, ''), size).positions, plain);
    checkEqual('an unknown layout id on the root is ignored', run(withRootLayout(nodes, 'spiral'), size).positions, plain);
    checkEqual('an unknown layout id on a branch is ignored: the branch inherits',
               run(withLayout(withRootLayout(nodes, 'right'), 'n5', 'zigzag'), size).positions, run(withRootLayout(nodes, 'right'), size).positions);
    checkEqual('a non-string layout is ignored', run(withRootLayout(nodes, 5), size).positions, plain);
    const restricted = run(withRootLayout(nodes, 'radial'), size, { layouts: [{ id: 'balanced', name: 'Balanced' }, { id: 'right', name: 'Right' }] }).positions;
    checkEqual('with a layouts list, an id missing from it is ignored', restricted, plain);
    checkEqual('with a full layouts list the preset applies',
               run(withRootLayout(nodes, 'radial'), size, { layouts: L.PRESETS.map(function (id) { return { id: id, name: id }; }) }).positions,
               run(withRootLayout(nodes, 'radial'), size).positions);

    check('effectiveLayout: root default', L.effectiveLayout(nodes, 'n1') === 'balanced');
    check('effectiveLayout: inherited from the root', L.effectiveLayout(withRootLayout(nodes, 'down'), 'n9') === 'down');
    const tree = withLayout(withRootLayout(nodes, 'down'), 'n3', 'left');
    check('effectiveLayout: the branch\'s own beats the ancestor\'s', L.effectiveLayout(tree, 'n3') === 'left');
    const underN3 = descendants(tree, 'n3').slice(1);
    check('effectiveLayout: a descendant of the branch takes the branch\'s layout', underN3.length === 0 || underN3.every(function (id) { return L.effectiveLayout(tree, id) === 'left'; }));
    check('effectiveLayout: an unknown id falls back to balanced', L.effectiveLayout(nodes, 'missing') === 'balanced');

    // Root 'right', branch A 'down': A's whole subtree grows downwards, the other branches grow to the right.
    const t = [node('r', '', 'Root', { layout: 'right' }), node('a', 'r', 'Branch A', { layout: 'down' }), node('b', 'r', 'Branch B'),
               node('a1', 'a', 'A1'), node('a2', 'a', 'A2'), node('a11', 'a1', 'A11'), node('b1', 'b', 'B1'), node('b11', 'b1', 'B11')];
    const p = run(t, size).positions;
    check('a branch with its own layout arranges all its descendants (down)', p.a1.y > p.a.y && p.a2.y > p.a.y && p.a11.y > p.a1.y && p.a11.x - p.a1.x < 230);
    check('the branch node itself is placed by its parent\'s layout (right)', p.a.x > p.r.x && p.b.x > p.r.x);
    check('branches without a layout use the root\'s (right)', p.b1.x > p.b.x && p.b11.x > p.b1.x);
    check('nothing overlaps in the mixed tree', tightest(p, t, size).gap >= MIN_GAP);
})();

// ---- 4. nested layouts ------------------------------------------------------------------------------------------------
(function nestedLayouts() {
    const nodes = nested();
    Object.keys(sizers).forEach(function (key) {
        const r = run(nodes, sizers[key]);
        const t = tightest(r.positions, nodes, sizers[key]);
        check('nested layouts (' + key + ' sizes): no two boxes touch (closest ' + Math.round(t.gap) + 'px)', t.gap >= MIN_GAP, t.pair);
    });
    const p = run(nodes, sizers.estimate).positions;
    check('nested: a branch laid out "right" inside a radial branch grows to the right', ['deep0', 'deep1', 'deep2'].every(function (id) { return p[id].x > p.deep.x; }));
    check('nested: a radial branch inside a "down" branch surrounds its node', (function () {
        const xs = [0, 1, 2, 3, 4].map(function (k) { return p['deeper' + k].x - p.deeper.x; }), ys = [0, 1, 2, 3, 4].map(function (k) { return p['deeper' + k].y - p.deeper.y; });
        return xs.some(function (x) { return x > 0; }) && xs.some(function (x) { return x < 0; }) && ys.some(function (y) { return y > 0; }) && ys.some(function (y) { return y < 0; });
    })());
    check('nested: the "down" branch grows downwards', p.b3c0.y > p.b3.y && p.b3c0g0.y > p.b3c0.y);
    check('nested: the "up" branch grows upwards', p.b4c0.y < p.b4.y);
    check('nested: the "left" branch grows to the left', p.b2c0.x < p.b2.x);
    check('nested: the "outline" branch is a list below its node', p.b6c0.y > p.b6.y && p.b6c1.y > p.b6c0.y);
    check('nested: the layout of a branch does not move its siblings\' descendants', (function () {
        const base = run(nodes, sizers.estimate).positions;
        const changed = run(withLayout(nodes, 'b0', 'down'), sizers.estimate).positions;
        // Different positions for b0's subtree are expected; every other branch keeps its shape relative to its own node.
        return ['b1', 'b2', 'b5', 'b6'].every(function (b) {
            return descendants(nodes, b).every(function (id) {
                return Math.abs((base[id].x - base[b].x) - (changed[id].x - changed[b].x)) <= 1 && Math.abs((base[id].y - base[b].y) - (changed[id].y - changed[b].y)) <= 1;
            });
        });
    })());
})();

// ---- 5. manual positions ----------------------------------------------------------------------------------------------
L.PRESETS.forEach(function (preset) {
    const nodes = withRootLayout(mixed(40, 5), preset);
    const size = sizers.estimate;
    const base = run(nodes, size).positions;
    const branch = nodes.filter(function (n) { return n.parent === 'n1'; })[1].id;
    const target = { x: base[branch].x + 3000, y: base[branch].y + 2600 };
    const moved = nodes.map(function (n) { return n.id === branch ? Object.assign({}, n, target) : n; });
    const r = run(moved, size).positions;
    const subtree = descendants(moved, branch);
    check(preset + ' manual: the node is exactly where it was put', r[branch].x === target.x && r[branch].y === target.y);
    check(preset + ' manual: its descendants keep their layout relative to it', subtree.every(function (id) {
        return Math.abs((r[id].x - r[branch].x) - (base[id].x - base[branch].x)) <= 1 && Math.abs((r[id].y - r[branch].y) - (base[id].y - base[branch].y)) <= 1;
    }));
    check(preset + ' manual: nothing else moves', nodes.every(function (n) { return subtree.indexOf(n.id) >= 0 || (r[n.id].x === base[n.id].x && r[n.id].y === base[n.id].y); }));
    check(preset + ' manual: the moved branch overlaps nothing', tightest(r, moved, size).gap >= MIN_GAP);

    // A manual node inside a moved branch: it is exactly there, its own children follow it.
    const inner = subtree.filter(function (id) { return id !== branch && moved.some(function (n) { return n.parent === id; }); })[0];
    if (inner) {
        const spot = { x: r[inner].x - 40, y: r[inner].y + 9000 };
        const twice = moved.map(function (n) { return n.id === inner ? Object.assign({}, n, spot) : n; });
        const q = run(twice, size).positions;
        check(preset + ' manual: a manual node inside a moved branch is exactly there', q[inner].x === spot.x && q[inner].y === spot.y);
        check(preset + ' manual: and its children follow it', descendants(twice, inner).every(function (id) {
            return Math.abs((q[id].x - spot.x) - (r[id].x - r[inner].x)) <= 1 && Math.abs((q[id].y - spot.y) - (r[id].y - r[inner].y)) <= 1;
        }));
    }
});
(function manualRoot() {
    const nodes = mixed(20, 2), size = sizers.estimate;
    const base = run(nodes, size).positions;
    const moved = nodes.map(function (n, i) { return i === 0 ? Object.assign({}, n, { x: 500, y: -300 }) : n; });
    const r = run(moved, size).positions;
    check('manual root: it is where it was put and the whole map follows', r.n1.x === 500 && r.n1.y === -300 &&
          nodes.every(function (n) { return r[n.id].x - 500 === base[n.id].x && r[n.id].y + 300 === base[n.id].y; }));
    const half = nodes.map(function (n, i) { return i === 1 ? Object.assign({}, n, { x: 10 }) : n; });
    checkEqual('a node with only x or only y is not manual', run(half, size).positions, base);
    const strings = nodes.map(function (n, i) { return i === 1 ? Object.assign({}, n, { x: '10', y: '20' }) : n; });
    checkEqual('coordinates that are not numbers are not manual', run(strings, size).positions, base);
    const zero = nodes.map(function (n, i) { return i === 1 ? Object.assign({}, n, { x: 0, y: 0 }) : n; });
    check('a manual position of 0, 0 counts', run(zero, size).positions.n2.x === 0 && run(zero, size).positions.n2.y === 0);
})();

// ---- 6. odd input ------------------------------------------------------------------------------------------------------
(function oddInput() {
    checkEqual('no nodes: nothing to place', L.compute({ nodes: [] }).positions, {});
    checkEqual('no arguments: nothing to place', L.compute().positions, {});
    checkEqual('a single node sits at the origin', run(single(), sizers.estimate).positions, { n1: { x: 0, y: 0 } });
    const orphan = [node('r', '', 'Root'), node('a', 'gone', 'Orphan'), node('b', 'r', 'Child')];
    const p = run(orphan, sizers.estimate).positions;
    check('a node whose parent is missing hangs from the root', Object.keys(p).length === 3 && tightest(p, orphan, sizers.estimate).gap >= MIN_GAP);
    const cycle = [node('r', '', 'Root'), node('a', 'b', 'A'), node('b', 'a', 'B'), node('c', 'a', 'C')];
    const q = run(cycle, sizers.estimate).positions;
    check('a parent cycle does not hang or lose nodes', Object.keys(q).length === 4 && tightest(q, cycle, sizers.estimate).gap >= MIN_GAP);
    const dup = [node('r', '', 'Root'), node('a', 'r', 'First'), node('a', 'r', 'Second')];
    check('a repeated id is placed once', Object.keys(run(dup, sizers.estimate).positions).length === 2);
    const noSize = L.compute({ nodes: fan(5) }).positions;
    check('without a size function the estimate is used', Object.keys(noSize).length === 6);
    const badSize = L.compute({ nodes: fan(5), size: function () { return { w: 0, h: NaN }; } }).positions;
    checkEqual('a size function that returns nonsense falls back to the estimate', badSize, noSize);
    const throwing = L.compute({ nodes: fan(5), size: function () { throw new Error('no'); } }).positions;
    checkEqual('a size function that throws falls back to the estimate', throwing, noSize);
    const two = [node('r', '', 'Root'), node('x', '', 'Second root')];
    check('a second node without a parent hangs from the root', run(two, sizers.estimate).positions.x.x !== run(two, sizers.estimate).positions.r.x);
    const sizes = [L.estimateSize({ title: '' }, false), L.estimateSize({ title: 'x'.repeat(300) }, false), L.estimateSize({ title: 'Root title' }, true)];
    check('estimateSize stays within the node\'s min and max width', sizes[0].w === 110 && sizes[1].w === 220 && sizes[2].w >= 170 && sizes[1].h > sizes[0].h);
    const big = mixed(300, 11);
    const started = Date.now();
    const bigResult = run(withRootLayout(big, 'radial'), sizers.estimate);
    const elapsed = Date.now() - started;
    check('300 nodes in a radial layout: no overlap and fast enough (' + elapsed + ' ms)', tightest(bigResult.positions, big, sizers.estimate).gap >= MIN_GAP && elapsed < 4000);
    const result = run(fan(3), sizers.estimate);
    check('compute also returns the bounds of the map', result.bounds && result.bounds.r > result.bounds.l && result.bounds.b > result.bounds.t);
    check('positions are whole numbers', Object.keys(bigResult.positions).every(function (id) { return Number.isInteger(bigResult.positions[id].x) && Number.isInteger(bigResult.positions[id].y); }));
})();

console.log(failures === 0 ? 'ALL OK' : failures + ' FAILED');
process.exit(failures === 0 ? 0 : 1);
