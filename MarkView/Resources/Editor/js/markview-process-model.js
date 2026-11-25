(function(P) {
    function element(tag, className, text) {
        const node = document.createElement(tag);
        if (className) node.className = className;
        if (text !== undefined) node.textContent = text;
        return node;
    }

    function button(text, action, className) {
        const node = element('button', className || 'arch-btn', text);
        node.type = 'button';
        node.addEventListener('click', action);
        return node;
    }

    function index(graph) {
        return new Map((graph.nodes || []).map(function(node) { return [node.id, node]; }));
    }

    function children(graph, parent) {
        return graph.nodes.filter(function(node) { return (node.parent || null) === (parent || null); });
    }

    function within(byID, id, ancestor) {
        const seen = new Set();
        for (let node = byID.get(id); node && !seen.has(node.id); node = byID.get(node.parent)) {
            if (node.id === ancestor) return true;
            seen.add(node.id);
        }
        return false;
    }

    function ancestors(graph, id) {
        const byID = index(graph), result = [], seen = new Set();
        for (let node = byID.get(id); node && !seen.has(node.id); node = byID.get(node.parent)) {
            result.unshift(node);
            seen.add(node.id);
        }
        return result;
    }

    function relations(graph, level, selected) {
        const byID = index(graph), incoming = [], outgoing = [], seen = new Set();
        function add(edge, boundary) {
            const from = boundary ? within(byID, edge.from, selected) : edge.from === selected;
            const to = boundary ? within(byID, edge.to, selected) : edge.to === selected;
            if (from && !seen.has('out|' + edge.id)) {
                outgoing.push({ edge: edge, other: edge.to, boundary: boundary });
                seen.add('out|' + edge.id);
            }
            if (to && !seen.has('in|' + edge.id)) {
                incoming.push({ edge: edge, other: edge.from, boundary: boundary });
                seen.add('in|' + edge.id);
            }
        }
        (level.edges || []).forEach(function(edge) { add(edge, false); });
        (level.boundary || []).forEach(function(edge) { add(edge, true); });
        return { incoming: incoming, outgoing: outgoing };
    }

    function bundle(edges) {
        const groups = new Map();
        edges.forEach(function(edge) {
            const key = JSON.stringify([edge.from, edge.to, edge.kind]);
            let group = groups.get(key);
            if (!group) {
                group = Object.assign({}, edge, { members: [], labels: [] });
                groups.set(key, group);
            }
            group.members.push(edge.id);
            if (group.labels.indexOf(edge.label) < 0) group.labels.push(edge.label);
        });
        return Array.from(groups.values()).map(function(group) {
            group.label = group.labels.length === 1 ? group.labels[0] : group.labels.length + ' conditions';
            group.fullLabel = group.labels.join('; ');
            return group;
        });
    }

    function isStale(scenario, snapshot) {
        const modules = (snapshot.views || []).find(function(view) { return view.id === 'modules'; });
        if (!modules) return false;
        const signatures = new Map(modules.nodes.filter(function(node) { return node.path; })
            .map(function(node) { return [node.path, node.signature]; }));
        return Object.keys(scenario.signatures || {}).some(function(path) {
            return signatures.get(path) !== scenario.signatures[path];
        });
    }

    function levelKey(scenario, parent) { return scenario.id + '|' + (parent || ''); }
    function sourceKey(scenario, node, source) { return scenario.id + '|' + node.id + '|' + source; }

    Object.assign(P, { element: element, button: button, index: index, children: children, ancestors: ancestors,
        relations: relations, bundle: bundle, isStale: isStale, levelKey: levelKey, sourceKey: sourceKey });
})(window['MVProcess'] = {});
