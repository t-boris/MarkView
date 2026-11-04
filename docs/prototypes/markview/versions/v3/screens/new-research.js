(function () {
  'use strict';
  var h = App.h;
  App.register({ id: 'new-research', route: '/research/new', title: 'Новое исследование', render: function () {
    return App.load(function () {
      var title = h('input', { class: 'input', id: 'research-title', required: true, maxlength: '120' });
      var question = h('textarea', { class: 'input', id: 'research-question', required: true });
      var error = h('p', { class: 'field-error', role: 'alert' });
      var form = h('form', { class: 'form', onSubmit: function (event) {
        event.preventDefault();
        if (!title.value.trim() || !question.value.trim()) { error.textContent = 'Укажите название и вопрос исследования.'; return; }
        var research = DB.create('Research', { title: title.value.trim(), question: question.value.trim() });
        DB.create('Node', { researchId: research.id, parentId: '', title: research.title });
        App.navigate('/research/' + encodeURIComponent(research.id));
      } }, h('label', { class: 'field', for: 'research-title' }, 'Название исследования', title),
      h('label', { class: 'field', for: 'research-question' }, 'Вопрос исследования', question), error,
      h('button', { class: 'btn btn-primary', type: 'submit' }, 'Создать исследование'));
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
