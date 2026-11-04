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
    .mind-node-wrap{position:absolute;transform:translate(-50%,-50%);z-index:1}.mind-node-wrap:has(.mind-node-menu[open]){z-index:3}.mind-node-wrap .mind-node{position:relative;left:auto;top:auto;transform:none;padding-right:28px}.mind-node-menu{position:absolute;top:4px;right:5px;z-index:2}.mind-node-menu summary{display:grid;place-items:center;width:18px;height:18px;border:0;border-radius:4px;background:transparent;color:inherit;opacity:.5;cursor:pointer;list-style:none;font-size:9px}.mind-node-menu summary:hover,.mind-node-menu[open] summary{opacity:1}.mind-node-wrap:has(.root) .mind-node-menu summary{color:#fff}.mind-node-menu summary::-webkit-details-marker{display:none}.mind-node-actions{position:absolute;right:0;top:20px;display:flex;gap:3px;padding:4px;border:1px solid #dce3e8;border-radius:7px;background:#fff;box-shadow:0 4px 12px #284d4b1a}.mind-icon{display:inline-grid;place-items:center;width:28px;height:28px;flex:none;padding:0;border:1px solid #dce3e8;border-radius:5px;background:#fff;color:#285f62;font-size:14px;cursor:pointer}.mind-icon:disabled{opacity:.4;cursor:not-allowed}.mind-property-row{display:flex;align-items:center;gap:6px}.mind-property-row input{min-width:0;flex:1}.mind-right{padding:16px}.mind-right h2{font-size:16px;margin:0 0 12px}.mind-right h3{font-size:14px;margin:14px 0 6px}.mind-right .mind-small-label{font-size:12px;color:#657384}.mind-right .field-error{margin:2px 0 6px}.mind-right .field-error:empty{display:none}.mind-right .input,.mind-right .select,.mind-right input[type=color]{min-height:28px;height:28px;padding:3px 7px;border-radius:5px;font-size:13px}.mind-right textarea.input{height:120px;min-height:80px;padding:7px;resize:vertical}.mind-right input[type=color]{width:32px;padding:2px;vertical-align:middle}.mind-right select{width:auto;max-width:100%}.mind-right .mind-property-row + .mind-property-row{margin-top:8px}.mind-right .mind-property-row label{display:flex;align-items:center;gap:5px}.mind-right .mind-small-label + .mind-property-row{margin-top:4px}.mind-right p.mind-small-label{margin:6px 0 0}.mind-node-menu summary:focus-visible,.mind-icon:focus-visible{outline:3px solid #78b8b5;outline-offset:2px}
    .mind-heading{background:#172b32;color:#f4f8f5;border:0}.mind-heading a{color:#a8d7c9;text-decoration:none}.mind-heading p{color:#a8bcb9}.mind-toolbar{background:#edf3f0;border:0;padding:12px 18px}.mind-toolbar .btn,.mind-icon{display:inline-grid;place-items:center;width:34px;height:34px;min-height:34px;padding:0;border:0;border-radius:11px;background:#fff;color:#245c55;box-shadow:0 2px 8px #1f514b18;font-size:17px}.mind-toolbar .btn:hover,.mind-icon:hover:not(:disabled){background:#d7ebe3}.mind-toolbar .btn:focus-visible,.mind-icon:focus-visible,.mind-right input:focus-visible,.mind-right textarea:focus-visible{outline:3px solid #71bdaa;outline-offset:2px}.mind-viewport{background-color:#edf3f0;background-image:radial-gradient(#bfd2c9 1px,transparent 1px)}.mind-right{display:flex;flex-direction:column;gap:12px;background:#fbfcfa;padding:22px;overflow:auto}.mind-right .mind-title{width:100%;height:auto;min-height:44px;padding:5px 0;border:0;border-bottom:2px solid transparent;border-radius:0;background:transparent;color:#183c39;font-size:21px;font-weight:700}.mind-right .mind-title:focus{border-bottom-color:#71bdaa}.mind-right .mind-tags{display:flex;flex-wrap:wrap;align-items:center;gap:6px}.mind-right .mind-tag{display:inline-flex;align-items:center;gap:5px;padding:5px 8px;border-radius:9px;background:#e4f0e9;color:#315b50;font-size:12px}.mind-right .mind-tag button{border:0;background:transparent;color:inherit;cursor:pointer;font-size:15px;line-height:1}.mind-right .mind-tag-input{flex:1;min-width:90px;border:0;background:transparent;box-shadow:none}.mind-right .mind-color{display:flex;align-items:center;gap:8px;color:#657384;font-size:12px}.mind-right input[type=color]{width:34px;height:34px;padding:2px;border:0;border-radius:10px;background:#e4f0e9;cursor:pointer}.mind-right h3{margin:4px 0 0;color:#315b50}.mind-right textarea.input{width:100%;height:auto;min-height:180px;flex:1;padding:14px;border:0;border-radius:14px;background:#eff5f1;line-height:1.6;resize:vertical}.mind-right .mind-property-row{flex-wrap:wrap}.mind-right .field-error{color:#b33d48}.mind-node{border-width:2px;box-shadow:0 8px 22px #284d4b1a}.mind-node-menu summary{border-radius:50%;font-size:11px}.mind-node-actions{gap:5px;padding:6px;border:0;border-radius:12px}.mind-divider{background:#dce9e2}.mind-hint{border-radius:12px;background:#ffffffd9;color:#496c61}
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
      function addConnection(node) {
        var from = h('select', { class: 'select', 'aria-label': 'Первый узел' }, nodes.map(function (n) { return h('option', { value: n.id }, n.title); }));
        var to = h('select', { class: 'select', 'aria-label': 'Второй узел' }, nodes.map(function (n) { return h('option', { value: n.id }, n.title); }));
        from.value = node.id; if (nodes.length > 1) to.value = nodes.filter(function (n) { return n.id !== node.id; })[0].id;
        var error = h('p', { class: 'field-error', role: 'alert' });
        App.modal({ title: 'Добавить логическую связь', body: h('div', { class: 'form' }, h('label', { class: 'field' }, 'Первый узел', from), h('label', { class: 'field' }, 'Второй узел', to), error), actions: [
          { label: 'Отмена', kind: 'ghost' }, { label: 'Добавить', kind: 'primary', onClick: function () {
            if (from.value === to.value) { error.textContent = 'Выберите два разных узла.'; return false; }
            if (links.some(function (link) { return (link.fromId === from.value && link.toId === to.value) || (link.fromId === to.value && link.toId === from.value); })) { error.textContent = 'Такая связь уже существует.'; return false; }
            DB.create('Connection', { researchId: research.id, fromId: from.value, toId: to.value }); App.refresh();
          } }
        ] });
      }
      function addOracleChild(parent) {
        var input = h('input', { class: 'input', maxlength: '120', 'aria-label': 'Направление развития темы' });
        var error = h('p', { class: 'field-error', role: 'alert' });
        App.modal({ title: 'Развить тему с оракулом', body: h('div', null, h('p', null, 'Укажите направление для узла «' + parent.title + '».'), input, error), actions: [
          { label: 'Отмена', kind: 'ghost' }, { label: 'Создать ветвь', kind: 'primary', onClick: function () {
            if (!input.value.trim()) { error.textContent = 'Укажите направление.'; input.focus(); return false; }
            var p = positions[parent.id] || { x: 0, y: 0 };
            var count = nodes.filter(function (n) { return n.parentId === parent.id; }).length;
            var node = DB.create('Node', { researchId: research.id, parentId: parent.id, title: input.value.trim(), x: p.x + (p.x < 0 ? -240 : 240), y: p.y + (count - 0.5) * 100 });
            choose(node.id);
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
        Object.keys(elements).forEach(function (id) { elements[id].wrap.style.left = positions[id].x + 'px'; elements[id].wrap.style.top = positions[id].y + 'px'; });
      }
      nodes.forEach(function (node) {
        var p = positions[node.id]; if (!p) return;
        var button = h('button', { type: 'button', class: 'mind-node' + (!node.parentId ? ' root' : node.parentId === (root && root.id) ? ' branch' : ''), 'aria-pressed': node.id === selected ? 'true' : 'false', 'aria-label': node.title + '. Выбрать узел; стрелки перемещают узел', onClick: function () { if (!button.dataset.dragged) choose(node.id); button.dataset.dragged = ''; }, onKeyDown: function (event) {
          var delta = event.shiftKey ? 40 : 10, dx = event.key === 'ArrowLeft' ? -delta : event.key === 'ArrowRight' ? delta : 0, dy = event.key === 'ArrowUp' ? -delta : event.key === 'ArrowDown' ? delta : 0;
          if (!dx && !dy) return; event.preventDefault(); p.x += dx; p.y += dy; DB.update('Node', node.id, { x: p.x, y: p.y }); draw();
        } }, node.title);
        button.style.setProperty('--branch', node.color || p.color[0]); button.style.setProperty('--tint', p.color[1]);
        button.addEventListener('pointerdown', function (event) {
          if (event.button !== 0) return; event.stopPropagation(); button.setPointerCapture(event.pointerId);
          var startX = event.clientX, startY = event.clientY, x = p.x, y = p.y, moved = false;
          function move(e) { var dx = e.clientX - startX, dy = e.clientY - startY; if (Math.abs(dx) + Math.abs(dy) > 3) moved = true; if (moved) { p.x = x + dx / scale; p.y = y + dy / scale; draw(); } }
          function finish() { button.removeEventListener('pointermove', move); button.removeEventListener('pointerup', finish); button.removeEventListener('pointercancel', cancel); if (moved) { button.dataset.dragged = '1'; DB.update('Node', node.id, { x: Math.round(p.x), y: Math.round(p.y) }); } }
          function cancel() { p.x = x; p.y = y; draw(); button.removeEventListener('pointermove', move); button.removeEventListener('pointerup', finish); button.removeEventListener('pointercancel', cancel); }
          button.addEventListener('pointermove', move); button.addEventListener('pointerup', finish); button.addEventListener('pointercancel', cancel);
        });
        function action(label, symbol, handler, disabled) { return h('button', { class: 'mind-icon', type: 'button', title: label, 'aria-label': label, disabled: !!disabled, onClick: function (event) { event.stopPropagation(); menu.open = false; handler(); } }, symbol); }
        var menu = h('details', { class: 'mind-node-menu' }, h('summary', { 'aria-label': 'Действия с узлом «' + node.title + '»', title: 'Действия с узлом' }, '▼'),
          h('div', { class: 'mind-node-actions' }, action('Добавить дочерний узел', '+', function () { addChild(node); }), action('Развить тему с оракулом', '✦', function () { addOracleChild(node); }), action('Добавить логическую связь', '↔', function () { addConnection(node); }, nodes.length < 2), action('Редактировать узел', '✎', function () { editNode(node); }), action('Удалить узел', '🗑', function () { removeNode(node); }, !node.parentId)));
        menu.addEventListener('pointerdown', function (event) { event.stopPropagation(); });
        var wrap = h('div', { class: 'mind-node-wrap' }, button, menu);
        elements[node.id] = { button: button, menu: menu, wrap: wrap }; world.appendChild(wrap);
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
        h('button', { class: 'btn', type: 'button', 'aria-label': 'Уменьшить масштаб', onClick: function () { zoom(scale / 1.2, viewport.clientWidth / 2, viewport.clientHeight / 2); } }, '−'), zoomLabel,
        h('button', { class: 'btn', type: 'button', 'aria-label': 'Увеличить масштаб', onClick: function () { zoom(scale * 1.2, viewport.clientWidth / 2, viewport.clientHeight / 2); } }, '+'),
        h('button', { class: 'btn', type: 'button', title: 'По центру', 'aria-label': 'По центру', onClick: center }, '⊙'));
      var left = h('section', { class: 'mind-left', 'aria-label': 'Карта исследования' }, toolbar, viewport, h('div', { class: 'mind-hint' }, 'Перетаскивайте карту и узлы · колесо мыши меняет масштаб'));
      var current = find(selected);
      var right = h('aside', { class: 'mind-right', 'aria-label': 'Редактирование узла' });
      if (current) {
        var titleInput = h('input', { class: 'input mind-title', maxlength: '120', value: current.title, 'aria-label': 'Название узла' });
        var titleError = h('p', { class: 'field-error', role: 'alert' });
        titleInput.addEventListener('input', function () {
          var value = titleInput.value.trim();
          if (!value) { titleError.textContent = 'Введите название узла.'; return; }
          titleError.textContent = '';
          DB.update('Node', current.id, { title: value });
          if (!current.parentId) DB.update('Research', research.id, { title: value });
          if (elements[current.id]) { elements[current.id].button.textContent = value; elements[current.id].button.setAttribute('aria-label', value + '. Выбрать узел; стрелки перемещают узел'); }
        });
        titleInput.addEventListener('blur', function () { if (!titleInput.value.trim()) { titleInput.value = DB.get('Node', current.id).title; titleError.textContent = ''; } });
        var tags = Array.isArray(current.tags) ? current.tags.slice() : (current.type ? [{ topic: 'Тема', question: 'Вопрос', idea: 'Идея' }[current.type] || current.type] : []);
        var tagInput = h('input', { class: 'input mind-tag-input', maxlength: '120', placeholder: 'Добавить тег', 'aria-label': 'Добавить тег' });
        var tagList = h('div', { class: 'mind-tags' });
        function renderTags() {
          tagList.textContent = '';
          tags.forEach(function (tag, index) { tagList.appendChild(h('span', { class: 'mind-tag' }, tag, h('button', { type: 'button', 'aria-label': 'Удалить тег «' + tag + '»', onClick: function () { tags.splice(index, 1); DB.update('Node', current.id, { tags: tags.slice() }); renderTags(); } }, '×'))); });
          tagList.appendChild(tagInput);
        }
        tagInput.addEventListener('keydown', function (event) {
          if (event.key !== 'Enter') return;
          event.preventDefault();
          var value = tagInput.value.trim();
          if (!value) return;
          if (!tags.some(function (tag) { return tag.toLocaleLowerCase() === value.toLocaleLowerCase(); })) { tags.push(value); DB.update('Node', current.id, { tags: tags.slice() }); }
          tagInput.value = ''; renderTags(); tagInput.focus();
        });
        renderTags();
        var color = h('input', { type: 'color', value: current.color || (positions[current.id] ? positions[current.id].color[0] : '#548d9a'), 'aria-label': 'Цвет узла', title: 'Цвет узла' });
        color.addEventListener('change', function () { DB.update('Node', current.id, { color: color.value }); if (elements[current.id]) elements[current.id].button.style.setProperty('--branch', color.value); });
        var description = h('textarea', { class: 'input', 'aria-label': 'Описание в Markdown', placeholder: 'Добавьте описание в Markdown' }); description.value = current.description || '';
        description.addEventListener('input', function () { DB.update('Node', current.id, { description: description.value }); });
        function insert(before, after, placeholder) { var start = description.selectionStart, end = description.selectionEnd, value = description.value, selectedText = value.slice(start, end) || placeholder; description.value = value.slice(0, start) + before + selectedText + after + value.slice(end); description.dispatchEvent(new Event('input')); description.focus(); description.setSelectionRange(start + before.length, start + before.length + selectedText.length); }
        var formatting = h('div', { class: 'mind-property-row', 'aria-label': 'Форматирование Markdown' },
          h('button', { class: 'mind-icon', type: 'button', title: 'Полужирный', 'aria-label': 'Полужирный', onClick: function () { insert('**', '**', 'текст'); } }, 'Ж'),
          h('button', { class: 'mind-icon', type: 'button', title: 'Курсив', 'aria-label': 'Курсив', onClick: function () { insert('*', '*', 'текст'); } }, 'К'),
          h('button', { class: 'mind-icon', type: 'button', title: 'Ссылка', 'aria-label': 'Ссылка', onClick: function () { insert('[', '](адрес)', 'текст'); } }, '↗'),
          h('button', { class: 'mind-icon', type: 'button', title: 'Изображение', 'aria-label': 'Изображение', onClick: function () { insert('![', '](адрес изображения)', 'описание'); } }, '▧'),
          h('button', { class: 'mind-icon', type: 'button', title: 'Список', 'aria-label': 'Список', onClick: function () { insert('- ', '', 'пункт'); } }, '☷'));
        right.appendChild(titleInput);
        right.appendChild(titleError);
        right.appendChild(tagList);
        right.appendChild(h('label', { class: 'mind-color' }, 'Цвет', color));
        right.appendChild(h('h3', null, 'Описание'));
        right.appendChild(formatting); right.appendChild(description);
      } else right.appendChild(h('p', null, 'Выберите узел на карте.'));
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
