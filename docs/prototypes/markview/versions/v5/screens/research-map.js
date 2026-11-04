(function () {
  'use strict';
  var h = App.h;
  App.addStyles('.app-shell:has(.app-main[data-screen="research-map"]) .app-nav,.app-shell:has(.app-main[data-screen="research-map"]) .app-menu-toggle{display:none}.research-workspace{display:grid;grid-template-columns:minmax(0,2fr) minmax(250px,1fr);gap:20px;align-items:start}.research-tree,.research-practices{min-width:0}.research-canvas{overflow:auto;margin:18px -20px 0;border-top:1px solid #dce3e8;background-color:#f8faf9;background-image:radial-gradient(#dce7e5 1px,transparent 1px);background-size:20px 20px}.research-graph{position:relative;min-height:460px}.research-graph svg{position:absolute;inset:0;pointer-events:none}.research-graph-node{position:absolute;width:180px;min-height:58px;display:flex;align-items:center;gap:3px}.research-graph-node .research-select{flex:1;min-width:0;min-height:54px;white-space:normal;overflow-wrap:anywhere;text-align:center;box-shadow:0 3px 12px #253b4914}.research-graph-node .research-select[aria-pressed=true]{background:#e4f1ef;border-color:#286d70;box-shadow:0 0 0 2px #9bc8c5}.research-graph-node .research-add{flex:none;padding:5px;min-height:32px}.research-links{margin:0;padding-top:18px;border-top:1px solid #dce3e8}.research-links ul{padding-left:20px}.research-links li{margin:8px 0}.research-practices p{overflow-wrap:anywhere}@media(max-width:760px){.research-workspace{grid-template-columns:1fr}.research-graph{min-height:380px}}');
  App.register({ id: 'research-map', route: '/research/:id', title: 'Карта исследования', render: function (ctx) {
    return App.load(function () {
      var research = DB.get('Research', ctx.params.id);
      if (!research || ctx.proto.empty) return App.empty({ title: 'Исследование не найдено', text: 'Откройте существующее исследование или создайте новое.', action: { label: 'Новое исследование', onClick: function () { App.navigate('/research/new'); } } });
      var nodes = DB.list('Node', { filter: { researchId: research.id } }).items;
      var links = DB.list('Connection', { filter: { researchId: research.id } }).items;
      var selected = App.store('selected-node:' + research.id);
      if (!nodes.some(function (node) { return node.id === selected; })) selected = nodes.length ? nodes[0].id : '';
      function nodeName(id) { var node = nodes.filter(function (item) { return item.id === id; })[0]; return node ? node.title : 'Удалённый узел'; }
      function addChild(parent) {
        var input = h('input', { class: 'input', maxlength: '120', 'aria-label': 'Название дочернего узла' });
        var error = h('p', { class: 'field-error', role: 'alert' });
        App.modal({ title: 'Добавить дочерний узел', body: h('div', null, h('p', null, 'Родительский узел: ' + parent.title), input, error), actions: [
          { label: 'Отмена', kind: 'ghost' }, { label: 'Добавить', kind: 'primary', onClick: function () {
            if (!input.value.trim()) { error.textContent = 'Введите название узла.'; input.focus(); return false; }
            var node = DB.create('Node', { researchId: research.id, parentId: parent.id, title: input.value.trim() });
            App.store('selected-node:' + research.id, node.id); App.refresh();
          } }
        ] });
      }
      function addConnection() {
        var from = h('select', { class: 'select', 'aria-label': 'Первый узел' }, nodes.map(function (node) { return h('option', { value: node.id }, node.title); }));
        var to = h('select', { class: 'select', 'aria-label': 'Второй узел' }, nodes.map(function (node) { return h('option', { value: node.id }, node.title); }));
        from.value = selected; if (nodes.length > 1) to.value = nodes.filter(function (node) { return node.id !== selected; })[0].id;
        var error = h('p', { class: 'field-error', role: 'alert' });
        App.modal({ title: 'Добавить логическую связь', body: h('div', { class: 'form' }, h('label', { class: 'field' }, 'Первый узел', from), h('label', { class: 'field' }, 'Второй узел', to), error), actions: [
          { label: 'Отмена', kind: 'ghost' }, { label: 'Добавить', kind: 'primary', onClick: function () {
            if (from.value === to.value) { error.textContent = 'Выберите два разных узла.'; return false; }
            if (links.some(function (link) { return (link.fromId === from.value && link.toId === to.value) || (link.fromId === to.value && link.toId === from.value); })) { error.textContent = 'Такая связь уже существует.'; return false; }
            DB.create('Connection', { researchId: research.id, fromId: from.value, toId: to.value }); App.refresh();
          } }
        ] });
      }
      function editNode(node) {
        var input = h('input', { class: 'input', maxlength: '120', value: node.title, 'aria-label': 'Название узла' });
        var error = h('p', { class: 'field-error', role: 'alert' });
        App.modal({ title: 'Редактировать узел', body: h('div', null, input, error), actions: [
          { label: 'Отмена', kind: 'ghost' }, { label: 'Сохранить', kind: 'primary', onClick: function () {
            var value = input.value.trim();
            if (!value) { error.textContent = 'Введите название узла.'; input.focus(); return false; }
            DB.update('Node', node.id, { title: value });
            if (!node.parentId) DB.update('Research', research.id, { title: value });
            App.refresh();
          } }
        ] });
      }
      function graph() {
        var root = nodes.filter(function (node) { return !node.parentId; })[0];
        if (!root) return h('p', null, 'В карте пока нет узлов.');
        var children = function (id) { return nodes.filter(function (node) { return node.parentId === id; }); };
        var first = children(root.id), sides = [[], []], positions = {}, colors = ['#548d9a', '#a77c60', '#7c82ad', '#7f9a70', '#b27787', '#b09555'];
        first.forEach(function (node, i) { sides[i % 2].push({ node: node, color: colors[i % colors.length] }); });
        function depth(node) { var list = children(node.id); return list.length ? 1 + Math.max.apply(null, list.map(depth)) : 1; }
        var leftDepth = sides[0].length ? Math.max.apply(null, sides[0].map(function (item) { return depth(item.node); })) : 0;
        var rightDepth = sides[1].length ? Math.max.apply(null, sides[1].map(function (item) { return depth(item.node); })) : 0;
        var gapX = 245, gapY = 100, rootX = 40 + Math.max(1, leftDepth) * gapX;
        function layout(items, direction) {
          var nextY = 0;
          function place(node, level, color) {
            var descendants = children(node.id), y;
            if (descendants.length) {
              var childY = descendants.map(function (child) { return place(child, level + 1, color); });
              y = (childY[0] + childY[childY.length - 1]) / 2;
            } else { y = nextY; nextY += gapY; }
            positions[node.id] = { x: rootX + direction * level * gapX, y: y, color: color, node: node };
            return y;
          }
          items.forEach(function (item) { place(item.node, 1, item.color); });
          return Math.max(gapY, nextY);
        }
        var leftHeight = layout(sides[0], -1), rightHeight = layout(sides[1], 1);
        var height = Math.max(460, leftHeight + 100, rightHeight + 100);
        Object.keys(positions).forEach(function (id) {
          var point = positions[id], sideHeight = point.x < rootX ? leftHeight : rightHeight;
          point.y += (height - sideHeight) / 2;
        });
        positions[root.id] = { x: rootX, y: (height - 58) / 2, color: '#286d70', node: root };
        var width = rootX + Math.max(1, rightDepth) * gapX + 220;
        var ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg');
        svg.setAttribute('width', width); svg.setAttribute('height', height); svg.setAttribute('aria-hidden', 'true');
        function line(a, b, color, dashed) {
          var path = document.createElementNS(ns, 'path'), ax = a.x + 90, ay = a.y + 29, bx = b.x + 90, by = b.y + 29;
          path.setAttribute('d', 'M ' + ax + ' ' + ay + ' C ' + ((ax + bx) / 2) + ' ' + ay + ', ' + ((ax + bx) / 2) + ' ' + by + ', ' + bx + ' ' + by);
          path.setAttribute('fill', 'none'); path.setAttribute('stroke', color); path.setAttribute('stroke-width', dashed ? '2' : '3');
          if (dashed) path.setAttribute('stroke-dasharray', '6 5');
          svg.appendChild(path);
        }
        Object.keys(positions).forEach(function (id) { var point = positions[id], parent = positions[point.node.parentId]; if (parent) line(parent, point, point.color, false); });
        links.forEach(function (link) { if (positions[link.fromId] && positions[link.toId]) line(positions[link.fromId], positions[link.toId], '#697985', true); });
        return h('div', { class: 'research-canvas', role: 'region', 'aria-label': 'Графическая карта исследования', tabindex: '0' },
          h('div', { class: 'research-graph', style: { width: width + 'px', height: height + 'px' } }, svg, Object.keys(positions).map(function (id) {
            var point = positions[id], node = point.node;
            return h('div', { class: 'research-graph-node', style: { left: point.x + 'px', top: point.y + 'px' } },
              h('button', { class: 'btn research-select', type: 'button', style: { borderColor: point.color }, 'aria-pressed': node.id === selected ? 'true' : 'false', onClick: function () { App.store('selected-node:' + research.id, node.id); App.refresh(); } }, node.title),
              h('button', { class: 'btn btn-ghost research-add', type: 'button', 'aria-label': 'Добавить дочерний узел к «' + node.title + '»', onClick: function () { addChild(node); } }, '+'));
          })));
      }
      var practices = DB.list('Practice', { filter: { researchId: research.id, nodeId: selected } }).items;
      return h('div', null, h('p', null, h('a', { href: '#/research/new' }, '← Исследования')), h('h1', null, research.title), h('p', null, research.question),
        h('div', { class: 'research-workspace' },
          h('section', { class: 'card card-body research-tree', 'aria-label': 'Карта исследования' },
            h('div', { class: 'toolbar', style: { justifyContent: 'space-between', flexWrap: 'wrap' } }, h('h2', { style: { margin: '0' } }, 'Карта исследования'), h('button', { class: 'btn', type: 'button', disabled: nodes.length < 2, onClick: addConnection }, 'Добавить логическую связь')),
            graph(),
            h('div', { class: 'research-links' }, h('h3', null, 'Логические связи'), links.length ? h('ul', null, links.map(function (link) {
              return h('li', null, nodeName(link.fromId) + ' ↔ ' + nodeName(link.toId) + ' ', h('button', { class: 'btn btn-ghost', type: 'button', onClick: function () {
                App.confirm('Удалить связь между «' + nodeName(link.fromId) + '» и «' + nodeName(link.toId) + '»?', { title: 'Удаление связи', confirmLabel: 'Удалить', danger: true }).then(function (confirmed) { if (confirmed) { DB.remove('Connection', link.id); App.refresh(); } });
              } }, 'Удалить'));
            })) : h('p', null, 'Логических связей пока нет.'))),
          h('aside', { class: 'card card-body research-practices', 'aria-label': 'Свойства узла' }, h('h2', null, 'Свойства'),
            selected ? h('div', null, h('p', null, 'Узел: ' + nodeName(selected)), h('button', { class: 'btn', type: 'button', onClick: function () { editNode(nodes.filter(function (node) { return node.id === selected; })[0]); } }, 'Редактировать узел')) : h('p', null, 'Выберите узел на карте.'),
            h('h3', { style: { marginTop: '24px' } }, 'Практики'),
            practices.length ? practices.map(function (practice) { return h('p', null, practice.title); }) : h('p', null, 'Для выбранного узла практик пока нет.'))));
    });
  }});
})();
