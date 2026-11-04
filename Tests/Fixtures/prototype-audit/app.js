// A minimal shell with the contract of the real one: App.plan, App.register, App.load, a hash router, an unbuilt-route panel.
window.App = (function () {
  var screens = {}, plan = [
    { id: 'dashboard', name: 'Dashboard', route: '/dashboard' },
    { id: 'orders', name: 'Orders', route: '/orders' },
    { id: 'customers', name: 'Customers', route: '/customers' },
    { id: 'reports', name: 'Reports', route: '/reports' },
    { id: 'settings', name: 'Settings', route: '/settings' },
    { id: 'trade', name: 'Trade', route: '/trade' },
    { id: 'risky', name: 'Risky', route: '/risky' },
    { id: 'stuck', name: 'Stuck', route: '/stuck' },
    { id: 'ghost', name: 'Ghost', route: '/ghost' },
    { id: 'chain', name: 'Chain', route: '/chain' },
    { id: 'scroller', name: 'Scroller', route: '/scroller' },
    { id: 'folded', name: 'Folded', route: '/folded' },
    { id: 'gate', name: 'Gate', route: '/gate' },
    { id: 'rail', name: 'Rail', route: '/rail' },
    { id: 'order', name: 'Order', route: '/orders/:id' },
    { id: 'confirm', name: 'Confirm', route: '/modals/confirm' }
  ];
  function h(tag, attrs) {
    var el = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) { el.setAttribute(k, attrs[k]); });
    Array.prototype.slice.call(arguments, 2).forEach(function (c) { el.append(c); });
    return el;
  }
  function content(result) {
    if (typeof result === 'string') { var t = document.createElement('div'); t.innerHTML = result; return t; }
    return result;
  }
  function load(fn) {
    var container = h('div', { 'aria-live': 'polite' });
    container.replaceChildren(h('div', { class: 'skeleton', role: 'status', 'aria-label': 'Loading' }, 'Loading…'));
    setTimeout(async function () {
      try { container.replaceChildren(content(await fn())); }
      catch (_) { container.replaceChildren(h('section', { class: 'card', role: 'alert' }, 'Could not load the data.')); }
    }, 350);
    return container;
  }
  function render() {
    var route = location.hash.replace(/^#/, '') || '/dashboard';
    var screen = Object.keys(screens).map(function (k) { return screens[k]; }).filter(function (s) { return s.route === route; })[0];
    var outlet = document.getElementById('outlet');
    if (!outlet) return;
    outlet.replaceChildren(screen ? content(screen.render({ params: {}, query: {} })) : h('section', { class: 'card' }, 'This screen is still being built.'));
  }
  function start() {
    var app = document.getElementById('app');
    var nav = h('nav');
    plan.filter(function (s) { return s.route.indexOf(':') < 0 && s.route.indexOf('/modals/') !== 0; })
      .forEach(function (s) { nav.append(h('a', { href: '#' + s.route }, s.name), ' '); });
    // The header carries a sign-in link, as the real shells do, so the gate screen's button repeats a chrome label (BUG-064).
    app.append(h('header', {}, h('strong', {}, 'Fixture Desk'), nav, h('a', { href: '#/gate' }, 'Sign in')), h('main', { id: 'outlet' }));
    window.addEventListener('hashchange', render);
    render();
  }
  return { plan: plan, h: h, load: load, start: start, register: function (s) { screens[s.id] = s; } };
})();
