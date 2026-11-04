(function () {
  'use strict';
  var h = App.h;
  App.addStyles('.app-shell:has(.app-main[data-screen="new-research"]) .app-nav{display:none}.app-shell:has(.app-main[data-screen="new-research"]) .app-menu-toggle{display:none}');
  App.register({ id: 'new-research', route: '/research/new', title: 'Новое исследование', render: function () {
    return App.load(function () {
      var question = h('textarea', { class: 'input', id: 'research-question', required: true });
      var error = h('p', { class: 'field-error', role: 'alert' });
      var submit = h('button', { class: 'btn btn-primary', type: 'submit' }, 'Создать исследование');
      var form = h('form', { class: 'form', onSubmit: function (event) {
        event.preventDefault();
        var value = question.value.trim();
        if (!value) { error.textContent = 'Укажите вопрос исследования.'; question.focus(); return; }
        error.textContent = '';
        submit.disabled = true;
        submit.textContent = 'Подготовка исследования…';
        setTimeout(function () {
          var subject = value.replace(/[?!.]+\s*$/, '').trim();
          var title = 'Исследование: ' + subject;
          if (title.length > 120) title = title.slice(0, 117).trimEnd() + '…';
          var research = DB.create('Research', { title: title, question: value });
          DB.create('Node', { researchId: research.id, parentId: '', title: research.title });
          App.store('selected-node:' + research.id, '');
          App.navigate('/research/' + encodeURIComponent(research.id));
        }, 350);
      } }, h('label', { class: 'field', for: 'research-question' }, 'Вопрос исследования', question), error, submit);
      var examples = DB.all('Research');
      return h('div', { style: { maxWidth: '680px', margin: '0 auto' } }, h('h1', null, 'Новое исследование'),
        h('div', { class: 'card card-body' }, form),
        h('h2', { style: { marginTop: '32px' } }, 'Исследования'),
        examples.length ? h('div', { class: 'card card-body' }, examples.map(function (item) {
          return h('p', null, h('a', { href: '#/research/' + encodeURIComponent(item.id) }, item.title));
        })) : App.empty({ title: 'Исследований пока нет', text: 'Создайте исследование, чтобы открыть его карту.' }));
    });
  }});
})();
