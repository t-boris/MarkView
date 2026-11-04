(function () {
  'use strict';
  var h = App.h;
  App.addStyles('.app-shell:has(.app-main[data-screen="new-research"]) .app-nav{display:none}.app-shell:has(.app-main[data-screen="new-research"]) .app-menu-toggle{display:none}.new-research{max-width:960px;margin:0 auto;padding:clamp(24px,5vw,64px) 0}.new-research__eyebrow{color:#7566b5;font-size:12px;font-weight:700;letter-spacing:.12em;text-transform:uppercase}.new-research h1{font-size:clamp(32px,5vw,52px);line-height:1.05;letter-spacing:-.04em;margin:12px 0 32px}.new-research__form{display:grid;gap:16px;padding:clamp(20px,4vw,36px);border:1px solid #ded9ed;border-radius:24px;background:#f8f6fd}.new-research__label{display:grid;gap:12px;font-weight:700}.new-research__input{box-sizing:border-box;width:100%;min-height:150px;resize:vertical;padding:18px;border:1px solid #ccc4df;border-radius:16px;background:#fff;color:#252033;font:inherit;line-height:1.5}.new-research__input:focus-visible,.new-research__button:focus-visible,.new-research__link:focus-visible{outline:3px solid #8c76d6;outline-offset:3px}.new-research__button{justify-self:start;display:inline-flex;align-items:center;gap:24px;padding:13px 18px;border:0;border-radius:14px;background:#443273;color:#fff;font:inherit;font-weight:700;cursor:pointer}.new-research__button:hover{background:#342456}.new-research__button:disabled{opacity:.6;cursor:wait}.new-research__arrow{display:grid;place-items:center;width:28px;height:28px;border-radius:50%;background:rgba(255,255,255,.18);font-size:18px}.new-research__list{margin-top:48px}.new-research__list h2{font-size:22px;letter-spacing:-.02em}.new-research__links{display:grid;gap:10px}.new-research__link{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:18px 20px;border:1px solid #e2deeb;border-radius:16px;color:inherit;text-decoration:none;background:#fff}.new-research__link:hover{border-color:#9584c4;background:#faf8ff}.new-research__link-arrow{color:#7566b5;font-size:20px}@media(max-width:480px){.new-research{padding:24px 0}.new-research__button{width:100%;justify-content:space-between}}');
  App.register({ id: 'new-research', route: '/research/new', title: 'Новое исследование', render: function () {
    return App.load(function () {
      var question = h('textarea', { class: 'new-research__input', id: 'research-question', required: true });
      var error = h('p', { class: 'field-error', role: 'alert' });
      var submit = h('button', { class: 'new-research__button', type: 'submit' }, h('span', null, 'Создать исследование'), h('span', { class: 'new-research__arrow', 'aria-hidden': 'true' }, '↗'));
      var form = h('form', { class: 'new-research__form', onSubmit: function (event) {
        event.preventDefault();
        var value = question.value.trim();
        if (!value) { error.textContent = 'Введите вопрос исследования.'; question.focus(); return; }
        error.textContent = '';
        submit.disabled = true;
        submit.textContent = 'Подготавливаем исследование…';
        setTimeout(function () {
          var subject = value.replace(/[?!.]+\s*$/, '').trim();
          var title = 'Research: ' + subject;
          if (title.length > 120) title = title.slice(0, 117).trimEnd() + '…';
          var research = DB.create('Research', { title: title, question: value });
          DB.create('Node', { researchId: research.id, parentId: '', title: research.title });
          App.store('selected-node:' + research.id, '');
          App.navigate('/research/' + encodeURIComponent(research.id));
        }, 350);
      } }, h('label', { class: 'new-research__label', for: 'research-question' }, 'Вопрос исследования', question), error, submit);
      var examples = DB.all('Research');
      return h('div', { class: 'new-research' }, h('div', { class: 'new-research__eyebrow' }, 'Карта исследования'), h('h1', null, 'Новое исследование'),
        form,
        h('section', { class: 'new-research__list' }, h('h2', null, 'Исследования'),
          examples.length ? h('div', { class: 'new-research__links' }, examples.map(function (item) {
            return h('a', { class: 'new-research__link', href: '#/research/' + encodeURIComponent(item.id) }, h('span', null, item.title), h('span', { class: 'new-research__link-arrow', 'aria-hidden': 'true' }, '↗'));
          })) : App.empty({ title: 'Исследований пока нет', text: 'Создайте исследование, чтобы открыть его карту.' })));
    });
  }});
})();
