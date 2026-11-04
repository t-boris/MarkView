(function () {
  'use strict';
  var h = App.h;
  App.addStyles(`
    .app-shell:has(.app-main[data-screen="research-map"]) .app-nav,.app-shell:has(.app-main[data-screen="research-map"]) .app-menu-toggle{display:none}
    .app-main[data-screen="research-map"]{padding:0;overflow:hidden}
    .mind-page{height:calc(100vh - 64px);min-height:520px;display:flex;flex-direction:column;background:#f4f7f6}
    .mind-heading{display:flex;align-items:center;gap:18px;padding:15px 24px;background:#fff;border-bottom:1px solid #dce3e8}
    .mind-heading a{white-space:nowrap}.mind-heading h1{font-size:19px;margin:0}.mind-heading p{color:#657384;margin:2px 0 0}
    .mind-workspace{display:flex;flex:1;min-height:0;--panel-width:320px}
    .mind-left{position:relative;min-width:0;flex:1;display:flex;flex-direction:column}
    .mind-right{width:var(--panel-width);min-width:240px;max-width:60%;overflow:auto;background:#fff;padding:24px;box-shadow:-8px 0 30px #253b490a}
    .mind-right h2{font-size:18px;margin-bottom:20px}.mind-right h3{margin:28px 0 12px}.mind-right p{overflow-wrap:anywhere}.mind-right .btn{margin:0 6px 8px 0}
    .mind-divider{width:9px;flex:none;cursor:col-resize;background:#e7eeed;touch-action:none;position:relative}.mind-divider:after{content:'';position:absolute;top:45%;bottom:45%;left:3px;width:3px;border-radius:3px;background:#9eb4b1}.mind-divider:focus-visible{outline-offset:-3px}
    .mind-toolbar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:12px 18px;background:#fff;border-bottom:1px solid #e2e9e8}.mind-toolbar h2{font-size:15px;margin:0 auto 0 0}.mind-toolbar .btn{min-height:34px;padding:6px 10px}.mind-zoom{min-width:48px;text-align:center;color:#526b6b;font-variant-numeric:tabular-nums}
    .mind-viewport{position:relative;flex:1;overflow:hidden;touch-action:none;cursor:grab;background-color:#f7faf9;background-image:radial-gradient(#d8e4e1 1px,transparent 1px);background-size:22px 22px}.mind-viewport.is-panning{cursor:grabbing}.mind-world{position:absolute;left:0;top:0;width:1px;height:1px;transform-origin:0 0}.mind-lines{position:absolute;left:0;top:0;overflow:visible;pointer-events:none}
    .mind-node{position:absolute;transform:translate(-50%,-50%);max-width:220px;min-width:110px;padding:11px 17px;border:1px solid var(--branch);border-radius:18px;background:#fff;color:#263c40;box-shadow:0 5px 18px #284d4b1a;text-align:center;white-space:normal;overflow-wrap:anywhere;line-height:1.3;font-weight:650;cursor:grab;touch-action:none}.mind-node:active{cursor:grabbing}.mind-node.root{min-width:170px;padding:18px 24px;border:0;border-radius:26px;background:#285f62;color:#fff;font-size:16px;box-shadow:0 10px 24px #285f6240}.mind-node.branch{border-radius:22px;background:var(--tint)}.mind-node[aria-pressed="true"]{outline:3px solid #78b8b5;outline-offset:3px}.mind-hint{position:absolute;left:16px;bottom:12px;padding:6px 10px;border-radius:8px;background:#ffffffde;color:#62777a;font-size:12px;pointer-events:none}
    .mind-label{color:#788b8b;text-transform:uppercase;letter-spacing:.08em;font-size:11px;font-weight:700}.mind-selected{font-size:18px;font-weight:700;color:#273d40}.mind-links{padding-left:18px}.mind-links li{margin:10px 0;overflow-wrap:anywhere}.mind-links .btn{min-height:30px;padding:4px 8px}
    @media(max-width:760px){.mind-page{height:auto;min-height:calc(100vh - 64px)}.mind-heading{padding:14px 16px;align-items:flex-start;flex-direction:column;gap:6px}.mind-workspace{display:flex;flex-direction:column}.mind-left{height:58vh;min-height:400px;flex:none}.mind-divider{display:none}.mind-right{width:100%;max-width:none;min-width:0;min-height:240px;border-top:1px solid #dce3e8}.mind-toolbar{padding:10px}.mind-hint{max-width:80%}}
  `);
  App.register({ id: 'research-map', route: '/research/:id', title: 'Карта исследования', render: function (ctx) {
    return App.load(function () {
      var research = DB.get('Research', ctx.params.id);
      if (!research || ctx.proto.empty) return App.empty({ title: 'Исследование не найдено', text: 'Откройте существующее исследование или создайте новое.', action: { label: 'Новое исследование', onClick: function () { App.navigate('/research/new'); } } });
      var nodes = DB.list('Node', { filter: { researchId: research.id } }).items;
      var links = DB.list('Connection', { filter: { researchId: research.id } }).items;
      var root = nodes.filter(function (n) { return !n.parentId; })[0];
      var selected = App.store('selected-node:' + research.id);
      if (!nodes.some(function (n) { return n.id === selected; })) selected = root ? root.id : '';
      function find(id) { return nodes.filter(function (n) { return n.id === id; })[0]; }
      function name(id) { var n = find(id); return n ? n.title : 'Удалённый узел'; }
      function choose(id) { App.store('selected-node:' + research.id, id); App.refresh(); }
      function addChild(parent) {
        var input = h('input', { class: 'input', maxlength: '120', 'aria-label': 'Название дочернего узла' });
        var error = h('p', { class: 'field-error', role: 'alert' });
        App.modal({ title: 'Добавить дочерний узел', body: h('div', null, h('p', null, 'Родительский узел: ' + parent.title), input, error), actions: [
          { label: 'Отмена', kind: 'ghost' }, { label: 'Добавить', kind: 'primary', onClick: function () {
            if (!input.value.trim()) { error.textContent = 'Введите название узла.'; input.focus(); return false; }
            var parentPosition = positions[parent.id] || { x: 0, y: 0 };
            var count = nodes.filter(function (n) { return n.parentId === parent.id; }).length;
            var node = DB.create('Node', { researchId: research.id, parentId: parent.id, title: input.value.trim(), x: parentPosition.x + (parentPosition.x < 0 ? -240 : 240), y: parentPosition.y + (count - 0.5) * 100 });
            choose(node.id);
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
      function removeNode(node) {
        var ids = [node.id];
        for (var i = 0; i < ids.length; i++) nodes.forEach(function (n) { if (n.parentId === ids[i] && ids.indexOf(n.id) < 0) ids.push(n.id); });
        App.confirm('Удалить узел «' + node.title + '»' + (ids.length > 1 ? ' и его дочерние узлы (' + (ids.length - 1) + ')' : '') + '? Связанные практики и логические связи также будут удалены.', { title: 'Удаление узла', confirmLabel: 'Удалить', danger: true }).then(function (confirmed) {
          if (!confirmed) return;
          DB.all('Connection').filter(function (link) { return link.researchId === research.id && (ids.indexOf(link.fromId) >= 0 || ids.indexOf(link.toId) >= 0); }).forEach(function (link) { DB.remove('Connection', link.id); });
          DB.all('Practice').filter(function (p) { return p.researchId === research.id && ids.indexOf(p.nodeId) >= 0; }).forEach(function (p) { DB.remove('Practice', p.id); });
          ids.forEach(function (id) { DB.remove('Node', id); });
          choose(node.parentId);
        });
      }
      function addConnection() {
        var from = h('select', { class: 'select', 'aria-label': 'Первый узел' }, nodes.map(function (n) { return h('option', { value: n.id }, n.title); }));
        var to = h('select', { class: 'select', 'aria-label': 'Второй узел' }, nodes.map(function (n) { return h('option', { value: n.id }, n.title); }));
        from.value = selected; if (nodes.length > 1) to.value = nodes.filter(function (n) { return n.id !== selected; })[0].id;
        var error = h('p', { class: 'field-error', role: 'alert' });
        App.modal({ title: 'Добавить логическую связь', body: h('div', { class: 'form' }, h('label', { class: 'field' }, 'Первый узел', from), h('label', { class: 'field' }, 'Второй узел', to), error), actions: [
          { label: 'Отмена', kind: 'ghost' }, { label: 'Добавить', kind: 'primary', onClick: function () {
            if (from.value === to.value) { error.textContent = 'Выберите два разных узла.'; return false; }
            if (links.some(function (link) { return (link.fromId === from.value && link.toId === to.value) || (link.fromId === to.value && link.toId === from.value); })) { error.textContent = 'Такая связь уже существует.'; return false; }
            DB.create('Connection', { researchId: research.id, fromId: from.value, toId: to.value }); App.refresh();
          } }
        ] });
      }
      var positions = {}, palette = [ ['#548d9a','#eaf5f6'], ['#b08168','#fbf1eb'], ['#8584ad','#f0eff9'], ['#83a074','#eef7eb'], ['#b27787','#faeef1'], ['#b19a59','#faf6e8'] ];
      function children(id) { return nodes.filter(function (n) { return n.parentId === id; }); }
      if (root) {
        positions[root.id] = { x: typeof root.x === 'number' ? root.x : 0, y: typeof root.y === 'number' ? root.y : 0, color: palette[0] };
        var branches = children(root.id), sideCounts = [0, 0];
        branches.forEach(function (branch, index) {
          var side = index % 2 ? 1 : -1, slot = sideCounts[index % 2]++, color = palette[index % palette.length];
          function place(node, level, fallbackX, fallbackY) {
            var p = positions[node.id] = { x: typeof node.x === 'number' ? node.x : fallbackX, y: typeof node.y === 'number' ? node.y : fallbackY, color: color };
            var descendants = children(node.id);
            descendants.forEach(function (child, childIndex) { place(child, level + 1, p.x + side * 230, p.y + (childIndex - (descendants.length - 1) / 2) * 100); });
          }
          place(branch, 1, side * 245, (slot - (Math.ceil((branches.length - index % 2) / 2) - 1) / 2) * 150);
        });
      }
      var viewKey = 'mind-view:' + research.id, savedView = App.store(viewKey) || {}, scale = Math.min(2, Math.max(0.4, Number(savedView.scale) || 1));
      var offset = { x: Number(savedView.x) || 0, y: Number(savedView.y) || 0 }, initialized = false;
      var world = h('div', { class: 'mind-world' }), viewport = h('div', { class: 'mind-viewport', tabindex: '0', role: 'region', 'aria-label': 'Карта исследования. Перетаскивайте фон для перемещения карты, узлы — для изменения их положения.' }, world);
      var ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg'); svg.setAttribute('class', 'mind-lines'); svg.setAttribute('aria-hidden', 'true'); world.appendChild(svg);
      var elements = {};
      function saveView() { App.store(viewKey, { x: offset.x, y: offset.y, scale: scale }); }
      function transform() { world.style.transform = 'translate(' + offset.x + 'px,' + offset.y + 'px) scale(' + scale + ')'; zoomLabel.textContent = Math.round(scale * 100) + '%'; }
      function line(a, b, color, dashed) {
        if (!a || !b) return;
        var path = document.createElementNS(ns, 'path'), mid = (a.x + b.x) / 2;
        path.setAttribute('d', 'M ' + a.x + ' ' + a.y + ' C ' + mid + ' ' + a.y + ', ' + mid + ' ' + b.y + ', ' + b.x + ' ' + b.y);
        path.setAttribute('fill', 'none'); path.setAttribute('stroke', color); path.setAttribute('stroke-width', dashed ? '2' : '3'); path.setAttribute('stroke-linecap', 'round');
        if (dashed) path.setAttribute('stroke-dasharray', '6 6'); svg.appendChild(path);
      }
      function draw() {
        while (svg.firstChild) svg.removeChild(svg.firstChild);
        nodes.forEach(function (n) { if (positions[n.id] && positions[n.parentId]) line(positions[n.parentId], positions[n.id], positions[n.id].color[0], false); });
        links.forEach(function (link) { line(positions[link.fromId], positions[link.toId], '#849395', true); });
        Object.keys(elements).forEach(function (id) { elements[id].style.left = positions[id].x + 'px'; elements[id].style.top = positions[id].y + 'px'; });
      }
      nodes.forEach(function (node) {
        var p = positions[node.id]; if (!p) return;
        var button = h('button', { type: 'button', class: 'mind-node' + (!node.parentId ? ' root' : node.parentId === (root && root.id) ? ' branch' : ''), 'aria-pressed': node.id === selected ? 'true' : 'false', 'aria-label': node.title + '. Выбрать узел; стрелки перемещают узел', onClick: function () { if (!button.dataset.dragged) choose(node.id); button.dataset.dragged = ''; }, onKeyDown: function (event) {
          var delta = event.shiftKey ? 40 : 10, dx = event.key === 'ArrowLeft' ? -delta : event.key === 'ArrowRight' ? delta : 0, dy = event.key === 'ArrowUp' ? -delta : event.key === 'ArrowDown' ? delta : 0;
          if (!dx && !dy) return; event.preventDefault(); p.x += dx; p.y += dy; DB.update('Node', node.id, { x: p.x, y: p.y }); draw();
        } }, node.title);
        button.style.setProperty('--branch', p.color[0]); button.style.setProperty('--tint', p.color[1]);
        button.addEventListener('pointerdown', function (event) {
          if (event.button !== 0) return; event.stopPropagation(); button.setPointerCapture(event.pointerId);
          var startX = event.clientX, startY = event.clientY, x = p.x, y = p.y, moved = false;
          function move(e) { var dx = e.clientX - startX, dy = e.clientY - startY; if (Math.abs(dx) + Math.abs(dy) > 3) moved = true; if (moved) { p.x = x + dx / scale; p.y = y + dy / scale; draw(); } }
          function finish() { button.removeEventListener('pointermove', move); button.removeEventListener('pointerup', finish); button.removeEventListener('pointercancel', cancel); if (moved) { button.dataset.dragged = '1'; DB.update('Node', node.id, { x: Math.round(p.x), y: Math.round(p.y) }); } }
          function cancel() { p.x = x; p.y = y; draw(); button.removeEventListener('pointermove', move); button.removeEventListener('pointerup', finish); button.removeEventListener('pointercancel', cancel); }
          button.addEventListener('pointermove', move); button.addEventListener('pointerup', finish); button.addEventListener('pointercancel', cancel);
        });
        elements[node.id] = button; world.appendChild(button);
      });
      viewport.addEventListener('pointerdown', function (event) {
        if (event.button !== 0 || event.target.closest('.mind-node')) return;
        viewport.setPointerCapture(event.pointerId); viewport.classList.add('is-panning');
        var startX = event.clientX, startY = event.clientY, x = offset.x, y = offset.y;
        function move(e) { offset.x = x + e.clientX - startX; offset.y = y + e.clientY - startY; transform(); }
        function finish() { viewport.classList.remove('is-panning'); viewport.removeEventListener('pointermove', move); viewport.removeEventListener('pointerup', finish); viewport.removeEventListener('pointercancel', finish); saveView(); }
        viewport.addEventListener('pointermove', move); viewport.addEventListener('pointerup', finish); viewport.addEventListener('pointercancel', finish);
      });
      function zoom(next, x, y) { var old = scale; scale = Math.max(0.4, Math.min(2, next)); offset.x = x - (x - offset.x) * scale / old; offset.y = y - (y - offset.y) * scale / old; transform(); saveView(); }
      viewport.addEventListener('wheel', function (event) { event.preventDefault(); var rect = viewport.getBoundingClientRect(); zoom(scale * (event.deltaY < 0 ? 1.1 : 1 / 1.1), event.clientX - rect.left, event.clientY - rect.top); }, { passive: false });
      var zoomLabel = h('span', { class: 'mind-zoom', 'aria-live': 'polite' });
      function center() { offset.x = viewport.clientWidth / 2; offset.y = viewport.clientHeight / 2; scale = 1; transform(); saveView(); }
      var toolbar = h('div', { class: 'mind-toolbar' }, h('h2', null, 'Карта исследования'),
        h('button', { class: 'btn', type: 'button', disabled: nodes.length < 2, onClick: addConnection }, 'Добавить логическую связь'),
        h('button', { class: 'btn', type: 'button', 'aria-label': 'Уменьшить масштаб', onClick: function () { zoom(scale / 1.2, viewport.clientWidth / 2, viewport.clientHeight / 2); } }, '−'), zoomLabel,
        h('button', { class: 'btn', type: 'button', 'aria-label': 'Увеличить масштаб', onClick: function () { zoom(scale * 1.2, viewport.clientWidth / 2, viewport.clientHeight / 2); } }, '+'),
        h('button', { class: 'btn', type: 'button', onClick: center }, 'По центру'));
      var left = h('section', { class: 'mind-left', 'aria-label': 'Карта исследования' }, toolbar, viewport, h('div', { class: 'mind-hint' }, 'Перетаскивайте карту и узлы · колесо мыши меняет масштаб'));
      var current = find(selected), practices = DB.list('Practice', { filter: { researchId: research.id, nodeId: selected } }).items;
      var right = h('aside', { class: 'mind-right', 'aria-label': 'Свойства узла' }, h('h2', null, 'Свойства'),
        current ? h('div', null, h('p', { class: 'mind-label' }, 'Выбранный узел'), h('p', { class: 'mind-selected' }, current.title),
          h('button', { class: 'btn btn-primary', type: 'button', onClick: function () { addChild(current); } }, 'Добавить дочерний узел'),
          h('button', { class: 'btn', type: 'button', onClick: function () { editNode(current); } }, 'Редактировать узел'),
          h('button', { class: 'btn', type: 'button', disabled: !current.parentId, title: !current.parentId ? 'Корневой узел удалить нельзя' : 'Удалить узел', onClick: function () { removeNode(current); } }, 'Удалить узел')) : h('p', null, 'Выберите узел на карте.'),
        h('h3', null, 'Практики'), practices.length ? practices.map(function (p) { return h('p', null, p.title); }) : h('p', null, 'Для выбранного узла практик пока нет.'),
        h('h3', null, 'Логические связи'), links.length ? h('ul', { class: 'mind-links' }, links.map(function (link) { return h('li', null, name(link.fromId) + ' ↔ ' + name(link.toId) + ' ', h('button', { class: 'btn btn-ghost', type: 'button', onClick: function () {
          App.confirm('Удалить связь между «' + name(link.fromId) + '» и «' + name(link.toId) + '»?', { title: 'Удаление связи', confirmLabel: 'Удалить', danger: true }).then(function (confirmed) { if (confirmed) { DB.remove('Connection', link.id); App.refresh(); } });
        } }, 'Удалить')); })) : h('p', null, 'Логических связей пока нет.'));
      var widthKey = 'mind-panel-width', width = Math.max(240, Math.min(600, Number(App.store(widthKey)) || 320));
      var workspace = h('div', { class: 'mind-workspace' });
      function setWidth(value) { var max = Math.min(600, workspace.clientWidth * 0.6); width = Math.max(240, Math.min(max, value)); workspace.style.setProperty('--panel-width', width + 'px'); divider.setAttribute('aria-valuenow', Math.round(width)); App.store(widthKey, width); }
      var divider = h('div', { class: 'mind-divider', role: 'separator', tabindex: '0', 'aria-label': 'Изменить ширину панели свойств', 'aria-orientation': 'vertical', 'aria-valuemin': '240', 'aria-valuemax': '600', 'aria-valuenow': String(width), onKeyDown: function (event) { if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); setWidth(width + (event.key === 'ArrowLeft' ? 20 : -20)); } } });
      divider.addEventListener('pointerdown', function (event) { if (event.button !== 0) return; divider.setPointerCapture(event.pointerId); var start = event.clientX, initial = width; function move(e) { setWidth(initial + start - e.clientX); } function end() { divider.removeEventListener('pointermove', move); divider.removeEventListener('pointerup', end); divider.removeEventListener('pointercancel', end); } divider.addEventListener('pointermove', move); divider.addEventListener('pointerup', end); divider.addEventListener('pointercancel', end); });
      workspace.style.setProperty('--panel-width', width + 'px'); workspace.appendChild(left); workspace.appendChild(divider); workspace.appendChild(right);
      var page = h('div', { class: 'mind-page' }, h('header', { class: 'mind-heading' }, h('a', { href: '#/research/new' }, '← Исследования'), h('div', null, h('h1', null, research.title), h('p', null, research.question))), workspace);
      draw();
      requestAnimationFrame(function () { if (!page.isConnected || initialized) return; initialized = true; if (typeof savedView.x !== 'number' || typeof savedView.y !== 'number') { offset.x = viewport.clientWidth / 2; offset.y = viewport.clientHeight / 2; } transform(); });
      return page;
    });
  }});
})();
