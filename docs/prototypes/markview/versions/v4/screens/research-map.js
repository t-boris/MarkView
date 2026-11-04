(function () {
  'use strict';
  var h = App.h;
  App.addStyles('.research-workspace{display:grid;grid-template-columns:minmax(0,2fr) minmax(250px,1fr);gap:20px;align-items:start}.research-tree,.research-practices{min-width:0}.research-tree ul{list-style:none;margin:0;padding-left:24px;border-left:1px solid #dce3e8}.research-tree>ul{padding-left:0;border:0}.research-tree li{margin:12px 0}.research-node{display:flex;flex-wrap:wrap;align-items:center;gap:8px}.research-node button[aria-pressed=true]{background:#e4f1ef;border-color:#286d70}.research-links{margin:24px 0 0;padding-top:18px;border-top:1px solid #dce3e8}.research-links li{margin:8px 0}.research-practices p{overflow-wrap:anywhere}@media(max-width:760px){.research-workspace{grid-template-columns:1fr}}');
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
      function branch(parentId) {
        var children = nodes.filter(function (node) { return node.parentId === parentId; });
        return children.length ? h('ul', null, children.map(function (node) {
          return h('li', null, h('div', { class: 'research-node' },
            h('button', { class: 'btn', type: 'button', 'aria-pressed': node.id === selected ? 'true' : 'false', onClick: function () { App.store('selected-node:' + research.id, node.id); App.refresh(); } }, node.title),
            h('button', { class: 'btn btn-ghost', type: 'button', 'aria-label': 'Добавить дочерний узел к «' + node.title + '»', onClick: function () { addChild(node); } }, '+')), branch(node.id));
        })) : null;
      }
      var practices = DB.list('Practice', { filter: { researchId: research.id, nodeId: selected } }).items;
      return h('div', null, h('p', null, h('a', { href: '#/research/new' }, '← Исследования')), h('h1', null, research.title), h('p', null, research.question),
        h('div', { class: 'research-workspace' },
          h('section', { class: 'card card-body research-tree', 'aria-label': 'Дерево исследования' },
            h('div', { class: 'toolbar', style: { justifyContent: 'space-between', flexWrap: 'wrap' } }, h('h2', { style: { margin: '0' } }, 'Карта исследования'), h('button', { class: 'btn', type: 'button', disabled: nodes.length < 2, onClick: addConnection }, 'Добавить логическую связь')),
            branch('') || h('p', null, 'В карте пока нет узлов.'),
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
