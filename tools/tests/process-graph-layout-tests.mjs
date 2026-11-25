import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import vm from 'node:vm';

const root = new URL('../../', import.meta.url);
const window = globalThis;
globalThis.window = window;
// elk checks array identity, use the same realm as the shipped layout library
for (const file of ['markview-process-model.js', 'markview-process-layout.js']) {
    vm.runInThisContext(readFileSync(new URL('MarkView/Resources/Editor/js/' + file, root), 'utf8'), { filename: file });
}
const P = window.MVProcess;
const ELK = createRequire(import.meta.url)('../../MarkView/Resources/Editor/vendor/js/elk.bundled.js');
let checks = 0;
function check(value, message) { assert.ok(value, message); checks++; }
function edge(from, to, kind = 'next', label = 'Pass result') { return { id: from + '-' + to, from, to, kind, label, sources: [] }; }
function fixture() {
    const nodes = Array.from({ length: 14 }, (_, i) => ({ id: String(i + 1), title: 'Block ' + (i + 1), kind: 'action' }));
    const edges = [edge('1', '2', 'parallel'), edge('1', '3', 'parallel'), edge('1', '4', 'parallel'),
        edge('2', '5'), edge('3', '5'), edge('3', '6'), edge('4', '6'), edge('5', '7'), edge('6', '7'),
        edge('7', '8', 'branch', 'Allowed'), edge('7', '9', 'branch', 'Needs review'), edge('7', '10', 'branch', 'Denied'),
        edge('8', '11', 'parallel'), edge('8', '12', 'parallel'), edge('11', '13'), edge('12', '13'), edge('13', '14'),
        edge('13', '8', 'return', 'Temporary failure, at most two retries'), edge('13', '6', 'return', 'Plan requires revision')];
    return { nodes, edges, boundary: [] };
}
function crosses(a, b, box) {
    const left = box.x + 0.5, right = box.x + box.width - 0.5;
    const top = box.y + 0.5, bottom = box.y + box.height - 0.5;
    if (Math.abs(a.x - b.x) < 0.01) return a.x > left && a.x < right && Math.max(a.y, b.y) > top && Math.min(a.y, b.y) < bottom;
    return a.y > top && a.y < bottom && Math.max(a.x, b.x) > left && Math.min(a.x, b.x) < right;
}
async function verify(level, direction) {
    const result = await P.layout(level, new ELK(), direction);
    check(result.nodes.size === level.nodes.length, 'Every block receives a position');
    check(Number.isFinite(result.width) && Number.isFinite(result.height), 'The graph has finite bounds');
    const nodes = [...result.nodes.entries()];
    for (let i = 0; i < nodes.length; i++) for (let j = i + 1; j < nodes.length; j++) {
        const a = nodes[i][1], b = nodes[j][1];
        assert.ok(a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y,
            'Blocks overlap: ' + nodes[i][0] + ' and ' + nodes[j][0]);
    }
    checks++;
    for (const route of result.edges) {
        if (route.labelBox) check(Object.values(route.labelBox).filter(value => typeof value === 'number').every(Number.isFinite), 'Label position is finite');
        for (const section of route.sections) for (let i = 1; i < section.length; i++) {
            const a = section[i - 1], b = section[i];
            assert.ok(a.x === b.x || a.y === b.y, 'The route is orthogonal: ' + route.id);
            for (const [id, box] of nodes) assert.ok(!crosses(a, b, box), 'Route ' + route.id + ' crosses block ' + id + ' in ' + direction);
        }
    }
    checks++;
    return result;
}

for (const direction of ['RIGHT', 'DOWN']) {
    const graph = fixture();
    const result = await verify(graph, direction);
    check(result.edges.filter(edge => edge.kind === 'return').length === 2, 'Both feedback paths remain visible');
    check(result.edges.filter(edge => edge.from === '1').length === 3, 'The first fork retains all three paths');
    check(result.edges.filter(edge => edge.to === '13' && edge.kind !== 'return').length === 2, 'The join retains both incoming tasks');
    const repeated = await P.layout(graph, new ELK(), direction);
    assert.equal(JSON.stringify([...repeated.nodes]), JSON.stringify([...result.nodes]), 'Layout is deterministic'); checks++;
    graph.edges.push({ ...edge('7', '8', 'branch', 'Alternative admission rule'), id: 'additional-rule' });
    const bundled = await verify(graph, direction);
    const admission = bundled.edges.find(edge => edge.from === '7' && edge.to === '8');
    check(admission.members.length === 2 && admission.fullLabel.includes('Alternative admission rule'), 'Bundling preserves distinct conditions');
    graph.edges.push(edge('8', '8', 'return', 'Retry the same stage'));
    await verify(graph, direction);
}

for (const direction of ['RIGHT', 'DOWN']) {
    const nodes = Array.from({ length: 24 }, (_, i) => ({ id: 'n' + i, title: 'Stage ' + i, kind: 'action' }));
    const edges = nodes.slice(1).map((node, i) => edge(nodes[i].id, node.id));
    for (let i = 0; i < 20; i += 3) edges.push(edge('n' + i, 'n' + (i + 3), 'branch', 'Condition ' + i));
    edges.push(edge('n23', 'n4', 'return'), edge('n21', 'n0', 'return'), edge('n18', 'n9', 'return'));
    await verify({ nodes, edges }, direction);
}

const graph = fixture();
const relations = P.relations(graph, graph, '13');
check(relations.incoming.length === 2 && relations.outgoing.length === 3, 'The inspector exposes the join, continuation and both returns');
const nested = { nodes: [{ id: 'group' }, { id: 'child', parent: 'group' }, { id: 'outside' }] };
const boundary = { edges: [], boundary: [edge('child', 'outside')] };
check(P.relations(nested, boundary, 'group').outgoing.length === 1, 'A collapsed child retains its external connection');
check(P.ancestors(nested, 'child').map(node => node.id).join('/') === 'group/child', 'Breadcrumbs retain the parent chain');
const scenario = { id: 'saved', signatures: { 'flow.py': 'v1' } };
check(!P.isStale(scenario, { views: [{ id: 'modules', nodes: [{ path: 'flow.py', signature: 'v1' }, { path: 'other.py', signature: 'v2' }] }] }), 'Unrelated source changes keep the map current');
check(P.isStale(scenario, { views: [{ id: 'modules', nodes: [] }] }), 'A removed source makes the map stale');
check(P.sourceKey(scenario, { id: 'child' }, 2) === 'saved|child|2', 'Source selection uses the native cache key');
console.log(checks + ' process graph checks passed');
